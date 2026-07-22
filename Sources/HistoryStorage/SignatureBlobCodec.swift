/// SignatureBlobV1 / SignatureBlobCodec — the versioned wire value and codec
/// for `HistoryItemRow.canonicalSignatureBlob`, the durable scalar metadata
/// used to rebuild the complete Signature Index without decoding content
/// bytes.
/// Owning spec: docs/05-authority-kernel.md §3.1 (column semantics), §4
/// (versioned storage codecs), §12–§13 (Signature Index lifecycle and
/// startup); gates: docs/06-cross-cutting.md §7.3 (codec round trip) and
/// §7.4 (corruption rejection).
import Foundation
import HistoryCore
import HistoryDomain

// MARK: - Wire values (docs/05-authority-kernel.md §4)

/// Versioned wire value of the Canonical signature blob.
/// docs/05-authority-kernel.md §4
///
/// `formatVersion` is exactly 1 for every blob `SignatureBlobCodec` writes;
/// decode rejects any other version.
internal struct SignatureBlobV1: Codable, Sendable {
    internal let formatVersion: UInt16
    internal let entries: [StoredSignatureEntryV1]
}

/// One stored signature entry. docs/05-authority-kernel.md §4
///
/// Signature evidence only: it accelerates dedup candidacy and never
/// completes a match by itself — byte-exact confirmation decides every match
/// (docs/02-domain.md §2.2, D7).
internal struct StoredSignatureEntryV1: Codable, Sendable {
    internal let typeIdentifier: String
    internal let fingerprint: UInt64
    internal let byteCount: Int
}

// MARK: - Codec (docs/05-authority-kernel.md §4)

/// Encodes validated Canonical signature entries to their durable blob and
/// decodes the blob back with the full §4 check set, failing closed with
/// `CodecRejection`. docs/05-authority-kernel.md §4
internal enum SignatureBlobCodec {
    /// The only blob version this codec reads or writes (§4: "known blob
    /// version (exactly 1 for each V1 blob)").
    private static let formatVersion: UInt16 = 1

    // MARK: Encode

    /// Encodes validated signature entries deterministically (§4: "Encode
    /// starts from validated Domain/stamped values and is deterministic").
    /// Entries derive one-to-one from Canonical representations in their
    /// normalized order (Part V §6.1 step 6), so the written list is sorted
    /// and unique; decode re-verifies every property.
    internal static func encode(_ entries: [ContentSignatureEntry]) throws -> Data {
        let wire = SignatureBlobV1(
            formatVersion: formatVersion,
            entries: entries.map { entry in
                StoredSignatureEntryV1(
                    typeIdentifier: entry.typeIdentifier,
                    fingerprint: entry.fingerprint.rawValue,
                    byteCount: entry.byteCount
                )
            }
        )
        return try encodeWire(wire)
    }

    // MARK: Decode

    /// Decodes one signature blob with the §4 checks that apply to signature
    /// metadata, failing closed:
    ///
    /// - the blob size is bounded before parsing (§4: "bounded byte/count
    ///   values before any large allocation");
    /// - `formatVersion` is exactly 1;
    /// - the entry list is non-empty and within the Part VI
    ///   representation-count bound (entries correspond one-to-one to
    ///   Canonical representations);
    /// - type identifiers are non-empty, within the Part VI UTF-8 bound,
    ///   unique, and strictly increasing in stable Unicode scalar order;
    /// - every `byteCount` lies in `1...maximumRepresentationBytes`
    ///   (Canonical bytes are non-empty and per-representation bounded).
    ///
    /// Startup (Part V §13) decodes signature metadata without decoding
    /// Canonical bytes; the §4 bidirectional fingerprint/signature coverage
    /// check against the Canonical blob is
    /// `validateCoverage(canonical:entries:)`.
    ///
    /// `limits` is the fixed `HistoryLimits.standard` profile in production
    /// (Part VI §2); focused tests inject smaller bounds.
    internal static func decode(
        _ data: Data,
        limits: HistoryLimits = .standard
    ) throws -> [ContentSignatureEntry] {
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
        guard !wire.entries.isEmpty else {
            throw CodecRejection.emptyList
        }
        guard wire.entries.count <= limits.maximumRepresentationsPerCaptureOrRevision else {
            throw CodecRejection.countExceedsBound(
                found: wire.entries.count,
                bound: limits.maximumRepresentationsPerCaptureOrRevision
            )
        }
        for entry in wire.entries {
            try CodecValidation.validateTypeIdentifier(entry.typeIdentifier, limits: limits)
            guard entry.byteCount >= 1 else {
                throw CodecRejection.nonPositiveSignatureByteCount(found: entry.byteCount)
            }
            guard entry.byteCount <= limits.maximumRepresentationBytes else {
                throw CodecRejection.signatureByteCountExceedsBound(
                    found: entry.byteCount,
                    bound: limits.maximumRepresentationBytes
                )
            }
        }
        try CodecValidation.requireNormalizedTypeIdentifierOrder(
            wire.entries.map(\.typeIdentifier)
        )
        return wire.entries.map { entry in
            ContentSignatureEntry(
                typeIdentifier: entry.typeIdentifier,
                fingerprint: ContentFingerprint(rawValue: entry.fingerprint),
                byteCount: entry.byteCount
            )
        }
    }

    // MARK: Bidirectional coverage (docs/05-authority-kernel.md §4)

    /// The §4 fingerprint/signature coverage check: every Canonical
    /// representation has a signature entry and every signature entry
    /// corresponds to a Canonical representation — no orphan entries. A match
    /// requires the same type identifier, the same stored fingerprint
    /// evidence, and a `byteCount` equal to the representation's byte length.
    ///
    /// Fingerprint *correctness* — recomputing xxh3 over the bytes — is not
    /// re-verified (§4, D7): a fingerprint corrupted identically in both
    /// durable copies may add a spurious dedup candidate but can never
    /// produce a false byte-confirmed match.
    ///
    /// `entries` are expected to come from `decode(_:limits:)` (unique type
    /// identifiers); a hand-built list is checked as given.
    internal static func validateCoverage(
        canonical: CanonicalContent,
        entries: [ContentSignatureEntry]
    ) throws {
        guard canonical.representations.count == entries.count else {
            throw CodecRejection.signatureCoverageCountMismatch(
                canonicalCount: canonical.representations.count,
                signatureCount: entries.count
            )
        }
        var canonicalTypes = Set<String>()
        canonicalTypes.reserveCapacity(canonical.representations.count)
        for representation in canonical.representations {
            canonicalTypes.insert(representation.content.typeIdentifier)
        }
        for entry in entries where !canonicalTypes.contains(entry.typeIdentifier) {
            throw CodecRejection.signatureCoverageOrphanedEntry(
                typeIdentifier: entry.typeIdentifier
            )
        }
        var entriesByType = [String: ContentSignatureEntry](minimumCapacity: entries.count)
        for entry in entries {
            entriesByType[entry.typeIdentifier] = entry
        }
        for representation in canonical.representations {
            let typeIdentifier = representation.content.typeIdentifier
            guard let entry = entriesByType[typeIdentifier] else {
                throw CodecRejection.signatureCoverageMissingEntry(
                    typeIdentifier: typeIdentifier
                )
            }
            guard entry.fingerprint == representation.fingerprint else {
                throw CodecRejection.signatureCoverageFingerprintMismatch(
                    typeIdentifier: typeIdentifier
                )
            }
            guard entry.byteCount == representation.content.bytes.count else {
                throw CodecRejection.signatureCoverageByteCountMismatch(
                    typeIdentifier: typeIdentifier
                )
            }
        }
    }

    // MARK: Decode envelope

    /// The largest serialized size that could still be a valid v1 signature
    /// blob under `limits`; larger inputs are rejected before parsing (§4:
    /// "bounded byte/count values before any large allocation").
    ///
    /// 8× the identifier bound exceeds worst-case `\u00XX` escaping; 256
    /// bytes per entry cover keys, punctuation, and the fingerprint/byteCount
    /// digits; 4,096 covers the fixed container. Generosity is safe: every
    /// exact §4 bound is re-checked after parsing.
    internal static func maximumBlobBytes(limits: HistoryLimits = .standard) -> Int {
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
            4_096,
        ])
    }

    // MARK: Wire serialization

    /// Serializes a wire value with the shared deterministic container
    /// format. Production callers use `encode(_:)`, which builds the wire
    /// value from validated Domain values; this entry point exists so tests
    /// can craft decodable-but-invalid blobs through the exact production
    /// serializer (docs/06-cross-cutting.md §7.4).
    internal static func encodeWire(_ wire: SignatureBlobV1) throws -> Data {
        do {
            return try CodecWireFormat.makeEncoder().encode(wire)
        } catch {
            throw CodecRejection.encodingFailed
        }
    }

    /// Parses the container only, mapping every container failure to
    /// `CodecRejection.malformedBlob`. No §4 validation happens here;
    /// production callers use `decode(_:limits:)`.
    internal static func decodeWire(_ data: Data) throws -> SignatureBlobV1 {
        do {
            return try CodecWireFormat.makeDecoder().decode(SignatureBlobV1.self, from: data)
        } catch {
            throw CodecRejection.malformedBlob
        }
    }
}
