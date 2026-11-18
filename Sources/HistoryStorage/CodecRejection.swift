/// Shared support for the v1 versioned storage codecs: the rejection
/// vocabulary with its Part V §16 failure mapping, the normalization checks
/// every decoder applies, and the one deterministic container format.
/// Owning spec: docs/storage.md (versioned storage codecs,
/// decode checks) and §16 (failure translation); bounds:
/// docs/testing.md (Part VI).
import Foundation
import HistoryCore
import HistoryDomain

// MARK: - Codec rejection vocabulary (docs/storage.md)

/// Rejection of a versioned blob at encode or decode time.
/// docs/storage.md
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

    /// A stored list of effective type identifiers is empty.
    case emptyList

    /// A list count exceeds its Part VI bound (§4: "bounded ... count
    /// values").
    case countExceedsBound(found: Int, bound: Int)

    /// A type identifier is the empty string (§4: "non-empty type
    /// identifiers").
    case emptyTypeIdentifier

    /// A type identifier exceeds the Part VI UTF-8 byte bound
    /// (docs/testing.md).
    case typeIdentifierExceedsBound(found: Int, bound: Int)

    /// A type identifier appears more than once (§4: "unique ... type
    /// identifiers"; the decoder does not choose a duplicate).
    case duplicateTypeIdentifier(String)

    /// Type identifiers are not strictly increasing in the stable Unicode
    /// scalar order of a normalized content set (§4: "normalized";
    /// docs/architecture.md).
    case nonNormalizedOrder

    /// A stored title exceeds the Part VI UTF-8 byte bound. Projection fields
    /// are durable derived data and are re-validated on every path that reads
    /// them; corruption is never silently truncated at read time (§4).
    case storedTitleExceedsBound(found: Int, bound: Int)

    /// The bounded title bytes are not strictly valid UTF-8. No replacement
    /// characters or legacy String fallback may repair this projection (§4).
    case invalidStoredTitleUTF8
    case invalidStoredSearchBodyUTF8

    /// A stored search body exceeds the Part VI UTF-8 byte bound, under the
    /// same fail-closed scalar-projection rule as `storedTitleExceedsBound`.
    case storedSearchBodyExceedsBound(found: Int, bound: Int)

    // Copy occurrence, version, and pin scalars decoded from SQLite rows.
    case invalidContentVersion(found: UInt64)
    case zeroCopyCount
    case lastCopiedAtPrecedesFirstCopiedAt
    case nonFiniteFirstCopiedAt
    case nonFiniteLastCopiedAt
    case sourceObservationExceedsBound(found: Int, bound: Int)
    case negativePinOrdinal(found: Int)

    /// Encoding a previously validated value failed. Unreachable for valid
    /// input; an encode-side failure is an internal invariant violation, not
    /// a corrupt stored value (docs/storage.md).
    case encodingFailed
}

extension CodecRejection {
    /// The docs/storage.md boundary mapping: every decode
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
             .storedTitleExceedsBound,
             .invalidStoredTitleUTF8,
             .invalidStoredSearchBodyUTF8,
             .storedSearchBodyExceedsBound,
             .invalidContentVersion,
             .zeroCopyCount,
             .lastCopiedAtPrecedesFirstCopiedAt,
             .nonFiniteFirstCopiedAt,
             .nonFiniteLastCopiedAt,
             .sourceObservationExceedsBound,
             .negativePinOrdinal:
            return .persistence(.corruptStoredValue)
        }
    }
}

/// Applies the one exhaustive codec rejection mapping at every storage
/// boundary. Non-codec errors propagate unchanged (§16).
internal func mapCodecFailure<T>(_ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let rejection as CodecRejection {
        throw rejection.historyFailure
    }
}

// MARK: - Shared normalization checks (docs/storage.md)

/// Normalization checks and envelope arithmetic shared by the v1 blob
/// decoders. docs/storage.md
internal enum CodecValidation {
    /// Item positions are contiguous and each item has its own normalized
    /// representation set. Boundaries are retained in immutable content.
    internal static func requireNormalizedRepresentationOrder(
        _ keys: [ContentRepresentationKey]
    ) throws {
        var seen = Set<ContentRepresentationKey>()
        for key in keys {
            guard seen.insert(key).inserted else {
                throw CodecRejection.duplicateTypeIdentifier(key.typeIdentifier)
            }
        }
        guard keys.first?.pasteboardItemIndex == 0 else {
            throw CodecRejection.nonNormalizedOrder
        }
        for (previous, next) in zip(keys, keys.dropFirst()) {
            guard previous.precedes(next),
                  next.pasteboardItemIndex - previous.pasteboardItemIndex <= 1 else {
                throw CodecRejection.nonNormalizedOrder
            }
        }
    }

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
    /// Unicode scalar order (docs/architecture.md). A repeated identifier
    /// is always diagnosed as a duplicate before any ordering violation,
    /// matching the `CanonicalContent` validator's precedence
    /// (docs/architecture.md).
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
    /// blob — and no byte-count calculation wraps (docs/testing.md
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

// MARK: - Decode-envelope sizing (docs/storage.md)

/// Bounds the type-summary JSON before parsing. The envelope includes space
/// for escaping and structure. The decoder checks exact limits afterward.
internal enum CodecDecodeEnvelope {
    private static let identifierExpansionAllowance = 8
    private static let representationStructuralBytes = 256
    private static let containerStructuralBytes = 4_096

    internal static func effectiveTypeIdentifiers(limits: HistoryLimits) -> Int {
        let oneRepresentation = CodecValidation.clampedEnvelopeSum([
            CodecValidation.clampedEnvelopeProduct(
                limits.maximumTypeIdentifierUTF8Bytes,
                identifierExpansionAllowance
            ),
            representationStructuralBytes,
        ])
        let representations = CodecValidation.clampedEnvelopeProduct(
            limits.maximumRepresentationsPerCaptureOrRevision,
            oneRepresentation
        )
        return CodecValidation.clampedEnvelopeSum([representations, containerStructuralBytes])
    }
}

// MARK: - Container format (docs/storage.md)

/// Deterministic JSON for type summaries and page cursors. Each decoder
/// checks its byte envelope before parsing.
internal enum CodecWireFormat {
    internal static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dataEncodingStrategy = .base64
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }

    internal static func makeDecoder() -> JSONDecoder {
        // A fresh mutable coder is intentional: codec entry points are static
        // and may run under different actors. Sharing JSONDecoder would need
        // an isolated owner and is only justified by measured construction
        // cost rather than assumed per-row allocation savings.
        let decoder = JSONDecoder()
        decoder.dataDecodingStrategy = .base64
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }
}
