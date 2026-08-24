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
            @escaping @MainActor @Sendable (HistoryItemID) -> Void = { _ in }
    ) {
        self.facade = facade
        self.onCommittedRemoval = onCommittedRemoval
    }

    func perform(
        _ request: ExternalRequest
    ) async throws -> ExternalResponse {
        let response = try await facade.perform(request)
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
        try await facade.read(request)
    }
}
