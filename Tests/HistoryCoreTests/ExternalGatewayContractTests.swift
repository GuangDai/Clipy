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

    #expect(ConnectionStatus(rawValue: 0) == nil)
    #expect(ExternalDenialReason(rawValue: 0) == nil)
    #expect(ExternalTransientReason(rawValue: 0) == nil)
    #expect(ExternalFailureKindRaw(rawValue: 0) == nil)
    #expect(AuditRebaseReason(rawValue: 0) == nil)
    #expect(ExternalOutcome(rawValue: 0) == nil)
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
    #expect(operation.connectionID == connectionID)
    #expect(operation.capability == .manage)
    #expect(operation.operationKind == .manageRemove)
    #expect(operation.outcome == .denied)
    #expect(operation.requestedAt == enrolledAt)
    #expect(operation.committedAt == revokedAt)
    #expect(operation.changePosition == ChangePosition(rawValue: 17))
    #expect(operation.failureKind == .requestDenied)
    #expect(operation.denialReason == .rateLimited)
    #expect(operation.affectedItemIDs == [itemID])
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
