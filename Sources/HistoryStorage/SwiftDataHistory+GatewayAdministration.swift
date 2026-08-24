/// Public forwarding witnesses for the in-app Gateway administration concern.
/// Owning spec: `V2-05` §3.3 and roadmap X.4/GW3.
import Foundation
import HistoryCore

extension SwiftDataHistory: GatewayAdminHistory {
    public func enrollConnection(
        kind: ConnectionEnrollKind,
        displayName: String,
        credential: Data?
    ) async throws -> ExternalConnectionID {
        guard kind != .localAutomation else {
            // V2-05 §3.2 F1: the generic public admin shape cannot carry a
            // preassigned ID or prove client/server custody readbacks. Reject
            // before Authority admission, audit, clock, or ID minting.
            throw ExternalFailure.requestDenied(.invalidInput)
        }
        return try await authority.enrollConnection(
            kind: kind,
            displayName: displayName,
            credential: credential
        )
    }

    public func revokeConnection(
        _ id: ExternalConnectionID
    ) async throws {
        try await authority.revokeConnection(id)
    }

    public func grantCapability(
        _ capability: ExternalCapability,
        to id: ExternalConnectionID
    ) async throws {
        try await authority.grantCapability(capability, to: id)
    }

    public func revokeCapability(
        _ capability: ExternalCapability,
        of id: ExternalConnectionID
    ) async throws {
        try await authority.revokeCapability(capability, of: id)
    }

    public func connections() async throws -> [ConnectionDTO] {
        try await authority.connections()
    }

    public func grants(
        for id: ExternalConnectionID
    ) async throws -> [GrantDTO] {
        try await authority.grants(for: id)
    }

    public func auditLog(
        since auditSequence: UInt64
    ) async throws -> [OperationRecordDTO] {
        try await authority.auditLog(since: auditSequence)
    }

    public func rebaseAuditLog(
        reason: AuditRebaseReason
    ) async throws {
        try await authority.rebaseAuditLog(reason: reason)
    }
}
