/// Batch 17 authoritative connection-kind recheck proofs.
/// Owning spec: `V2-05` §3.1/§4.5/§5.2 and roadmap X.9/F1.
import Foundation
import HistoryCore
import SwiftData
import Synchronization
import Testing
@testable import HistoryStorage

// Every case opens and seeds a complete V4 store. Serializing this suite keeps
// five ModelContainer startup/migration paths from competing at once with the
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
        let history: SwiftDataHistory
        let authority: HistoryAuthority
        let container: ModelContainer
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

    private struct HistorySnapshot: Equatable {
        struct Item: Equatable {
            let id: UUID
            let contentVersionRaw: UInt64
            let canonicalBlob: Data
            let revisionStateBlob: Data
            let copyCount: UInt64
            let pinOrdinal: Int?

            init(_ row: HistoryItemRow) {
                id = row.id
                contentVersionRaw = row.contentVersionRaw
                canonicalBlob = row.canonicalBlob
                revisionStateBlob = row.revisionStateBlob
                copyCount = row.copyCount
                pinOrdinal = row.pinOrdinal
            }
        }

        struct ChangeRecord: Equatable {
            let sequence: UInt64
            let changePositionRaw: UInt64
            let changeKindRaw: Int16
            let affectedItemsBlob: Data

            init(_ row: HistoryChangeRecordRow) {
                sequence = row.sequence
                changePositionRaw = row.changePositionRaw
                changeKindRaw = row.changeKindRaw
                affectedItemsBlob = row.affectedItemsBlob
            }
        }

        let position: UInt64
        let items: [Item]
        let changes: [ChangeRecord]
    }

    @Test("App Intents row cannot authorize a local browse-preview descriptor")
    func appIntentsRowRejectsLocalDescriptorWithoutDurableEffects()
        async throws
    {
        let fixture = try await Self.makeFixture()
        let historyBefore = try Self.historySnapshot(in: fixture.container)
        let gatewayBefore = try Self.gatewaySnapshot(in: fixture.container)
#if DEBUG
        let historyReadProbe = await Self.installHistoryReadProbe(
            on: fixture.authority
        )
#endif

        await #expect(throws: ExternalFailure.unauthorized(
            requestedCapability: .browsePreview,
            connectionID: fixture.appIntentsConnection
        )) {
            try await fixture.authority.authorizeExternal(
                Self.localRecentDescriptor,
                as: fixture.appIntentsConnection,
                expectedConnectionKind: .localAutomation
            )
        }

        #expect(try Self.historySnapshot(in: fixture.container) == historyBefore)
        #expect(try Self.gatewaySnapshot(in: fixture.container) == gatewayBefore)
#if DEBUG
        #expect(!historyReadProbe.didReachRecentFetch)
#endif
    }

    @Test("local row cannot authorize an App Intents browse descriptor")
    func localRowRejectsAppDescriptorWithoutDurableEffects() async throws {
        let fixture = try await Self.makeFixture()
        let historyBefore = try Self.historySnapshot(in: fixture.container)
        let gatewayBefore = try Self.gatewaySnapshot(in: fixture.container)
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

        #expect(try Self.historySnapshot(in: fixture.container) == historyBefore)
        #expect(try Self.gatewaySnapshot(in: fixture.container) == gatewayBefore)
#if DEBUG
        #expect(!historyReadProbe.didReachRecentFetch)
#endif
    }

    @Test("correct local kind retains granted and revoked audit behavior")
    func correctLocalKindRetainsAuthorizationSemantics() async throws {
        let fixture = try await Self.makeFixture()
        let historyBeforeGrant = try Self.historySnapshot(in: fixture.container)
        let gatewayBeforeGrant = try Self.gatewaySnapshot(in: fixture.container)

        try await fixture.authority.authorizeExternal(
            Self.localRecentDescriptor,
            as: fixture.localAutomationConnection,
            expectedConnectionKind: .localAutomation
        )

        #expect(try Self.historySnapshot(in: fixture.container)
            == historyBeforeGrant)
        #expect(try Self.gatewaySnapshot(in: fixture.container)
            == gatewayBeforeGrant)

        try await fixture.history.revokeConnection(
            fixture.localAutomationConnection
        )
        let historyBeforeDenial = try Self.historySnapshot(in: fixture.container)
        let gatewayBeforeDenial = try Self.gatewaySnapshot(in: fixture.container)

        await #expect(throws: ExternalFailure.connectionRevoked(
            connectionID: fixture.localAutomationConnection
        )) {
            try await fixture.authority.authorizeExternal(
                Self.localRecentDescriptor,
                as: fixture.localAutomationConnection,
                expectedConnectionKind: .localAutomation
            )
        }

        #expect(try Self.historySnapshot(in: fixture.container)
            == historyBeforeDenial)
        let gatewayAfterDenial = try Self.gatewaySnapshot(in: fixture.container)
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
        let historyBefore = try Self.historySnapshot(in: fixture.container)
        let gatewayBefore = try Self.gatewaySnapshot(in: fixture.container)

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

        #expect(try Self.historySnapshot(in: fixture.container) == historyBefore)
        #expect(try Self.gatewaySnapshot(in: fixture.container) == gatewayBefore)
    }

    @Test("correct App Intents kind retains successful and revoked read audits")
    func correctAppKindRetainsReadAuditSemantics() async throws {
        let fixture = try await Self.makeFixture()
        let historyBeforeRead = try Self.historySnapshot(in: fixture.container)
        let gatewayBeforeRead = try Self.gatewaySnapshot(in: fixture.container)

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
        #expect(try Self.historySnapshot(in: fixture.container)
            == historyBeforeRead)
        let gatewayAfterRead = try Self.gatewaySnapshot(in: fixture.container)
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
        let historyBeforeDenial = try Self.historySnapshot(in: fixture.container)
        let gatewayBeforeDenial = try Self.gatewaySnapshot(in: fixture.container)

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

        #expect(try Self.historySnapshot(in: fixture.container)
            == historyBeforeDenial)
        let gatewayAfterDenial = try Self.gatewaySnapshot(in: fixture.container)
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
        let history = try await SwiftDataHistory.open(configuration:
            HistoryConfiguration(persistence: .memory)
        )
        let authority = history.authority
        let container = await authority.container
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
            container: container,
            appIntentsConnection: appIntentsConnection,
            localAutomationConnection: localAutomationConnection
        )
    }

    private static func historySnapshot(
        in container: ModelContainer
    ) throws -> HistorySnapshot {
        let context = ModelContext(container)
        let position = try #require(
            context.fetch(FetchDescriptor<LastChangePositionRow>()).first
        )
        let items = try context.fetch(FetchDescriptor<HistoryItemRow>())
            .map(HistorySnapshot.Item.init)
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let changes = try context.fetch(
            FetchDescriptor<HistoryChangeRecordRow>()
        )
            .map(HistorySnapshot.ChangeRecord.init)
            .sorted { $0.sequence < $1.sequence }
        return HistorySnapshot(
            position: position.rawValue,
            items: items,
            changes: changes
        )
    }

    private static func gatewaySnapshot(
        in container: ModelContainer
    ) throws -> GatewayStoreSnapshot {
        try GatewayStoreSnapshot.read(in: ModelContext(container))
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
