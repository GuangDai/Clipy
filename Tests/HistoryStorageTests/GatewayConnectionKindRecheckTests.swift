/// Batch 17 authoritative connection-kind recheck proofs.
/// Owning spec: `V2-05` §3.1/§4.5/§5.2 and roadmap X.9/F1.
import Foundation
import HistoryCore
import Synchronization
import Testing
@testable import HistoryStorage

// Every case opens and seeds a complete current store. Serializing this suite keeps
// five temporary SQLite startup paths from competing at once with the
// MainActor-driven PresentationUI suites in the package-wide test process.
@Suite("Gateway authoritative connection-kind recheck", .serialized)
struct GatewayConnectionKindRecheckTests {
    private static let epoch = Date(
        timeIntervalSinceReferenceDate: 915_000_000
    )
    private static let absentItemID = HistoryItemID(rawValue: UUID(
        uuidString: "00000000-0000-0000-0000-000000001701"
    )!)
    private static let localAutomationConnection = ExternalConnectionID(
        rawValue: UUID(
            uuidString: "00000000-0000-0000-0000-000000001702"
        )!
    )

    private static let localRecentDescriptor = ExternalOperationDescriptor(
        capability: .browsePreview,
        operationKind: .readRecent,
        requestSummary: .recent(limit: 1)
    )

    private struct Fixture {
        let history: SQLiteHistory
        let authority: HistoryAuthority
        let appIntentsConnection: ExternalConnectionID
        let localAutomationConnection: ExternalConnectionID
    }

#if DEBUG
    private final class HistoryReadProbe: Sendable {
        private let reachedRecentFetch = Mutex(false)

        func record(_ phase: StorageLifecycleDebugPhase) {
            guard phase == .recentFetchBegin else { return }
            reachedRecentFetch.withLock { $0 = true }
        }

        var didReachRecentFetch: Bool {
            reachedRecentFetch.withLock { $0 }
        }
    }
#endif

    private typealias HistorySnapshot = GatewayHistoryTestSnapshot

    @Test("App Intents row cannot authorize a local browse-preview descriptor")
    func appIntentsRowRejectsLocalDescriptorWithoutDurableEffects()
        async throws
    {
        let fixture = try await Self.makeFixture()
        let historyBefore = try await Self.historySnapshot(in: fixture.authority)
        let gatewayBefore = try await Self.gatewaySnapshot(in: fixture.authority)
#if DEBUG
        let historyReadProbe = await Self.installHistoryReadProbe(
            on: fixture.authority
        )
#endif

        await #expect(throws: ExternalFailure.unauthorized(
            requestedCapability: .browsePreview,
            connectionID: fixture.appIntentsConnection
        )) {
            _ = try await fixture.authority.performLocalAutomationBrowsePreview(
                .recent(limit: 1),
                connection: fixture.appIntentsConnection,
                requestedAt: Self.epoch,
                searchWorker: SearchWorker()
            )
        }

        #expect(try await Self.historySnapshot(in: fixture.authority) == historyBefore)
        #expect(try await Self.gatewaySnapshot(in: fixture.authority) == gatewayBefore)
#if DEBUG
        #expect(!historyReadProbe.didReachRecentFetch)
#endif
    }

    @Test("local row cannot authorize an App Intents browse descriptor")
    func localRowRejectsAppDescriptorWithoutDurableEffects() async throws {
        let fixture = try await Self.makeFixture()
        let historyBefore = try await Self.historySnapshot(in: fixture.authority)
        let gatewayBefore = try await Self.gatewaySnapshot(in: fixture.authority)
#if DEBUG
        let historyReadProbe = await Self.installHistoryReadProbe(
            on: fixture.authority
        )
#endif

        await #expect(throws: ExternalFailure.unauthorized(
            requestedCapability: .browse,
            connectionID: fixture.localAutomationConnection
        )) {
            _ = try await fixture.authority.performExternalRead(
                .recent(limit: 1),
                connection: fixture.localAutomationConnection,
                expectedConnectionKind: .appIntents,
                requestedAt: Self.epoch,
                searchWorker: SearchWorker()
            )
        }

        #expect(try await Self.historySnapshot(in: fixture.authority) == historyBefore)
        #expect(try await Self.gatewaySnapshot(in: fixture.authority) == gatewayBefore)
#if DEBUG
        #expect(!historyReadProbe.didReachRecentFetch)
#endif
    }

    @Test("correct local kind retains granted and revoked audit behavior")
    func correctLocalKindRetainsAuthorizationSemantics() async throws {
        let fixture = try await Self.makeFixture()
        let historyBeforeGrant = try await Self.historySnapshot(in: fixture.authority)
        let gatewayBeforeGrant = try await Self.gatewaySnapshot(in: fixture.authority)

        try await fixture.authority.withTestDatabase { authority in
            let context = authority.database
            let config = try HistoryAuthority.loadGatewayConfig(in: context)
            guard case .authorized = try HistoryAuthority.targetedExternalAuthorizationDecision(
                Self.localRecentDescriptor,
                connection: fixture.localAutomationConnection,
                expectedConnectionKind: .localAutomation,
                config: config,
                in: context
            ) else {
                Issue.record("the correct local kind and live grant must authorize")
                return
            }
        }

        #expect(try await Self.historySnapshot(in: fixture.authority)
            == historyBeforeGrant)
        #expect(try await Self.gatewaySnapshot(in: fixture.authority)
            == gatewayBeforeGrant)

        try await fixture.history.revokeConnection(
            fixture.localAutomationConnection
        )
        let historyBeforeDenial = try await Self.historySnapshot(in: fixture.authority)
        let gatewayBeforeDenial = try await Self.gatewaySnapshot(in: fixture.authority)

        await #expect(throws: ExternalFailure.connectionRevoked(
            connectionID: fixture.localAutomationConnection
        )) {
            _ = try await fixture.authority.performLocalAutomationBrowsePreview(
                .recent(limit: 1),
                connection: fixture.localAutomationConnection,
                requestedAt: Self.epoch,
                searchWorker: SearchWorker()
            )
        }

        #expect(try await Self.historySnapshot(in: fixture.authority)
            == historyBeforeDenial)
        let gatewayAfterDenial = try await Self.gatewaySnapshot(in: fixture.authority)
        #expect(gatewayAfterDenial.connections == gatewayBeforeDenial.connections)
        #expect(gatewayAfterDenial.grants == gatewayBeforeDenial.grants)
        #expect(gatewayAfterDenial.operations.dropLast()
            == gatewayBeforeDenial.operations[...])
        let denial = try #require(gatewayAfterDenial.operations.last)
        #expect(gatewayAfterDenial.operations.count
            == gatewayBeforeDenial.operations.count + 1)
        #expect(denial.connectionIDRaw
            == fixture.localAutomationConnection.rawValue)
        #expect(denial.capabilityRaw
            == ExternalCapability.browsePreview.rawValue)
        #expect(denial.operationKindRaw
            == ExternalOperationKind.readRecent.rawValue)
        #expect(denial.outcomeRaw == ExternalOutcome.denied.rawValue)
        #expect(denial.failureKindRaw
            == ExternalFailureKindRaw.connectionRevoked.rawValue)
        #expect(denial.denialReasonRaw == nil)
        #expect(denial.changePositionRaw == nil)
    }

    @Test("wrong kind rejects a write before target facts and audit")
    func wrongKindWriteRejectsBeforeHistoryFacts() async throws {
        let fixture = try await Self.makeFixture()
        let historyBefore = try await Self.historySnapshot(in: fixture.authority)
        let gatewayBefore = try await Self.gatewaySnapshot(in: fixture.authority)

        // The absent target is intentional: a write that reached History
        // facts could expose notFound. The kind mismatch must win first.
        await #expect(throws: ExternalFailure.unauthorized(
            requestedCapability: .manage,
            connectionID: fixture.localAutomationConnection
        )) {
            _ = try await fixture.authority.commitExternal(
                request: .remove(Self.absentItemID),
                connection: fixture.localAutomationConnection,
                expectedConnectionKind: .appIntents,
                requestedAt: Self.epoch
            )
        }

        #expect(try await Self.historySnapshot(in: fixture.authority) == historyBefore)
        #expect(try await Self.gatewaySnapshot(in: fixture.authority) == gatewayBefore)
    }

    @Test("correct App Intents kind retains successful and revoked read audits")
    func correctAppKindRetainsReadAuditSemantics() async throws {
        let fixture = try await Self.makeFixture()
        let historyBeforeRead = try await Self.historySnapshot(in: fixture.authority)
        let gatewayBeforeRead = try await Self.gatewaySnapshot(in: fixture.authority)

        let result = try await fixture.authority.performExternalRead(
            .recent(limit: 1),
            connection: fixture.appIntentsConnection,
            expectedConnectionKind: .appIntents,
            requestedAt: Self.epoch,
            searchWorker: SearchWorker()
        )
        guard case .page(let page) = result else {
            Issue.record("expected recent page")
            return
        }
        #expect(page.rows.count == 1)
        #expect(try await Self.historySnapshot(in: fixture.authority)
            == historyBeforeRead)
        let gatewayAfterRead = try await Self.gatewaySnapshot(in: fixture.authority)
        #expect(gatewayAfterRead.operations.dropLast()
            == gatewayBeforeRead.operations[...])
        let success = try #require(gatewayAfterRead.operations.last)
        #expect(gatewayAfterRead.operations.count
            == gatewayBeforeRead.operations.count + 1)
        #expect(success.connectionIDRaw == fixture.appIntentsConnection.rawValue)
        #expect(success.capabilityRaw == ExternalCapability.browse.rawValue)
        #expect(success.operationKindRaw
            == ExternalOperationKind.readRecent.rawValue)
        #expect(success.outcomeRaw == ExternalOutcome.succeeded.rawValue)
        #expect(success.failureKindRaw == nil)
        #expect(success.changePositionRaw == nil)

        try await fixture.history.revokeConnection(
            fixture.appIntentsConnection
        )
        let historyBeforeDenial = try await Self.historySnapshot(in: fixture.authority)
        let gatewayBeforeDenial = try await Self.gatewaySnapshot(in: fixture.authority)

        await #expect(throws: ExternalFailure.connectionRevoked(
            connectionID: fixture.appIntentsConnection
        )) {
            _ = try await fixture.authority.performExternalRead(
                .recent(limit: 1),
                connection: fixture.appIntentsConnection,
                expectedConnectionKind: .appIntents,
                requestedAt: Self.epoch,
                searchWorker: SearchWorker()
            )
        }

        #expect(try await Self.historySnapshot(in: fixture.authority)
            == historyBeforeDenial)
        let gatewayAfterDenial = try await Self.gatewaySnapshot(in: fixture.authority)
        #expect(gatewayAfterDenial.operations.dropLast()
            == gatewayBeforeDenial.operations[...])
        let denial = try #require(gatewayAfterDenial.operations.last)
        #expect(gatewayAfterDenial.operations.count
            == gatewayBeforeDenial.operations.count + 1)
        #expect(denial.connectionIDRaw == fixture.appIntentsConnection.rawValue)
        #expect(denial.capabilityRaw == ExternalCapability.browse.rawValue)
        #expect(denial.operationKindRaw
            == ExternalOperationKind.readRecent.rawValue)
        #expect(denial.outcomeRaw == ExternalOutcome.denied.rawValue)
        #expect(denial.failureKindRaw
            == ExternalFailureKindRaw.connectionRevoked.rawValue)
        #expect(denial.denialReasonRaw == nil)
        #expect(denial.changePositionRaw == nil)
    }

    private static func makeFixture() async throws -> Fixture {
        let history = try await SQLiteHistory.open(configuration:
            HistoryConfiguration(persistence: .temporary)
        )
        let authority = history.authority
        let appIntentsConnection = try #require(
            try await history.connections().first
        ).id
        let localAutomationConnection = Self.localAutomationConnection
        try await authority.publishVerifiedLocalAutomationEnrollment(
            localAutomationConnection,
            displayName: "Batch 17 local kind recheck"
        )
        try await history.grantCapability(
            .browse,
            to: appIntentsConnection
        )
        try await history.grantCapability(
            .browsePreview,
            to: localAutomationConnection
        )

        _ = try await history.perform(.capture(WSSupport.textCapture(
            "batch17-kind-recheck-sentinel",
            observedAt: Self.epoch
        )))

        return Fixture(
            history: history,
            authority: authority,
            appIntentsConnection: appIntentsConnection,
            localAutomationConnection: localAutomationConnection
        )
    }

    private static func historySnapshot(in authority: HistoryAuthority) async throws -> HistorySnapshot {
        try await GatewayHistoryTestSnapshot.read(from: authority)
    }

    private static func gatewaySnapshot(in authority: HistoryAuthority) async throws -> GatewayStoreSnapshot {
        try await GatewayStoreSnapshot.read(from: authority)
    }

#if DEBUG
    private static func installHistoryReadProbe(
        on authority: HistoryAuthority
    ) async -> HistoryReadProbe {
        let probe = HistoryReadProbe()
        await authority.setStorageLifecycleDebugProbe(
            StorageLifecycleDebugProbe(isEnabled: true) { event in
                probe.record(event.phase)
            }
        )
        return probe
    }
#endif
}
