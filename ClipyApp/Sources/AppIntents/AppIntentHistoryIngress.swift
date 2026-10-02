/// App-owned external History ingress. The connection-bound Storage facade
/// remains UI-free; this concrete adapter joins a successful external remove
/// to the existing panel-surface owner before returning to App Intents
/// (REVIEW Card 9B).
import HistoryCore
import HistoryStorage

struct AppIntentHistoryIngress: ExternalHistory, Sendable {
    private let facade: ExternalHistoryFacade
    private let onCommittedRemoval:
        @MainActor @Sendable (HistoryItemID) -> Void

    init(
        facade: ExternalHistoryFacade,
        onCommittedRemoval:
            @escaping @MainActor @Sendable (HistoryItemID) -> Void
    ) {
        self.facade = facade
        self.onCommittedRemoval = onCommittedRemoval
    }

    func perform(
        _ request: ExternalRequest
    ) async throws -> ExternalResponse {
        try Task.checkCancellation()
        let response: ExternalResponse
        do {
            response = try await facade.perform(request)
        } catch {
            // Gateway records cancellation with its typed audit vocabulary.
            // Preserve the invocation's cancellation at the App Intents edge.
            try Task.checkCancellation()
            throw error
        }
        switch request {
        case .pin, .unpin:
            break
        case .remove(let itemID):
            switch response {
            case .removed(let count) where count > 0:
                await onCommittedRemoval(itemID)
            case .removed, .unchanged, .pin, .unpin:
                break
            }
        }
        return response
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
