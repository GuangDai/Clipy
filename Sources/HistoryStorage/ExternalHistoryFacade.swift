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

    public func read(
        _ request: ExternalRead
    ) async throws -> ExternalReadResult {
        try await gateway.read(request, as: connectionID)
    }
}
