import Foundation

/// A complete, reopenable copy of History and its referenced immutable files.
/// Backup does not change the source's ChangePosition or retention policy.
public struct HistoryBackupReceipt: Sendable, Equatable {
    public let position: ChangePosition
    public let retainedItemCount: Int

    public init(position: ChangePosition, retainedItemCount: Int) {
        self.position = position
        self.retainedItemCount = retainedItemCount
    }
}

/// Destination failures never include paths or clipboard content.
/// Cancellation throws CancellationError; corrupt source values keep their
/// typed HistoryFailure instead of producing an incomplete backup.
public enum HistoryBackupFailure: Error, Sendable, Equatable {
    case invalidDestination
    case destinationAlreadyExists
    case destinationUnavailable
    case writeFailed
}
