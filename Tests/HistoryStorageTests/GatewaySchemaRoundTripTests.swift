import Foundation
import Testing
@testable import HistoryStorage

/// Current Gateway/audit rows preserve their stored values and optional
/// absence; regrant updates the existing grant row (V2-05 §4).
@Suite("Gateway schema round trip")
struct GatewaySchemaRoundTripTests {

    @Test("SQLite round-trips the complete Gateway row surface")
    func gatewayRowsRoundTrip() async throws {
        let authority = try HistoryAuthority(storeLocation: HistoryStoreLocation(persistence: .temporary))
        try await authority.withTestDatabase { owner in
            let context = owner.database
            try context.writeTransaction { try SQLiteHistorySchema.create(in: context) }

            let connectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
            let enrolledAt = Date(timeIntervalSinceReferenceDate: 800_000_001)
            try context.execute("""
                INSERT INTO connections (id, displayNameRaw, enrollKindRaw, statusRaw, enrolledAt, revokedAt, configSchemaVersion)
                VALUES (?, ?, 1, 1, ?, NULL, 1)
                """, bindings: [.text(connectionID.uuidString), .text("Clipy App Intents"),
                    .real(enrolledAt.timeIntervalSinceReferenceDate)])

            let grantedAt = Date(timeIntervalSinceReferenceDate: 800_000_002)
            let revokedAt = Date(timeIntervalSinceReferenceDate: 800_000_003)
            try context.execute("""
                INSERT INTO grants (grantKey, connectionIDRaw, capabilityRaw, grantedAt, revokedAt, configSchemaVersion)
                VALUES (?, ?, 3, ?, ?, 1)
                """, bindings: [.text("00000000-0000-0000-0000-000000000301:3"),
                    .text(connectionID.uuidString), .real(grantedAt.timeIntervalSinceReferenceDate),
                    .real(revokedAt.timeIntervalSinceReferenceDate)])

            let requestedAt = Date(timeIntervalSinceReferenceDate: 800_000_004)
            let committedAt = Date(timeIntervalSinceReferenceDate: 800_000_005)
            let payload = Data([0x01, 0x02, 0x03])
            try context.execute("""
                INSERT INTO operation_records
                    (auditSequence, connectionIDRaw, capabilityRaw, operationKindRaw, outcomeRaw,
                     failureKindRaw, denialReasonRaw, payloadBlob, requestedAt, committedAt, changePositionRaw, auditSchemaVersion)
                VALUES (?, ?, 3, 5, 1, NULL, NULL, ?, ?, ?, ?, 1)
                """, bindings: [.blob(sqliteUInt64(7)), .text(connectionID.uuidString),
                    .blob(payload), .real(requestedAt.timeIntervalSinceReferenceDate),
                    .real(committedAt.timeIntervalSinceReferenceDate), .blob(sqliteUInt64(11))])

            try context.execute("""
                INSERT INTO gateway_config (key, appIntentsConnectionID, nextAuditSequence, auditBytes, compactionFloor, configSchemaVersion)
                VALUES ('external-gateway', ?, ?, ?, ?, 1)
                """, bindings: [.text(connectionID.uuidString), .blob(sqliteUInt64(8)),
                    .blob(sqliteUInt64(3)), .blob(sqliteUInt64(1))])

            let state = try GatewayStoreSnapshot.read(in: context)
            let connection = try #require(state.connections.first)
            #expect(connection.id == connectionID)
            #expect(connection.displayNameRaw == "Clipy App Intents")
            #expect(connection.enrollKindRaw == 1)
            #expect(connection.statusRaw == 1)
            #expect(connection.enrolledAt == enrolledAt)
            #expect(connection.revokedAt == nil)
            #expect(connection.configSchemaVersion == 1)

            let grant = try #require(state.grants.first)
            #expect(grant.grantKey == "00000000-0000-0000-0000-000000000301:3")
            #expect(grant.connectionIDRaw == connectionID)
            #expect(grant.capabilityRaw == 3)
            #expect(grant.grantedAt == grantedAt)
            #expect(grant.revokedAt == revokedAt)
            #expect(grant.configSchemaVersion == 1)

            let operation = try #require(state.operations.first)
            #expect(operation.auditSequence == 7)
            #expect(operation.connectionIDRaw == connectionID)
            #expect(operation.capabilityRaw == 3)
            #expect(operation.operationKindRaw == 5)
            #expect(operation.outcomeRaw == 1)
            #expect(operation.failureKindRaw == nil)
            #expect(operation.denialReasonRaw == nil)
            #expect(operation.payloadBlob == payload)
            #expect(operation.requestedAt == requestedAt)
            #expect(operation.committedAt == committedAt)
            #expect(operation.changePositionRaw == 11)
            #expect(operation.auditSchemaVersion == 1)

            // In-app rebase/compact audit records have no external connection or
            // capability; the schema represents absence without a fake raw value.
            try context.execute("""
                INSERT INTO operation_records
                    (auditSequence, connectionIDRaw, capabilityRaw, operationKindRaw, outcomeRaw,
                     failureKindRaw, denialReasonRaw, payloadBlob, requestedAt, committedAt, changePositionRaw, auditSchemaVersion)
                VALUES (?, NULL, NULL, 11, 1, NULL, NULL, ?, ?, ?, NULL, 1)
                """, bindings: [.blob(sqliteUInt64(8)), .blob(Data()),
                    .real(requestedAt.timeIntervalSinceReferenceDate),
                    .real(committedAt.timeIntervalSinceReferenceDate)])
            let operations = try GatewayStoreSnapshot.read(in: context).operations
            let adminOperation = try #require(
                operations.first { $0.auditSequence == 8 }
            )
            #expect(adminOperation.connectionIDRaw == nil)
            #expect(adminOperation.capabilityRaw == nil)

            let config = try #require(state.configs.first)
            #expect(config.key == "external-gateway")
            #expect(config.appIntentsConnectionID == connectionID)
            #expect(config.nextAuditSequence == 8)
            #expect(config.auditBytes == 3)
            #expect(config.compactionFloor == 1)
            #expect(config.configSchemaVersion == 1)

            // GrantRow owns only current state. Regrant updates the same unique
            // pair row; immutable OperationRecordRow entries own lifecycle audit.
            let regrantedAt = Date(timeIntervalSinceReferenceDate: 800_000_006)
            try context.execute("UPDATE grants SET grantedAt = ?, revokedAt = NULL WHERE grantKey = ?",
                bindings: [.real(regrantedAt.timeIntervalSinceReferenceDate), .text(grant.grantKey)])

            let grants = try GatewayStoreSnapshot.read(in: context).grants
            #expect(grants.count == 1)
            #expect(grants[0].grantedAt == regrantedAt)
            #expect(grants[0].revokedAt == nil)
        }
    }
}
