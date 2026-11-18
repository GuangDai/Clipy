import Foundation
import HistoryCore
import HistoryDomain

/// Validates version, copy occurrence, and pin scalars read from SQLite rows.
internal enum RevisionStateBlobCodec {
    /// Decodes the row's `contentVersionRaw` (§3.1: "Current Effective
    /// Content version, always at least 1"; §4: "a valid (≥1) Content
    /// Version").
    internal static func decodeContentVersion(_ rawValue: UInt64) throws -> ContentVersion {
        guard rawValue >= 1 else {
            throw CodecRejection.invalidContentVersion(found: rawValue)
        }
        return ContentVersion(rawValue: rawValue)
    }

    /// Decodes the row's occurrence fields into a `CopyOccurrence` (§3.1:
    /// "Full first/last time and source summary"; §4: "valid occurrence
    /// values"). Valid means: a copy count of at least one (the item exists
    /// through an accepted capture), finite first/last timestamps, monotone
    /// recency (D11), and source-application observations within the Part VI
    /// UTF-8 byte bound.
    internal static func decodeOccurrence(
        firstCopiedAt: Date,
        lastCopiedAt: Date,
        copyCount: UInt64,
        firstSource: String?,
        lastSource: String?,
        limits: HistoryLimits = .standard
    ) throws -> CopyOccurrence {
        try validateCopyCount(copyCount)
        try validateFiniteFirstCopiedAt(firstCopiedAt)
        try validateFiniteLastCopiedAt(lastCopiedAt)
        guard lastCopiedAt >= firstCopiedAt else {
            throw CodecRejection.lastCopiedAtPrecedesFirstCopiedAt
        }
        for source in [firstSource, lastSource] {
            try validateSourceObservation(source, limits: limits)
        }
        return CopyOccurrence(
            firstCopiedAt: firstCopiedAt,
            lastCopiedAt: lastCopiedAt,
            count: copyCount,
            firstSource: firstSource,
            lastSource: lastSource
        )
    }

    /// Scalar-only paths consume copy dates without hydrating the complete
    /// occurrence. These validators keep the same fail-closed vocabulary on
    /// recent, search, and source-summary reads as full occurrence decoding.
    internal static func validateFiniteFirstCopiedAt(_ value: Date) throws {
        guard value.timeIntervalSinceReferenceDate.isFinite else {
            throw CodecRejection.nonFiniteFirstCopiedAt
        }
    }

    internal static func validateFiniteLastCopiedAt(_ value: Date) throws {
        guard value.timeIntervalSinceReferenceDate.isFinite else {
            throw CodecRejection.nonFiniteLastCopiedAt
        }
    }

    internal static func validateCopyCount(_ value: UInt64) throws {
        guard value >= 1 else {
            throw CodecRejection.zeroCopyCount
        }
    }

    internal static func validateSourceObservation(
        _ value: String?,
        limits: HistoryLimits = .standard
    ) throws {
        guard let value else { return }
        let utf8ByteCount = value.utf8.count
        guard utf8ByteCount <= limits.maximumSourceApplicationObservationUTF8Bytes else {
            throw CodecRejection.sourceObservationExceedsBound(
                found: utf8ByteCount,
                bound: limits.maximumSourceApplicationObservationUTF8Bytes
            )
        }
    }

    /// Decodes the row's `pinOrdinal` (§3.1: "`nil` is unpinned"; §4: "a
    /// non-negative pin ordinal (negative is corruption)";
    /// docs/architecture.md). The unique-contiguous pinned-order proof is a
    /// separate collection-wide fact load (Part V §7.2), not a per-row check.
    internal static func decodePinOrdinal(_ rawValue: Int?) throws -> PinOrdinal? {
        guard let rawValue else { return nil }
        guard rawValue >= 0 else {
            throw CodecRejection.negativePinOrdinal(found: rawValue)
        }
        return PinOrdinal(rawValue: rawValue)
    }
}
