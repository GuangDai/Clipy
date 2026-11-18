/// Public connection-bound App Intents entry into the External Gateway.
/// Owning spec: `V2-05` §6.1/§6.5/§7.1 and roadmap X.6.
import HistoryCore

public struct ExternalHistoryFacade: ExternalHistory, Sendable {
    private let gateway: ExternalGateway
    private let connectionID: ExternalConnectionID

    internal init(
        gateway: ExternalGateway,
        connectionID: ExternalConnectionID
    ) {
        self.gateway = gateway
        self.connectionID = connectionID
    }

    public func perform(
        _ request: ExternalRequest
    ) async throws -> ExternalResponse {
        try await gateway.perform(request, as: connectionID)
    }

    /// The app uses the committed position to retire buffered display state
    /// before returning a successful removal to App Intents.
    public func perform(
        _ request: ExternalRequest,
        onCommittedRemoval: @escaping @Sendable (HistoryItemID, ChangePosition) async -> Void
    ) async throws -> ExternalResponse {
        try await gateway.perform(request, as: connectionID, onCommittedRemoval: onCommittedRemoval)
    }

    public func read(
        _ request: ExternalRead
    ) async throws -> ExternalReadResult {
        try await gateway.read(request, as: connectionID)
    }
}
