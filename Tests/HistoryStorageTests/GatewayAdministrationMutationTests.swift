/// X.4 atomic Gateway connection/grant administration proofs.
/// Owning spec: `V2-05` §3.3/§5.3/§5.4 and roadmap X.4/GW3.
import Foundation
import HistoryCore
import SwiftData
import Synchronization
import Testing
@testable import HistoryStorage

@Suite("Gateway administration mutations (X.4)")
struct GatewayAdministrationMutationTests {
    private static let appIntentsID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000941"
    )!
    private static let enrolledID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000942"
    )!
    private static let epoch = Date(
        timeIntervalSinceReferenceDate: 900_100_000
    )

    private final class UUIDSource: Sendable {
        private let values: Mutex<[UUID]>

        init(_ values: [UUID]) {
            self.values = Mutex(values)
        }

        func next() -> UUID {
            values.withLock { values in
                values.removeFirst()
            }
        }

        var remainingCount: Int {
            values.withLock { $0.count }
        }
    }

    private final class StepClock: StorageClock {
        private struct State: Sendable {
            var nextOffset: Int = 0
        }

        private let epoch: Date
        private let state = Mutex(State())

        init(epoch: Date) {
            self.epoch = epoch
        }

        func now() -> Date {
            state.withLock { state in
                defer { state.nextOffset += 1 }
                return epoch.addingTimeInterval(
                    TimeInterval(state.nextOffset)
                )
            }
        }

        var callCount: Int {
            state.withLock { $0.nextOffset }
        }
    }

    private struct Fixture {
        let authority: HistoryAuthority
        let container: ModelContainer
        let idSource: UUIDSource
        let clock: StepClock
    }

    private static func makeFixture() async throws -> Fixture {
        let schema = Schema(versionedSchema: HistorySchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )]
        )
        let idSource = UUIDSource([appIntentsID, enrolledID])
        let clock = StepClock(epoch: epoch)
        let authority = HistoryAuthority(
            container: container,
            storageClock: clock,
            gatewayConnectionIDSource: { idSource.next() }
        )
        try await authority.performStartup(initialMaximumUnpinnedItems: 200)
        return Fixture(
            authority: authority,
            container: container,
            idSource: idSource,
            clock: clock
        )
    }

    private static func snapshot(_ fixture: Fixture) throws
        -> GatewayStoreSnapshot
    {
        try GatewayStoreSnapshot.read(in: ModelContext(fixture.container))
    }

    private static func historyPosition(_ fixture: Fixture) throws -> UInt64 {
        let context = ModelContext(fixture.container)
        return try #require(
            context.fetch(FetchDescriptor<LastChangePositionRow>()).first
        ).rawValue
    }

    @Test("enrollment mints the injected ID and atomically audits no History commit")
    func enrollmentIsAtomicAndDoesNotAdvanceHistory() async throws {
        let fixture = try await Self.makeFixture()
        let maximumDisplayName = String(repeating: "x", count: 256)
        let id = try await fixture.authority.enrollConnection(
            kind: .localAutomation,
            displayName: maximumDisplayName,
            credential: nil
        )

        #expect(id.rawValue == Self.enrolledID)
        #expect(fixture.idSource.remainingCount == 0)
        #expect(fixture.clock.callCount == 3)

        let snapshot = try Self.snapshot(fixture)
        let connection = try #require(snapshot.connections.first(where: {
            $0.id == Self.enrolledID
        }))
        #expect(snapshot.connections.count == 2)
        #expect(connection.displayNameRaw == maximumDisplayName)
        #expect(connection.enrollKindRaw == ConnectionEnrollKind.localAutomation.rawValue)
        #expect(connection.statusRaw == ConnectionStatus.active.rawValue)
        #expect(connection.enrolledAt == Self.epoch.addingTimeInterval(2))
        #expect(connection.revokedAt == nil)
        #expect(snapshot.grants.isEmpty)

        let operation = try #require(snapshot.operations.first)
        #expect(snapshot.operations.count == 1)
        #expect(operation.auditSequence == 1)
        #expect(operation.connectionIDRaw == Self.enrolledID)
        #expect(operation.capabilityRaw == nil)
        #expect(operation.operationKindRaw == ExternalOperationKind.adminEnroll.rawValue)
        #expect(operation.outcomeRaw == ExternalOutcome.succeeded.rawValue)
        #expect(operation.requestedAt == Self.epoch.addingTimeInterval(1))
        #expect(operation.committedAt == connection.enrolledAt)
        #expect(operation.changePositionRaw == nil)
        #expect(snapshot.configs.first?.nextAuditSequence == 2)
        let payloadBytes = try #require(
            UInt64(exactly: operation.payloadBlob.count)
        )
        let expectedAuditBytes = payloadBytes.addingReportingOverflow(128)
        #expect(!expectedAuditBytes.overflow)
        #expect(snapshot.configs.first?.auditBytes
            == expectedAuditBytes.partialValue)
        #expect(try Self.historyPosition(fixture) == 0)
    }

    @Test("invalid shape is unaudited, while admitted credential and capacity denials audit")
    func enrollmentAdmissionAndPolicyDenialsAreDistinct() async throws {
        let fixture = try await Self.makeFixture()
        let oversized = String(repeating: "é", count: 129)

        await #expect(throws: ExternalFailure.requestDenied(.invalidInput)) {
            _ = try await fixture.authority.enrollConnection(
                kind: .localAutomation,
                displayName: oversized,
                credential: nil
            )
        }
        #expect(try Self.snapshot(fixture).operations.isEmpty)
        #expect(fixture.clock.callCount == 1)
        #expect(fixture.idSource.remainingCount == 1)

        await #expect(throws: ExternalFailure.requestDenied(.invalidInput)) {
            _ = try await fixture.authority.enrollConnection(
                kind: .localAutomation,
                displayName: "Credential-bearing",
                credential: Data([0x01])
            )
        }
        var snapshot = try Self.snapshot(fixture)
        #expect(snapshot.connections.count == 1)
        #expect(snapshot.operations.count == 1)
        #expect(snapshot.operations[0].connectionIDRaw == nil)
        #expect(snapshot.operations[0].outcomeRaw == ExternalOutcome.denied.rawValue)
        #expect(snapshot.operations[0].failureKindRaw
            == ExternalFailureKindRaw.requestDenied.rawValue)
        #expect(snapshot.operations[0].denialReasonRaw
            == ExternalDenialReason.invalidInput.rawValue)
        #expect(fixture.idSource.remainingCount == 1)

        let context = ModelContext(fixture.container)
        context.autosaveEnabled = false
        for suffix in 1...499 {
            let id = UUID(uuidString: String(
                format: "10000000-0000-0000-0000-%012llX",
                UInt64(suffix)
            ))!
            context.insert(ConnectionRow(
                id: id,
                displayNameRaw: "Connection \(suffix)",
                enrollKindRaw: ConnectionEnrollKind.localAutomation.rawValue,
                statusRaw: ConnectionStatus.active.rawValue,
                enrolledAt: Self.epoch,
                revokedAt: nil,
                configSchemaVersion: HistoryAuthority.gatewayConfigSchemaVersion
            ))
        }
        try context.save()

        await #expect(throws: ExternalFailure.requestDenied(.invalidInput)) {
            _ = try await fixture.authority.enrollConnection(
                kind: .localAutomation,
                displayName: "Connection 501",
                credential: nil
            )
        }
        snapshot = try Self.snapshot(fixture)
        #expect(snapshot.connections.count == 500)
        #expect(snapshot.operations.count == 2)
        #expect(snapshot.operations[1].connectionIDRaw == nil)
        #expect(snapshot.operations[1].outcomeRaw == ExternalOutcome.denied.rawValue)
        #expect(fixture.idSource.remainingCount == 1)
        #expect(try Self.historyPosition(fixture) == 0)
    }

    @Test("grant, revoke, and re-grant keep one canonical current-state row")
    func grantLifecycleUsesOneCurrentRowAndAuditsNoOps() async throws {
        let fixture = try await Self.makeFixture()
        let id = try await fixture.authority.enrollConnection(
            kind: .localAutomation,
            displayName: "Local automation",
            credential: nil
        )

        try await fixture.authority.grantCapability(.organize, to: id)
        try await fixture.authority.grantCapability(.organize, to: id)
        try await fixture.authority.revokeCapability(.organize, of: id)
        try await fixture.authority.revokeCapability(.organize, of: id)
        try await fixture.authority.grantCapability(.organize, to: id)

        let snapshot = try Self.snapshot(fixture)
        let grant = try #require(snapshot.grants.first)
        #expect(snapshot.grants.count == 1)
        #expect(grant.grantKey == GatewayAdministration.canonicalGrantKey(
            connectionID: Self.enrolledID,
            capability: .organize
        ))
        #expect(grant.connectionIDRaw == Self.enrolledID)
        #expect(grant.capabilityRaw == ExternalCapability.organize.rawValue)
        #expect(grant.grantedAt == Self.epoch.addingTimeInterval(12))
        #expect(grant.revokedAt == nil)
        #expect(snapshot.operations.map(\.operationKindRaw) == [
            ExternalOperationKind.adminEnroll.rawValue,
            ExternalOperationKind.adminGrant.rawValue,
            ExternalOperationKind.adminGrant.rawValue,
            ExternalOperationKind.adminRevokeCapability.rawValue,
            ExternalOperationKind.adminRevokeCapability.rawValue,
            ExternalOperationKind.adminGrant.rawValue,
        ])
        #expect(snapshot.operations.map(\.outcomeRaw) == [
            ExternalOutcome.succeeded.rawValue,
            ExternalOutcome.succeeded.rawValue,
            ExternalOutcome.noOp.rawValue,
            ExternalOutcome.succeeded.rawValue,
            ExternalOutcome.noOp.rawValue,
            ExternalOutcome.succeeded.rawValue,
        ])
        #expect(snapshot.operations.allSatisfy { $0.changePositionRaw == nil })
        #expect(fixture.clock.callCount == 13)
        #expect(try Self.historyPosition(fixture) == 0)
    }

    @Test("connection revoke closes every live grant and repeated revoke is audited noOp")
    func connectionRevokeClosesLiveGrants() async throws {
        let fixture = try await Self.makeFixture()
        let id = try await fixture.authority.enrollConnection(
            kind: .localAutomation,
            displayName: "Local automation",
            credential: nil
        )
        try await fixture.authority.grantCapability(.organize, to: id)
        try await fixture.authority.grantCapability(.deleteItem, to: id)

        try await fixture.authority.revokeConnection(id)
        try await fixture.authority.revokeConnection(id)

        let snapshot = try Self.snapshot(fixture)
        let connection = try #require(snapshot.connections.first(where: {
            $0.id == Self.enrolledID
        }))
        #expect(connection.statusRaw == ConnectionStatus.revoked.rawValue)
        #expect(connection.revokedAt == Self.epoch.addingTimeInterval(8))
        #expect(snapshot.grants.count == 2)
        #expect(snapshot.grants.allSatisfy {
            $0.revokedAt == Self.epoch.addingTimeInterval(8)
        })
        #expect(Array(snapshot.operations.map(\.outcomeRaw).suffix(2)) == [
            ExternalOutcome.succeeded.rawValue,
            ExternalOutcome.noOp.rawValue,
        ])
        #expect(snapshot.operations.suffix(2).allSatisfy {
            $0.operationKindRaw == ExternalOperationKind.adminRevoke.rawValue
        })
        #expect(try Self.historyPosition(fixture) == 0)
    }

    @Test("unknown targets, revoked connections, and cross-kind grants use exact typed failures")
    func invalidGrantTargetsAreTypedAndAudited() async throws {
        let fixture = try await Self.makeFixture()
        let missing = ExternalConnectionID(rawValue: UUID(
            uuidString: "00000000-0000-0000-0000-000000000949"
        )!)

        await #expect(throws: ExternalFailure.requestDenied(.invalidInput)) {
            try await fixture.authority.grantCapability(.browse, to: missing)
        }

        let id = try await fixture.authority.enrollConnection(
            kind: .localAutomation,
            displayName: "Local automation",
            credential: nil
        )
        await #expect(throws: ExternalFailure.requestDenied(.invalidInput)) {
            try await fixture.authority.grantCapability(.browse, to: id)
        }
        try await fixture.authority.revokeConnection(id)
        await #expect(throws: ExternalFailure.connectionRevoked(connectionID: id)) {
            try await fixture.authority.grantCapability(.organize, to: id)
        }

        let snapshot = try Self.snapshot(fixture)
        #expect(snapshot.grants.isEmpty)
        #expect(snapshot.operations.count == 5)
        #expect(snapshot.operations[0].connectionIDRaw == missing.rawValue)
        #expect(snapshot.operations[0].outcomeRaw == ExternalOutcome.denied.rawValue)
        #expect(snapshot.operations.last?.failureKindRaw
            == ExternalFailureKindRaw.connectionRevoked.rawValue)
    }

    @Test("a failure after audit staging rolls back state, audit, and counters")
    func transactionFailureRollsBackAdminAndAuditTogether() async throws {
        let fixture = try await Self.makeFixture()
        let id = try await fixture.authority.enrollConnection(
            kind: .localAutomation,
            displayName: "Local automation",
            credential: nil
        )
        let before = try Self.snapshot(fixture)
        await fixture.authority.setTransactionFailureInjection(
            .beforeSingletonUpdate
        )

        await #expect(throws: ExternalFailure.persistence(.transaction)) {
            try await fixture.authority.grantCapability(.organize, to: id)
        }

        #expect(try Self.snapshot(fixture) == before)
        #expect(try Self.historyPosition(fixture) == 0)
    }
}
