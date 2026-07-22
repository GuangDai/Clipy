/// CanonicalBlobV1 / CanonicalBlobCodec — the versioned wire value and codec
/// for `HistoryItemRow.canonicalBlob`, the immutable Canonical representations
/// including per-representation fingerprint evidence.
/// Owning spec: docs/05-authority-kernel.md §3.1 (column semantics) and §4
/// (versioned storage codecs); gates: docs/06-cross-cutting.md §7.3 (codec
/// round trip) and §7.4 (corruption rejection).
import Foundation
import HistoryCore
import HistoryDomain

// MARK: - Wire values (docs/05-authority-kernel.md §4)

/// Versioned wire value of the Canonical blob. docs/05-authority-kernel.md §4
///
/// `formatVersion` is exactly 1 for every blob `CanonicalBlobCodec` writes;
/// decode rejects any other version.
internal struct CanonicalBlobV1: Codable, Sendable {
    internal let formatVersion: UInt16
    internal let representations: [StoredCanonicalRepresentationV1]
}

/// One stored Canonical representation: its bytes plus the xxh3-64
/// fingerprint evidence computed at ingest (docs/05-authority-kernel.md §3.1,
/// §4). Fingerprint correctness is not re-verified at decode (§4, D7).
internal struct StoredCanonicalRepresentationV1: Codable, Sendable {
    internal let typeIdentifier: String
    internal let bytes: Data
    internal let fingerprint: UInt64
}

// MARK: - Codec (docs/05-authority-kernel.md §4)

/// Encodes validated `CanonicalContent` to its durable blob and decodes the
/// blob back with the full §4 check set, failing closed with
/// `CodecRejection`. docs/05-authority-kernel.md §4
internal enum CanonicalBlobCodec {
    /// The only blob version this codec reads or writes (§4: "known blob
    /// version (exactly 1 for each V1 blob)").
    private static let formatVersion: UInt16 = 1

    // MARK: Encode

    /// Encodes an already-validated `CanonicalContent` deterministically
    /// (§4: "Encode starts from validated Domain/stamped values and is
    /// deterministic"). Preparation (Part V §6.1) has already enforced the
    /// Part VI bounds; decode re-verifies every one of them.
    internal static func encode(_ canonical: CanonicalContent) throws -> Data {
        let wire = CanonicalBlobV1(
            formatVersion: formatVersion,
            representations: canonical.representations.map { representation in
                StoredCanonicalRepresentationV1(
                    typeIdentifier: representation.content.typeIdentifier,
                    bytes: representation.content.bytes,
                    fingerprint: representation.fingerprint.rawValue
                )
            }
        )
        return try encodeWire(wire)
    }

    // MARK: Decode

    /// Decodes one Canonical blob, applying every §4 check that concerns
    /// Canonical representations, failing closed with `CodecRejection`:
    ///
    /// - the blob size is bounded before parsing (§4: "bounded byte/count
    ///   values before any large allocation");
    /// - `formatVersion` is exactly 1;
    /// - the representation list is non-empty and within the Part VI
    ///   representation-count bound;
    /// - type identifiers are non-empty and within the Part VI UTF-8 bound;
    /// - no representation carries empty bytes;
    /// - per-representation and total bytes stay within the Part VI bounds
    ///   (checked arithmetic — no byte-count calculation wraps, Part VI §2);
    /// - Domain normalization (unique identifiers in stable Unicode scalar
    ///   order) is re-proved by constructing through the validating
    ///   `CanonicalContent` initializer (§4: decode "reconstructs Domain
    ///   values through their validators").
    ///
    /// `limits` is the fixed `HistoryLimits.standard` profile in production
    /// (Part VI §2); focused tests inject smaller bounds so the checks run
    /// without large fixtures.
    internal static func decode(
        _ data: Data,
        limits: HistoryLimits = .standard
    ) throws -> CanonicalContent {
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
        guard !wire.representations.isEmpty else {
            throw CodecRejection.emptyList
        }
        guard wire.representations.count <= limits.maximumRepresentationsPerCaptureOrRevision else {
            throw CodecRejection.countExceedsBound(
                found: wire.representations.count,
                bound: limits.maximumRepresentationsPerCaptureOrRevision
            )
        }
        var totalBytes = 0
        for stored in wire.representations {
            try CodecValidation.validateTypeIdentifier(stored.typeIdentifier, limits: limits)
            guard !stored.bytes.isEmpty else {
                throw CodecRejection.emptyBytes(typeIdentifier: stored.typeIdentifier)
            }
            guard stored.bytes.count <= limits.maximumRepresentationBytes else {
                throw CodecRejection.representationBytesExceedBound(
                    found: stored.bytes.count,
                    bound: limits.maximumRepresentationBytes
                )
            }
            let (newTotal, overflow) = totalBytes.addingReportingOverflow(stored.bytes.count)
            guard !overflow else {
                throw CodecRejection.totalBytesExceedBound(
                    found: Int.max,
                    bound: limits.maximumCaptureBytes
                )
            }
            totalBytes = newTotal
        }
        guard totalBytes <= limits.maximumCaptureBytes else {
            throw CodecRejection.totalBytesExceedBound(
                found: totalBytes,
                bound: limits.maximumCaptureBytes
            )
        }
        let representations = wire.representations.map { stored in
            CanonicalRepresentation(
                content: ContentRepresentation(
                    typeIdentifier: stored.typeIdentifier,
                    bytes: stored.bytes
                ),
                fingerprint: ContentFingerprint(rawValue: stored.fingerprint)
            )
        }
        do {
            return try CanonicalContent(representations: representations)
        } catch let rejection as CanonicalContentRejection {
            throw CodecRejection(canonicalRejection: rejection)
        }
    }

    // MARK: Decode envelope

    /// The largest serialized size that could still be a valid v1 Canonical
    /// blob under `limits`; larger inputs are rejected before parsing (§4:
    /// "bounded byte/count values before any large allocation").
    ///
    /// 2× the capture bound exceeds base64's 4/3 inflation of the
    /// representation bytes; 8× the identifier bound exceeds worst-case
    /// `\u00XX` escaping; 256 bytes per representation cover keys,
    /// punctuation, and fingerprint digits; 4,096 covers the fixed container.
    /// Generosity is safe: every exact §4 bound is re-checked after parsing.
    internal static func maximumBlobBytes(limits: HistoryLimits = .standard) -> Int {
        CodecValidation.clampedEnvelopeSum([
            CodecValidation.clampedEnvelopeProduct(limits.maximumCaptureBytes, 2),
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
    internal static func encodeWire(_ wire: CanonicalBlobV1) throws -> Data {
        do {
            return try CodecWireFormat.makeEncoder().encode(wire)
        } catch {
            throw CodecRejection.encodingFailed
        }
    }

    /// Parses the container only, mapping every container failure to
    /// `CodecRejection.malformedBlob`. No §4 validation happens here;
    /// production callers use `decode(_:limits:)`.
    internal static func decodeWire(_ data: Data) throws -> CanonicalBlobV1 {
        do {
            return try CodecWireFormat.makeDecoder().decode(CanonicalBlobV1.self, from: data)
        } catch {
            throw CodecRejection.malformedBlob
        }
    }
}

private extension CodecRejection {
    /// Maps the Domain validator's rejection onto the codec vocabulary (§4:
    /// decode "reconstructs Domain values through their validators"). The
    /// decoder pre-checks every case, so this is a defensive backstop that
    /// preserves the validator's specific diagnosis.
    init(canonicalRejection: CanonicalContentRejection) {
        switch canonicalRejection {
        case .emptyRepresentations:
            self = .emptyList
        case .duplicateTypeIdentifier(let typeIdentifier):
            self = .duplicateTypeIdentifier(typeIdentifier)
        case .emptyBytes(let typeIdentifier):
            self = .emptyBytes(typeIdentifier: typeIdentifier)
        case .nonNormalizedOrder:
            self = .nonNormalizedOrder
        }
    }
}
