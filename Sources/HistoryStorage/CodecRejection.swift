/// Shared support for the v1 versioned storage codecs: the rejection
/// vocabulary with its Part V §16 failure mapping, the normalization checks
/// every decoder applies, and the one deterministic container format.
/// Owning spec: docs/05-authority-kernel.md §4 (versioned storage codecs,
/// decode checks) and §16 (failure translation); bounds:
/// docs/06-cross-cutting.md §2 (Part VI).
import Foundation
import HistoryCore

// MARK: - Codec rejection vocabulary (docs/05-authority-kernel.md §4)

/// Rejection of a versioned blob at encode or decode time.
/// docs/05-authority-kernel.md §4
///
/// Decode is not a blind memberwise conversion and never silently drops a bad
/// representation, chooses a duplicate, resets to Canonical, or repairs
/// anything locally (§4): the first violated §4 check throws one of these
/// cases and the whole load fails closed.
internal enum CodecRejection: Error, Sendable, Equatable {
    /// The bytes are not a decodable v1 container at all — foreign bytes,
    /// truncation, or a well-formed container of the wrong shape (§4: decode
    /// is not a blind memberwise conversion).
    case malformedBlob

    /// `formatVersion` is not exactly 1 (§4: "known blob version").
    case unknownBlobVersion(found: UInt16)

    /// The raw blob exceeds the pre-decode envelope derived from the Part VI
    /// bounds and so cannot be any valid v1 payload; rejected before parsing
    /// performs any large allocation (§4: "bounded byte/count values before
    /// any large allocation").
    case blobExceedsDecodeEnvelope(found: Int, bound: Int)

    /// A list §4 requires to be non-empty is empty (Canonical
    /// representations, signature entries, or effective type identifiers).
    case emptyList

    /// A list count exceeds its Part VI bound (§4: "bounded ... count
    /// values").
    case countExceedsBound(found: Int, bound: Int)

    /// A type identifier is the empty string (§4: "non-empty type
    /// identifiers").
    case emptyTypeIdentifier

    /// A type identifier exceeds the Part VI UTF-8 byte bound
    /// (docs/06-cross-cutting.md §2).
    case typeIdentifierExceedsBound(found: Int, bound: Int)

    /// A type identifier appears more than once (§4: "unique ... type
    /// identifiers"; the decoder does not choose a duplicate).
    case duplicateTypeIdentifier(String)

    /// Type identifiers are not strictly increasing in the stable Unicode
    /// scalar order of a normalized content set (§4: "normalized";
    /// docs/02-domain.md §2.1).
    case nonNormalizedOrder

    /// A representation carries zero-length bytes (§4: "no empty-bytes
    /// representation").
    case emptyBytes(typeIdentifier: String)

    /// One representation's bytes exceed the Part VI per-representation
    /// bound.
    case representationBytesExceedBound(found: Int, bound: Int)

    /// Total Canonical representation bytes exceed the Part VI per-capture
    /// bound. Totals use checked arithmetic — no byte-count calculation wraps
    /// (docs/06-cross-cutting.md §2).
    case totalBytesExceedBound(found: Int, bound: Int)

    /// A signature entry's `byteCount` is below 1; Canonical bytes are
    /// non-empty, so a non-positive stored count is corruption (§4).
    case nonPositiveSignatureByteCount(found: Int)

    /// A signature entry's `byteCount` exceeds the Part VI per-representation
    /// byte bound (§4: "bounded byte/count values").
    case signatureByteCountExceedsBound(found: Int, bound: Int)

    /// The signature entry count differs from the Canonical representation
    /// count (§4: fingerprint/signature coverage is checked bidirectionally).
    case signatureCoverageCountMismatch(canonicalCount: Int, signatureCount: Int)

    /// A Canonical representation has no signature entry (§4: "every
    /// Canonical representation has a signature entry").
    case signatureCoverageMissingEntry(typeIdentifier: String)

    /// A signature entry names no Canonical representation (§4: "no orphan
    /// entries").
    case signatureCoverageOrphanedEntry(typeIdentifier: String)

    /// A signature entry's fingerprint differs from the fingerprint evidence
    /// stored with its Canonical representation. Fingerprint *correctness* —
    /// recomputing xxh3 over the bytes — is deliberately not re-verified at
    /// decode (§4, D7); this check only requires the two durable copies of
    /// the same evidence to agree.
    case signatureCoverageFingerprintMismatch(typeIdentifier: String)

    /// A signature entry's `byteCount` differs from its Canonical
    /// representation's byte length (§4: bidirectional coverage).
    case signatureCoverageByteCountMismatch(typeIdentifier: String)

    /// Encoding a previously validated value failed. Unreachable for valid
    /// input; an encode-side failure is an internal invariant violation, not
    /// a corrupt stored value (docs/05-authority-kernel.md §16).
    case encodingFailed
}

extension CodecRejection {
    /// The docs/05-authority-kernel.md §16 boundary mapping: every decode
    /// rejection is a corrupt persisted value; the encode-side backstop is a
    /// storage invariant violation.
    internal var historyFailure: HistoryFailure {
        switch self {
        case .encodingFailed:
            return .persistence(.invariantViolation)
        case .malformedBlob,
             .unknownBlobVersion,
             .blobExceedsDecodeEnvelope,
             .emptyList,
             .countExceedsBound,
             .emptyTypeIdentifier,
             .typeIdentifierExceedsBound,
             .duplicateTypeIdentifier,
             .nonNormalizedOrder,
             .emptyBytes,
             .representationBytesExceedBound,
             .totalBytesExceedBound,
             .nonPositiveSignatureByteCount,
             .signatureByteCountExceedsBound,
             .signatureCoverageCountMismatch,
             .signatureCoverageMissingEntry,
             .signatureCoverageOrphanedEntry,
             .signatureCoverageFingerprintMismatch,
             .signatureCoverageByteCountMismatch:
            return .persistence(.corruptStoredValue)
        }
    }
}

// MARK: - Shared normalization checks (docs/05-authority-kernel.md §4)

/// Normalization checks and envelope arithmetic shared by the v1 blob
/// decoders. docs/05-authority-kernel.md §4
internal enum CodecValidation {
    /// §4: a type identifier is non-empty and within the Part VI UTF-8 byte
    /// bound.
    internal static func validateTypeIdentifier(
        _ typeIdentifier: String,
        limits: HistoryLimits
    ) throws {
        guard !typeIdentifier.isEmpty else {
            throw CodecRejection.emptyTypeIdentifier
        }
        let utf8ByteCount = typeIdentifier.utf8.count
        guard utf8ByteCount <= limits.maximumTypeIdentifierUTF8Bytes else {
            throw CodecRejection.typeIdentifierExceedsBound(
                found: utf8ByteCount,
                bound: limits.maximumTypeIdentifierUTF8Bytes
            )
        }
    }

    /// §4: type identifiers are unique and strictly increasing in the stable
    /// Unicode scalar order (docs/02-domain.md §2.1). A repeated identifier
    /// is always diagnosed as a duplicate before any ordering violation,
    /// matching the `CanonicalContent` validator's precedence
    /// (docs/02-domain.md §2.3).
    internal static func requireNormalizedTypeIdentifierOrder(
        _ typeIdentifiers: [String]
    ) throws {
        var seen = Set<String>()
        seen.reserveCapacity(typeIdentifiers.count)
        for typeIdentifier in typeIdentifiers {
            guard seen.insert(typeIdentifier).inserted else {
                throw CodecRejection.duplicateTypeIdentifier(typeIdentifier)
            }
        }
        for (previous, next) in zip(typeIdentifiers, typeIdentifiers.dropFirst()) {
            guard previous.unicodeScalars.lexicographicallyPrecedes(next.unicodeScalars) else {
                throw CodecRejection.nonNormalizedOrder
            }
        }
    }

    /// Checked sum for decode-envelope estimates, clamping to `Int.max` on
    /// overflow. The envelope is only a pre-parse gate and the exact §4 bound
    /// checks still run after parsing, so clamping can never admit an invalid
    /// blob — and no byte-count calculation wraps (docs/06-cross-cutting.md
    /// §2).
    internal static func clampedEnvelopeSum(_ terms: [Int]) -> Int {
        var total = 0
        for term in terms {
            let (sum, overflow) = total.addingReportingOverflow(term)
            guard !overflow else { return Int.max }
            total = sum
        }
        return total
    }

    /// Checked product with the same clamping contract as
    /// `clampedEnvelopeSum(_:)`.
    internal static func clampedEnvelopeProduct(_ lhs: Int, _ rhs: Int) -> Int {
        let (product, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? Int.max : product
    }
}

// MARK: - Container format (docs/05-authority-kernel.md §4)

/// The one deterministic container format shared by the v1 blob codecs.
/// docs/05-authority-kernel.md §4
///
/// JSON with sorted keys: a property-list integer is a signed 64-bit value,
/// so full-range `UInt64` fingerprints are not safely representable there,
/// while JSON round-trips them exactly; base64 `Data` encoding and a
/// canonical key order make encoding one validated value twice yield
/// identical bytes (§4: "Encode ... is deterministic").
internal enum CodecWireFormat {
    internal static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    internal static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}
