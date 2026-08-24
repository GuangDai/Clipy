/// X.2 Foundation-only public Gateway contract proofs.
/// Owning spec: docs/v2/V2-05-external-gateway.md §3.3/§7.1–§7.3;
/// roadmap: docs/v2/V2-roadmap.md X.2.
import Foundation
import Testing
@testable import HistoryCore

@Test func externalGatewayStableRawVocabularyMatchesTheOwningContract() {
    #expect(ConnectionStatus.active.rawValue == 1)
    #expect(ConnectionStatus.revoked.rawValue == 2)

    #expect(ExternalDenialReason.invalidInput.rawValue == 1)
    #expect(ExternalDenialReason.rateLimited.rawValue == 2)

    #expect(ExternalTransientReason.indexRebuild.rawValue == 1)
    #expect(ExternalTransientReason.storeLocked.rawValue == 2)
    #expect(ExternalTransientReason.insufficientDiskSpace.rawValue == 3)
    #expect(ExternalTransientReason.cancelled.rawValue == 4)

    #expect(ExternalFailureKindRaw.unauthorized.rawValue == 1)
    #expect(ExternalFailureKindRaw.connectionRevoked.rawValue == 2)
    #expect(ExternalFailureKindRaw.requestDenied.rawValue == 3)
    #expect(ExternalFailureKindRaw.notFound.rawValue == 4)
    #expect(ExternalFailureKindRaw.history.rawValue == 5)
    #expect(ExternalFailureKindRaw.temporarilyUnavailable.rawValue == 6)
    #expect(ExternalFailureKindRaw.persistence.rawValue == 7)
    #expect(ExternalFailureKindRaw.auditCompactedBefore.rawValue == 8)

    #expect(AuditRebaseReason.corruptionDetected.rawValue == 1)
    #expect(AuditRebaseReason.adminForced.rawValue == 2)

    #expect(ExternalOutcome.succeeded.rawValue == 1)
    #expect(ExternalOutcome.failed.rawValue == 2)
    #expect(ExternalOutcome.denied.rawValue == 3)
    #expect(ExternalOutcome.noOp.rawValue == 4)

    #expect(ExternalOperationKind.readRecent.rawValue == 1)
    #expect(ExternalOperationKind.readSearch.rawValue == 2)
    #expect(ExternalOperationKind.readDetails.rawValue == 3)
    #expect(ExternalOperationKind.readPastePayload.rawValue == 4)
    #expect(ExternalOperationKind.managePin.rawValue == 5)
    #expect(ExternalOperationKind.manageUnpin.rawValue == 6)
    #expect(ExternalOperationKind.manageRemove.rawValue == 7)
    #expect(ExternalOperationKind.adminEnroll.rawValue == 8)
    #expect(ExternalOperationKind.adminGrant.rawValue == 9)
    #expect(ExternalOperationKind.adminRevoke.rawValue == 10)
    #expect(ExternalOperationKind.adminRebase.rawValue == 11)
    #expect(ExternalOperationKind.adminCompact.rawValue == 12)
    #expect(ExternalOperationKind.readEffectiveContent.rawValue == 13)
    #expect(ExternalOperationKind.reviseContent.rawValue == 14)
    #expect(ExternalOperationKind.describeFormatCapabilities.rawValue == 15)
    #expect(ExternalOperationKind.adminRevokeCapability.rawValue == 16)
    #expect(ExternalOperationKind.adminReadConnections.rawValue == 17)
    #expect(ExternalOperationKind.adminReadGrants.rawValue == 18)
    #expect(ExternalOperationKind.adminReadAudit.rawValue == 19)

    #expect(ConnectionStatus(rawValue: 0) == nil)
    #expect(ExternalDenialReason(rawValue: 0) == nil)
    #expect(ExternalTransientReason(rawValue: 0) == nil)
    #expect(ExternalTransientReason(rawValue: 5) == nil)
    #expect(ExternalFailureKindRaw(rawValue: 0) == nil)
    #expect(AuditRebaseReason(rawValue: 0) == nil)
    #expect(ExternalOutcome(rawValue: 0) == nil)
    #expect(ExternalOperationKind(rawValue: 20) == nil)
}

@Test func externalGatewayProjectionDTOsPreserveAuthoritativeFields() {
    let connectionID = ExternalConnectionID(
        rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    )
    let itemID = HistoryItemID(
        rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    )
    let enrolledAt = Date(timeIntervalSince1970: 1_700_000_000)
    let revokedAt = Date(timeIntervalSince1970: 1_700_000_100)
    let connection = ConnectionDTO(
        id: connectionID,
        displayName: "Shortcuts",
        enrollKind: .appIntents,
        status: .revoked,
        enrolledAt: enrolledAt,
        revokedAt: revokedAt
    )
    let grant = GrantDTO(
        connectionID: connectionID,
        capability: .manage,
        grantedAt: enrolledAt,
        revokedAt: revokedAt
    )
    let operation = OperationRecordDTO(
        auditSequence: 41,
        connectionID: connectionID,
        capability: .manage,
        operationKind: .manageRemove,
        outcome: .denied,
        requestedAt: enrolledAt,
        committedAt: revokedAt,
        changePosition: ChangePosition(rawValue: 17),
        failureKind: .requestDenied,
        denialReason: .rateLimited,
        affectedItemIDs: [itemID]
    )
    let globalAdmin = OperationRecordDTO(
        auditSequence: 42,
        connectionID: nil,
        capability: nil,
        operationKind: .adminCompact,
        outcome: .succeeded,
        requestedAt: enrolledAt,
        committedAt: revokedAt,
        changePosition: nil,
        failureKind: nil,
        denialReason: nil,
        affectedItemIDs: nil
    )

    #expect(connection.id == connectionID)
    #expect(connection.displayName == "Shortcuts")
    #expect(connection.enrollKind == .appIntents)
    #expect(connection.status == .revoked)
    #expect(connection.enrolledAt == enrolledAt)
    #expect(connection.revokedAt == revokedAt)
    #expect(connectionID.description == "11111111-2222-3333-4444-555555555555")

    #expect(grant.connectionID == connectionID)
    #expect(grant.capability == .manage)
    #expect(grant.grantedAt == enrolledAt)
    #expect(grant.revokedAt == revokedAt)

    #expect(operation.auditSequence == 41)
    #expect(operation.connectionID == Optional(connectionID))
    #expect(operation.capability == Optional(ExternalCapability.manage))
    #expect(operation.operationKind == .manageRemove)
    #expect(operation.outcome == .denied)
    #expect(operation.requestedAt == enrolledAt)
    #expect(operation.committedAt == revokedAt)
    #expect(operation.changePosition == ChangePosition(rawValue: 17))
    #expect(operation.failureKind == .requestDenied)
    #expect(operation.denialReason == .rateLimited)
    #expect(operation.affectedItemIDs == [itemID])
    #expect(globalAdmin.connectionID == nil)
    #expect(globalAdmin.capability == nil)
    #expect(globalAdmin.operationKind == .adminCompact)
    #expect(globalAdmin.changePosition == nil)
}

@Test func externalItemProjectionDTOsCarryPurposeSpecificEntityFacts() {
    let itemID = HistoryItemID(
        rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    )
    let item = HistoryItemReference(
        id: itemID,
        contentVersion: ContentVersion(rawValue: 4)
    )
    let copiedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let historyRow = HistoryRow(
        item: item,
        title: "Effective title",
        typeIdentifiers: ["public.utf8-plain-text"],
        lastCopiedAt: copiedAt,
        copyCount: 3,
        lastSource: "com.example.source",
        pinnedPosition: 1,
        search: nil
    )
    let row = ExternalHistoryRow(
        row: historyRow,
        revisionCount: 2
    )
    let page = ExternalHistoryPage(
        position: ChangePosition(rawValue: 9),
        rows: [row],
        next: nil
    )
    let occurrence = CopyOccurrenceSummary(
        firstCopiedAt: copiedAt.addingTimeInterval(-10),
        lastCopiedAt: copiedAt,
        count: 3,
        firstSource: "com.example.first",
        lastSource: "com.example.source"
    )
    let historyDetails = HistoryDetails(
        item: item,
        canonical: [],
        effective: [],
        revisions: [],
        occurrence: occurrence,
        pinnedPosition: 1
    )
    let details = ExternalHistoryDetails(
        details: historyDetails,
        title: "Effective title"
    )

    #expect(page.rows == [row])
    #expect(page.rows[0].row.title == "Effective title")
    #expect(page.rows[0].revisionCount == 2)
    #expect(details.title == "Effective title")
    #expect(details.revisionCount == 0)
    #expect(details.details.item == item)
}

@Test func externalRequestValuesPreserveTheFrozenAppIntentsArguments() {
    let itemID = HistoryItemID(
        rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    )
    let request = ExternalRequest.pin(itemID)
    let read = ExternalRead.search(text: "clipy", mode: .exact, limit: 7)

    guard case let .pin(returnedID) = request else {
        Issue.record("expected the closed pin request")
        return
    }
    guard case let .search(text, mode, limit) = read else {
        Issue.record("expected the closed search read")
        return
    }
    #expect(returnedID == itemID)
    #expect(text == "clipy")
    #expect(mode == .exact)
    #expect(limit == 7)
}

@Test func externalFailurePreservesTypedRecoveryInformation() {
    let connectionID = ExternalConnectionID(
        rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    )

    #expect(
        ExternalFailure.unauthorized(
            requestedCapability: .readContent,
            connectionID: connectionID
        ) == .unauthorized(
            requestedCapability: .readContent,
            connectionID: connectionID
        )
    )
    #expect(
        ExternalFailure.temporarilyUnavailable(.storeLocked)
            == .temporarilyUnavailable(.storeLocked)
    )
    #expect(
        ExternalFailure.auditCompactedBefore(floor: 29)
            == .auditCompactedBefore(floor: 29)
    )
}
