import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct GatewayStoreSnapshot: Equatable, Sendable {
    struct Config: Equatable, Sendable {
        let key: String
        let appIntentsConnectionID: UUID
        let nextAuditSequence: UInt64
        let auditBytes: UInt64
        let compactionFloor: UInt64
        let configSchemaVersion: UInt16

        init(_ row: GatewayConfigRow) {
            key = row.key
            appIntentsConnectionID = row.appIntentsConnectionID
            nextAuditSequence = row.nextAuditSequence
            auditBytes = row.auditBytes
            compactionFloor = row.compactionFloor
            configSchemaVersion = row.configSchemaVersion
        }
    }

    struct Connection: Equatable, Sendable {
        let id: UUID
        let displayNameRaw: String
        let enrollKindRaw: Int16
        let statusRaw: Int16
        let enrolledAt: Date
        let revokedAt: Date?
        let configSchemaVersion: UInt16

        init(_ row: ConnectionRow) {
            id = row.id
            displayNameRaw = row.displayNameRaw
            enrollKindRaw = row.enrollKindRaw
            statusRaw = row.statusRaw
            enrolledAt = row.enrolledAt
            revokedAt = row.revokedAt
            configSchemaVersion = row.configSchemaVersion
        }
    }

    struct Grant: Equatable, Sendable {
        let grantKey: String
        let connectionIDRaw: UUID
        let capabilityRaw: Int16
        let grantedAt: Date
        let revokedAt: Date?
        let configSchemaVersion: UInt16

        init(_ row: GrantRow) {
            grantKey = row.grantKey
            connectionIDRaw = row.connectionIDRaw
            capabilityRaw = row.capabilityRaw
            grantedAt = row.grantedAt
            revokedAt = row.revokedAt
            configSchemaVersion = row.configSchemaVersion
        }
    }

    struct Operation: Equatable, Sendable {
        let auditSequence: UInt64
        let connectionIDRaw: UUID?
        let capabilityRaw: Int16?
        let operationKindRaw: Int16
        let outcomeRaw: Int16
        let failureKindRaw: Int16?
        let denialReasonRaw: Int16?
        let payloadBlob: Data
        let requestedAt: Date
        let committedAt: Date
        let changePositionRaw: UInt64?
        let auditSchemaVersion: UInt16

        init(_ row: OperationRecordRow) {
            auditSequence = row.auditSequence
            connectionIDRaw = row.connectionIDRaw
            capabilityRaw = row.capabilityRaw
            operationKindRaw = row.operationKindRaw
            outcomeRaw = row.outcomeRaw
            failureKindRaw = row.failureKindRaw
            denialReasonRaw = row.denialReasonRaw
            payloadBlob = row.payloadBlob
            requestedAt = row.requestedAt
            committedAt = row.committedAt
            changePositionRaw = row.changePositionRaw
            auditSchemaVersion = row.auditSchemaVersion
        }
    }

    let configs: [Config]
    let connections: [Connection]
    let grants: [Grant]
    let operations: [Operation]

    static func read(from authority: HistoryAuthority) async throws -> GatewayStoreSnapshot {
        try await authority.gatewayStoreSnapshot()
    }

    static func read(from storeURL: URL) throws -> GatewayStoreSnapshot {
        let database = try SQLiteDatabase(url: storeURL, readOnly: true)
        return try database.readTransaction { try read(in: database) }
    }

    static func read(in database: SQLiteDatabase) throws -> GatewayStoreSnapshot {
        let configStatement = try database.prepare(
            "SELECT \(GatewayConfigRow.columns) FROM gateway_config ORDER BY key"
        )
        defer { configStatement.finalize() }
        var configs: [Config] = []
        while try configStatement.step() {
            configs.append(Config(try GatewayConfigRow(statement: configStatement)))
        }
        let connectionStatement = try database.prepare(
            "SELECT \(ConnectionRow.columns) FROM connections ORDER BY id"
        )
        defer { connectionStatement.finalize() }
        var connections: [Connection] = []
        while try connectionStatement.step() {
            connections.append(Connection(try ConnectionRow(statement: connectionStatement)))
        }
        let grantStatement = try database.prepare(
            "SELECT \(GrantRow.columns) FROM grants ORDER BY grantKey"
        )
        defer { grantStatement.finalize() }
        var grants: [Grant] = []
        while try grantStatement.step() {
            grants.append(Grant(try GrantRow(statement: grantStatement)))
        }
        let operations = try operationRows(in: database).map(Operation.init)
        return GatewayStoreSnapshot(
            configs: configs,
            connections: connections,
            grants: grants,
            operations: operations
        )
    }

    static func operationRows(in database: SQLiteDatabase) throws -> [OperationRecordRow] {
        let statement = try database.prepare("""
            SELECT auditSequence, connectionIDRaw, capabilityRaw, operationKindRaw,
                   outcomeRaw, failureKindRaw, denialReasonRaw, payloadBlob,
                   requestedAt, committedAt, changePositionRaw, auditSchemaVersion
            FROM operation_records ORDER BY auditSequence
            """)
        defer { statement.finalize() }
        var rows: [OperationRecordRow] = []
        while try statement.step() {
            let connectionID = try statement.optionalText(at: 1).map { raw in
                try #require(UUID(uuidString: raw))
            }
            rows.append(try OperationRecordRow(
                auditSequence: sqliteUInt64(statement.blob(at: 0)),
                connectionIDRaw: connectionID,
                capabilityRaw: statement.isNull(at: 2) ? nil : #require(Int16(exactly: statement.integer(at: 2))),
                operationKindRaw: #require(Int16(exactly: statement.integer(at: 3))),
                outcomeRaw: #require(Int16(exactly: statement.integer(at: 4))),
                failureKindRaw: statement.isNull(at: 5) ? nil : #require(Int16(exactly: statement.integer(at: 5))),
                denialReasonRaw: statement.isNull(at: 6) ? nil : #require(Int16(exactly: statement.integer(at: 6))),
                payloadBlob: statement.blob(at: 7),
                requestedAt: Date(timeIntervalSinceReferenceDate: statement.real(at: 8)),
                committedAt: Date(timeIntervalSinceReferenceDate: statement.real(at: 9)),
                changePositionRaw: statement.optionalBlob(at: 10).map { try sqliteUInt64($0) },
                auditSchemaVersion: #require(UInt16(exactly: statement.integer(at: 11)))
            ))
        }
        return rows
    }

    func expectX3DenyByDefaultBootstrap() throws {
        #expect(configs.count == 1)
        #expect(connections.count == 1)
        let config = try #require(configs.first)
        let connection = try #require(connections.first)
        #expect(config.key == "external-gateway")
        #expect(config.nextAuditSequence == 1)
        #expect(config.auditBytes == 0)
        #expect(config.compactionFloor == 1)
        #expect(config.configSchemaVersion == 1)
        #expect(connection.id == config.appIntentsConnectionID)
        #expect(connection.displayNameRaw == "Siri / Shortcuts / Spotlight")
        #expect(connection.enrollKindRaw == ConnectionEnrollKind.appIntents.rawValue)
        #expect(connection.statusRaw == ConnectionStatus.active.rawValue)
        #expect(connection.revokedAt == nil)
        #expect(connection.configSchemaVersion == 1)
        #expect(grants.isEmpty)
        #expect(operations.isEmpty)
    }
}

extension HistoryAuthority {
    func gatewayStoreSnapshot() throws -> GatewayStoreSnapshot {
        try database.readTransaction { try GatewayStoreSnapshot.read(in: database) }
    }

}
