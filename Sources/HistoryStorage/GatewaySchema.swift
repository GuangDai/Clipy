/// Durable Gateway connections, grants, operation records and configuration.
/// All transient row values remain internal to HistoryStorage (V2-05 §4).
import Foundation
import HistoryCore

extension ConnectionRow {
    internal init(statement: SQLiteStatement) throws {
        guard let id = UUID(uuidString: try statement.text(at: 0)),
              let kind = Int16(exactly: try statement.integer(at: 2)),
              let status = Int16(exactly: try statement.integer(at: 3)),
              let version = UInt16(exactly: try statement.integer(at: 6)) else {
            throw HistoryFailure.persistence(.corruptStoredValue)
        }
        self.init(id: id, displayNameRaw: try statement.text(at: 1),
            enrollKindRaw: kind, statusRaw: status,
            enrolledAt: Date(timeIntervalSinceReferenceDate: try statement.real(at: 4)),
            revokedAt: try statement.isNull(at: 5) ? nil : Date(timeIntervalSinceReferenceDate: statement.real(at: 5)),
            configSchemaVersion: version)
    }
}

extension GrantRow {
    internal init(statement: SQLiteStatement) throws {
        guard let id = UUID(uuidString: try statement.text(at: 1)),
              let capability = Int16(exactly: try statement.integer(at: 2)),
              let version = UInt16(exactly: try statement.integer(at: 5)) else {
            throw HistoryFailure.persistence(.corruptStoredValue)
        }
        self.init(grantKey: try statement.text(at: 0), connectionIDRaw: id,
            capabilityRaw: capability,
            grantedAt: Date(timeIntervalSinceReferenceDate: try statement.real(at: 3)),
            revokedAt: try statement.isNull(at: 4) ? nil : Date(timeIntervalSinceReferenceDate: statement.real(at: 4)),
            configSchemaVersion: version)
    }
}

extension GatewayConfigRow {
    internal init(statement: SQLiteStatement) throws {
        guard let id = UUID(uuidString: try statement.text(at: 1)),
              let version = UInt16(exactly: try statement.integer(at: 5)) else {
            throw HistoryFailure.persistence(.corruptStoredValue)
        }
        self.init(key: try statement.text(at: 0), appIntentsConnectionID: id,
            nextAuditSequence: try sqliteUInt64(statement.blob(at: 2)),
            auditBytes: try sqliteUInt64(statement.blob(at: 3)),
            compactionFloor: try sqliteUInt64(statement.blob(at: 4)),
            configSchemaVersion: version)
    }
}

/// Durable lifecycle state for one external connection (`V2-05` §4.1).
/// Capability grants and audit records reference the business UUID by value;
/// SQL changes never cascade-delete their independent state.
internal struct ConnectionRow: Sendable {
    internal static let columns = "id, displayNameRaw, enrollKindRaw, statusRaw, enrolledAt, revokedAt, configSchemaVersion"
    var id: UUID

    var displayNameRaw: String
    var enrollKindRaw: Int16
    var statusRaw: Int16
    var enrolledAt: Date
    var revokedAt: Date?
    var configSchemaVersion: UInt16

    init(
        id: UUID,
        displayNameRaw: String,
        enrollKindRaw: Int16,
        statusRaw: Int16,
        enrolledAt: Date,
        revokedAt: Date?,
        configSchemaVersion: UInt16
    ) {
        self.id = id
        self.displayNameRaw = displayNameRaw
        self.enrollKindRaw = enrollKindRaw
        self.statusRaw = statusRaw
        self.enrolledAt = enrolledAt
        self.revokedAt = revokedAt
        self.configSchemaVersion = configSchemaVersion
    }
}

/// Current grant state for one `(connection, capability)` pair (`V2-05`
/// §4.2, X.3 resolved shape). `grantKey` is the composite-unique anchor.
/// Revocation and later regrant update this same row; immutable operation
/// records, not duplicate GrantRows, own the lifecycle audit trail.
internal struct GrantRow: Sendable {
    internal static let columns = "grantKey, connectionIDRaw, capabilityRaw, grantedAt, revokedAt, configSchemaVersion"
    var grantKey: String

    var connectionIDRaw: UUID
    var capabilityRaw: Int16
    var grantedAt: Date
    var revokedAt: Date?
    var configSchemaVersion: UInt16

    init(
        grantKey: String,
        connectionIDRaw: UUID,
        capabilityRaw: Int16,
        grantedAt: Date,
        revokedAt: Date?,
        configSchemaVersion: UInt16
    ) {
        self.grantKey = grantKey
        self.connectionIDRaw = connectionIDRaw
        self.capabilityRaw = capabilityRaw
        self.grantedAt = grantedAt
        self.revokedAt = revokedAt
        self.configSchemaVersion = configSchemaVersion
    }
}

/// Immutable classification and bounded payload for one external operation
/// (`V2-05` §4.3, X.3 resolved shape). The row deliberately contains no
/// chain-link or hash field; audit ordering is the unique monotone sequence.
internal struct OperationRecordRow: Sendable {
    var auditSequence: UInt64

    var connectionIDRaw: UUID?
    var capabilityRaw: Int16?
    var operationKindRaw: Int16
    var outcomeRaw: Int16
    var failureKindRaw: Int16?
    var denialReasonRaw: Int16?
    var payloadBlob: Data
    var requestedAt: Date
    var committedAt: Date
    var changePositionRaw: UInt64?
    var auditSchemaVersion: UInt16

    init(
        auditSequence: UInt64,
        connectionIDRaw: UUID?,
        capabilityRaw: Int16?,
        operationKindRaw: Int16,
        outcomeRaw: Int16,
        failureKindRaw: Int16?,
        denialReasonRaw: Int16?,
        payloadBlob: Data,
        requestedAt: Date,
        committedAt: Date,
        changePositionRaw: UInt64?,
        auditSchemaVersion: UInt16
    ) {
        self.auditSequence = auditSequence
        self.connectionIDRaw = connectionIDRaw
        self.capabilityRaw = capabilityRaw
        self.operationKindRaw = operationKindRaw
        self.outcomeRaw = outcomeRaw
        self.failureKindRaw = failureKindRaw
        self.denialReasonRaw = denialReasonRaw
        self.payloadBlob = payloadBlob
        self.requestedAt = requestedAt
        self.committedAt = committedAt
        self.changePositionRaw = changePositionRaw
        self.auditSchemaVersion = auditSchemaVersion
    }
}

/// Durable Gateway/audit singleton (`V2-05` §4.6), keyed by
/// `"external-gateway"`. The schema carries only state with an admitted
/// consumer: the durable App Intents identity, audit head/counter, compaction
/// floor, and schema fence. DC-26 therefore omits the former write-only
/// `generation` proposal.
internal struct GatewayConfigRow: Sendable {
    internal static let columns = "key, appIntentsConnectionID, nextAuditSequence, auditBytes, compactionFloor, configSchemaVersion"
    var key: String

    var appIntentsConnectionID: UUID
    var nextAuditSequence: UInt64
    var auditBytes: UInt64
    var compactionFloor: UInt64
    var configSchemaVersion: UInt16

    init(
        key: String,
        appIntentsConnectionID: UUID,
        nextAuditSequence: UInt64,
        auditBytes: UInt64,
        compactionFloor: UInt64,
        configSchemaVersion: UInt16
    ) {
        self.key = key
        self.appIntentsConnectionID = appIntentsConnectionID
        self.nextAuditSequence = nextAuditSequence
        self.auditBytes = auditBytes
        self.compactionFloor = compactionFloor
        self.configSchemaVersion = configSchemaVersion
    }
}
