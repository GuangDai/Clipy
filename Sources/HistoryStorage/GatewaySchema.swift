/// X.3 Gateway/Audit schema additions (`V2-roadmap` §10 X.3; `V2-05` §4
/// / Record 5), corrected by DC-03 incremental shipping. The shipped
/// `HistorySchemaV2` remains immutable; this purely additive graft receives
/// `HistorySchemaV3`. All model types remain internal to HistoryStorage.
import Foundation
import SwiftData

/// The second shipped V2-era schema: the immutable V2 retention schema plus
/// the four Gateway/Audit rows. The `V2 → V3` hop is lightweight because it
/// adds tables only and neither rewrites existing rows nor backfills data.
internal enum HistorySchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            HistoryItemRow.self,
            LastChangePositionRow.self,
            RetentionExpansionConfigRow.self,
            RetainedBytesRow.self,
            ConnectionRow.self,
            GrantRow.self,
            OperationRecordRow.self,
            GatewayConfigRow.self
        ]
    }
}

/// Durable lifecycle state for one external connection (`V2-05` §4.1).
/// Capability grants and audit records reference the business UUID by value;
/// no SwiftData relationship can cascade-delete their independent state.
@Model
internal final class ConnectionRow {
    @Attribute(.unique)
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
@Model
internal final class GrantRow {
    @Attribute(.unique)
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
@Model
internal final class OperationRecordRow {
    @Attribute(.unique)
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
@Model
internal final class GatewayConfigRow {
    @Attribute(.unique)
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
