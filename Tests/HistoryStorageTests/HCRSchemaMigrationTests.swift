/// X-HCR/DC-25 HCR-only schema and literal V3 → V4 migration proofs.
/// Owning spec: the `V2-roadmap` DC-25 controlling amendment.
import Foundation
import SwiftData
import Testing
@testable import HistoryStorage

@Suite("Internal HCR-only V4 schema (X-HCR/DC-25)")
struct HCRSchemaMigrationTests {
    @Test("V4 adds exactly the two journal models after immutable V3")
    func v4ModelSet() {
        #expect(HistorySchemaV4.versionIdentifier == Schema.Version(4, 0, 0))
        let v4Models = HistorySchemaV4.models.map { "\($0)" }.sorted()
        let expected = (HistorySchemaV3.models.map { "\($0)" } + [
            "\(HistoryChangeRecordRow.self)",
            "\(JournalConfigRow.self)",
        ]).sorted()
        #expect(v4Models == expected)
        #expect(HistorySchemaV4.models.count == 10)
        let currentSchema = HistoryMigrationPlan.schemas.last
        #expect(currentSchema.map { ObjectIdentifier($0) }
            == ObjectIdentifier(HistorySchemaV4.self))
    }

    @Test("V4 round-trips the exact journal row surfaces")
    func journalRowsRoundTrip() throws {
        let schema = Schema(versionedSchema: HistorySchemaV4.self)
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
        let createdAt = Date(timeIntervalSinceReferenceDate: 902_000_001)
        let affectedItems = Data([0x00, 0x01, 0x02, 0x03])
        context.insert(HistoryChangeRecordRow(
            sequence: 41,
            changePositionRaw: 41,
            changeKindRaw: 8,
            affectedItemsBlob: affectedItems,
            createdAt: createdAt
        ))
        context.insert(JournalConfigRow(
            key: "change-journal",
            compactionFloorRaw: 9,
            journalBytes: 4,
            configSchemaVersion: 1
        ))
        try context.save()

        let record = try #require(
            context.fetch(FetchDescriptor<HistoryChangeRecordRow>()).first
        )
        #expect(record.sequence == 41)
        #expect(record.changePositionRaw == 41)
        #expect(record.changeKindRaw == 8)
        #expect(record.affectedItemsBlob == affectedItems)
        #expect(record.createdAt == createdAt)

        let config = try #require(
            context.fetch(FetchDescriptor<JournalConfigRow>()).first
        )
        #expect(config.key == "change-journal")
        #expect(config.compactionFloorRaw == 9)
        #expect(config.journalBytes == 4)
        #expect(config.configSchemaVersion == 1)
    }

    @Test("literal V3 rows survive lightweight migration and journal starts empty")
    func literalV3MigrationPreservesRows() throws {
        let storeURL = WSSupport.tempStoreURL("hcr-v3-to-v4")
        defer { WSSupport.removeStore(storeURL) }
        let expected: LiteralV3Snapshot

        do {
            let schema = Schema(versionedSchema: HistorySchemaV3.self)
            let container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(
                    schema: schema,
                    url: storeURL,
                    cloudKitDatabase: .none
                )]
            )
            let context = ModelContext(container)
            context.autosaveEnabled = false
            Self.insertLiteralV3Rows(in: context)
            try context.save()
            expected = try LiteralV3Snapshot.read(context)
        }

        let schema = Schema(versionedSchema: HistorySchemaV4.self)
        let migrated = try ModelContainer(
            for: schema,
            migrationPlan: HistoryMigrationPlan.self,
            configurations: [ModelConfiguration(
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )]
        )
        let context = ModelContext(migrated)
        #expect(try LiteralV3Snapshot.read(context) == expected)
        #expect(try context.fetchCount(
            FetchDescriptor<HistoryChangeRecordRow>()
        ) == 0)
        #expect(try context.fetchCount(FetchDescriptor<JournalConfigRow>()) == 0)
    }

    private static func insertLiteralV3Rows(in context: ModelContext) {
        let itemID = UUID(
            uuidString: "00000000-0000-0000-0000-0000000004B1"
        )!
        let connectionID = UUID(
            uuidString: "00000000-0000-0000-0000-0000000004B2"
        )!
        let first = Date(timeIntervalSinceReferenceDate: 902_100_001)
        let last = Date(timeIntervalSinceReferenceDate: 902_100_002)
        context.insert(HistoryItemRow(
            id: itemID,
            contentVersionRaw: 7,
            canonicalBlob: Data([0x11, 0x12]),
            revisionStateBlob: Data([0x21, 0x22]),
            canonicalSignatureBlob: Data([0x31, 0x32]),
            projectionSchemaVersion: 2,
            title: "literal V3 title",
            searchBody: "literal V3 body",
            effectiveTypeIdentifiersBlob: Data([0x41, 0x42]),
            firstCopiedAt: first,
            lastCopiedAt: last,
            copyCount: 5,
            firstSource: "com.example.first",
            lastSource: "com.example.last",
            pinOrdinal: 0
        ))
        context.insert(LastChangePositionRow(
            key: "retained-history",
            rawValue: 19,
            maximumUnpinnedItems: 177
        ))
        context.insert(RetentionExpansionConfigRow(
            key: "retention-expansion",
            agePolicyEnabled: true,
            ageMaxSeconds: 86_400,
            storagePolicyEnabled: true,
            storageMaxBytes: 9_999,
            revisionPolicyEnabled: true,
            revisionMaxCount: 4,
            revisionMaxBytes: 8_888,
            configSchemaVersion: 1
        ))
        context.insert(RetainedBytesRow(
            itemID: itemID,
            canonicalBytes: 101,
            revisionCount: 2,
            revisionBytes: 202,
            bytesSchemaVersion: 1
        ))
        context.insert(ConnectionRow(
            id: connectionID,
            displayNameRaw: "literal V3 connection",
            enrollKindRaw: 1,
            statusRaw: 1,
            enrolledAt: first,
            revokedAt: nil,
            configSchemaVersion: 1
        ))
        context.insert(GrantRow(
            grantKey: "00000000-0000-0000-0000-0000000004B2:3",
            connectionIDRaw: connectionID,
            capabilityRaw: 3,
            grantedAt: last,
            revokedAt: nil,
            configSchemaVersion: 1
        ))
        context.insert(OperationRecordRow(
            auditSequence: 6,
            connectionIDRaw: connectionID,
            capabilityRaw: 3,
            operationKindRaw: 5,
            outcomeRaw: 1,
            failureKindRaw: nil,
            denialReasonRaw: nil,
            payloadBlob: Data([0x51, 0x52]),
            requestedAt: first,
            committedAt: last,
            changePositionRaw: 19,
            auditSchemaVersion: 1
        ))
        context.insert(GatewayConfigRow(
            key: "external-gateway",
            appIntentsConnectionID: connectionID,
            nextAuditSequence: 7,
            auditBytes: 130,
            compactionFloor: 2,
            configSchemaVersion: 1
        ))
    }
}

private struct LiteralV3Snapshot: Equatable {
    let items: [LiteralItem]
    let positions: [LiteralPosition]
    let retention: [LiteralRetention]
    let bytes: [LiteralBytes]
    let gateway: GatewayStoreSnapshot

    static func read(_ context: ModelContext) throws -> Self {
        Self(
            items: try context.fetch(FetchDescriptor<HistoryItemRow>())
                .map(LiteralItem.init),
            positions: try context.fetch(FetchDescriptor<LastChangePositionRow>())
                .map(LiteralPosition.init),
            retention: try context.fetch(
                FetchDescriptor<RetentionExpansionConfigRow>()
            ).map(LiteralRetention.init),
            bytes: try context.fetch(FetchDescriptor<RetainedBytesRow>())
                .map(LiteralBytes.init),
            gateway: try GatewayStoreSnapshot.read(in: context)
        )
    }
}

private struct LiteralItem: Equatable {
    let id: UUID
    let contentVersionRaw: UInt64
    let canonicalBlob: Data
    let revisionStateBlob: Data
    let canonicalSignatureBlob: Data
    let projectionSchemaVersion: UInt16
    let title: String
    let searchBody: String
    let effectiveTypeIdentifiersBlob: Data
    let firstCopiedAt: Date
    let lastCopiedAt: Date
    let copyCount: UInt64
    let firstSource: String?
    let lastSource: String?
    let pinOrdinal: Int?

    init(_ row: HistoryItemRow) {
        id = row.id
        contentVersionRaw = row.contentVersionRaw
        canonicalBlob = row.canonicalBlob
        revisionStateBlob = row.revisionStateBlob
        canonicalSignatureBlob = row.canonicalSignatureBlob
        projectionSchemaVersion = row.projectionSchemaVersion
        title = row.title
        searchBody = row.searchBody
        effectiveTypeIdentifiersBlob = row.effectiveTypeIdentifiersBlob
        firstCopiedAt = row.firstCopiedAt
        lastCopiedAt = row.lastCopiedAt
        copyCount = row.copyCount
        firstSource = row.firstSource
        lastSource = row.lastSource
        pinOrdinal = row.pinOrdinal
    }
}

private struct LiteralPosition: Equatable {
    let key: String
    let rawValue: UInt64
    let maximumUnpinnedItems: Int

    init(_ row: LastChangePositionRow) {
        key = row.key
        rawValue = row.rawValue
        maximumUnpinnedItems = row.maximumUnpinnedItems
    }
}

private struct LiteralRetention: Equatable {
    let key: String
    let agePolicyEnabled: Bool
    let ageMaxSeconds: Double
    let storagePolicyEnabled: Bool
    let storageMaxBytes: Int
    let revisionPolicyEnabled: Bool
    let revisionMaxCount: Int?
    let revisionMaxBytes: Int?
    let configSchemaVersion: UInt16

    init(_ row: RetentionExpansionConfigRow) {
        key = row.key
        agePolicyEnabled = row.agePolicyEnabled
        ageMaxSeconds = row.ageMaxSeconds
        storagePolicyEnabled = row.storagePolicyEnabled
        storageMaxBytes = row.storageMaxBytes
        revisionPolicyEnabled = row.revisionPolicyEnabled
        revisionMaxCount = row.revisionMaxCount
        revisionMaxBytes = row.revisionMaxBytes
        configSchemaVersion = row.configSchemaVersion
    }
}

private struct LiteralBytes: Equatable {
    let itemID: UUID
    let canonicalBytes: Int
    let revisionCount: Int
    let revisionBytes: Int
    let bytesSchemaVersion: UInt16

    init(_ row: RetainedBytesRow) {
        itemID = row.itemID
        canonicalBytes = row.canonicalBytes
        revisionCount = row.revisionCount
        revisionBytes = row.revisionBytes
        bytesSchemaVersion = row.bytesSchemaVersion
    }
}
