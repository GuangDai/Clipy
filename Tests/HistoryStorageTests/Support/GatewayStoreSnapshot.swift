import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

struct GatewayStoreSnapshot: Equatable {
    struct Config: Equatable {
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

    struct Connection: Equatable {
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

    struct Grant: Equatable {
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

    struct Operation: Equatable {
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

    static func read(from storeURL: URL) throws -> GatewayStoreSnapshot {
        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        return try read(in: context)
    }

    static func read(in context: ModelContext) throws -> GatewayStoreSnapshot {
        let configs = try context.fetch(FetchDescriptor<GatewayConfigRow>())
            .map(Config.init)
            .sorted { $0.key < $1.key }
        let connections = try context.fetch(FetchDescriptor<ConnectionRow>())
            .map(Connection.init)
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let grants = try context.fetch(FetchDescriptor<GrantRow>())
            .map(Grant.init)
            .sorted { $0.grantKey < $1.grantKey }
        let operations = try context.fetch(FetchDescriptor<OperationRecordRow>())
            .map(Operation.init)
            .sorted { $0.auditSequence < $1.auditSequence }
        return GatewayStoreSnapshot(
            configs: configs,
            connections: connections,
            grants: grants,
            operations: operations
        )
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
