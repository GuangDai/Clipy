/// X.6 Authority positive-write proofs through the real in-memory V4 store.
/// Owning spec: `V2-05` §5.1/§6.4 and roadmap X.6.
import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

@Suite("Gateway external writes (X.6)")
struct GatewayExternalWriteTests {
    private static let requestedAt = Date(
        timeIntervalSinceReferenceDate: 700_000_000
    )

    private struct Fixture {
        let history: SwiftDataHistory
        let authority: HistoryAuthority
        let container: ModelContainer
        let connection: ExternalConnectionID
        let item: HistoryItemReference
    }

    private struct HCRSnapshot: Equatable {
        let sequence: UInt64
        let changePosition: UInt64
        let kind: HistoryChangeKindRawV1
        let affected: [HistoryItemID]
    }

    private struct DurableSnapshot {
        let position: UInt64
        let pinOrdinal: Int?
        let itemCount: Int
        let hcrs: [HCRSnapshot]
        let gateway: GatewayStoreSnapshot
    }

    @Test("pin, no-op, unpin, and remove preserve HCR/audit/position equality")
    func successfulManageSubsetUsesOneAtomicKernel() async throws {
        let fixture = try await Self.makeFixture(text: "private clipboard body")
        let baseline = try Self.snapshot(fixture)

        let pinned = try await fixture.authority.commitExternal(
            request: .pin(fixture.item.id),
            connection: fixture.connection,
            requestedAt: Self.requestedAt
        )
        guard case .pin(let pinnedID) = pinned else {
            Issue.record("expected external pin response")
            return
        }
        #expect(pinnedID == fixture.item.id)
        let afterPin = try Self.snapshot(fixture)
        try Self.expectCommittedWrite(
            afterPin,
            prior: baseline,
            operation: .managePin,
            kind: .pin,
            request: .pin(itemID: fixture.item.id.rawValue),
            itemID: fixture.item.id,
            expectedPosition: 2
        )
        #expect(afterPin.pinOrdinal == 0)

        let unchanged = try await fixture.authority.commitExternal(
            request: .pin(fixture.item.id),
            connection: fixture.connection,
            requestedAt: Self.requestedAt.addingTimeInterval(1)
        )
        guard case .unchanged = unchanged else {
            Issue.record("expected repeated external pin to be unchanged")
            return
        }
        let afterNoOp = try Self.snapshot(fixture)
        #expect(afterNoOp.position == afterPin.position)
        #expect(afterNoOp.hcrs == afterPin.hcrs)
        #expect(afterNoOp.gateway.operations.count
            == afterPin.gateway.operations.count + 1)
        let noOp = try #require(afterNoOp.gateway.operations.last)
        #expect(noOp.outcomeRaw == ExternalOutcome.noOp.rawValue)
        #expect(noOp.changePositionRaw == nil)
        #expect(try Self.decode(noOp, in: afterNoOp.gateway)
            == OperationPayloadBlobV1(
                request: .pin(itemID: fixture.item.id.rawValue),
                result: .affectedItemIDs([])
            ))

        let unpinned = try await fixture.authority.commitExternal(
            request: .unpin(fixture.item.id),
            connection: fixture.connection,
            requestedAt: Self.requestedAt.addingTimeInterval(2)
        )
        guard case .unpin(let unpinnedID) = unpinned else {
            Issue.record("expected external unpin response")
            return
        }
        #expect(unpinnedID == fixture.item.id)
        let afterUnpin = try Self.snapshot(fixture)
        try Self.expectCommittedWrite(
            afterUnpin,
            prior: afterNoOp,
            operation: .manageUnpin,
            kind: .unpin,
            request: .unpin(itemID: fixture.item.id.rawValue),
            itemID: fixture.item.id,
            expectedPosition: 3
        )
        #expect(afterUnpin.pinOrdinal == nil)

        let removed = try await fixture.authority.commitExternal(
            request: .remove(fixture.item.id),
            connection: fixture.connection,
            requestedAt: Self.requestedAt.addingTimeInterval(3)
        )
        guard case .removed(let count) = removed else {
            Issue.record("expected external remove response")
            return
        }
        #expect(count == 1)
        let afterRemove = try Self.snapshot(fixture)
        try Self.expectCommittedWrite(
            afterRemove,
            prior: afterUnpin,
            operation: .manageRemove,
            kind: .remove,
            request: .remove(itemID: fixture.item.id.rawValue),
            itemID: fixture.item.id,
            expectedPosition: 4
        )
        #expect(afterRemove.itemCount == 0)
    }

    @Test("absent pin differs from absent unpin/remove and every failure audits")
    func absentTargetAsymmetryIsTypedAndAudited() async throws {
        let fixture = try await Self.makeFixture(text: "retained witness")
        let absent = HistoryItemID(rawValue: UUID(
            uuidString: "00000000-0000-0000-0000-000000001301"
        )!)
        var prior = try Self.snapshot(fixture)

        await #expect(throws: ExternalFailure.history(
            .invalidPinnedPlacement(.targetMissing)
        )) {
            _ = try await fixture.authority.commitExternal(
                request: .pin(absent),
                connection: fixture.connection,
                requestedAt: Self.requestedAt
            )
        }
        var after = try Self.snapshot(fixture)
        try Self.expectFailedAttempt(
            after,
            prior: prior,
            operation: .managePin,
            failureKind: .history,
            request: .pin(itemID: absent.rawValue)
        )

        prior = after
        await #expect(throws: ExternalFailure.notFound(absent)) {
            _ = try await fixture.authority.commitExternal(
                request: .unpin(absent),
                connection: fixture.connection,
                requestedAt: Self.requestedAt.addingTimeInterval(1)
            )
        }
        after = try Self.snapshot(fixture)
        try Self.expectFailedAttempt(
            after,
            prior: prior,
            operation: .manageUnpin,
            failureKind: .notFound,
            request: .unpin(itemID: absent.rawValue)
        )

        prior = after
        await #expect(throws: ExternalFailure.notFound(absent)) {
            _ = try await fixture.authority.commitExternal(
                request: .remove(absent),
                connection: fixture.connection,
                requestedAt: Self.requestedAt.addingTimeInterval(2)
            )
        }
        after = try Self.snapshot(fixture)
        try Self.expectFailedAttempt(
            after,
            prior: prior,
            operation: .manageRemove,
            failureKind: .notFound,
            request: .remove(itemID: absent.rawValue)
        )
    }

    @Test("revocation after admitted precheck is denied at the save boundary")
    func revokeTOCTOUIsClosedInsideWriteTransaction() async throws {
        let fixture = try await Self.makeFixture(text: "revoke target")
        _ = try await fixture.history.perform(
            .placePinned(fixture.item.id, at: .first)
        )
        let descriptor = ExternalOperationDescriptor(
            capability: .manage,
            operationKind: .manageUnpin,
            requestSummary: .unpin(itemID: fixture.item.id.rawValue)
        )
        try await fixture.authority.authorizeExternal(
            descriptor,
            as: fixture.connection
        )
        try await fixture.history.revokeCapability(
            .manage,
            of: fixture.connection
        )
        let prior = try Self.snapshot(fixture)

        await #expect(throws: ExternalFailure.unauthorized(
            requestedCapability: .manage,
            connectionID: fixture.connection
        )) {
            _ = try await fixture.authority.commitExternal(
                request: .unpin(fixture.item.id),
                connection: fixture.connection,
                requestedAt: Self.requestedAt
            )
        }

        let after = try Self.snapshot(fixture)
        #expect(after.position == prior.position)
        #expect(after.pinOrdinal == 0)
        #expect(after.hcrs == prior.hcrs)
        #expect(after.gateway.operations.count
            == prior.gateway.operations.count + 1)
        let denied = try #require(after.gateway.operations.last)
        #expect(denied.outcomeRaw == ExternalOutcome.denied.rawValue)
        #expect(denied.failureKindRaw
            == ExternalFailureKindRaw.unauthorized.rawValue)
        #expect(denied.changePositionRaw == nil)
        #expect(try Self.decode(denied, in: after.gateway)
            == OperationPayloadBlobV1(
                request: .unpin(itemID: fixture.item.id.rawValue),
                result: .none
            ))

        // The same revoked caller must not learn that pin would be a planner
        // no-op; the no-op audit transaction publishes a denial instead.
        await #expect(throws: ExternalFailure.unauthorized(
            requestedCapability: .manage,
            connectionID: fixture.connection
        )) {
            _ = try await fixture.authority.commitExternal(
                request: .pin(fixture.item.id),
                connection: fixture.connection,
                requestedAt: Self.requestedAt.addingTimeInterval(1)
            )
        }
        let afterNoOp = try Self.snapshot(fixture)
        #expect(afterNoOp.position == after.position)
        #expect(afterNoOp.pinOrdinal == 0)
        #expect(afterNoOp.hcrs == after.hcrs)
        #expect(afterNoOp.gateway.operations.count
            == after.gateway.operations.count + 1)
        let noOpDenied = try #require(afterNoOp.gateway.operations.last)
        #expect(noOpDenied.outcomeRaw == ExternalOutcome.denied.rawValue)
        #expect(noOpDenied.failureKindRaw
            == ExternalFailureKindRaw.unauthorized.rawValue)
        #expect(try Self.decode(noOpDenied, in: afterNoOp.gateway)
            == OperationPayloadBlobV1(
                request: .pin(itemID: fixture.item.id.rawValue),
                result: .none
            ))

        // If authorization were evaluated after fact-derived publication,
        // this absent remove would leak notFound instead of the live denial.
        let absent = HistoryItemID(rawValue: UUID(
            uuidString: "00000000-0000-0000-0000-000000001302"
        )!)
        await #expect(throws: ExternalFailure.unauthorized(
            requestedCapability: .manage,
            connectionID: fixture.connection
        )) {
            _ = try await fixture.authority.commitExternal(
                request: .remove(absent),
                connection: fixture.connection,
                requestedAt: Self.requestedAt.addingTimeInterval(2)
            )
        }
        let afterAbsent = try Self.snapshot(fixture)
        #expect(afterAbsent.position == afterNoOp.position)
        #expect(afterAbsent.hcrs == afterNoOp.hcrs)
        #expect(afterAbsent.gateway.operations.count
            == afterNoOp.gateway.operations.count + 1)
        let absentDenied = try #require(afterAbsent.gateway.operations.last)
        #expect(absentDenied.outcomeRaw == ExternalOutcome.denied.rawValue)
        #expect(absentDenied.failureKindRaw
            == ExternalFailureKindRaw.unauthorized.rawValue)
        #expect(try Self.decode(absentDenied, in: afterAbsent.gateway)
            == OperationPayloadBlobV1(
                request: .remove(itemID: absent.rawValue),
                result: .none
            ))
    }

#if DEBUG
    @Test("both transaction injection windows roll back mutation/HCR/success audit")
    func transactionInjectionsPublishOnlyTheFailedAttempt() async throws {
        try await Self.expectInjectedRollback(.beforeHCRAppend)
        try await Self.expectInjectedRollback(.beforeSingletonUpdate)
    }

    @Test("not-producible write failures trip the audited boundary sentinel")
    func notProducibleWriteFailureSentinel() async throws {
        let fixture = try await Self.makeFixture(
            text: "not-producible write private body"
        )
        let privateMarker = "batch13-write-not-producible-private-marker"
        let absentItemID = HistoryItemID(rawValue: UUID(
            uuidString: "00000000-0000-0000-0000-000000001363"
        )!)
        let revisionID = RevisionID(rawValue: UUID(
            uuidString: "00000000-0000-0000-0000-000000001364"
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
            // These siblings are real for other operations but impossible
            // for the admitted `.pin` path exercised by this boundary.
            .notFound(absentItemID),
            .invalidInput(.invalidSearchTerm),
            .invalidInput(.invalidRegularExpression),
        ]
        var prior = try Self.snapshot(fixture)

        for source in failures {
            do {
                _ = try await ExternalFailureDebugInstrumentation
                    .$injectedFailure.withValue(source) {
                        try await fixture.authority.commitExternal(
                            request: .pin(fixture.item.id),
                            connection: fixture.connection,
                            requestedAt: Self.requestedAt
                        )
                    }
                Issue.record("sentinel accepted impossible failure \(source)")
            } catch let failure as ExternalFailure {
                #expect(failure == .persistence(.invariantViolation))
            }

            let after = try Self.snapshot(fixture)
            try Self.expectFailedAttempt(
                after,
                prior: prior,
                operation: .managePin,
                failureKind: .persistence,
                request: .pin(itemID: fixture.item.id.rawValue)
            )
            let audit = try #require(after.gateway.operations.last)
            #expect(audit.payloadBlob.range(of: Data(privateMarker.utf8))
                == nil)
            prior = after
        }
    }
#endif

    @Test("out-of-space rolls back the write and publishes one retryable failure")
    func outOfSpaceMapsTruthfullyAfterAtomicRollback() async throws {
        let fixture = try await Self.makeFixture(text: "disk-full private body")
        let prior = try Self.snapshot(fixture)
        await fixture.authority.setTransactionFailureInjection(
            .insufficientDiskSpace
        )

        await #expect(throws: ExternalFailure.temporarilyUnavailable(
            .insufficientDiskSpace
        )) {
            _ = try await fixture.authority.commitExternal(
                request: .pin(fixture.item.id),
                connection: fixture.connection,
                requestedAt: Self.requestedAt
            )
        }

        let after = try Self.snapshot(fixture)
        try Self.expectFailedAttempt(
            after,
            prior: prior,
            operation: .managePin,
            failureKind: .temporarilyUnavailable,
            request: .pin(itemID: fixture.item.id.rawValue)
        )
    }

    @Test("exhausted ChangePosition stays unchanged and audits raw history failure")
    func exhaustedCoherenceTokenIsHistoryFailure() async throws {
        let fixture = try await Self.makeFixture(text: "coherence private body")
        try Self.exhaustCoherencePosition(fixture)
        let prior = try Self.snapshot(fixture)

        await #expect(throws: ExternalFailure.history(
            .capacityExceeded(.coherenceToken)
        )) {
            _ = try await fixture.authority.commitExternal(
                request: .pin(fixture.item.id),
                connection: fixture.connection,
                requestedAt: Self.requestedAt
            )
        }

        let after = try Self.snapshot(fixture)
        try Self.expectFailedAttempt(
            after,
            prior: prior,
            operation: .managePin,
            failureKind: .history,
            request: .pin(itemID: fixture.item.id.rawValue)
        )
        #expect(after.position == UInt64.max)
        #expect(after.hcrs.isEmpty)
    }

    private static func makeFixture(text: String) async throws -> Fixture {
        let history = try await SwiftDataHistory.open(configuration:
            HistoryConfiguration(persistence: .memory)
        )
        let authority = history.authority
        let container = await authority.container
        let connection = try #require(try await history.connections().first)
        try await history.grantCapability(.manage, to: connection.id)
        let receipt = try await history.perform(.capture(
            WSSupport.textCapture(
                text,
                observedAt: Date(timeIntervalSinceReferenceDate: 790_000_000)
            )
        ))
        guard case .committed(let commit) = receipt,
              case .inserted(let item) = commit.outcome else {
            Issue.record("expected fixture insert")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return Fixture(
            history: history,
            authority: authority,
            container: container,
            connection: connection.id,
            item: item
        )
    }

    private static func snapshot(_ fixture: Fixture) throws -> DurableSnapshot {
        let context = ModelContext(fixture.container)
        let position = try #require(
            context.fetch(FetchDescriptor<LastChangePositionRow>()).first
        )
        let items = try context.fetch(FetchDescriptor<HistoryItemRow>())
        let hcrRows = try context.fetch(FetchDescriptor<HistoryChangeRecordRow>(
            sortBy: [SortDescriptor(\.sequence)]
        ))
        let hcrs = try hcrRows.map { row in
            let kind = try #require(
                HistoryChangeKindRawV1(rawValue: row.changeKindRaw)
            )
            return HCRSnapshot(
                sequence: row.sequence,
                changePosition: row.changePositionRaw,
                kind: kind,
                affected: try AffectedItemsBlobCodec.decode(
                    row.affectedItemsBlob,
                    for: kind
                )
            )
        }
        return DurableSnapshot(
            position: position.rawValue,
            pinOrdinal: items.first(where: {
                $0.id == fixture.item.id.rawValue
            })?.pinOrdinal,
            itemCount: items.count,
            hcrs: hcrs,
            gateway: try GatewayStoreSnapshot.read(in: context)
        )
    }

    private static func exhaustCoherencePosition(_ fixture: Fixture) throws {
        let context = ModelContext(fixture.container)
        let position = try #require(
            context.fetch(FetchDescriptor<LastChangePositionRow>()).first
        )
        let journal = try #require(
            context.fetch(FetchDescriptor<JournalConfigRow>()).first
        )
        let records = try context.fetch(FetchDescriptor<HistoryChangeRecordRow>())
        for record in records {
            context.delete(record)
        }
        position.rawValue = UInt64.max
        journal.compactionFloorRaw = UInt64.max
        journal.journalBytes = 0
        try context.save()
    }

    private static func expectCommittedWrite(
        _ snapshot: DurableSnapshot,
        prior: DurableSnapshot,
        operation: ExternalOperationKind,
        kind: HistoryChangeKindRawV1,
        request: RequestSummaryV1,
        itemID: HistoryItemID,
        expectedPosition: UInt64
    ) throws {
        #expect(snapshot.position == expectedPosition)
        #expect(snapshot.hcrs.count == prior.hcrs.count + 1)
        #expect(snapshot.hcrs.dropLast() == prior.hcrs[...])
        let hcr = try #require(snapshot.hcrs.last)
        #expect(hcr.sequence == expectedPosition)
        #expect(hcr.changePosition == expectedPosition)
        #expect(hcr.kind == kind)
        #expect(hcr.affected == [itemID])
        #expect(snapshot.gateway.operations.count
            == prior.gateway.operations.count + 1)
        let audit = try #require(snapshot.gateway.operations.last)
        #expect(audit.operationKindRaw == operation.rawValue)
        #expect(audit.outcomeRaw == ExternalOutcome.succeeded.rawValue)
        #expect(audit.failureKindRaw == nil)
        #expect(audit.denialReasonRaw == nil)
        #expect(audit.changePositionRaw == expectedPosition)
        #expect(audit.changePositionRaw == hcr.sequence)
        #expect(try Self.decode(audit, in: snapshot.gateway)
            == OperationPayloadBlobV1(
                request: request,
                result: .affectedItemIDs([itemID.rawValue])
            ))
    }

    private static func expectFailedAttempt(
        _ snapshot: DurableSnapshot,
        prior: DurableSnapshot,
        operation: ExternalOperationKind,
        failureKind: ExternalFailureKindRaw,
        request: RequestSummaryV1
    ) throws {
        #expect(snapshot.position == prior.position)
        #expect(snapshot.pinOrdinal == prior.pinOrdinal)
        #expect(snapshot.itemCount == prior.itemCount)
        #expect(snapshot.hcrs == prior.hcrs)
        #expect(snapshot.gateway.operations.count
            == prior.gateway.operations.count + 1)
        let audit = try #require(snapshot.gateway.operations.last)
        #expect(audit.operationKindRaw == operation.rawValue)
        #expect(audit.outcomeRaw == ExternalOutcome.failed.rawValue)
        #expect(audit.failureKindRaw == failureKind.rawValue)
        #expect(audit.denialReasonRaw == nil)
        #expect(audit.changePositionRaw == nil)
        #expect(try Self.decode(audit, in: snapshot.gateway)
            == OperationPayloadBlobV1(request: request, result: .none))
    }

#if DEBUG
    private static func expectInjectedRollback(
        _ injection: InjectedTransactionFailure
    ) async throws {
        let fixture = try await Self.makeFixture(
            text: "injection \(injection) private bytes"
        )
        let prior = try Self.snapshot(fixture)
        await fixture.authority.setTransactionFailureInjection(injection)

        await #expect(throws: ExternalFailure.persistence(.transaction)) {
            _ = try await fixture.authority.commitExternal(
                request: .pin(fixture.item.id),
                connection: fixture.connection,
                requestedAt: Self.requestedAt
            )
        }

        let after = try Self.snapshot(fixture)
        try Self.expectFailedAttempt(
            after,
            prior: prior,
            operation: .managePin,
            failureKind: .persistence,
            request: .pin(itemID: fixture.item.id.rawValue)
        )
    }
#endif

    private static func decode(
        _ operation: GatewayStoreSnapshot.Operation,
        in snapshot: GatewayStoreSnapshot
    ) throws -> OperationPayloadBlobV1 {
        let config = try #require(snapshot.configs.first)
        return try OperationPayloadBlobCodec.decode(
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
                compactionFloor: config.compactionFloor,
                nextAuditSequence: config.nextAuditSequence
            )
        )
    }
}
