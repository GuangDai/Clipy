/// EffectiveTypeIdentifiersBlobV1 / EffectiveTypeIdentifiersBlobCodec — the
/// versioned wire value and codec for
/// `HistoryItemRow.effectiveTypeIdentifiersBlob`, the durable projection of
/// the current Effective Content's type identifiers.
/// Owning spec: docs/05-authority-kernel.md §3.1 (projection fields), §4
/// (versioned storage codecs), §15 (projection rules: "effective type
/// identifiers: sorted unique list"); gates: docs/06-cross-cutting.md §7.3
/// (codec round trip) and §7.4 (corruption rejection).
import Foundation
import HistoryCore

// MARK: - Wire value (docs/05-authority-kernel.md §4)

/// Versioned wire value of the effective type identifiers blob: a sorted,
/// unique, non-empty list at format version 1 (docs/05-authority-kernel.md
/// §4).
internal struct EffectiveTypeIdentifiersBlobV1: Codable, Sendable {
    internal let formatVersion: UInt16
    internal let typeIdentifiers: [String]
}

// MARK: - Codec (docs/05-authority-kernel.md §4)

/// Encodes the validated effective-type-identifiers projection to its
/// durable blob and decodes the blob back with the full §4 check set,
/// failing closed with `CodecRejection`. docs/05-authority-kernel.md §4
internal enum EffectiveTypeIdentifiersBlobCodec {
    /// The only blob version this codec reads or writes (§4: "known blob
    /// version (exactly 1 for each V1 blob)").
    private static let formatVersion: UInt16 = 1

    // MARK: Encode

    /// Encodes the validated projection list deterministically (§4: "Encode
    /// starts from validated Domain/stamped values and is deterministic").
    /// The projector (Part V §15) already produced a sorted, unique,
    /// non-empty list; decode re-verifies every property.
    internal static func encode(_ typeIdentifiers: [String]) throws -> Data {
        try encodeWire(
            EffectiveTypeIdentifiersBlobV1(
                formatVersion: formatVersion,
                typeIdentifiers: typeIdentifiers
            )
        )
    }

    // MARK: Decode

    /// Decodes the blob, requiring exactly §4's "valid versioned
    /// sorted-unique list", failing closed:
    ///
    /// - the blob size is bounded before parsing (§4: "bounded byte/count
    ///   values before any large allocation");
    /// - `formatVersion` is exactly 1;
    /// - the list is non-empty and within the Part VI representation-count
    ///   bound (Effective Content has at most that many representations);
    /// - every identifier is non-empty and within the Part VI UTF-8 bound;
    /// - identifiers are unique and strictly increasing in the stable
    ///   Unicode scalar order of a normalized content set
    ///   (docs/02-domain.md §2.1).
    ///
    /// `limits` is the fixed `HistoryLimits.standard` profile in production
    /// (Part VI §2); focused tests inject smaller bounds.
    internal static func decode(
        _ data: Data,
        limits: HistoryLimits = .standard
    ) throws -> [String] {
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
        guard !wire.typeIdentifiers.isEmpty else {
            throw CodecRejection.emptyList
        }
        guard wire.typeIdentifiers.count <= limits.maximumRepresentationsPerCaptureOrRevision else {
            throw CodecRejection.countExceedsBound(
                found: wire.typeIdentifiers.count,
                bound: limits.maximumRepresentationsPerCaptureOrRevision
            )
        }
        for typeIdentifier in wire.typeIdentifiers {
            try CodecValidation.validateTypeIdentifier(typeIdentifier, limits: limits)
        }
        try CodecValidation.requireNormalizedTypeIdentifierOrder(wire.typeIdentifiers)
        return wire.typeIdentifiers
    }

    // MARK: Decode envelope

    /// The largest serialized size that could still be a valid v1 effective
    /// type identifiers blob under `limits`; larger inputs are rejected
    /// before parsing (§4: "bounded byte/count values before any large
    /// allocation").
    ///
    /// 8× the identifier bound exceeds worst-case `\u00XX` escaping; 256
    /// bytes per identifier cover keys and punctuation; 4,096 covers the
    /// fixed container. Generosity is safe: every exact §4 bound is
    /// re-checked after parsing.
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
    /// value from the validated projection; this entry point exists so tests
    /// can craft decodable-but-invalid blobs through the exact production
    /// serializer (docs/06-cross-cutting.md §7.4).
    internal static func encodeWire(_ wire: EffectiveTypeIdentifiersBlobV1) throws -> Data {
        do {
            return try CodecWireFormat.makeEncoder().encode(wire)
        } catch {
            throw CodecRejection.encodingFailed
        }
    }

    /// Parses the container only, mapping every container failure to
    /// `CodecRejection.malformedBlob`. No §4 validation happens here;
    /// production callers use `decode(_:limits:)`.
    internal static func decodeWire(_ data: Data) throws -> EffectiveTypeIdentifiersBlobV1 {
        do {
            return try CodecWireFormat.makeDecoder().decode(
                EffectiveTypeIdentifiersBlobV1.self,
                from: data
            )
        } catch {
            throw CodecRejection.malformedBlob
        }
    }
}
