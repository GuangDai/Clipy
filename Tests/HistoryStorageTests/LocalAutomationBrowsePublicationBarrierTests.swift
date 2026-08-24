/// F1 publication-barrier proofs for the authenticated Local Automation
/// browse join. These stay below ingress/transport and do not claim X.9.
/// Owning spec: `V2-05` §5.2 and DEC-PY-READ-AUDIT.
import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

@Suite("Local Automation browse publication barrier")
struct LocalAutomationBrowsePublicationBarrierTests {
    private static let connection = ExternalConnectionID(rawValue: UUID(
        uuidString: "00000000-0000-0000-0000-000000004307"
    )!)
    private static let secret = Data((0..<32).map { UInt8(0x60 + $0) })
    private static let capturedText =
        "batch43-local-automation-publication-barrier"

    private struct Fixture {
        let history: SwiftDataHistory
        let authority: HistoryAuthority
        let container: ModelContainer
        let credential: LocalAutomationCredential
        let browse: LocalAutomationAuthenticatedBrowse
    }

    private struct HistorySnapshot: Equatable {
        let position: ChangePosition
        let page: HistoryPage
    }

    @Test("admitted recent with a failed audit commit publishes no page")
    func recentAuditCommitFailureIsThePublicationBarrier() async throws {
        let fixture = try await Self.makeFixture()

        try await Self.expectAuditCommitRollback(
            .recent(limit: 10),
            in: fixture
        )
    }

    @Test("admitted search with a failed audit commit publishes no page")
    func searchAuditCommitFailureIsThePublicationBarrier() async throws {
        let fixture = try await Self.makeFixture()

        try await Self.expectAuditCommitRollback(
            .search(
                text: "publication-barrier",
                mode: .exact,
                limit: 10
            ),
            in: fixture
        )
    }

    private static func expectAuditCommitRollback(
        _ request: LocalAutomationBrowsePreviewRequest,
        in fixture: Fixture
    ) async throws {
        let gatewayBefore = try GatewayStoreSnapshot.read(
            in: ModelContext(fixture.container)
        )
        let historyBefore = try await historySnapshot(fixture)
        await fixture.authority.setTransactionFailureInjection(
            .beforeSingletonUpdate
        )

        var publishedPage: HistoryPage?
        do {
            publishedPage = try await fixture.browse.browsePreview(
                request,
                presenting: fixture.credential.exactBytes
            )
            Issue.record("expected the audit transaction failure")
        } catch let failure as ExternalFailure {
            #expect(failure == .persistence(.transaction))
        }

        #expect(publishedPage == nil)
        #expect(try GatewayStoreSnapshot.read(
            in: ModelContext(fixture.container)
        ) == gatewayBefore)
        #expect(try await historySnapshot(fixture) == historyBefore)
    }

    private static func historySnapshot(
        _ fixture: Fixture
    ) async throws -> HistorySnapshot {
        HistorySnapshot(
            position: try await fixture.authority.currentPosition(),
            page: try await fixture.history.browse(HistoryBrowseRequest(
                kind: .recent,
                limit: 10
            ))
        )
    }

    private static func makeFixture() async throws -> Fixture {
        let history = try await SwiftDataHistory.open(configuration:
            HistoryConfiguration(persistence: .memory)
        )
        let authority = history.authority
        try await authority.publishVerifiedLocalAutomationEnrollment(
            connection,
            displayName: "Publication barrier fixture"
        )
        try await history.grantCapability(
            .browsePreview,
            to: connection
        )
        _ = try await history.perform(.capture(WSSupport.textCapture(
            capturedText,
            observedAt: Date(timeIntervalSinceReferenceDate: 943_000_000)
        )))
        let credential = try LocalAutomationCredential(
            connection: connection,
            secret: secret
        )
        let store = CredentialStore(operations:
            PublicationBarrierMemoryCredentialOperations(values: [
                connection: credential.exactBytes,
            ])
        )
        let authenticator = LocalAutomationCredentialAuthenticator(
            credentialStore: store,
            authority: authority
        )
        return Fixture(
            history: history,
            authority: authority,
            container: await authority.container,
            credential: credential,
            browse: LocalAutomationAuthenticatedBrowse(
                authenticator: authenticator,
                gateway: history.externalGateway
            )
        )
    }
}

private struct PublicationBarrierMemoryCredentialOperations:
    CredentialStoreExternalOperations
{
    private var values: [ExternalConnectionID: Data]

    init(values: [ExternalConnectionID: Data]) {
        self.values = values
    }

    mutating func addCredential(
        _ data: Data,
        for connection: ExternalConnectionID
    ) -> CredentialStoreAddResult {
        guard values[connection] == nil else { return .duplicate }
        values[connection] = data
        return .stored
    }

    mutating func copyCredential(
        for connection: ExternalConnectionID
    ) -> CredentialStoreCopyResult {
        values[connection].map(CredentialStoreCopyResult.value) ?? .missing
    }

    mutating func deleteCredential(
        for connection: ExternalConnectionID
    ) -> CredentialStoreDeleteResult {
        values.removeValue(forKey: connection)
        return .deletedOrMissing
    }
}
