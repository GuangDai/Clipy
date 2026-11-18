/// App-owned external History ingress. The connection-bound Storage facade
/// remains UI-free; this concrete adapter joins a successful external remove
/// to the existing panel-surface owner before returning to App Intents
/// (REVIEW Card 9B).
import HistoryCore
import HistoryStorage

struct AppIntentHistoryIngress: ExternalHistory, Sendable {
    private let facade: ExternalHistoryFacade
    private let onCommittedRemoval:
        @MainActor @Sendable (HistoryItemID, ChangePosition) -> Void

    init(
        facade: ExternalHistoryFacade,
        onCommittedRemoval:
            @escaping @MainActor @Sendable (HistoryItemID, ChangePosition) -> Void
    ) {
        self.facade = facade
        self.onCommittedRemoval = onCommittedRemoval
    }

    func perform(
        _ request: ExternalRequest
    ) async throws -> ExternalResponse {
        try Task.checkCancellation()
        do {
            return try await facade.perform(request) { [onCommittedRemoval] itemID, position in
                await onCommittedRemoval(itemID, position)
            }
        } catch {
            // Gateway records cancellation with its typed audit vocabulary.
            // Preserve the invocation's cancellation at the App Intents edge.
            try Task.checkCancellation()
            throw error
        }
    }

    func read(
        _ request: ExternalRead
    ) async throws -> ExternalReadResult {
        try Task.checkCancellation()
        do {
            let result = try await facade.read(request)
            try Task.checkCancellation()
            return result
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }
}
