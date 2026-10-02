/// Durable Gateway raw discriminators, including rejection of unknown values.
/// Owning spec: docs/automation.md;
/// roadmap: docs/testing.md X.2.
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
