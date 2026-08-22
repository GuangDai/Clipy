/// X.4 audited Gateway administration read/rebase proofs.
/// Owning spec: `V2-05` §3.3/§4.3/§5.4 and roadmap X.4/GW3.
import Foundation
import HistoryCore
import SwiftData
import Synchronization
import Testing
@testable import HistoryStorage

@Suite("Gateway administration reads (X.4)")
struct GatewayAdministrationReadTests {
    private static let appIntentsID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000951"
    )!
    private static let enrolledID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000952"
    )!
    private static let epoch = Date(
        timeIntervalSinceReferenceDate: 900_200_000
    )

    private final class StepClock: StorageClock, Sendable {
        private let epoch: Date
        private let nextOffset = Mutex(0)

        init(epoch: Date) {
            self.epoch = epoch
        }

        func now() -> Date {
            nextOffset.withLock { offset in
                defer { offset += 1 }
                return epoch.addingTimeInterval(TimeInterval(offset))
            }
        }
    }

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
    }

    private struct Fixture {
        let authority: HistoryAuthority
        let container: ModelContainer
    }

    private static func makeFixture() async throws -> Fixture {
        let schema = Schema(versionedSchema: HistorySchemaV3.self)
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
            container: container
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

    private static func decodedPayload(
        at sequence: UInt64,
        in fixture: Fixture
    ) throws -> OperationPayloadBlobV1 {
        let context = ModelContext(fixture.container)
        let config = try #require(
            context.fetch(FetchDescriptor<GatewayConfigRow>()).first
        )
        let row = try #require(
            context.fetch(FetchDescriptor<OperationRecordRow>()).first {
                $0.auditSequence == sequence
            }
        )
        let operationKind = try #require(
            ExternalOperationKind(rawValue: row.operationKindRaw)
        )
        let outcome = try #require(ExternalOutcome(rawValue: row.outcomeRaw))
        return try OperationPayloadBlobCodec.decode(
            row.payloadBlob,
            context: OperationPayloadRecordContextV1(
                connectionID: row.connectionIDRaw,
                capability: row.capabilityRaw.flatMap {
                    ExternalCapability(rawValue: $0)
                },
                operationKind: operationKind,
                outcome: outcome,
                failureKind: row.failureKindRaw.flatMap {
                    ExternalFailureKindRaw(rawValue: $0)
                },
                denialReason: row.denialReasonRaw.flatMap {
                    ExternalDenialReason(rawValue: $0)
                },
                changePosition: row.changePositionRaw,
                auditSequence: row.auditSequence,
                compactionFloor: config.compactionFloor,
                nextAuditSequence: config.nextAuditSequence
            )
        )
    }

    @Test("connection and grant DTOs publish only after their exact audit rows")
    func currentStateReadsAreAuditedWithExactAttribution() async throws {
        let fixture = try await Self.makeFixture()
        let initialConnections = try await fixture.authority.connections()

        let bootstrapped = try #require(initialConnections.first)
        #expect(initialConnections.count == 1)
        #expect(bootstrapped.id.rawValue == Self.appIntentsID)
        #expect(bootstrapped.enrollKind == .appIntents)
        #expect(bootstrapped.status == .active)

        var snapshot = try Self.snapshot(fixture)
        let connectionRead = try #require(snapshot.operations.first)
        #expect(connectionRead.auditSequence == 1)
        #expect(connectionRead.operationKindRaw == 17)
        #expect(connectionRead.connectionIDRaw == nil)
        #expect(connectionRead.capabilityRaw == nil)
        #expect(connectionRead.outcomeRaw == ExternalOutcome.succeeded.rawValue)
        #expect(connectionRead.changePositionRaw == nil)
        #expect(connectionRead.requestedAt
            == Self.epoch.addingTimeInterval(1))
        #expect(connectionRead.committedAt
            == Self.epoch.addingTimeInterval(2))
        #expect(try Self.decodedPayload(at: 1, in: fixture)
            == OperationPayloadBlobV1(
                request: .readConnections,
                result: .connections(returnedCount: 1)
            ))

        let id = try await fixture.authority.enrollConnection(
            kind: .localAutomation,
            displayName: "Local automation",
            credential: nil
        )
        try await fixture.authority.grantCapability(.organize, to: id)
        let grants = try await fixture.authority.grants(for: id)

        let grant = try #require(grants.first)
        #expect(grants.count == 1)
        #expect(grant.connectionID == id)
        #expect(grant.capability == .organize)
        #expect(grant.revokedAt == nil)

        snapshot = try Self.snapshot(fixture)
        let grantRead = try #require(snapshot.operations.last)
        #expect(grantRead.auditSequence == 4)
        #expect(grantRead.operationKindRaw == 18)
        #expect(grantRead.connectionIDRaw == id.rawValue)
        #expect(grantRead.capabilityRaw == nil)
        #expect(grantRead.changePositionRaw == nil)
        #expect(try Self.decodedPayload(at: 4, in: fixture)
            == OperationPayloadBlobV1(
                request: .readGrants(connectionID: id.rawValue),
                result: .grants(returnedCount: 1)
            ))
        #expect(try Self.historyPosition(fixture) == 0)
    }

    @Test("audit read freezes an exclusive head and never returns its own row")
    func auditReadUsesExclusiveHighWaterMark() async throws {
        let fixture = try await Self.makeFixture()
        _ = try await fixture.authority.connections()
        _ = try await fixture.authority.connections()

        let page = try await fixture.authority.auditLog(since: 1)

        #expect(page.map(\.auditSequence) == [1, 2])
        #expect(page.map(\.operationKind) == [
            .adminReadConnections,
            .adminReadConnections,
        ])
        #expect(!page.contains(where: { $0.auditSequence == 3 }))

        let snapshot = try Self.snapshot(fixture)
        let ownRow = try #require(snapshot.operations.last)
        #expect(ownRow.auditSequence == 3)
        #expect(ownRow.operationKindRaw == 19)
        #expect(ownRow.connectionIDRaw == nil)
        #expect(ownRow.capabilityRaw == nil)
        #expect(ownRow.changePositionRaw == nil)
        #expect(snapshot.configs.first?.nextAuditSequence == 4)
        #expect(try Self.decodedPayload(at: 3, in: fixture)
            == OperationPayloadBlobV1(
                request: .readAudit(since: 1, limit: 500),
                result: .auditPage(returnedCount: 2, snapshotHead: 3)
            ))
        #expect(try Self.historyPosition(fixture) == 0)
    }

    @Test("audit since equal to head is empty; above head is an audited denial")
    func auditReadValidatesAgainstFrozenHead() async throws {
        let fixture = try await Self.makeFixture()

        let emptyPage = try await fixture.authority.auditLog(since: 1)
        #expect(emptyPage.isEmpty)
        #expect(try Self.decodedPayload(at: 1, in: fixture)
            == OperationPayloadBlobV1(
                request: .readAudit(since: 1, limit: 500),
                result: .auditPage(returnedCount: 0, snapshotHead: 1)
            ))

        await #expect(throws: ExternalFailure.requestDenied(.invalidInput)) {
            _ = try await fixture.authority.auditLog(since: 3)
        }

        let snapshot = try Self.snapshot(fixture)
        let denial = try #require(snapshot.operations.last)
        #expect(snapshot.operations.map(\.auditSequence) == [1, 2])
        #expect(denial.operationKindRaw == 19)
        #expect(denial.outcomeRaw == ExternalOutcome.denied.rawValue)
        #expect(denial.failureKindRaw
            == ExternalFailureKindRaw.requestDenied.rawValue)
        #expect(denial.denialReasonRaw
            == ExternalDenialReason.invalidInput.rawValue)
        #expect(denial.changePositionRaw == nil)
    }

    @Test("forced rebase clears the healthy prefix; recovery reason is denied")
    func rebaseUsesCentralStoreWithoutClaimingOrdinaryRecovery() async throws {
        let fixture = try await Self.makeFixture()
        _ = try await fixture.authority.connections()
        _ = try await fixture.authority.connections()

        try await fixture.authority.rebaseAuditLog(reason: .adminForced)

        var snapshot = try Self.snapshot(fixture)
        #expect(snapshot.operations.map(\.auditSequence) == [3])
        #expect(snapshot.operations[0].operationKindRaw
            == ExternalOperationKind.adminRebase.rawValue)
        #expect(snapshot.operations[0].outcomeRaw
            == ExternalOutcome.succeeded.rawValue)
        #expect(snapshot.configs.first?.compactionFloor == 3)
        #expect(snapshot.configs.first?.nextAuditSequence == 4)

        await #expect(throws: ExternalFailure.requestDenied(.invalidInput)) {
            try await fixture.authority.rebaseAuditLog(
                reason: .corruptionDetected
            )
        }

        snapshot = try Self.snapshot(fixture)
        let denial = try #require(snapshot.operations.last)
        #expect(snapshot.operations.map(\.auditSequence) == [3, 4])
        #expect(denial.operationKindRaw
            == ExternalOperationKind.adminRebase.rawValue)
        #expect(denial.outcomeRaw == ExternalOutcome.denied.rawValue)
        #expect(denial.failureKindRaw
            == ExternalFailureKindRaw.requestDenied.rawValue)
        #expect(denial.denialReasonRaw
            == ExternalDenialReason.invalidInput.rawValue)
        #expect(try Self.historyPosition(fixture) == 0)
    }

    @Test("below-floor failure is appended before the typed failure escapes")
    func auditBelowFloorFailureCrossesAuditBarrier() async throws {
        let fixture = try await Self.makeFixture()
        _ = try await fixture.authority.connections()
        try await fixture.authority.rebaseAuditLog(reason: .adminForced)

        await #expect(throws: ExternalFailure.auditCompactedBefore(floor: 2)) {
            _ = try await fixture.authority.auditLog(since: 1)
        }

        let snapshot = try Self.snapshot(fixture)
        let failure = try #require(snapshot.operations.last)
        #expect(snapshot.operations.map(\.auditSequence) == [2, 3])
        #expect(failure.operationKindRaw == 19)
        #expect(failure.outcomeRaw == ExternalOutcome.failed.rawValue)
        #expect(failure.failureKindRaw
            == ExternalFailureKindRaw.auditCompactedBefore.rawValue)
        #expect(failure.connectionIDRaw == nil)
        #expect(failure.capabilityRaw == nil)
        #expect(failure.changePositionRaw == nil)
        #expect(try Self.historyPosition(fixture) == 0)
    }

    @Test("audit failure publishes neither a prepared DTO nor an underlying read failure")
    func auditAppendFailureIsThePublicationBarrier() async throws {
        let fixture = try await Self.makeFixture()
        await fixture.authority.setTransactionFailureInjection(
            .beforeSingletonUpdate
        )

        await #expect(throws: ExternalFailure.persistence(.transaction)) {
            _ = try await fixture.authority.connections()
        }
        #expect(try Self.snapshot(fixture).operations.isEmpty)

        let context = ModelContext(fixture.container)
        context.autosaveEnabled = false
        let connection = try #require(
            context.fetch(FetchDescriptor<ConnectionRow>()).first
        )
        connection.statusRaw = 0
        try context.save()

        await fixture.authority.setTransactionFailureInjection(
            .beforeSingletonUpdate
        )
        await #expect(throws: ExternalFailure.persistence(.transaction)) {
            _ = try await fixture.authority.connections()
        }
        #expect(try Self.snapshot(fixture).operations.isEmpty)

        await #expect(
            throws: ExternalFailure.persistence(.corruptStoredValue)
        ) {
            _ = try await fixture.authority.connections()
        }
        let failure = try #require(Self.snapshot(fixture).operations.first)
        #expect(failure.operationKindRaw == 17)
        #expect(failure.outcomeRaw == ExternalOutcome.failed.rawValue)
        #expect(failure.failureKindRaw
            == ExternalFailureKindRaw.persistence.rawValue)
    }
}
