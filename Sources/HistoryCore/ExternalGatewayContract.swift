/// Public External Gateway concern protocols and immutable values.
/// Owning spec: docs/v2/V2-05-external-gateway.md §3.3/§7.1–§7.3.
/// Foundation-only; the Gateway actor, grants, audit persistence, transport,
/// and concrete facade construction remain owned by `HistoryStorage`.
import Foundation

// MARK: - External connection identity and lifecycle

/// Stable identity of one user-enrolled external connection.
///
/// The raw UUID is observable for display and persistence, but minting remains
/// package-only so callers cannot self-enroll by constructing an identity.
public struct ExternalConnectionID:
    Sendable, Hashable, CustomStringConvertible
{
    public let rawValue: UUID

    package init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

/// Durable lifecycle state of an external connection.
public enum ConnectionStatus: Int16, Sendable, Hashable, Codable {
    case active = 1
    case revoked = 2
}

// MARK: - External request concern

/// The capability-gated App Intents surface.
///
/// This protocol is deliberately distinct from `ClipboardHistory`; it cannot
/// spell capture, revise, clear, retention, or Gateway administration.
public protocol ExternalHistory: Sendable {
    func perform(_ request: ExternalRequest) async throws -> ExternalResponse
    func read(_ request: ExternalRead) async throws -> ExternalReadResult
}

/// The closed App Intents mutation subset.
public enum ExternalRequest: Sendable, Hashable {
    case pin(HistoryItemID)
    case unpin(HistoryItemID)
    case remove(HistoryItemID)
}

/// The closed App Intents read subset.
public enum ExternalRead: Sendable, Hashable {
    case recent(limit: Int)
    case search(text: String, mode: SearchMode, limit: Int)
    case details(HistoryItemID)
    case pastePayload(HistoryItemID)
}

/// Result of one external mutation request.
public enum ExternalResponse: Sendable {
    case pin(HistoryItemID)
    case unpin(HistoryItemID)
    case removed(count: Int)
    case unchanged
}

/// Result of one external read request.
public enum ExternalReadResult: Sendable {
    case page(ExternalHistoryPage)
    case details(ExternalHistoryDetails)
    case pastePayload(PastePayload)
}

/// One browse/search row projected specifically for an external caller.
///
/// The V1 row remains unchanged; this value adds the authoritative retained
/// revision count App Intents needs without exposing retention rows, lineage
/// blobs, or Storage implementation vocabulary (V2-05 §7.1; X.7).
public struct ExternalHistoryRow: Sendable, Hashable {
    public let row: HistoryRow
    public let revisionCount: Int

    package init(
        row: HistoryRow,
        revisionCount: Int
    ) {
        self.row = row
        self.revisionCount = revisionCount
    }
}

/// A bounded external browse/search page.
///
/// Position and continuation semantics are identical to `HistoryPage`; only
/// the row projection is purpose-specific (V2-05 §7.1; X.7).
public struct ExternalHistoryPage: Sendable, Hashable {
    public let position: ChangePosition
    public let rows: [ExternalHistoryRow]
    public let next: HistoryPageCursor?

    package init(
        position: ChangePosition,
        rows: [ExternalHistoryRow],
        next: HistoryPageCursor?
    ) {
        self.position = position
        self.rows = rows
        self.next = next
    }
}

/// Full external details plus the authoritative Effective Content title.
///
/// `HistoryDetails` remains the unchanged V1 read DTO. This external value
/// carries the title projection and explicit revision count needed by the
/// output-only App Intent entity, with all facts produced by the same gated
/// Storage read (V2-05 §7.1; X.7).
public struct ExternalHistoryDetails: Sendable, Hashable {
    public let details: HistoryDetails
    public let title: String
    public var revisionCount: Int { details.revisions.count }

    package init(
        details: HistoryDetails,
        title: String
    ) {
        self.details = details
        self.title = title
    }
}

// MARK: - In-app Gateway administration concern

/// In-app-only connection, grant, and audit administration.
///
/// This protocol is never an external connection surface and remains distinct
/// from the closed `HistoryAction` / `ClipboardHistory` concern.
public protocol GatewayAdminHistory: Sendable {
    func enrollConnection(
        kind: ConnectionEnrollKind,
        displayName: String,
        credential: Data?
    ) async throws -> ExternalConnectionID

    func revokeConnection(_ id: ExternalConnectionID) async throws

    func grantCapability(
        _ capability: ExternalCapability,
        to id: ExternalConnectionID
    ) async throws

    func revokeCapability(
        _ capability: ExternalCapability,
        of id: ExternalConnectionID
    ) async throws

    func connections() async throws -> [ConnectionDTO]
    func grants(for id: ExternalConnectionID) async throws -> [GrantDTO]
    func auditLog(since auditSequence: UInt64) async throws -> [OperationRecordDTO]
    func rebaseAuditLog(reason: AuditRebaseReason) async throws
}

public extension GatewayAdminHistory {
    /// App Intents enrollment carries no credential. Credential-bearing kinds
    /// use the requirement above without widening the protocol later.
    func enrollConnection(
        kind: ConnectionEnrollKind,
        displayName: String
    ) async throws -> ExternalConnectionID {
        try await enrollConnection(
            kind: kind,
            displayName: displayName,
            credential: nil
        )
    }
}

/// Read projection of one durable external connection.
public struct ConnectionDTO: Sendable, Equatable {
    public let id: ExternalConnectionID
    public let displayName: String
    public let enrollKind: ConnectionEnrollKind
    public let status: ConnectionStatus
    public let enrolledAt: Date
    public let revokedAt: Date?

    package init(
        id: ExternalConnectionID,
        displayName: String,
        enrollKind: ConnectionEnrollKind,
        status: ConnectionStatus,
        enrolledAt: Date,
        revokedAt: Date?
    ) {
        self.id = id
        self.displayName = displayName
        self.enrollKind = enrollKind
        self.status = status
        self.enrolledAt = enrolledAt
        self.revokedAt = revokedAt
    }
}

/// Read projection of one durable capability grant.
public struct GrantDTO: Sendable, Equatable {
    public let connectionID: ExternalConnectionID
    public let capability: ExternalCapability
    public let grantedAt: Date
    public let revokedAt: Date?

    package init(
        connectionID: ExternalConnectionID,
        capability: ExternalCapability,
        grantedAt: Date,
        revokedAt: Date?
    ) {
        self.connectionID = connectionID
        self.capability = capability
        self.grantedAt = grantedAt
        self.revokedAt = revokedAt
    }
}

/// Read projection of one durable external-operation audit record.
///
/// Request text and returned content are intentionally absent. Only bounded
/// classification, timing, optional write position, and affected IDs cross the
/// public boundary.
public struct OperationRecordDTO: Sendable, Equatable {
    public let auditSequence: UInt64
    /// External caller or targeted admin connection when the operation has
    /// one; nil for global admin maintenance such as audit compaction/rebase.
    public let connectionID: ExternalConnectionID?
    /// Capability required by an external request; nil for in-app admin
    /// operations, which are never authorized through an external grant.
    public let capability: ExternalCapability?
    public let operationKind: ExternalOperationKind
    public let outcome: ExternalOutcome
    public let requestedAt: Date
    public let committedAt: Date
    public let changePosition: ChangePosition?
    public let failureKind: ExternalFailureKindRaw?
    public let denialReason: ExternalDenialReason?
    public let affectedItemIDs: [HistoryItemID]?

    package init(
        auditSequence: UInt64,
        connectionID: ExternalConnectionID?,
        capability: ExternalCapability?,
        operationKind: ExternalOperationKind,
        outcome: ExternalOutcome,
        requestedAt: Date,
        committedAt: Date,
        changePosition: ChangePosition?,
        failureKind: ExternalFailureKindRaw?,
        denialReason: ExternalDenialReason?,
        affectedItemIDs: [HistoryItemID]?
    ) {
        self.auditSequence = auditSequence
        self.connectionID = connectionID
        self.capability = capability
        self.operationKind = operationKind
        self.outcome = outcome
        self.requestedAt = requestedAt
        self.committedAt = committedAt
        self.changePosition = changePosition
        self.failureKind = failureKind
        self.denialReason = denialReason
        self.affectedItemIDs = affectedItemIDs
    }
}

// MARK: - Typed Gateway failures and audit classification

/// Typed failure vocabulary of the external and Gateway-admin concerns.
public enum ExternalFailure: Error, Sendable, Equatable {
    case unauthorized(
        requestedCapability: ExternalCapability,
        connectionID: ExternalConnectionID
    )
    case connectionRevoked(connectionID: ExternalConnectionID)
    case requestDenied(ExternalDenialReason)
    case notFound(HistoryItemID)
    case history(HistoryFailure)
    case temporarilyUnavailable(ExternalTransientReason)
    case persistence(PersistenceFailure)
    case auditCompactedBefore(floor: UInt64)
}

/// Why a well-formed external request was denied at admission.
public enum ExternalDenialReason: Int16, Sendable, Equatable, Codable {
    case invalidInput = 1
    case rateLimited = 2
}

/// Retryable state exposed by the Gateway boundary.
public enum ExternalTransientReason: Int16, Sendable, Equatable, Codable {
    case indexRebuild = 1
    case storeLocked = 2
    case insufficientDiskSpace = 3
    case cancelled = 4
}

/// Stable discriminator persisted for a failed operation record.
public enum ExternalFailureKindRaw: Int16, Sendable, Hashable, Codable {
    case unauthorized = 1
    case connectionRevoked = 2
    case requestDenied = 3
    case notFound = 4
    case history = 5
    case temporarilyUnavailable = 6
    case persistence = 7
    case auditCompactedBefore = 8
}

/// Explicit reason for discarding an old audit-log range during rebase.
public enum AuditRebaseReason: Int16, Sendable, Hashable, Codable {
    case corruptionDetected = 1
    case adminForced = 2
}

/// Durable outcome class of one admitted external or admin operation.
public enum ExternalOutcome: Int16, Sendable, Hashable, Codable {
    case succeeded = 1
    case failed = 2
    case denied = 3
    case noOp = 4
}
