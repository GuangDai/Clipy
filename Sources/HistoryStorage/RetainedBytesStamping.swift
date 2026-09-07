/// Logical revision-byte facts. SQLite keeps these counters on history_items
/// and history_state in the same transaction as immutable content references.
import HistoryDomain

internal struct RetainedRevisionScalars: Sendable, Equatable {
    internal let count: Int
    internal let bytes: Int
}

internal enum RetainedBytesStamping {
    internal static func revisionScalars<S: Sequence>(of revisions: S) -> RetainedRevisionScalars
    where S.Element == RevisionRetentionSummary {
        var count = 0
        var bytes = 0
        for revision in revisions {
            count += 1
            bytes += revision.byteCount
        }
        return RetainedRevisionScalars(count: count, bytes: bytes)
    }
}
