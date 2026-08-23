/// Batch 13 X.6 positive reads at the real Authority/V4 seam.
/// Owning spec: `V2-05` §5.2 and X-BEHAVIOR-1.
import Foundation
import HistoryCore
import SwiftData
import Synchronization
import Testing
@testable import HistoryStorage

@Suite("Gateway granted external reads (X.6)")
struct GatewayExternalReadTests {
    private static let connectionUUID = UUID(
        uuidString: "00000000-0000-0000-0000-000000001361"
    )!
    private static let connectionID = ExternalConnectionID(
        rawValue: connectionUUID
    )
    private static let absentItemID = HistoryItemID(rawValue: UUID(
        uuidString: "00000000-0000-0000-0000-000000001362"
    )!)
    private static let epoch = Date(
        timeIntervalSinceReferenceDate: 912_000_000
    )
    private static let privateText =
        "batch13-private-content-54F75BBE-DA3A-4322-880B-380E5D574D98"

    private struct FixedClock: StorageClock {
        let fixed: Date
        func now() -> Date { fixed }
    }

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

    private struct Fixture {
        let authority: HistoryAuthority
        let container: ModelContainer
        let connection: ExternalConnectionID
        let searchWorker: SearchWorker
        let item: HistoryItemReference?
    }

    private struct HistoryState: Equatable {
        struct Item: Equatable {
            let id: UUID
            let contentVersionRaw: UInt64
            let canonicalBlob: Data
            let revisionStateBlob: Data
            let copyCount: UInt64
            let pinOrdinal: Int?
        }

        let position: UInt64
        let items: [Item]
    }

    private static func makeFixture(
        seedItem: Bool = true,
        storageClock: any StorageClock = FixedClock(fixed: epoch)
    ) async throws
        -> Fixture
    {
        let schema = Schema(versionedSchema: HistorySchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )]
        )
        let authority = HistoryAuthority(
            container: container,
            storageClock: storageClock,
            gatewayConnectionIDSource: { connectionUUID }
        )
        let connection = try await authority.performStartup(
            initialMaximumUnpinnedItems: 200
        )

        let item: HistoryItemReference?
        if seedItem {
            let prepared = try await IngestPreparationActor().prepare(
                WSSupport.textCapture(
                    privateText,
                    observedAt: epoch.addingTimeInterval(10),
                    source: "com.example.batch13.external-read"
                )
            )
            let receipt = try await authority.commitCapture(prepared)
            guard case .committed(let commit) = receipt,
                  case .inserted(let reference) = commit.outcome else {
                Issue.record("expected one inserted fixture item")
                throw HistoryFailure.persistence(.invariantViolation)
            }
            item = reference
        } else {
            item = nil
        }
        return Fixture(
            authority: authority,
            container: container,
            connection: connection,
            searchWorker: SearchWorker(),
            item: item
        )
    }

    private static func grant(
        _ capability: ExternalCapability,
        in fixture: Fixture
    ) async throws {
        try await fixture.authority.grantCapability(
            capability,
            to: fixture.connection
        )
    }

    private static func read(
        _ request: ExternalRead,
        in fixture: Fixture,
        requestedAt: Date = epoch
    ) async throws -> ExternalReadResult {
        try await fixture.authority.performExternalRead(
            request,
            connection: fixture.connection,
            requestedAt: requestedAt,
            searchWorker: fixture.searchWorker
        )
    }

    private static func snapshot(_ fixture: Fixture) throws
        -> GatewayStoreSnapshot
    {
        try GatewayStoreSnapshot.read(in: ModelContext(fixture.container))
    }

    private static func externalReadOperations(
        _ fixture: Fixture
    ) throws -> [GatewayStoreSnapshot.Operation] {
        try snapshot(fixture).operations.filter { operation in
            operation.operationKindRaw >= ExternalOperationKind.readRecent.rawValue
                && operation.operationKindRaw
                    <= ExternalOperationKind.readPastePayload.rawValue
        }
    }

    private static func historyState(_ fixture: Fixture) throws
        -> HistoryState
    {
        let context = ModelContext(fixture.container)
        let position = try #require(
            context.fetch(FetchDescriptor<LastChangePositionRow>()).first
        )
        let items = try context.fetch(FetchDescriptor<HistoryItemRow>())
            .map {
                HistoryState.Item(
                    id: $0.id,
                    contentVersionRaw: $0.contentVersionRaw,
                    canonicalBlob: $0.canonicalBlob,
                    revisionStateBlob: $0.revisionStateBlob,
                    copyCount: $0.copyCount,
                    pinOrdinal: $0.pinOrdinal
                )
            }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        return HistoryState(position: position.rawValue, items: items)
    }

    private static func cancelParkedSearch(
        in fixture: Fixture,
        injectAuditFailure: Bool = false
    ) async throws -> ExternalFailure {
        let gate = SuspensionGate()
        let point = SearchWorkerSuspensionPoint.evaluationEntry.rawValue
        await fixture.searchWorker.setSuspensionHandler { suspension in
            guard suspension == .evaluationEntry else { return }
            await gate.park(at: suspension.rawValue)
        }
        let authority = fixture.authority
        let connection = fixture.connection
        let worker = fixture.searchWorker
        let task = Task {
            try await authority.performExternalRead(
                .search(text: Self.privateText, mode: .exact, limit: 10),
                connection: connection,
                requestedAt: Self.epoch,
                searchWorker: worker
            )
        }
        await gate.waitForPark(point)
        if injectAuditFailure {
            await fixture.authority.setTransactionFailureInjection(
                .beforeSingletonUpdate
            )
        }
        task.cancel()
        await gate.resume(point)
        do {
            _ = try await task.value
            await fixture.searchWorker.setSuspensionHandler(nil)
            Issue.record("expected cancelled search failure")
            throw HistoryFailure.persistence(.invariantViolation)
        } catch let failure as ExternalFailure {
            await fixture.searchWorker.setSuspensionHandler(nil)
            return failure
        } catch {
            await fixture.searchWorker.setSuspensionHandler(nil)
            throw error
        }
    }

    private static func decodedPayload(
        _ operation: GatewayStoreSnapshot.Operation,
        snapshot: GatewayStoreSnapshot
    ) throws -> OperationPayloadBlobV1 {
        try OperationPayloadBlobCodec.decode(
            operation.payloadBlob,
            context: OperationPayloadRecordContextV1(
                connectionID: operation.connectionIDRaw,
                capability: operation.capabilityRaw.flatMap {
                    ExternalCapability(rawValue: $0)
                },
                operationKind: try #require(ExternalOperationKind(
                    rawValue: operation.operationKindRaw
                )),
                outcome: try #require(ExternalOutcome(
                    rawValue: operation.outcomeRaw
                )),
                failureKind: operation.failureKindRaw.flatMap {
                    ExternalFailureKindRaw(rawValue: $0)
                },
                denialReason: operation.denialReasonRaw.flatMap {
                    ExternalDenialReason(rawValue: $0)
                },
                changePosition: operation.changePositionRaw,
                auditSequence: operation.auditSequence,
                compactionFloor: snapshot.configs.first?.compactionFloor,
                nextAuditSequence: snapshot.configs.first?.nextAuditSequence
            )
        )
    }

    private static func expectSucceeded(
        _ operation: GatewayStoreSnapshot.Operation,
        capability: ExternalCapability,
        kind: ExternalOperationKind
    ) {
        #expect(operation.connectionIDRaw == connectionUUID)
        #expect(operation.capabilityRaw == capability.rawValue)
        #expect(operation.operationKindRaw == kind.rawValue)
        #expect(operation.outcomeRaw == ExternalOutcome.succeeded.rawValue)
        #expect(operation.failureKindRaw == nil)
        #expect(operation.denialReasonRaw == nil)
        #expect(operation.requestedAt == epoch)
        #expect(operation.changePositionRaw == nil)
    }

    @Test("all four reads publish real V1 projections after private audits")
    func allFourPositiveReads() async throws {
        let fixture = try await Self.makeFixture()
        let item = try #require(fixture.item)
        try await Self.grant(.browse, in: fixture)
        try await Self.grant(.readContent, in: fixture)

        let recent = try await Self.read(.recent(limit: 10), in: fixture)
        guard case .page(let recentPage) = recent else {
            Issue.record("expected recent page")
            return
        }
        #expect(recentPage.rows.map(\.item.id) == [item.id])

        let search = try await Self.read(
            .search(text: Self.privateText, mode: .exact, limit: 10),
            in: fixture
        )
        guard case .page(let searchPage) = search else {
            Issue.record("expected search page")
            return
        }
        #expect(searchPage.rows.map(\.item.id) == [item.id])

        let detailsResult = try await Self.read(.details(item.id), in: fixture)
        guard case .details(let details) = detailsResult else {
            Issue.record("expected details")
            return
        }
        #expect(details.item == item)
        #expect(details.effective.first?.bytes == Data(Self.privateText.utf8))

        let pasteResult = try await Self.read(
            .pastePayload(item.id),
            in: fixture
        )
        guard case .pastePayload(let paste) = pasteResult else {
            Issue.record("expected paste payload")
            return
        }
        #expect(paste.item == item)
        #expect(paste.representations.first?.bytes
            == Data(Self.privateText.utf8))

        let snapshot = try Self.snapshot(fixture)
        let operations = try Self.externalReadOperations(fixture)
        #expect(operations.count == 4)
        Self.expectSucceeded(operations[0], capability: .browse, kind: .readRecent)
        Self.expectSucceeded(operations[1], capability: .browse, kind: .readSearch)
        Self.expectSucceeded(
            operations[2],
            capability: .readContent,
            kind: .readDetails
        )
        Self.expectSucceeded(
            operations[3],
            capability: .readContent,
            kind: .readPastePayload
        )
        #expect(try Self.decodedPayload(operations[0], snapshot: snapshot)
            == OperationPayloadBlobV1(
                request: .recent(limit: 10),
                result: .page(returnedCount: 1, hasMore: false)
            ))
        #expect(try Self.decodedPayload(operations[1], snapshot: snapshot)
            == OperationPayloadBlobV1(
                request: .search(
                    queryUTF8ByteCount: UInt16(Self.privateText.utf8.count),
                    mode: .exact,
                    limit: 10
                ),
                result: .page(returnedCount: 1, hasMore: false)
            ))
        #expect(try Self.decodedPayload(operations[2], snapshot: snapshot)
            == OperationPayloadBlobV1(
                request: .details(itemID: item.id.rawValue),
                result: .details(
                    effectiveRepresentationCount: 1,
                    revisionCount: 0
                )
            ))
        #expect(try Self.decodedPayload(operations[3], snapshot: snapshot)
            == OperationPayloadBlobV1(
                request: .pastePayload(itemID: item.id.rawValue),
                result: .pastePayload(representationCount: 1)
            ))
        let privateBytes = Data(Self.privateText.utf8)
        for operation in operations {
            #expect(operation.payloadBlob.range(of: privateBytes) == nil)
        }
        let position = try await fixture.authority.currentPosition()
        #expect(position.rawValue == 1)
    }

    @Test("an empty recent page is a successful audited projection")
    func emptyPage() async throws {
        let fixture = try await Self.makeFixture(seedItem: false)
        try await Self.grant(.browse, in: fixture)

        let result = try await Self.read(.recent(limit: 5), in: fixture)
        guard case .page(let page) = result else {
            Issue.record("expected page")
            return
        }
        #expect(page.rows.isEmpty)
        let snapshot = try Self.snapshot(fixture)
        let operation = try #require(
            try Self.externalReadOperations(fixture).first
        )
        #expect(try Self.decodedPayload(operation, snapshot: snapshot)
            == OperationPayloadBlobV1(
                request: .recent(limit: 5),
                result: .page(returnedCount: 0, hasMore: false)
            ))
        let position = try await fixture.authority.currentPosition()
        #expect(position.rawValue == 0)
    }

    @Test("audit durability uses a later shared-clock sample than requestedAt")
    func committedAtUsesBarrierSample() async throws {
        let clock = StepClock(epoch: Self.epoch)
        let fixture = try await Self.makeFixture(
            seedItem: false,
            storageClock: clock
        )
        try await Self.grant(.browse, in: fixture)

        let recentRequestedAt = clock.now()
        _ = try await Self.read(
            .recent(limit: 5),
            in: fixture,
            requestedAt: recentRequestedAt
        )
        let searchRequestedAt = clock.now()
        _ = try await Self.read(
            .search(text: "absent", mode: .exact, limit: 5),
            in: fixture,
            requestedAt: searchRequestedAt
        )

        let operations = try Self.externalReadOperations(fixture)
        #expect(operations.count == 2)
        #expect(operations[0].requestedAt == recentRequestedAt)
        #expect(operations[0].committedAt > recentRequestedAt)
        #expect(operations[1].requestedAt == searchRequestedAt)
        #expect(operations[1].committedAt > searchRequestedAt)
    }

    @Test("missing content target audits notFound before throwing")
    func missingTarget() async throws {
        let fixture = try await Self.makeFixture(seedItem: false)
        try await Self.grant(.readContent, in: fixture)

        await #expect(throws: ExternalFailure.notFound(Self.absentItemID)) {
            _ = try await Self.read(.details(Self.absentItemID), in: fixture)
        }

        let snapshot = try Self.snapshot(fixture)
        let operation = try #require(
            try Self.externalReadOperations(fixture).first
        )
        #expect(operation.outcomeRaw == ExternalOutcome.failed.rawValue)
        #expect(operation.failureKindRaw
            == ExternalFailureKindRaw.notFound.rawValue)
        #expect(operation.changePositionRaw == nil)
        #expect(try Self.decodedPayload(operation, snapshot: snapshot)
            == OperationPayloadBlobV1(
                request: .details(itemID: Self.absentItemID.rawValue),
                result: .none
            ))
    }

    @Test("SearchWorker invalid input uses denied audit classification")
    func invalidSearchMapping() async throws {
        let fixture = try await Self.makeFixture(seedItem: false)
        try await Self.grant(.browse, in: fixture)
        let unsafePattern = "(a+)+"

        await #expect(throws: ExternalFailure.history(
            .invalidInput(.invalidRegularExpression)
        )) {
            _ = try await Self.read(
                .search(text: unsafePattern, mode: .regexp, limit: 10),
                in: fixture
            )
        }

        let snapshot = try Self.snapshot(fixture)
        let operation = try #require(
            try Self.externalReadOperations(fixture).first
        )
        #expect(operation.outcomeRaw == ExternalOutcome.denied.rawValue)
        #expect(operation.failureKindRaw
            == ExternalFailureKindRaw.requestDenied.rawValue)
        #expect(operation.denialReasonRaw
            == ExternalDenialReason.invalidInput.rawValue)
        #expect(operation.payloadBlob.range(of: Data(unsafePattern.utf8)) == nil)
        #expect(try Self.decodedPayload(operation, snapshot: snapshot)
            == OperationPayloadBlobV1(
                request: .search(
                    queryUTF8ByteCount: UInt16(unsafePattern.utf8.count),
                    mode: .regexp,
                    limit: 10
                ),
                result: .none
            ))
    }

    @Test("audit append failure publishes neither a prepared page nor an audit")
    func auditFailureBarrier() async throws {
        let fixture = try await Self.makeFixture()
        try await Self.grant(.browse, in: fixture)
        let before = try Self.externalReadOperations(fixture)
        await fixture.authority.setTransactionFailureInjection(
            .beforeSingletonUpdate
        )

        await #expect(throws: ExternalFailure.persistence(.transaction)) {
            _ = try await Self.read(.recent(limit: 10), in: fixture)
        }

        #expect(try Self.externalReadOperations(fixture) == before)
        let position = try await fixture.authority.currentPosition()
        #expect(position.rawValue == 1)
    }

#if DEBUG
    @Test("not-producible read failures trip the audited boundary sentinel")
    func notProducibleReadFailureSentinel() async throws {
        let fixture = try await Self.makeFixture()
        try await Self.grant(.browse, in: fixture)
        let before = try Self.historyState(fixture)
        let privateMarker = "batch13-not-producible-private-marker"
        let revisionID = RevisionID(rawValue: UUID(
            uuidString: "00000000-0000-0000-0000-000000001363"
        )!)
        let failures: [HistoryFailure] = [
            .staleContent(
                expected: ContentVersion(rawValue: 1),
                current: ContentVersion(rawValue: 2)
            ),
            .revisionNotFound(revisionID),
            .snapshotExpired(current: ChangePosition(rawValue: 1)),
            .capacityExceeded(.retainedItems),
            .capacityExceeded(.revisionCount),
            .capacityExceeded(.revisionBytes),
            .capacityExceeded(.copyCount),
            .capacityExceeded(.thumbnailBytes),
            .capacityExceeded(.storageBytes),
            .invalidPinnedPlacement(.anchorMissingOrUnpinned),
            .invalidPinnedPlacement(.targetEqualsAnchor),
            .temporarilyUnavailable(.dedupIndexRebuild),
            .persistence(.openStore),
            .invalidInput(.emptyCapture),
            .invalidInput(.excludedFromHistory),
            .invalidInput(.duplicateRepresentationType(privateMarker)),
            .invalidInput(.unsupportedRepresentationType(privateMarker)),
            .invalidInput(.representationLimit),
            .invalidInput(.byteLimit),
            .invalidInput(.invalidTimestamp),
            .invalidInput(.incoherentRevisionDraft),
            .invalidInput(.invalidPixelSize),
            .invalidInput(.invalidRetentionPolicy),
            // Dedicated siblings/search reclassification are producible on
            // other operations but impossible in the `.recent` context.
            .notFound(Self.absentItemID),
            .invalidInput(.invalidSearchTerm),
            .invalidInput(.invalidRegularExpression),
        ]

        for (index, source) in failures.enumerated() {
            do {
                _ = try await ExternalFailureDebugInstrumentation
                    .$injectedFailure.withValue(source) {
                        try await Self.read(.recent(limit: 10), in: fixture)
                    }
                Issue.record("sentinel accepted impossible failure \(source)")
            } catch let failure as ExternalFailure {
                #expect(failure == .persistence(.invariantViolation))
            }

            let operations = try Self.externalReadOperations(fixture)
            #expect(operations.count == index + 1)
            let operation = try #require(operations.last)
            #expect(operation.operationKindRaw
                == ExternalOperationKind.readRecent.rawValue)
            #expect(operation.outcomeRaw == ExternalOutcome.failed.rawValue)
            #expect(operation.failureKindRaw
                == ExternalFailureKindRaw.persistence.rawValue)
            #expect(operation.denialReasonRaw == nil)
            #expect(operation.changePositionRaw == nil)
            #expect(operation.payloadBlob.range(of: Data(privateMarker.utf8))
                == nil)
            let snapshot = try Self.snapshot(fixture)
            #expect(try Self.decodedPayload(operation, snapshot: snapshot)
                == OperationPayloadBlobV1(
                    request: .recent(limit: 10),
                    result: .none
                ))
            #expect(try Self.historyState(fixture) == before)
        }
    }
#endif

    @Test("search grant is fixed at capture; revocation affects the next read")
    func searchRevocationWindow() async throws {
        let fixture = try await Self.makeFixture()
        let item = try #require(fixture.item)
        try await Self.grant(.browse, in: fixture)
        let gate = SuspensionGate()
        let point = SearchWorkerSuspensionPoint.evaluationEntry.rawValue
        await fixture.searchWorker.setSuspensionHandler { suspension in
            guard suspension == .evaluationEntry else { return }
            await gate.park(at: suspension.rawValue)
        }

        let authority = fixture.authority
        let connection = fixture.connection
        let worker = fixture.searchWorker
        let task = Task {
            try await authority.performExternalRead(
                .search(text: Self.privateText, mode: .exact, limit: 10),
                connection: connection,
                requestedAt: Self.epoch,
                searchWorker: worker
            )
        }
        await gate.waitForPark(point)

        do {
            try await fixture.authority.revokeCapability(
                .browse,
                of: fixture.connection
            )
            await gate.resume(point)
            let result = try await task.value
            await fixture.searchWorker.setSuspensionHandler(nil)
            guard case .page(let page) = result else {
                Issue.record("expected search page")
                return
            }
            #expect(page.rows.map(\.item.id) == [item.id])
        } catch {
            await gate.resume(point)
            task.cancel()
            _ = try? await task.value
            await fixture.searchWorker.setSuspensionHandler(nil)
            throw error
        }

        await #expect(throws: ExternalFailure.unauthorized(
            requestedCapability: .browse,
            connectionID: fixture.connection
        )) {
            _ = try await Self.read(.recent(limit: 10), in: fixture)
        }

        let operations = try Self.externalReadOperations(fixture)
        #expect(operations.count == 2)
        #expect(operations[0].operationKindRaw
            == ExternalOperationKind.readSearch.rawValue)
        #expect(operations[0].outcomeRaw == ExternalOutcome.succeeded.rawValue)
        #expect(operations[1].operationKindRaw
            == ExternalOperationKind.readRecent.rawValue)
        #expect(operations[1].outcomeRaw == ExternalOutcome.denied.rawValue)
        #expect(operations[1].failureKindRaw
            == ExternalFailureKindRaw.unauthorized.rawValue)
    }

    @Test("cancelled SearchWorker evaluation audits once before typed failure")
    func searchCancellationIsAudited() async throws {
        let fixture = try await Self.makeFixture()
        try await Self.grant(.browse, in: fixture)
        let before = try Self.historyState(fixture)

        let failure = try await Self.cancelParkedSearch(in: fixture)

        #expect(failure == .temporarilyUnavailable(.cancelled))
        #expect(try Self.historyState(fixture) == before)
        let snapshot = try Self.snapshot(fixture)
        let operations = try Self.externalReadOperations(fixture)
        let operation = try #require(operations.first)
        #expect(operations.count == 1)
        #expect(operation.operationKindRaw
            == ExternalOperationKind.readSearch.rawValue)
        #expect(operation.outcomeRaw == ExternalOutcome.failed.rawValue)
        #expect(operation.failureKindRaw
            == ExternalFailureKindRaw.temporarilyUnavailable.rawValue)
        #expect(operation.denialReasonRaw == nil)
        #expect(operation.changePositionRaw == nil)
        #expect(operation.payloadBlob.range(of: Data(Self.privateText.utf8))
            == nil)
        #expect(try Self.decodedPayload(operation, snapshot: snapshot)
            == OperationPayloadBlobV1(
                request: .search(
                    queryUTF8ByteCount: UInt16(Self.privateText.utf8.count),
                    mode: .exact,
                    limit: 10
                ),
                result: .none
            ))
    }

    @Test("audit failure replaces cancelled search publication")
    func searchCancellationAuditFailureWins() async throws {
        let fixture = try await Self.makeFixture()
        try await Self.grant(.browse, in: fixture)
        let before = try Self.historyState(fixture)

        let failure = try await Self.cancelParkedSearch(
            in: fixture,
            injectAuditFailure: true
        )

        #expect(failure == .persistence(.transaction))
        #expect(try Self.externalReadOperations(fixture).isEmpty)
        #expect(try Self.historyState(fixture) == before)
    }
}
