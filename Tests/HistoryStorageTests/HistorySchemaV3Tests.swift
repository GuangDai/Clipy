import Foundation
import SwiftData
import Testing
@testable import HistoryStorage

/// X.3 schema proof (`V2-roadmap` §10 X.3; `V2-05` §4 / Record 5,
/// corrected by DC-03 incremental shipping): the immutable V3 schema is the
/// shipped V2 model set plus exactly four additive Gateway/Audit tables.
@Suite("HistorySchemaV3 (X.3 schema slice)")
struct HistorySchemaV3Tests {

    @Test("V3 is version 3.0.0 and adds exactly the four Gateway models")
    func modelSetIsV2PlusGatewayRows() {
        #expect(HistorySchemaV3.versionIdentifier == Schema.Version(3, 0, 0))

        let v3Models = Set(HistorySchemaV3.models.map { "\($0)" })
        let expected = Set(HistorySchemaV2.models.map { "\($0)" }).union([
            "\(ConnectionRow.self)",
            "\(GrantRow.self)",
            "\(OperationRecordRow.self)",
            "\(GatewayConfigRow.self)"
        ])

        #expect(v3Models == expected)
        #expect(HistorySchemaV3.models.count == 8)
        #expect(v3Models.isSuperset(of: Set(HistorySchemaV2.models.map { "\($0)" })))
    }

    @Test("a V3 container round-trips the complete Gateway row surface")
    func gatewayRowsRoundTrip() throws {
        let schema = Schema(versionedSchema: HistorySchemaV3.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )]
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let connectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
        let enrolledAt = Date(timeIntervalSinceReferenceDate: 800_000_001)
        context.insert(ConnectionRow(
            id: connectionID,
            displayNameRaw: "Clipy App Intents",
            enrollKindRaw: 1,
            statusRaw: 1,
            enrolledAt: enrolledAt,
            revokedAt: nil,
            configSchemaVersion: 1
        ))

        let grantedAt = Date(timeIntervalSinceReferenceDate: 800_000_002)
        let revokedAt = Date(timeIntervalSinceReferenceDate: 800_000_003)
        context.insert(GrantRow(
            grantKey: "00000000-0000-0000-0000-000000000301:3",
            connectionIDRaw: connectionID,
            capabilityRaw: 3,
            grantedAt: grantedAt,
            revokedAt: revokedAt,
            configSchemaVersion: 1
        ))

        let requestedAt = Date(timeIntervalSinceReferenceDate: 800_000_004)
        let committedAt = Date(timeIntervalSinceReferenceDate: 800_000_005)
        let payload = Data([0x01, 0x02, 0x03])
        context.insert(OperationRecordRow(
            auditSequence: 7,
            connectionIDRaw: connectionID,
            capabilityRaw: 3,
            operationKindRaw: 5,
            outcomeRaw: 1,
            failureKindRaw: nil,
            denialReasonRaw: nil,
            payloadBlob: payload,
            requestedAt: requestedAt,
            committedAt: committedAt,
            changePositionRaw: 11,
            auditSchemaVersion: 1
        ))

        context.insert(GatewayConfigRow(
            key: "external-gateway",
            appIntentsConnectionID: connectionID,
            nextAuditSequence: 8,
            auditBytes: 3,
            compactionFloor: 1,
            configSchemaVersion: 1
        ))
        try context.save()

        let connection = try #require(
            context.fetch(FetchDescriptor<ConnectionRow>()).first
        )
        #expect(connection.id == connectionID)
        #expect(connection.displayNameRaw == "Clipy App Intents")
        #expect(connection.enrollKindRaw == 1)
        #expect(connection.statusRaw == 1)
        #expect(connection.enrolledAt == enrolledAt)
        #expect(connection.revokedAt == nil)
        #expect(connection.configSchemaVersion == 1)

        let grant = try #require(context.fetch(FetchDescriptor<GrantRow>()).first)
        #expect(grant.grantKey == "00000000-0000-0000-0000-000000000301:3")
        #expect(grant.connectionIDRaw == connectionID)
        #expect(grant.capabilityRaw == 3)
        #expect(grant.grantedAt == grantedAt)
        #expect(grant.revokedAt == revokedAt)
        #expect(grant.configSchemaVersion == 1)

        let operation = try #require(
            context.fetch(FetchDescriptor<OperationRecordRow>()).first
        )
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
        context.insert(OperationRecordRow(
            auditSequence: 8,
            connectionIDRaw: nil,
            capabilityRaw: nil,
            operationKindRaw: 11,
            outcomeRaw: 1,
            failureKindRaw: nil,
            denialReasonRaw: nil,
            payloadBlob: Data(),
            requestedAt: requestedAt,
            committedAt: committedAt,
            changePositionRaw: nil,
            auditSchemaVersion: 1
        ))
        try context.save()
        let operations = try context.fetch(FetchDescriptor<OperationRecordRow>())
        let adminOperation = try #require(
            operations.first { $0.auditSequence == 8 }
        )
        #expect(adminOperation.connectionIDRaw == nil)
        #expect(adminOperation.capabilityRaw == nil)

        let config = try #require(
            context.fetch(FetchDescriptor<GatewayConfigRow>()).first
        )
        #expect(config.key == "external-gateway")
        #expect(config.appIntentsConnectionID == connectionID)
        #expect(config.nextAuditSequence == 8)
        #expect(config.auditBytes == 3)
        #expect(config.compactionFloor == 1)
        #expect(config.configSchemaVersion == 1)

        // GrantRow owns only current state. Regrant updates the same unique
        // pair row; immutable OperationRecordRow entries own lifecycle audit.
        let regrantedAt = Date(timeIntervalSinceReferenceDate: 800_000_006)
        grant.grantedAt = regrantedAt
        grant.revokedAt = nil
        try context.save()

        let grants = try context.fetch(FetchDescriptor<GrantRow>())
        #expect(grants.count == 1)
        #expect(grants[0].grantedAt == regrantedAt)
        #expect(grants[0].revokedAt == nil)
    }
}
