import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

/// X-PLATFORM-1 migration proof (`V2-roadmap` §10 X.3; `V2-05` Record 5,
/// corrected by DC-03): the additive V2 → V3 hop preserves every existing
/// persisted field and creates no Gateway data during the migration stage.
/// The fixture observes that pre-bootstrap state, then crosses the public-open
/// seam where the separate X.3 bootstrap runs.
@Suite("V2 → V3 Gateway schema migration")
struct GatewaySchemaMigrationTests {

    @Test("migration starts Gateway-empty and public reopen preserves literal V2 rows")
    func migrationStartsGatewayEmptyAndPublicReopenPreservesV2Rows() async throws {
        let storeURL = WSSupport.tempStoreURL("gateway-v2-to-v3")
        defer { WSSupport.removeStore(storeURL) }

        let expected = try await Self.seedLiteralV2Store(at: storeURL)

        // Construction through the production migration plan performs the
        // additive hop without running any startup/bootstrap writer.
        do {
            let migratedContainer = try MigrationSeeding.makeMigrationContainer(
                storeURL: storeURL
            )
            let migratedContext = ModelContext(migratedContainer)
            #expect(try ExistingV2RowsSnapshot.read(migratedContext) == expected)
            try Self.expectGatewayTablesEmpty(migratedContext)
        }

        // Reopen the same migrated URL through the public production seam.
        // Production startup now validates/rebuilds the preserved v1/V2 state
        // and then publishes the X.3 deny-by-default bootstrap rows.
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(
                persistence: .persistent(storeURL: storeURL),
                initialMaximumUnpinnedItems: 200
            )
        )
        let page = try await history.browse(HistoryBrowseRequest(
            kind: .recent,
            limit: 10
        ))
        #expect(
            Set(page.rows.map { $0.item.id.rawValue })
                == Set(expected.items.map { $0.id })
        )

        // A second public reopen proves an already-V3 store runs no stage.
        let reopened = try await WSSupport.openHistory(storeURL: storeURL)
        let reopenedPage = try await reopened.browse(HistoryBrowseRequest(
            kind: .recent,
            limit: 10
        ))
        #expect(
            Set(reopenedPage.rows.map { $0.item.id.rawValue })
                == Set(expected.items.map { $0.id })
        )

        // Independent row-level verification: neither migration nor either
        // public startup/reopen rewrote any pre-existing V2 field. Exact
        // Gateway bootstrap values are covered by GatewayBootstrapTests.
        let assertionContext = ModelContext(
            try WSSupport.makeContainer(storeURL: storeURL)
        )
        #expect(try ExistingV2RowsSnapshot.read(assertionContext) == expected)
        try GatewayStoreSnapshot.read(in: assertionContext)
            .expectX3DenyByDefaultBootstrap()
    }

    private static func seedLiteralV2Store(
        at storeURL: URL
    ) async throws -> ExistingV2RowsSnapshot {
        let schema = Schema(versionedSchema: HistorySchemaV2.self)
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

        _ = try await MigrationSeeding.seedV1Store(into: context)
        try RetainedBytesBackfill.backfill(in: context)
        // Seed a true current V2 production shape. The V2 → V3 migration
        // proof must not be confounded by the separate startup recipe-v1 →
        // recipe-v2 projection rebuild that public open intentionally owns.
        try ContentProjectionRebuild.rebuildIfNeeded(
            in: context,
            limits: .standard
        )
        context.insert(RetentionExpansionConfigRow(
            key: "retention-expansion",
            agePolicyEnabled: false,
            ageMaxSeconds: 0,
            storagePolicyEnabled: false,
            storageMaxBytes: 0,
            revisionPolicyEnabled: false,
            revisionMaxCount: nil,
            revisionMaxBytes: nil,
            configSchemaVersion: 1
        ))
        try context.save()
        return try ExistingV2RowsSnapshot.read(context)
    }

    private static func expectGatewayTablesEmpty(
        _ context: ModelContext
    ) throws {
        #expect(try context.fetchCount(FetchDescriptor<ConnectionRow>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<GrantRow>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<OperationRecordRow>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<GatewayConfigRow>()) == 0)
    }
}

/// Value-only migration oracle. Raw `Data` fields are copied and compared
/// directly; no checksum or codec-derived surrogate stands in for the bytes.
private struct ExistingV2RowsSnapshot: Equatable {
    let items: [ExistingItemSnapshot]
    let positions: [ExistingPositionSnapshot]
    let retentionConfigs: [ExistingRetentionConfigSnapshot]
    let retainedBytes: [ExistingRetainedBytesSnapshot]

    static func read(_ context: ModelContext) throws -> ExistingV2RowsSnapshot {
        let items = try context.fetch(FetchDescriptor<HistoryItemRow>())
        let positions = try context.fetch(FetchDescriptor<LastChangePositionRow>())
        let configs = try context.fetch(FetchDescriptor<RetentionExpansionConfigRow>())
        let retainedBytes = try context.fetch(FetchDescriptor<RetainedBytesRow>())
        return ExistingV2RowsSnapshot(
            items: items.map(ExistingItemSnapshot.init).sorted {
                $0.id.uuidString < $1.id.uuidString
            },
            positions: positions.map(ExistingPositionSnapshot.init).sorted {
                $0.key < $1.key
            },
            retentionConfigs: configs.map(ExistingRetentionConfigSnapshot.init).sorted {
                $0.key < $1.key
            },
            retainedBytes: retainedBytes.map(ExistingRetainedBytesSnapshot.init).sorted {
                $0.itemID.uuidString < $1.itemID.uuidString
            }
        )
    }
}

private struct ExistingItemSnapshot: Equatable {
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

private struct ExistingPositionSnapshot: Equatable {
    let key: String
    let rawValue: UInt64
    let maximumUnpinnedItems: Int

    init(_ row: LastChangePositionRow) {
        key = row.key
        rawValue = row.rawValue
        maximumUnpinnedItems = row.maximumUnpinnedItems
    }
}

private struct ExistingRetentionConfigSnapshot: Equatable {
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

private struct ExistingRetainedBytesSnapshot: Equatable {
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
