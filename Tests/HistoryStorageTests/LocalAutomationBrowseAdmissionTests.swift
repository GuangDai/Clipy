/// F1 request-admission and privacy proofs for the internal authenticated
/// Local Automation browse join (`V2-05` §0.3/§3.1/§5.2). These tests
/// stop at the existing product path: no ingress DTO, transport, or public
/// facade is introduced or claimed.
import Foundation
import HistoryCore
import SwiftData
import Synchronization
import Testing
@testable import HistoryStorage

@Suite("Local Automation browse admission", .serialized)
struct LocalAutomationBrowseAdmissionTests {
    private static let connection = ExternalConnectionID(rawValue: UUID(
        uuidString: "00000000-0000-0000-0000-000000004306"
    )!)
    private static let appIntentsConnection = ExternalConnectionID(
        rawValue: UUID(
            uuidString: "00000000-0000-0000-0000-000000004307"
        )!
    )
    private static let secret = Data((0..<32).map { UInt8(0x60 + $0) })
    private static let epoch = Date(
        timeIntervalSinceReferenceDate: 940_000_000
    )

    private struct FixedClock: StorageClock {
        let fixed: Date

        func now() -> Date { fixed }
    }

    private struct Fixture {
        let authority: HistoryAuthority
        let container: ModelContainer
        let credential: LocalAutomationCredential
        let browse: LocalAutomationAuthenticatedBrowse
    }

#if DEBUG
    private final class ReadProbe: Sendable {
        private struct Counts: Sendable {
            var recent = 0
            var search = 0
        }

        private let counts = Mutex(Counts())

        func recordStorage(_ event: StorageLifecycleDebugEvent) {
            guard event.phase == .recentFetchBegin else { return }
            counts.withLock { $0.recent += 1 }
        }

        func recordSearch(_: SearchDebugEvent) {
            counts.withLock { $0.search += 1 }
        }

        var didReachHistoryRead: Bool {
            counts.withLock { $0.recent != 0 || $0.search != 0 }
        }
    }
#endif

    @Test("exact credential rejects invalid bounds before audit, History, or cadence")
    func exactCredentialStillRequiresStructuralAdmission() async throws {
        let fixture = try await Self.makeFixture(compactionCadenceOps: 1)
        let before = try GatewayStoreSnapshot.read(
            in: ModelContext(fixture.container)
        )
#if DEBUG
        let readProbe = ReadProbe()
        await fixture.authority.setStorageLifecycleDebugProbe(
            StorageLifecycleDebugProbe(isEnabled: true) { event in
                readProbe.recordStorage(event)
            }
        )
        await fixture.authority.setSearchDebugProbe(
            SearchDebugProbe(isEnabled: true) { event in
                readProbe.recordSearch(event)
            }
        )
#endif
        // A cadence of one plus this one-shot failure makes any structurally
        // admitted request fail maintenance. Every out-of-bounds request below
        // must instead preserve the exact typed input rejection.
        await fixture.authority.setTransactionFailureInjection(
            .beforeGatewayAuditCompaction
        )
        let invalidRequests: [LocalAutomationBrowsePreviewRequest] = [
            .recent(limit: 0),
            .recent(limit: 501),
            .search(
                text: String(repeating: "a", count: 4_097),
                mode: .exact,
                limit: 1
            ),
            .search(
                text: String(repeating: "a", count: 65),
                mode: .fuzzy,
                limit: 1
            ),
            .search(
                text: String(repeating: "a", count: 513),
                mode: .regexp,
                limit: 1
            ),
        ]

        for request in invalidRequests {
            await #expect(throws:
                ExternalFailure.requestDenied(.invalidInput)
            ) {
                _ = try await fixture.browse.browsePreview(
                    request,
                    presenting: fixture.credential.exactBytes
                )
            }
        }

        #expect(try GatewayStoreSnapshot.read(
            in: ModelContext(fixture.container)
        ) == before)
#if DEBUG
        #expect(!readProbe.didReachHistoryRead)
#endif

        // The armed failure surviving all invalid calls proves none advanced
        // cadence. The first well-formed request reaches maintenance and
        // consumes it before it can read History or append an operation row.
        await #expect(throws: ExternalFailure.persistence(.transaction)) {
            _ = try await fixture.browse.browsePreview(
                .recent(limit: 1),
                presenting: fixture.credential.exactBytes
            )
        }
        #expect(try GatewayStoreSnapshot.read(
            in: ModelContext(fixture.container)
        ) == before)
#if DEBUG
        #expect(!readProbe.didReachHistoryRead)
#endif
    }

    @Test("malformed and wrong credentials stay nil and unaudited")
    func rejectedCredentialsNeverBecomeGatewayRequests() async throws {
        let fixture = try await Self.makeFixture()
        let before = try GatewayStoreSnapshot.read(
            in: ModelContext(fixture.container)
        )
        let exact = fixture.credential.exactBytes
        var wrongSecret = exact
        wrongSecret[LocalAutomationCredential.byteCount - 1] ^= 0x01
        let rejectedPresentations = [
            Data(),
            Data(exact.dropLast()),
            exact + Data([0]),
            wrongSecret,
        ]

        for credential in rejectedPresentations {
            let page = try await fixture.browse.browsePreview(
                .recent(limit: 1),
                presenting: credential
            )
            #expect(page == nil)
        }

        #expect(try GatewayStoreSnapshot.read(
            in: ModelContext(fixture.container)
        ) == before)
    }

    private static func makeFixture(
        compactionCadenceOps: Int = ExternalLimits.standard
            .compactionCadenceOps
    ) async throws -> Fixture {
        let history = try await SwiftDataHistory.open(configuration:
            HistoryConfiguration(persistence: .memory)
        )
        let authority = history.authority
        try await authority.publishVerifiedLocalAutomationEnrollment(
            connection,
            displayName: "Browse admission fixture"
        )
        try await history.grantCapability(.browsePreview, to: connection)
        _ = try await history.perform(.capture(WSSupport.textCapture(
            "local-automation-admission-sentinel",
            observedAt: epoch
        )))

        let credential = try LocalAutomationCredential(
            connection: connection,
            secret: secret
        )
        let authenticator = LocalAutomationCredentialAuthenticator(
            credentialStore: CredentialStore(
                operations: BrowseAdmissionMemoryCredentialOperations(values: [
                    connection: credential.exactBytes,
                ])
            ),
            authority: authority
        )
        let gateway = ExternalGateway(
            authority: authority,
            appIntentsConnectionID: appIntentsConnection,
            rateLimiter: ExternalRateLimiter(initialUptimeNanoseconds: 0),
            limits: GatewayAuditTestSupport.limits(
                compactionCadenceOps: compactionCadenceOps
            ),
            searchWorker: history.searchWorker,
            storageClock: FixedClock(fixed: epoch),
            uptimeNanoseconds: { 0 }
        )
        return Fixture(
            authority: authority,
            container: await authority.container,
            credential: credential,
            browse: LocalAutomationAuthenticatedBrowse(
                authenticator: authenticator,
                gateway: gateway
            )
        )
    }
}

private struct BrowseAdmissionMemoryCredentialOperations:
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
