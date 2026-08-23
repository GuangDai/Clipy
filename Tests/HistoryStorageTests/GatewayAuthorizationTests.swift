/// X.5 targeted authorization and mandatory denied-audit proofs.
/// Owning spec: `V2-05` §3.1/§5.1/§5.2 and D33–D35.
import Foundation
import HistoryCore
import SwiftData
import Synchronization
import Testing
@testable import HistoryStorage

@Suite("Gateway external authorization (X.5)")
struct GatewayAuthorizationTests {
    private static let connectionID = ExternalConnectionID(rawValue: UUID(
        uuidString: "00000000-0000-0000-0000-000000000A51"
    )!)
    private static let unknownConnectionID = ExternalConnectionID(rawValue: UUID(
        uuidString: "00000000-0000-0000-0000-000000000A52"
    )!)
    private static let itemID = HistoryItemID(rawValue: UUID(
        uuidString: "00000000-0000-0000-0000-000000000A53"
    )!)
    private static let epoch = Date(
        timeIntervalSinceReferenceDate: 901_000_000
    )

    private final class StepClock: StorageClock {
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

        var callCount: Int {
            nextOffset.withLock { $0 }
        }
    }

    private struct Fixture {
        let authority: HistoryAuthority
        let container: ModelContainer
        let clock: StepClock
    }

    private static let pinDescriptor = ExternalOperationDescriptor(
        capability: .manage,
        operationKind: .managePin,
        requestSummary: .pin(itemID: itemID.rawValue)
    )

    private static let recentDescriptor = ExternalOperationDescriptor(
        capability: .browse,
        operationKind: .readRecent,
        requestSummary: .recent(limit: 1)
    )

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
        let clock = StepClock(epoch: epoch)
        let authority = HistoryAuthority(
            container: container,
            storageClock: clock,
            gatewayConnectionIDSource: { connectionID.rawValue }
        )
        try await authority.performStartup(initialMaximumUnpinnedItems: 200)
        return Fixture(
            authority: authority,
            container: container,
            clock: clock
        )
    }

    private static func snapshot(_ fixture: Fixture) throws
        -> GatewayStoreSnapshot
    {
        try GatewayStoreSnapshot.read(in: ModelContext(fixture.container))
    }

    private static func insertGrant(
        _ capability: ExternalCapability,
        revokedAt: Date? = nil,
        in fixture: Fixture
    ) throws {
        let context = ModelContext(fixture.container)
        context.autosaveEnabled = false
        context.insert(GrantRow(
            grantKey: GatewayAdministration.canonicalGrantKey(
                connectionID: connectionID.rawValue,
                capability: capability
            ),
            connectionIDRaw: connectionID.rawValue,
            capabilityRaw: capability.rawValue,
            grantedAt: epoch.addingTimeInterval(1),
            revokedAt: revokedAt,
            configSchemaVersion: HistoryAuthority.gatewayConfigSchemaVersion
        ))
        try context.save()
    }

    private static func revokeConnection(in fixture: Fixture) throws {
        let context = ModelContext(fixture.container)
        context.autosaveEnabled = false
        let row = try #require(
            context.fetch(FetchDescriptor<ConnectionRow>()).first
        )
        row.statusRaw = ConnectionStatus.revoked.rawValue
        row.revokedAt = epoch.addingTimeInterval(1)
        try context.save()
    }

    private static func expectHistoryPositionUnchanged(
        _ fixture: Fixture
    ) async throws {
        let position = try await fixture.authority.currentPosition()
        #expect(position.rawValue == 0)
    }

    private static func expectDeniedOperation(
        _ operation: GatewayStoreSnapshot.Operation,
        descriptor: ExternalOperationDescriptor,
        failureKind: ExternalFailureKindRaw,
        denialReason: ExternalDenialReason?,
        snapshot: GatewayStoreSnapshot
    ) throws {
        #expect(operation.connectionIDRaw == connectionID.rawValue)
        #expect(operation.capabilityRaw == descriptor.capability.rawValue)
        #expect(operation.operationKindRaw == descriptor.operationKind.rawValue)
        #expect(operation.outcomeRaw == ExternalOutcome.denied.rawValue)
        #expect(operation.failureKindRaw == failureKind.rawValue)
        #expect(operation.denialReasonRaw == denialReason?.rawValue)
        #expect(operation.changePositionRaw == nil)

        let operationKind = try #require(ExternalOperationKind(
            rawValue: operation.operationKindRaw
        ))
        let outcome = try #require(ExternalOutcome(
            rawValue: operation.outcomeRaw
        ))
        let decodedFailureKind = try #require(ExternalFailureKindRaw(
            rawValue: operation.failureKindRaw ?? 0
        ))
        let decoded = try OperationPayloadBlobCodec.decode(
            operation.payloadBlob,
            context: OperationPayloadRecordContextV1(
                connectionID: operation.connectionIDRaw,
                capability: ExternalCapability(
                    rawValue: operation.capabilityRaw ?? 0
                ),
                operationKind: operationKind,
                outcome: outcome,
                failureKind: decodedFailureKind,
                denialReason: operation.denialReasonRaw.flatMap(
                    ExternalDenialReason.init(rawValue:)
                ),
                changePosition: operation.changePositionRaw,
                auditSequence: operation.auditSequence,
                compactionFloor: snapshot.configs.first?.compactionFloor,
                nextAuditSequence: snapshot.configs.first?.nextAuditSequence
            )
        )
        #expect(decoded.request == descriptor.requestSummary)
        #expect(decoded.result == .none)
    }

    @Test("unknown connection is unaudited and leaves History unchanged")
    func unknownConnectionIsUnaudited() async throws {
        let fixture = try await Self.makeFixture()

        await #expect(throws: ExternalFailure.unauthorized(
            requestedCapability: .manage,
            connectionID: Self.unknownConnectionID
        )) {
            try await fixture.authority.authorizeExternal(
                Self.pinDescriptor,
                as: Self.unknownConnectionID
            )
        }

        #expect(try Self.snapshot(fixture).operations.isEmpty)
        #expect(fixture.clock.callCount == 2)
        try await Self.expectHistoryPositionUnchanged(fixture)
    }

    @Test("known active connection without a grant audits before unauthorized")
    func missingGrantIsAudited() async throws {
        let fixture = try await Self.makeFixture()

        await #expect(throws: ExternalFailure.unauthorized(
            requestedCapability: .manage,
            connectionID: Self.connectionID
        )) {
            try await fixture.authority.authorizeExternal(
                Self.pinDescriptor,
                as: Self.connectionID
            )
        }

        let snapshot = try Self.snapshot(fixture)
        let operation = try #require(snapshot.operations.first)
        #expect(snapshot.operations.count == 1)
        #expect(operation.requestedAt == Self.epoch.addingTimeInterval(1))
        #expect(operation.committedAt == Self.epoch.addingTimeInterval(2))
        try Self.expectDeniedOperation(
            operation,
            descriptor: Self.pinDescriptor,
            failureKind: .unauthorized,
            denialReason: nil,
            snapshot: snapshot
        )
        #expect(fixture.clock.callCount == 3)
        try await Self.expectHistoryPositionUnchanged(fixture)
    }

    @Test("known revoked connection audits before connectionRevoked")
    func revokedConnectionIsAudited() async throws {
        let fixture = try await Self.makeFixture()
        // The connection lifecycle wins even if its formerly live grant row
        // has not yet been revoked by this deliberately damaged fixture.
        try Self.insertGrant(.manage, in: fixture)
        try Self.revokeConnection(in: fixture)

        await #expect(throws: ExternalFailure.connectionRevoked(
            connectionID: Self.connectionID
        )) {
            try await fixture.authority.authorizeExternal(
                Self.pinDescriptor,
                as: Self.connectionID
            )
        }

        let snapshot = try Self.snapshot(fixture)
        let operation = try #require(snapshot.operations.first)
        #expect(snapshot.operations.count == 1)
        try Self.expectDeniedOperation(
            operation,
            descriptor: Self.pinDescriptor,
            failureKind: .connectionRevoked,
            denialReason: nil,
            snapshot: snapshot
        )
        try await Self.expectHistoryPositionUnchanged(fixture)
    }

    @Test("revoked matching grant is audited as unauthorized")
    func revokedGrantIsAudited() async throws {
        let fixture = try await Self.makeFixture()
        try Self.insertGrant(
            .manage,
            revokedAt: Self.epoch.addingTimeInterval(2),
            in: fixture
        )

        await #expect(throws: ExternalFailure.unauthorized(
            requestedCapability: .manage,
            connectionID: Self.connectionID
        )) {
            try await fixture.authority.authorizeExternal(
                Self.pinDescriptor,
                as: Self.connectionID
            )
        }

        let snapshot = try Self.snapshot(fixture)
        let operation = try #require(snapshot.operations.first)
        #expect(snapshot.operations.count == 1)
        try Self.expectDeniedOperation(
            operation,
            descriptor: Self.pinDescriptor,
            failureKind: .unauthorized,
            denialReason: nil,
            snapshot: snapshot
        )
        try await Self.expectHistoryPositionUnchanged(fixture)
    }

    @Test("live matching grant authorizes without writing audit or History")
    func liveGrantAuthorizesWithoutWrites() async throws {
        let fixture = try await Self.makeFixture()
        try Self.insertGrant(.manage, in: fixture)

        try await fixture.authority.authorizeExternal(
            Self.pinDescriptor,
            as: Self.connectionID
        )

        #expect(try Self.snapshot(fixture).operations.isEmpty)
        #expect(fixture.clock.callCount == 2)
        try await Self.expectHistoryPositionUnchanged(fixture)
    }

    @Test("live manage grant satisfies browse without loading a second policy")
    func manageGrantImpliesBrowse() async throws {
        let fixture = try await Self.makeFixture()
        try Self.insertGrant(.manage, in: fixture)

        try await fixture.authority.authorizeExternal(
            Self.recentDescriptor,
            as: Self.connectionID
        )

        #expect(try Self.snapshot(fixture).operations.isEmpty)
        try await Self.expectHistoryPositionUnchanged(fixture)
    }

    @Test("rate denial precedes revoked status and grant checks")
    func rateDenialIsAuditedBeforeAuthorizationPolicy() async throws {
        let fixture = try await Self.makeFixture()
        try Self.revokeConnection(in: fixture)
        let requestedAt = fixture.clock.now()

        try await fixture.authority.commitExternalRateDenial(
            Self.pinDescriptor,
            as: Self.connectionID,
            requestedAt: requestedAt
        )

        let snapshot = try Self.snapshot(fixture)
        let operation = try #require(snapshot.operations.first)
        #expect(snapshot.operations.count == 1)
        #expect(operation.requestedAt == requestedAt)
        #expect(operation.committedAt > requestedAt)
        try Self.expectDeniedOperation(
            operation,
            descriptor: Self.pinDescriptor,
            failureKind: .requestDenied,
            denialReason: .rateLimited,
            snapshot: snapshot
        )
        try await Self.expectHistoryPositionUnchanged(fixture)
    }
}
