/// Internal pre-transport join from exact F1 credential authentication to the
/// unique ExternalGateway. It is deliberately not an ingress facade: no wire
/// framing, peer identity, client custody, cursor, or public DTO is selected.
import Foundation
import HistoryCore

internal enum LocalAutomationBrowsePreviewRequest: Sendable, Equatable {
    case recent(limit: Int, after: HistoryPageCursor? = nil)
    case search(text: String, mode: SearchMode, limit: Int, after: HistoryPageCursor? = nil)

    internal var after: HistoryPageCursor? {
        switch self {
        case .recent(_, let after), .search(_, _, _, let after): after
        }
    }

    internal var externalRead: ExternalRead {
        switch self {
        case .recent(let limit, _):
            .recent(limit: limit)
        case .search(let text, let mode, let limit, _):
            .search(text: text, mode: mode, limit: limit)
        }
    }
}

internal struct LocalAutomationAuthenticatedBrowse: Sendable {
    private let authenticator: LocalAutomationCredentialAuthenticator
    private let gateway: ExternalGateway

    internal init(
        authenticator: LocalAutomationCredentialAuthenticator,
        gateway: ExternalGateway
    ) {
        self.authenticator = authenticator
        self.gateway = gateway
    }

    /// `nil` is the content-free unauthenticated outcome. Exact active or
    /// revoked credentials yield only a durable ID; the Gateway/Authority then
    /// owns audited authorization, revocation, rate, and result publication.
    internal func browsePreview(
        _ request: LocalAutomationBrowsePreviewRequest,
        presenting credential: Data
    ) async throws -> HistoryPage? {
        guard let connection = try await authenticator.authenticate(
            credential
        ) else { return nil }
        return try await gateway.readLocalAutomationBrowsePreview(
            request,
            asAuthenticated: connection
        )
    }
}
