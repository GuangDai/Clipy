/// RevisionStateBlobV1 / RevisionStateBlobCodec — the versioned wire value and
/// codec for `HistoryItemRow.revisionStateBlob`, the full revision list plus
/// the active Revision ID, together with the §4 row-scalar checks that travel
/// with the revision lineage (Content Version, occurrence values, pin
/// ordinal).
/// Owning spec: docs/05-authority-kernel.md §3.1 (column semantics), §4
/// (versioned storage codecs), §7.3 (revision fact loading); gates:
/// docs/06-cross-cutting.md §7.3 (codec round trip) and §7.4 (corruption
/// rejection).
import Foundation
import HistoryCore
import HistoryDomain

// MARK: - Wire values (docs/05-authority-kernel.md §4)

/// Versioned wire value of the revision-state blob. docs/05-authority-kernel.md
/// §4
///
/// `formatVersion` is exactly 1 for every blob `RevisionStateBlobCodec`
/// writes; decode rejects any other version. For a Canonical-state item
/// (`activeRevisionID == nil`) the revision list is empty and there are no
/// revision bytes — Effective Content equals Canonical Content (§3.1, D3).
internal struct RevisionStateBlobV1: Codable, Sendable {
    internal let formatVersion: UInt16
    internal let revisions: [StoredRevisionV1]
    internal let activeRevisionID: UUID?
}

/// One stored revision: a complete Effective Content snapshot, not a sparse
/// action map (docs/02-domain.md §2.5). The active revision alone contains
/// every byte required to rebuild current Effective Content after restart.
/// docs/05-authority-kernel.md §4
internal struct StoredRevisionV1: Codable, Sendable {
    internal let id: UUID
    internal let createdAt: Date
    internal let representations: [StoredRepresentationV1]
}

/// One stored representation of a revision's Effective Content snapshot.
/// Unlike a Canonical representation it carries no fingerprint evidence:
/// revision content never feeds the Canonical Signature Index
/// (docs/05-authority-kernel.md §4, §11).
internal struct StoredRepresentationV1: Codable, Sendable {
    internal let typeIdentifier: String
    internal let bytes: Data
}

// MARK: - Revision-state rejection vocabulary (docs/05-authority-kernel.md §4)

/// Rejection of revision-state decode checks the shared `CodecRejection`
/// vocabulary does not cover. docs/05-authority-kernel.md §4
///
/// The generic checks (blob version, decode envelope, byte/count bounds,
/// normalization, empty bytes) throw the shared `CodecRejection` cases; only
/// the revision-lineage- and row-scalar-specific checks use this vocabulary.
/// A later refactor can fold these cases into the shared enum.
internal enum RevisionStateCodecRejection: Error, Sendable, Equatable {
    /// Two stored revisions carry the same Revision ID (§4: "unique revision
    /// IDs"; the decoder does not choose a duplicate).
    case duplicateRevisionID(UUID)

    /// The non-nil active Revision ID names no stored revision (§4: "when
    /// non-nil it ... names exactly one stored revision";
    /// docs/06-cross-cutting.md §7.4). Revision IDs are already proved
    /// unique, so a match is exactly one revision.
    case activeRevisionIDNamesNoStoredRevision(UUID)

    /// The revision list is non-empty but the active Revision ID is nil
    /// (§4: "`nil` is valid only when the revision list is empty", D3).
    case nonEmptyRevisionListWithNilActiveID

    /// A revision representation's type identifier is not one of the item's
    /// Canonical representation types (§4: "normalized, non-empty revision
    /// content containing only Canonical representation types").
    case nonCanonicalRevisionType(String)

    /// The stored Content Version is zero (§3.1: `contentVersionRaw` is
    /// "always at least 1"; §4: "a valid (≥1) Content Version"). A `UInt64`
    /// raw value cannot be negative, so zero is the only invalid value.
    case invalidContentVersion(found: UInt64)

    /// The stored copy count is zero; a retained item exists only through at
    /// least one accepted capture (§4: "valid occurrence values";
    /// docs/02-domain.md §3.1).
    case zeroCopyCount

    /// The stored last-copied time precedes the first-copied time; occurrence
    /// recency is monotone (§4: "valid occurrence values"; D11).
    case lastCopiedAtPrecedesFirstCopiedAt

    /// A stored source-application observation exceeds the Part VI UTF-8 byte
    /// bound (docs/06-cross-cutting.md §2: 1,024 bytes in `standard`).
    case sourceObservationExceedsBound(found: Int, bound: Int)

    /// The stored pin ordinal is negative (§4: "a non-negative pin ordinal
    /// (negative is corruption)"; docs/02-domain.md §3.2).
    case negativePinOrdinal(found: Int)
}

extension RevisionStateCodecRejection {
    /// The docs/05-authority-kernel.md §16 boundary mapping: every decode
    /// rejection is a corrupt persisted value.
    internal var historyFailure: HistoryFailure {
        .persistence(.corruptStoredValue)
    }
}

// MARK: - Codec (docs/05-authority-kernel.md §4)

/// Encodes validated revision state to its durable blob and decodes the blob
/// back with the full §4 check set, failing closed with `CodecRejection` /
/// `RevisionStateCodecRejection`. docs/05-authority-kernel.md §4
internal enum RevisionStateBlobCodec {
    /// The only blob version this codec reads or writes (§4: "known blob
    /// version (exactly 1 for each V1 blob)").
    private static let formatVersion: UInt16 = 1

    // MARK: Encode

    /// Encodes an already-validated revision list and active Revision ID
    /// deterministically (§4: "Encode starts from validated Domain/stamped
    /// values and is deterministic"). Domain planners (docs/02-domain.md §11)
    /// have already enforced the Part VI revision bounds and the D3 active-ID
    /// coherence; decode re-verifies every one of them.
    internal static func encode(
        revisions: [ContentRevision],
        activeRevisionID: RevisionID?
    ) throws -> Data {
        let wire = RevisionStateBlobV1(
            formatVersion: formatVersion,
            revisions: revisions.map { revision in
                StoredRevisionV1(
                    id: revision.id.rawValue,
                    createdAt: revision.createdAt,
                    representations: revision.content.representations.map { representation in
                        StoredRepresentationV1(
                            typeIdentifier: representation.typeIdentifier,
                            bytes: representation.bytes
                        )
                    }
                )
            },
            activeRevisionID: activeRevisionID?.rawValue
        )
        return try encodeWire(wire)
    }

    // MARK: Decode

    /// Decodes one revision-state blob, applying every §4 check that concerns
    /// the revision lineage, failing closed:
    ///
    /// - the blob size is bounded before parsing (§4: "bounded byte/count
    ///   values before any large allocation");
    /// - `formatVersion` is exactly 1;
    /// - the revision count stays within the Part VI per-item revision bound
    ///   (an empty list is valid — the Canonical state, §3.1);
    /// - every revision's content is a normalized, non-empty content set
    ///   (docs/02-domain.md §2.1): type identifiers non-empty, within the Part
    ///   VI UTF-8 bound, unique, and strictly increasing in stable Unicode
    ///   scalar order; no empty-bytes representation; per-representation,
    ///   per-revision, and total per-item revision bytes within the Part VI
    ///   bounds (checked arithmetic — no byte-count calculation wraps);
    /// - every revision representation type is one of the item's Canonical
    ///   representation types (§4);
    /// - Revision IDs are unique;
    /// - active ID coherence (§4, D3): a non-nil active ID names exactly one
    ///   stored revision; `nil` is valid only when the revision list is empty.
    ///
    /// `canonical` is the item's already-decoded Canonical Content; it
    /// supplies the Canonical type set for the containment check. `limits` is
    /// the fixed `HistoryLimits.standard` profile in production (Part VI §2);
    /// focused tests inject smaller bounds.
    internal static func decode(
        _ data: Data,
        canonical: CanonicalContent,
        limits: HistoryLimits = .standard
    ) throws -> (revisions: [ContentRevision], activeRevisionID: RevisionID?) {
        let envelope = maximumBlobBytes(limits: limits)
        guard data.count <= envelope else {
            throw CodecRejection.blobExceedsDecodeEnvelope(
                found: data.count,
                bound: envelope
            )
        }
        let wire = try decodeWire(data)
        guard wire.formatVersion == formatVersion else {
            throw CodecRejection.unknownBlobVersion(found: wire.formatVersion)
        }
        guard wire.revisions.count <= limits.maximumRevisionsPerItem else {
            throw CodecRejection.countExceedsBound(
                found: wire.revisions.count,
                bound: limits.maximumRevisionsPerItem
            )
        }
        var canonicalTypes = Set<String>()
        canonicalTypes.reserveCapacity(canonical.representations.count)
        for representation in canonical.representations {
            canonicalTypes.insert(representation.content.typeIdentifier)
        }
        var seenRevisionIDs = Set<UUID>()
        seenRevisionIDs.reserveCapacity(wire.revisions.count)
        var totalRevisionBytes = 0
        var revisions: [ContentRevision] = []
        revisions.reserveCapacity(wire.revisions.count)
        for stored in wire.revisions {
            guard !stored.representations.isEmpty else {
                throw CodecRejection.emptyList
            }
            guard stored.representations.count <= limits.maximumRepresentationsPerCaptureOrRevision else {
                throw CodecRejection.countExceedsBound(
                    found: stored.representations.count,
                    bound: limits.maximumRepresentationsPerCaptureOrRevision
                )
            }
            var revisionBytes = 0
            for representation in stored.representations {
                try CodecValidation.validateTypeIdentifier(
                    representation.typeIdentifier,
                    limits: limits
                )
                guard !representation.bytes.isEmpty else {
                    throw CodecRejection.emptyBytes(
                        typeIdentifier: representation.typeIdentifier
                    )
                }
                guard representation.bytes.count <= limits.maximumRepresentationBytes else {
                    throw CodecRejection.representationBytesExceedBound(
                        found: representation.bytes.count,
                        bound: limits.maximumRepresentationBytes
                    )
                }
                let (newRevisionBytes, overflow) = revisionBytes.addingReportingOverflow(
                    representation.bytes.count
                )
                guard !overflow else {
                    throw CodecRejection.totalBytesExceedBound(
                        found: Int.max,
                        bound: limits.maximumProposedRevisionBytes
                    )
                }
                revisionBytes = newRevisionBytes
            }
            guard revisionBytes <= limits.maximumProposedRevisionBytes else {
                throw CodecRejection.totalBytesExceedBound(
                    found: revisionBytes,
                    bound: limits.maximumProposedRevisionBytes
                )
            }
            let (newTotalRevisionBytes, overflow) = totalRevisionBytes.addingReportingOverflow(
                revisionBytes
            )
            guard !overflow else {
                throw CodecRejection.totalBytesExceedBound(
                    found: Int.max,
                    bound: limits.maximumTotalRevisionBytesPerItem
                )
            }
            totalRevisionBytes = newTotalRevisionBytes
            guard totalRevisionBytes <= limits.maximumTotalRevisionBytesPerItem else {
                throw CodecRejection.totalBytesExceedBound(
                    found: totalRevisionBytes,
                    bound: limits.maximumTotalRevisionBytesPerItem
                )
            }
            try CodecValidation.requireNormalizedTypeIdentifierOrder(
                stored.representations.map(\.typeIdentifier)
            )
            for representation in stored.representations
            where !canonicalTypes.contains(representation.typeIdentifier) {
                throw RevisionStateCodecRejection.nonCanonicalRevisionType(
                    representation.typeIdentifier
                )
            }
            guard seenRevisionIDs.insert(stored.id).inserted else {
                throw RevisionStateCodecRejection.duplicateRevisionID(stored.id)
            }
            revisions.append(
                ContentRevision(
                    id: RevisionID(rawValue: stored.id),
                    createdAt: stored.createdAt,
                    content: EffectiveContent(
                        representations: stored.representations.map { representation in
                            ContentRepresentation(
                                typeIdentifier: representation.typeIdentifier,
                                bytes: representation.bytes
                            )
                        }
                    )
                )
            )
        }
        guard let activeRevisionID = wire.activeRevisionID else {
            // D3: a nil active ID is valid only for the Canonical state.
            guard revisions.isEmpty else {
                throw RevisionStateCodecRejection.nonEmptyRevisionListWithNilActiveID
            }
            return (revisions: revisions, activeRevisionID: nil)
        }
        // Revision IDs are unique, so a match names exactly one revision.
        guard revisions.contains(where: { $0.id.rawValue == activeRevisionID }) else {
            throw RevisionStateCodecRejection.activeRevisionIDNamesNoStoredRevision(
                activeRevisionID
            )
        }
        return (revisions: revisions, activeRevisionID: RevisionID(rawValue: activeRevisionID))
    }

    // MARK: Row-scalar decode checks (docs/05-authority-kernel.md §4)

    /// Decodes the row's `contentVersionRaw` (§3.1: "Current Effective
    /// Content version, always at least 1"; §4: "a valid (≥1) Content
    /// Version").
    internal static func decodeContentVersion(_ rawValue: UInt64) throws -> ContentVersion {
        guard rawValue >= 1 else {
            throw RevisionStateCodecRejection.invalidContentVersion(found: rawValue)
        }
        return ContentVersion(rawValue: rawValue)
    }

    /// Decodes the row's occurrence fields into a `CopyOccurrence` (§3.1:
    /// "Full first/last time and source summary"; §4: "valid occurrence
    /// values"). Valid means: a copy count of at least one (the item exists
    /// through an accepted capture), monotone recency (D11), and
    /// source-application observations within the Part VI UTF-8 byte bound.
    internal static func decodeOccurrence(
        firstCopiedAt: Date,
        lastCopiedAt: Date,
        copyCount: UInt64,
        firstSource: String?,
        lastSource: String?,
        limits: HistoryLimits = .standard
    ) throws -> CopyOccurrence {
        guard copyCount >= 1 else {
            throw RevisionStateCodecRejection.zeroCopyCount
        }
        guard lastCopiedAt >= firstCopiedAt else {
            throw RevisionStateCodecRejection.lastCopiedAtPrecedesFirstCopiedAt
        }
        for source in [firstSource, lastSource] {
            guard let source else { continue }
            let utf8ByteCount = source.utf8.count
            guard utf8ByteCount <= limits.maximumSourceApplicationObservationUTF8Bytes else {
                throw RevisionStateCodecRejection.sourceObservationExceedsBound(
                    found: utf8ByteCount,
                    bound: limits.maximumSourceApplicationObservationUTF8Bytes
                )
            }
        }
        return CopyOccurrence(
            firstCopiedAt: firstCopiedAt,
            lastCopiedAt: lastCopiedAt,
            count: copyCount,
            firstSource: firstSource,
            lastSource: lastSource
        )
    }

    /// Decodes the row's `pinOrdinal` (§3.1: "`nil` is unpinned"; §4: "a
    /// non-negative pin ordinal (negative is corruption)";
    /// docs/02-domain.md §3.2). The unique-contiguous pinned-order proof is a
    /// separate collection-wide fact load (Part V §7.2), not a per-row check.
    internal static func decodePinOrdinal(_ rawValue: Int?) throws -> PinOrdinal? {
        guard let rawValue else { return nil }
        guard rawValue >= 0 else {
            throw RevisionStateCodecRejection.negativePinOrdinal(found: rawValue)
        }
        return PinOrdinal(rawValue: rawValue)
    }

    // MARK: Decode envelope

    /// The largest serialized size that could still be a valid v1
    /// revision-state blob under `limits`; larger inputs are rejected before
    /// parsing (§4: "bounded byte/count values before any large allocation").
    ///
    /// 2× the total-revision-bytes bound exceeds base64's 4/3 inflation of
    /// all representation bytes (their sum is bounded by
    /// `maximumTotalRevisionBytesPerItem`); 8× the identifier bound exceeds
    /// worst-case `\u00XX` escaping; 256 bytes per representation cover keys
    /// and punctuation; 128 bytes per revision cover the Revision ID,
    /// `createdAt`, keys, and punctuation; 4,096 covers the fixed container
    /// including the active Revision ID. Generosity is safe: every exact §4
    /// bound is re-checked after parsing.
    internal static func maximumBlobBytes(limits: HistoryLimits = .standard) -> Int {
        CodecValidation.clampedEnvelopeSum([
            CodecValidation.clampedEnvelopeProduct(
                limits.maximumRevisionsPerItem,
                CodecValidation.clampedEnvelopeSum([
                    CodecValidation.clampedEnvelopeProduct(
                        limits.maximumRepresentationsPerCaptureOrRevision,
                        CodecValidation.clampedEnvelopeSum([
                            CodecValidation.clampedEnvelopeProduct(
                                limits.maximumTypeIdentifierUTF8Bytes,
                                8
                            ),
                            256,
                        ])
                    ),
                    128,
                ])
            ),
            CodecValidation.clampedEnvelopeProduct(
                limits.maximumTotalRevisionBytesPerItem,
                2
            ),
            4_096,
        ])
    }

    // MARK: Wire serialization

    /// Serializes a wire value with the shared deterministic container
    /// format. Production callers use `encode(revisions:activeRevisionID:)`,
    /// which builds the wire value from validated Domain values; this entry
    /// point exists so tests can craft decodable-but-invalid blobs through
    /// the exact production serializer (docs/06-cross-cutting.md §7.4).
    internal static func encodeWire(_ wire: RevisionStateBlobV1) throws -> Data {
        do {
            return try CodecWireFormat.makeEncoder().encode(wire)
        } catch {
            throw CodecRejection.encodingFailed
        }
    }

    /// Parses the container only, mapping every container failure to
    /// `CodecRejection.malformedBlob`. No §4 validation happens here;
    /// production callers use `decode(_:canonical:limits:)`.
    internal static func decodeWire(_ data: Data) throws -> RevisionStateBlobV1 {
        do {
            return try CodecWireFormat.makeDecoder().decode(RevisionStateBlobV1.self, from: data)
        } catch {
            throw CodecRejection.malformedBlob
        }
    }
}
