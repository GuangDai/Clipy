/// X.5 real in-process Gateway denial proofs.
/// Owning spec: `V2-05` §3.1/§4.5/§8 and roadmap X.5.
import Foundation
import HistoryCore
import SwiftData
import Synchronization
import Testing
@testable import HistoryStorage

@Suite("External Gateway denial (X.5)")
struct ExternalGatewayDenialTests {
    private static let appIntentsUUID = UUID(
        uuidString: "00000000-0000-0000-0000-000000001051"
    )!
    private static let unknownUUID = UUID(
        uuidString: "00000000-0000-0000-0000-000000001053"
    )!
    private static let epoch = Date(
        timeIntervalSinceReferenceDate: 900_500_000
    )

    private struct FixedClock: StorageClock {
        let fixed: Date

        func now() -> Date { fixed }
    }

    private final class UUIDSource: Sendable {
        private let values: Mutex<[UUID]>

        init(_ values: [UUID]) {
            self.values = Mutex(values)
        }

        func next() -> UUID {
            values.withLock { $0.removeFirst() }
        }
    }

#if DEBUG
    private struct ExpectedParkMissing: Error {}

    private final class FirstEventRace: Sendable {
        enum Event: Sendable, Equatable {
            case parked
            case completed
        }

        private struct State: Sendable {
            var first: Event?
            var waiter: CheckedContinuation<Event, Never>?
        }

        private let state = Mutex(State())

        func track(
            _ operation: @escaping @Sendable () async throws -> Void
        ) async throws {
            do {
                try await operation()
                signal(.completed)
            } catch {
                signal(.completed)
                throw error
            }
        }

        func signal(_ event: Event) {
            let waiter: CheckedContinuation<Event, Never>? =
                state.withLock { state in
                    guard state.first == nil else { return nil }
                    state.first = event
                    defer { state.waiter = nil }
                    return state.waiter
                }
            waiter?.resume(returning: event)
        }

        func wait() async -> Event {
            await withCheckedContinuation { continuation in
                let immediate: Event? = state.withLock { state in
                    if let first = state.first { return first }
                    precondition(state.waiter == nil)
                    state.waiter = continuation
                    return nil
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                }
            }
        }
    }

    private final class CompactionEntryCounter: Sendable {
        private struct State: Sendable {
            var count = 0
            var thirdRequestExpected = false
        }

        private let state = Mutex(State())

        func record() -> (count: Int, thirdRequestExpected: Bool) {
            state.withLock { state in
                state.count += 1
                return (state.count, state.thirdRequestExpected)
            }
        }

        func expectThirdRequest() {
            state.withLock { $0.thirdRequestExpected = true }
        }

        var value: Int {
            state.withLock { $0.count }
        }
    }

    private static func requirePark(
        _ race: FirstEventRace,
        before task: Task<Void, Error>
    ) async throws {
        switch await race.wait() {
        case .parked:
            return
        case .completed:
            try await task.value
            throw ExpectedParkMissing()
        }
    }
#endif

    private struct HistoryValueSnapshot: Equatable {
        struct Item: Equatable {
            let id: UUID
            let contentVersionRaw: UInt64
            let canonicalBlob: Data
            let revisionStateBlob: Data
            let canonicalSignatureBlob: Data

            init(_ row: HistoryItemRow) {
                id = row.id
                contentVersionRaw = row.contentVersionRaw
                canonicalBlob = row.canonicalBlob
                revisionStateBlob = row.revisionStateBlob
                canonicalSignatureBlob = row.canonicalSignatureBlob
            }
        }

        struct RetainedBytes: Equatable {
            let itemID: UUID
            let canonicalBytes: Int
            let revisionCount: Int
            let revisionBytes: Int
            let bytesSchemaVersion: UInt16

            init(_ row: RetainedBytesRow) {
                itemID = row.itemID
                canonicalBytes = row.canonicalBytes
                revisionCount = row.revisionCount
                revisionBytes = row.revisionBytes
                bytesSchemaVersion = row.bytesSchemaVersion
            }
        }

        let position: UInt64
        let items: [Item]
        let retainedBytes: [RetainedBytes]
    }

    private struct JournalValueSnapshot: Equatable {
        struct Config: Equatable {
            let key: String
            let compactionFloorRaw: UInt64
            let journalBytes: UInt64
            let configSchemaVersion: UInt16

            init(_ row: JournalConfigRow) {
                key = row.key
                compactionFloorRaw = row.compactionFloorRaw
                journalBytes = row.journalBytes
                configSchemaVersion = row.configSchemaVersion
            }
        }

        struct Record: Equatable {
            let sequence: UInt64
            let changePositionRaw: UInt64
            let changeKindRaw: Int16
            let affectedItemsBlob: Data
            let createdAt: Date

            init(_ row: HistoryChangeRecordRow) {
                sequence = row.sequence
                changePositionRaw = row.changePositionRaw
                changeKindRaw = row.changeKindRaw
                affectedItemsBlob = row.affectedItemsBlob
                createdAt = row.createdAt
            }
        }

        let configs: [Config]
        let records: [Record]
    }

    private struct DurableValueSnapshot: Equatable {
        let history: HistoryValueSnapshot
        let journal: JournalValueSnapshot
        let gateway: GatewayStoreSnapshot
    }

    private struct Fixture {
        let authority: HistoryAuthority
        let container: ModelContainer
        let connection: ExternalConnectionID
        let gateway: ExternalGateway
    }

    private enum Route {
        case request(ExternalRequest)
        case read(ExternalRead)

        func authorize(
            on gateway: ExternalGateway,
            as connection: ExternalConnectionID
        ) async throws {
            switch self {
            case .request(let request):
                try await gateway.authorize(request, as: connection)
            case .read(let read):
                try await gateway.authorize(read, as: connection)
            }
        }
    }

    private static func makeFixture(
        limits: ExternalLimits = .standard,
        rateLimiter: ExternalRateLimiter? = nil
    ) async throws -> Fixture {
        let schema = Schema(versionedSchema: HistorySchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )]
        )
        let idSource = UUIDSource([
            Self.appIntentsUUID,
        ])
        let storageClock = FixedClock(fixed: Self.epoch)
        let authority = HistoryAuthority(
            container: container,
            storageClock: storageClock,
            gatewayConnectionIDSource: { idSource.next() }
        )
        try await authority.performStartup(initialMaximumUnpinnedItems: 200)

        let preparation = IngestPreparationActor()
        let prepared = try await preparation.prepare(WSSupport.textCapture(
            "gateway-history-sentinel",
            observedAt: Self.epoch
        ))
        _ = try await authority.commitCapture(prepared)

        let gateway = ExternalGateway(
            authority: authority,
            appIntentsConnectionID: ExternalConnectionID(
                rawValue: Self.appIntentsUUID
            ),
            rateLimiter: rateLimiter
                ?? ExternalRateLimiter(initialUptimeNanoseconds: 0),
            limits: limits,
            searchWorker: SearchWorker(),
            storageClock: storageClock,
            uptimeNanoseconds: { 0 }
        )
        return Fixture(
            authority: authority,
            container: container,
            connection: ExternalConnectionID(rawValue: Self.appIntentsUUID),
            gateway: gateway
        )
    }

    private static func historySnapshot(
        in container: ModelContainer
    ) throws -> HistoryValueSnapshot {
        let context = ModelContext(container)
        let position = try #require(
            context.fetch(FetchDescriptor<LastChangePositionRow>()).first
        )
        let items = try context.fetch(FetchDescriptor<HistoryItemRow>())
            .map(HistoryValueSnapshot.Item.init)
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let retainedBytes = try context.fetch(FetchDescriptor<RetainedBytesRow>())
            .map(HistoryValueSnapshot.RetainedBytes.init)
            .sorted { $0.itemID.uuidString < $1.itemID.uuidString }
        return HistoryValueSnapshot(
            position: position.rawValue,
            items: items,
            retainedBytes: retainedBytes
        )
    }

    private static func gatewaySnapshot(
        in container: ModelContainer
    ) throws -> GatewayStoreSnapshot {
        try GatewayStoreSnapshot.read(in: ModelContext(container))
    }

    private static func durableSnapshot(
        in container: ModelContainer
    ) throws -> DurableValueSnapshot {
        let context = ModelContext(container)
        let configs = try context.fetch(FetchDescriptor<JournalConfigRow>())
            .map(JournalValueSnapshot.Config.init)
            .sorted { $0.key < $1.key }
        let records = try context.fetch(FetchDescriptor<HistoryChangeRecordRow>())
            .map(JournalValueSnapshot.Record.init)
            .sorted { $0.sequence < $1.sequence }
        return DurableValueSnapshot(
            history: try historySnapshot(in: container),
            journal: JournalValueSnapshot(configs: configs, records: records),
            gateway: try GatewayStoreSnapshot.read(in: context)
        )
    }

    private static func rateLimiterWithTwoTokensRemaining()
        -> ExternalRateLimiter
    {
        var limiter = ExternalRateLimiter(initialUptimeNanoseconds: 0)
        for _ in 0..<28 {
            _ = limiter.admit(atUptimeNanoseconds: 0)
        }
        return limiter
    }

#if DEBUG
    private final class HistoryReadProbe: Sendable {
        private let phases = Mutex<[StorageLifecycleDebugPhase]>([])

        func record(_ phase: StorageLifecycleDebugPhase) {
            phases.withLock { $0.append(phase) }
        }

        var reachedRecentRead: Bool {
            phases.withLock { $0.contains(.recentFetchBegin) }
        }
    }

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

    private static func expectNoRecentHistoryRead(
        _ probe: HistoryReadProbe
    ) {
        #expect(!probe.reachedRecentRead)
    }
#endif

    @Test("public open constructs the internal Gateway only after startup")
    func publicOpenWiresTheInternalGateway() async throws {
        let history = try await SwiftDataHistory.open(configuration:
            HistoryConfiguration(persistence: .memory)
        )
        let connections = try await history.connections()
        let connection = try #require(connections.first).id
        try await history.grantCapability(.browse, to: connection)

        try await history.externalGateway.authorize(
            .recent(limit: 1),
            as: connection
        )

        let audit = try await history.auditLog(since: 1)
        #expect(audit.map(\.operationKind) == [
            .adminReadConnections,
            .adminGrant,
        ])
        #expect(audit.last?.outcome == .succeeded)
    }

    @Test("missing browse grant denies before History and audits no content")
    func missingGrantDeniesBeforeHistoryWithoutContentLeakage() async throws {
        let fixture = try await Self.makeFixture()
        let historyBefore = try Self.historySnapshot(in: fixture.container)
        let gatewayBefore = try Self.gatewaySnapshot(in: fixture.container)
#if DEBUG
        let phases = await Self.installHistoryReadProbe(on: fixture.authority)
#endif
        let privateQuery = "private-query-literal-1051"

        await #expect(throws: ExternalFailure.unauthorized(
            requestedCapability: .browse,
            connectionID: fixture.connection
        )) {
            try await fixture.gateway.authorize(
                .search(text: privateQuery, mode: .exact, limit: 10),
                as: fixture.connection
            )
        }

        #expect(try Self.historySnapshot(in: fixture.container) == historyBefore)
        let gatewayAfter = try Self.gatewaySnapshot(in: fixture.container)
        #expect(gatewayAfter.operations.count == gatewayBefore.operations.count + 1)
        let operation = try #require(gatewayAfter.operations.last)
        #expect(operation.operationKindRaw == ExternalOperationKind.readSearch.rawValue)
        #expect(operation.outcomeRaw == ExternalOutcome.denied.rawValue)
        #expect(operation.failureKindRaw == ExternalFailureKindRaw.unauthorized.rawValue)
        #expect(operation.denialReasonRaw == nil)
        #expect(operation.changePositionRaw == nil)
        #expect(operation.payloadBlob.range(of: Data(privateQuery.utf8)) == nil)
#if DEBUG
        Self.expectNoRecentHistoryRead(phases)
#endif
    }

    @Test("all seven closed requests map to their exact capability and kind")
    func closedRequestRoutingIsExhaustive() async throws {
        struct ExpectedRoute {
            let route: Route
            let capability: ExternalCapability
            let operationKind: ExternalOperationKind
        }

        let fixture = try await Self.makeFixture()
        let itemID = HistoryItemID(rawValue: Self.unknownUUID)
        let expected: [ExpectedRoute] = [
            ExpectedRoute(
                route: .request(.pin(itemID)),
                capability: .manage,
                operationKind: .managePin
            ),
            ExpectedRoute(
                route: .request(.unpin(itemID)),
                capability: .manage,
                operationKind: .manageUnpin
            ),
            ExpectedRoute(
                route: .request(.remove(itemID)),
                capability: .manage,
                operationKind: .manageRemove
            ),
            ExpectedRoute(
                route: .read(.recent(limit: 1)),
                capability: .browse,
                operationKind: .readRecent
            ),
            ExpectedRoute(
                route: .read(.search(text: "route", mode: .fuzzy, limit: 1)),
                capability: .browse,
                operationKind: .readSearch
            ),
            ExpectedRoute(
                route: .read(.details(itemID)),
                capability: .readContent,
                operationKind: .readDetails
            ),
            ExpectedRoute(
                route: .read(.pastePayload(itemID)),
                capability: .readContent,
                operationKind: .readPastePayload
            ),
        ]
        let before = try Self.gatewaySnapshot(in: fixture.container)

        for candidate in expected {
            await #expect(throws: ExternalFailure.unauthorized(
                requestedCapability: candidate.capability,
                connectionID: fixture.connection
            )) {
                try await candidate.route.authorize(
                    on: fixture.gateway,
                    as: fixture.connection
                )
            }
        }

        let after = try Self.gatewaySnapshot(in: fixture.container)
        #expect(after.operations.count == before.operations.count + expected.count)
        let appended = after.operations.suffix(expected.count)
        for (operation, candidate) in zip(appended, expected) {
            #expect(operation.connectionIDRaw == Self.appIntentsUUID)
            #expect(operation.capabilityRaw == candidate.capability.rawValue)
            #expect(operation.operationKindRaw == candidate.operationKind.rawValue)
            #expect(operation.outcomeRaw == ExternalOutcome.denied.rawValue)
            #expect(operation.failureKindRaw
                == ExternalFailureKindRaw.unauthorized.rawValue)
        }
    }

    @Test("revoked connection denies before History with its typed audit")
    func revokedConnectionDeniesBeforeHistory() async throws {
        let fixture = try await Self.makeFixture()
        try await fixture.authority.revokeConnection(fixture.connection)
        let historyBefore = try Self.historySnapshot(in: fixture.container)
        let gatewayBefore = try Self.gatewaySnapshot(in: fixture.container)
#if DEBUG
        let phases = await Self.installHistoryReadProbe(on: fixture.authority)
#endif

        await #expect(throws: ExternalFailure.connectionRevoked(
            connectionID: fixture.connection
        )) {
            try await fixture.gateway.authorize(
                .recent(limit: 10),
                as: fixture.connection
            )
        }

        #expect(try Self.historySnapshot(in: fixture.container) == historyBefore)
        let gatewayAfter = try Self.gatewaySnapshot(in: fixture.container)
        #expect(gatewayAfter.operations.count == gatewayBefore.operations.count + 1)
        let operation = try #require(gatewayAfter.operations.last)
        #expect(operation.failureKindRaw
            == ExternalFailureKindRaw.connectionRevoked.rawValue)
        #expect(operation.changePositionRaw == nil)
#if DEBUG
        Self.expectNoRecentHistoryRead(phases)
#endif
    }

    @Test("revoked grant denies before History while connection stays active")
    func revokedGrantDeniesBeforeHistory() async throws {
        let fixture = try await Self.makeFixture()
        try await fixture.authority.grantCapability(
            .browse,
            to: fixture.connection
        )
        try await fixture.authority.revokeCapability(
            .browse,
            of: fixture.connection
        )
        let historyBefore = try Self.historySnapshot(in: fixture.container)
        let gatewayBefore = try Self.gatewaySnapshot(in: fixture.container)
#if DEBUG
        let phases = await Self.installHistoryReadProbe(on: fixture.authority)
#endif

        await #expect(throws: ExternalFailure.unauthorized(
            requestedCapability: .browse,
            connectionID: fixture.connection
        )) {
            try await fixture.gateway.authorize(
                .recent(limit: 10),
                as: fixture.connection
            )
        }

        #expect(try Self.historySnapshot(in: fixture.container) == historyBefore)
        let gatewayAfter = try Self.gatewaySnapshot(in: fixture.container)
        #expect(gatewayAfter.operations.count == gatewayBefore.operations.count + 1)
        let operation = try #require(gatewayAfter.operations.last)
        #expect(operation.failureKindRaw
            == ExternalFailureKindRaw.unauthorized.rawValue)
        #expect(operation.changePositionRaw == nil)
#if DEBUG
        Self.expectNoRecentHistoryRead(phases)
#endif
    }

    @Test("invalid input and connection-kind pair never reach Authority audit")
    func invalidInputAndPairAreUnaudited() async throws {
        let fixture = try await Self.makeFixture()
        let invalidReads: [ExternalRead] = [
            .recent(limit: 0),
            .recent(limit: 501),
            .search(text: String(repeating: "a", count: 4_097), mode: .exact, limit: 1),
            .search(text: String(repeating: "a", count: 65), mode: .fuzzy, limit: 1),
            .search(text: String(repeating: "a", count: 513), mode: .regexp, limit: 1),
        ]
        let beforeInvalidInput = try Self.gatewaySnapshot(in: fixture.container)
        for read in invalidReads {
            await #expect(throws: ExternalFailure.requestDenied(.invalidInput)) {
                try await fixture.gateway.authorize(read, as: fixture.connection)
            }
        }
        for _ in 0..<25 {
            await #expect(throws: ExternalFailure.requestDenied(.invalidInput)) {
                try await fixture.gateway.authorize(
                    .recent(limit: 0),
                    as: fixture.connection
                )
            }
        }
        #expect(try Self.gatewaySnapshot(in: fixture.container) == beforeInvalidInput)

        let invalidPair = ExternalOperationDescriptor(
            capability: .readContent,
            operationKind: .managePin,
            requestSummary: .pin(itemID: Self.unknownUUID)
        )
        let beforeInvalidPair = try Self.gatewaySnapshot(in: fixture.container)
        for _ in 0..<30 {
            await #expect(throws: ExternalFailure.requestDenied(.invalidInput)) {
                try await fixture.gateway.authorize(
                    invalidPair,
                    as: fixture.connection
                )
            }
        }
        #expect(try Self.gatewaySnapshot(in: fixture.container) == beforeInvalidPair)

        // Thirty malformed requests and thirty invalid pairs consume no
        // token. The next thirty well-formed calls exhaust the bucket, and
        // only the following call is rate denied.
        for _ in 0..<30 {
            await #expect(throws: ExternalFailure.unauthorized(
                requestedCapability: .browse,
                connectionID: fixture.connection
            )) {
                try await fixture.gateway.authorize(
                    .recent(limit: 1),
                    as: fixture.connection
                )
            }
        }
        await #expect(throws: ExternalFailure.requestDenied(.rateLimited)) {
            try await fixture.gateway.authorize(
                .recent(limit: 1),
                as: fixture.connection
            )
        }
    }

    @Test("unknown connection is non-enumerating and unaudited")
    func unknownConnectionIsUnaudited() async throws {
        let fixture = try await Self.makeFixture()
        let unknown = ExternalConnectionID(rawValue: Self.unknownUUID)
        let before = try Self.gatewaySnapshot(in: fixture.container)

        await #expect(throws: ExternalFailure.unauthorized(
            requestedCapability: .browse,
            connectionID: unknown
        )) {
            try await fixture.gateway.authorize(.recent(limit: 1), as: unknown)
        }
        await #expect(throws: ExternalFailure.unauthorized(
            requestedCapability: .browse,
            connectionID: unknown
        )) {
            try await fixture.gateway.authorize(.recent(limit: 0), as: unknown)
        }

        #expect(try Self.gatewaySnapshot(in: fixture.container) == before)
    }

    @Test("the same-time thirty-first request is rate denied and audited")
    func rateLimitDenialUsesAuthorityAuditBarrier() async throws {
        let fixture = try await Self.makeFixture()
        let historyBefore = try Self.historySnapshot(in: fixture.container)
#if DEBUG
        let phases = await Self.installHistoryReadProbe(on: fixture.authority)
#endif

        for _ in 0..<30 {
            await #expect(throws: ExternalFailure.unauthorized(
                requestedCapability: .browse,
                connectionID: fixture.connection
            )) {
                try await fixture.gateway.authorize(
                    .recent(limit: 1),
                    as: fixture.connection
                )
            }
        }
        let beforeRateDenial = try Self.gatewaySnapshot(in: fixture.container)
        await #expect(throws: ExternalFailure.requestDenied(.rateLimited)) {
            try await fixture.gateway.authorize(
                .recent(limit: 1),
                as: fixture.connection
            )
        }

        #expect(try Self.historySnapshot(in: fixture.container) == historyBefore)
        let afterRateDenial = try Self.gatewaySnapshot(in: fixture.container)
        #expect(afterRateDenial.operations.count
            == beforeRateDenial.operations.count + 1)
        let operation = try #require(afterRateDenial.operations.last)
        #expect(operation.outcomeRaw == ExternalOutcome.denied.rawValue)
        #expect(operation.failureKindRaw
            == ExternalFailureKindRaw.requestDenied.rawValue)
        #expect(operation.denialReasonRaw
            == ExternalDenialReason.rateLimited.rawValue)
        #expect(operation.changePositionRaw == nil)
#if DEBUG
        Self.expectNoRecentHistoryRead(phases)
#endif
    }

    @Test("failed cadence maintenance precedes a destructive request")
    func failedCadenceMaintenanceDoesNotRemoveOrDebit() async throws {
        let limits = GatewayAuditTestSupport.limits(
            maxAuditLogSize: 1,
            compactionCadenceOps: 2
        )
        let fixture = try await Self.makeFixture(
            limits: limits,
            rateLimiter: Self.rateLimiterWithTwoTokensRemaining()
        )
        await #expect(throws: ExternalFailure.unauthorized(
            requestedCapability: .browse,
            connectionID: fixture.connection
        )) {
            try await fixture.gateway.authorize(
                .recent(limit: 1),
                as: fixture.connection
            )
        }
        try await fixture.authority.grantCapability(
            .manage,
            to: fixture.connection
        )
        let before = try Self.durableSnapshot(in: fixture.container)
        let itemUUID = try #require(before.history.items.first).id
        let itemID = HistoryItemID(rawValue: itemUUID)
        await fixture.authority.setTransactionFailureInjection(
            .beforeGatewayAuditCompaction
        )

        await #expect(throws: ExternalFailure.persistence(.transaction)) {
            _ = try await fixture.gateway.perform(
                .remove(itemID),
                as: fixture.connection
            )
        }
        #expect(try Self.durableSnapshot(in: fixture.container) == before)

        guard case .removed(count: 1) = try await fixture.gateway.perform(
            .remove(itemID),
            as: fixture.connection
        ) else {
            Issue.record("expected identical retry to remove one item")
            return
        }
        #expect(try Self.historySnapshot(in: fixture.container).items.isEmpty)
        let afterRetry = try Self.gatewaySnapshot(in: fixture.container)
        #expect(afterRetry.operations.last?.operationKindRaw
            == ExternalOperationKind.manageRemove.rawValue)
        #expect(afterRetry.operations.dropLast().last?.operationKindRaw
            == ExternalOperationKind.adminCompact.rawValue)
    }

    @Test("failed cadence maintenance precedes a History read")
    func failedCadenceMaintenanceDoesNotReadOrDebit() async throws {
        let limits = GatewayAuditTestSupport.limits(
            maxAuditLogSize: 1,
            compactionCadenceOps: 2
        )
        let fixture = try await Self.makeFixture(
            limits: limits,
            rateLimiter: Self.rateLimiterWithTwoTokensRemaining()
        )
        try await fixture.authority.grantCapability(
            .browse,
            to: fixture.connection
        )
        try await fixture.gateway.authorize(
            .recent(limit: 1),
            as: fixture.connection
        )
        let before = try Self.durableSnapshot(in: fixture.container)
        let expectedItemID = HistoryItemID(
            rawValue: try #require(before.history.items.first).id
        )
#if DEBUG
        let phases = await Self.installHistoryReadProbe(on: fixture.authority)
#endif
        await fixture.authority.setTransactionFailureInjection(
            .beforeGatewayAuditCompaction
        )

        await #expect(throws: ExternalFailure.persistence(.transaction)) {
            _ = try await fixture.gateway.read(
                .recent(limit: 1),
                as: fixture.connection
            )
        }
        #expect(try Self.durableSnapshot(in: fixture.container) == before)
#if DEBUG
        Self.expectNoRecentHistoryRead(phases)
#endif

        guard case .page(let page) = try await fixture.gateway.read(
            .recent(limit: 1),
            as: fixture.connection
        ) else {
            Issue.record("expected identical retry to return a page")
            return
        }
        #expect(page.rows.map(\.item.id) == [expectedItemID])
        let afterRetry = try Self.gatewaySnapshot(in: fixture.container)
        #expect(afterRetry.operations.last?.operationKindRaw
            == ExternalOperationKind.readRecent.rawValue)
        #expect(afterRetry.operations.dropLast().last?.operationKindRaw
            == ExternalOperationKind.adminCompact.rawValue)
    }

#if DEBUG
    @Test("concurrent cadence follower shares and advances maintenance")
    func concurrentFollowerSharesCompactionAndCountsNextInterval() async throws {
        let limits = GatewayAuditTestSupport.limits(
            maxAuditLogSize: ExternalLimits.standard.maxAuditLogSize,
            compactionCadenceOps: 2
        )
        let fixture = try await Self.makeFixture(limits: limits)
        try await fixture.authority.grantCapability(
            .browse,
            to: fixture.connection
        )
        try await fixture.gateway.authorize(
            .recent(limit: 1),
            as: fixture.connection
        )

        let compactionGate = SuspensionGate()
        let followerGate = SuspensionGate()
        let firstCompactionRace = FirstEventRace()
        let followerRace = FirstEventRace()
        let thirdCompactionRace = FirstEventRace()
        let entryCounter = CompactionEntryCounter()
        let entryPoint = AuthoritySuspensionPoint
            .gatewayAuditCompactionEntry.rawValue
        let followerPoint = "ExternalGateway.compactionFollower.joined"
        let gateway = fixture.gateway
        let connection = fixture.connection
        await fixture.authority.setSuspensionHandler { point in
            guard point == .gatewayAuditCompactionEntry else { return }
            let entry = entryCounter.record()
            if entry.count == 1 {
                firstCompactionRace.signal(.parked)
                await compactionGate.park(at: point.rawValue)
            } else if entry.count == 2, entry.thirdRequestExpected {
                thirdCompactionRace.signal(.parked)
                await compactionGate.park(at: point.rawValue)
            }
        }

        var first: Task<Void, Error>?
        var second: Task<Void, Error>?
        var third: Task<Void, Error>?
        do {
            let firstTask = Task {
                try await firstCompactionRace.track {
                    try await gateway.authorize(
                        .recent(limit: 1),
                        as: connection
                    )
                }
            }
            first = firstTask
            try await Self.requirePark(
                firstCompactionRace,
                before: firstTask
            )

            let secondTask = Task {
                try await followerRace.track {
                    try await ExternalGatewayDebugInstrumentation
                        .$compactionFollowerDidJoin.withValue({
                            followerRace.signal(.parked)
                            await followerGate.park(at: followerPoint)
                        }) {
                            try await gateway.authorize(
                                .recent(limit: 1),
                                as: connection
                            )
                        }
                }
            }
            second = secondTask
            try await Self.requirePark(followerRace, before: secondTask)

            await followerGate.resume(followerPoint)
            await compactionGate.resume(entryPoint)
            try await firstTask.value
            try await secondTask.value
            try #require(entryCounter.value == 1)

            entryCounter.expectThirdRequest()
            let thirdTask = Task {
                try await thirdCompactionRace.track {
                    try await gateway.authorize(
                        .recent(limit: 1),
                        as: connection
                    )
                }
            }
            third = thirdTask
            try await Self.requirePark(
                thirdCompactionRace,
                before: thirdTask
            )
            #expect(entryCounter.value == 2)
            await compactionGate.resume(entryPoint)
            try await thirdTask.value
        } catch {
            await followerGate.resumeAll()
            await compactionGate.resumeAll()
            first?.cancel()
            second?.cancel()
            third?.cancel()
            if let first {
                _ = try? await first.value
            }
            if let second {
                _ = try? await second.value
            }
            if let third {
                _ = try? await third.value
            }
            await fixture.authority.setSuspensionHandler(nil)
            throw error
        }
        await fixture.authority.setSuspensionHandler(nil)
    }
#endif

    @Test("the admitted-operation cadence precedes the request denial")
    func admittedCadenceCompactsBeforeThePublishedDenial() async throws {
        let limits = GatewayAuditTestSupport.limits(
            maxAuditLogSize: 1,
            compactionCadenceOps: 1
        )
        let fixture = try await Self.makeFixture(limits: limits)
        try await fixture.authority.grantCapability(
            .browse,
            to: fixture.connection
        )
        try await fixture.authority.revokeCapability(
            .browse,
            of: fixture.connection
        )

        await #expect(throws: ExternalFailure.unauthorized(
            requestedCapability: .browse,
            connectionID: fixture.connection
        )) {
            try await fixture.gateway.authorize(
                .recent(limit: 1),
                as: fixture.connection
            )
        }

        let snapshot = try Self.gatewaySnapshot(in: fixture.container)
        let config = try #require(snapshot.configs.first)
        #expect(config.compactionFloor > 1)
        #expect(snapshot.operations.last?.operationKindRaw
            == ExternalOperationKind.readRecent.rawValue)
        #expect(snapshot.operations.last?.outcomeRaw
            == ExternalOutcome.denied.rawValue)
        #expect(snapshot.operations.dropLast().last?.operationKindRaw
            == ExternalOperationKind.adminCompact.rawValue)
    }

    @Test("rate denials participate in the admitted-operation cadence")
    func rateDenialCadenceCompactsItsPublishedAudit() async throws {
        let limits = GatewayAuditTestSupport.limits(
            maxAuditLogSize: 1,
            compactionCadenceOps: 1
        )
        var exhausted = ExternalRateLimiter(initialUptimeNanoseconds: 0)
        for _ in 0..<30 {
            let admitted = exhausted.admit(atUptimeNanoseconds: 0)
            #expect(admitted)
        }
        let fixture = try await Self.makeFixture(
            limits: limits,
            rateLimiter: exhausted
        )
        try await fixture.authority.grantCapability(
            .browse,
            to: fixture.connection
        )

        await #expect(throws: ExternalFailure.requestDenied(.rateLimited)) {
            try await fixture.gateway.authorize(
                .recent(limit: 1),
                as: fixture.connection
            )
        }

        let snapshot = try Self.gatewaySnapshot(in: fixture.container)
        let config = try #require(snapshot.configs.first)
        #expect(config.compactionFloor > 1)
        #expect(snapshot.operations.last?.operationKindRaw
            == ExternalOperationKind.readRecent.rawValue)
        #expect(snapshot.operations.last?.outcomeRaw
            == ExternalOutcome.denied.rawValue)
        #expect(snapshot.operations.dropLast().last?.operationKindRaw
            == ExternalOperationKind.adminCompact.rawValue)
    }
}
