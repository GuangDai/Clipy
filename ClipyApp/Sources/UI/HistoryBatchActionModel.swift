import HistoryCore
import Observation

/// A bounded Settings selection runs through the existing receipt owner, one
/// History action at a time (03a §5–§6). Stop leaves the current request alone:
/// its real receipt must still publish every committed presentation purge.
@MainActor @Observable
final class HistoryBatchActionModel {
    enum Operation: Sendable, Equatable {
        case pin, unpin, remove
    }

    struct Failure: Sendable, Equatable {
        let item: HistoryItemReference
        /// History supplies typed failures. A cancelled or unclassified error
        /// has no receipt and must not be presented as a confirmed success.
        let reason: HistoryFailure?
    }

    private let viewState: HistoryViewState
    private(set) var isRunning = false
    private(set) var isStopping = false
    private(set) var wasStopped = false
    private(set) var operation: Operation?
    private(set) var requested: [HistoryItemReference] = []
    private(set) var succeeded: [HistoryItemReference] = []
    private(set) var failures: [Failure] = []
    private(set) var remaining: [HistoryItemReference] = []

    init(viewState: HistoryViewState) { self.viewState = viewState }

    var completedCount: Int { succeeded.count + failures.count }
    var successfulIDs: Set<HistoryItemID> { Set(succeeded.map(\.id)) }
    var failedReferences: [HistoryItemReference] { failures.map(\.item) }

    /// Failure and interruption keep their original selection order even if
    /// observation has moved these items outside the current page window.
    var retryReferences: [HistoryItemReference] {
        let unfinished = Set(failedReferences.map(\.id) + remaining.map(\.id))
        return requested.filter { unfinished.contains($0.id) }
    }

    func stop() {
        guard isRunning else { return }
        isStopping = true
    }

    func execute(_ operation: Operation, references: [HistoryItemReference]) async {
        guard !isRunning, !Task.isCancelled else { return }
        var seen: Set<HistoryItemID> = []
        let items = references.filter { seen.insert($0.id).inserted }
        guard !items.isEmpty else { return }

        self.operation = operation
        requested = items
        remaining = items
        succeeded = []
        failures = []
        isStopping = false
        wasStopped = false
        isRunning = true
        defer {
            wasStopped = !remaining.isEmpty
            isRunning = false
            isStopping = false
        }

        itemsLoop: for item in items {
            guard !isStopping, !Task.isCancelled else { break }
            do {
                switch operation {
                case .pin:
                    // Preserve existing fixed order; append newly pinned rows
                    // in the visible selection order rather than reversing it.
                    let details = try await viewState.details(for: item.id)
                    if details.pinnedPosition == nil {
                        guard !isStopping, !Task.isCancelled else { break itemsLoop }
                        _ = try await viewState.pinAwaitingReceipt(item.id, at: .last)
                    }
                case .unpin:
                    _ = try await viewState.unpinAwaitingReceipt(item.id)
                case .remove:
                    _ = try await viewState.removeAwaitingReceipt(item.id)
                }
                // Even if Stop/close arrived during the await, this completed
                // receipt is authoritative. Never discard it as cancellation.
                succeeded.append(item)
            } catch is CancellationError {
                failures.append(Failure(item: item, reason: nil))
                remaining.removeFirst()
                break
            } catch {
                failures.append(Failure(item: item, reason: error as? HistoryFailure))
            }
            remaining.removeFirst()
            if !remaining.isEmpty { await Task.yield() }
        }
    }
}
