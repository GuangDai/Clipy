import Testing
@testable import HistoryStorage
import SwiftData

/// M1.2 proof (schema half): `HistorySchemaV2` carries exactly the frozen v1
/// rows plus the two retention rows (`V2-02` §3.3, DC-03 incremental
/// shipping), both rows round-trip their complete field surface, and the
/// schema opens an in-memory container end to end. Expected values come from
/// the V2-02 spec field lists, not from the types' own definitions. The
/// `V1 → V2` migration hop itself (single custom stage + backfill) is proven
/// by the migration fixtures in `HistoryMigrationTests`.
@Suite("HistorySchemaV2 (M1.2 schema half)")
struct HistorySchemaV2Tests {

    @Test("versionIdentifier names the first shipped V2 schema as 2.0.0")
    func versionIdentifierIsTwo() {
        #expect(HistorySchemaV2.versionIdentifier == Schema.Version(2, 0, 0))
    }

    @Test("the V2 model set is the frozen v1 rows plus exactly the two retention rows")
    func modelSetIsV1PlusRetentionRows() {
        let v2Models = Set(HistorySchemaV2.models.map { "\($0)" })
        let expected: Set<String> = [
            "\(HistoryItemRow.self)",
            "\(LastChangePositionRow.self)",
            "\(RetentionExpansionConfigRow.self)",
            "\(RetainedBytesRow.self)"
        ]
        #expect(v2Models == expected)
        #expect(HistorySchemaV2.models.count == 4)

        // The V2 anchor is the v1 anchor plus the retention rows — no v1
        // model was removed or replaced (frozen v1 set, 05 §3).
        let v1Models = Set(HistorySchemaV1.models.map { "\($0)" })
        #expect(v2Models.isSuperset(of: v1Models))
    }

    @Test("a V2 in-memory container round-trips both retention rows completely")
    func retentionRowsRoundTrip() throws {
        let configuration = ModelConfiguration(
            schema: Schema(versionedSchema: HistorySchemaV2.self),
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: Schema(versionedSchema: HistorySchemaV2.self),
            configurations: [configuration]
        )
        let context = ModelContext(container)

        // Field surface per V2-02 §3.3: singleton key, R1/R2/R3 triples,
        // config fence. Values chosen to exercise optionals both ways.
        let config = RetentionExpansionConfigRow(
            key: "retention-expansion",
            agePolicyEnabled: true,
            ageMaxSeconds: 86_400,
            storagePolicyEnabled: false,
            storageMaxBytes: 1_000,
            revisionPolicyEnabled: true,
            revisionMaxCount: 20,
            revisionMaxBytes: nil,
            configSchemaVersion: 1
        )
        context.insert(config)

        // Field surface per V2-02 §3.3b: 1:1 business ID, three scalars,
        // projection fence. revisionCount == 0 / revisionBytes == 0 is the
        // insert-time stamp shape (DC-04: v1 inserts carry an empty list).
        let itemID = UUID()
        let bytes = RetainedBytesRow(
            itemID: itemID,
            canonicalBytes: 128,
            revisionCount: 0,
            revisionBytes: 0,
            bytesSchemaVersion: 1
        )
        context.insert(bytes)
        try context.save()

        let fetchedConfigs = try context.fetch(
            FetchDescriptor<RetentionExpansionConfigRow>()
        )
        #expect(fetchedConfigs.count == 1)
        let fetchedConfig = try #require(fetchedConfigs.first)
        #expect(fetchedConfig.key == "retention-expansion")
        #expect(fetchedConfig.agePolicyEnabled == true)
        #expect(fetchedConfig.ageMaxSeconds == 86_400)
        #expect(fetchedConfig.storagePolicyEnabled == false)
        #expect(fetchedConfig.storageMaxBytes == 1_000)
        #expect(fetchedConfig.revisionPolicyEnabled == true)
        #expect(fetchedConfig.revisionMaxCount == 20)
        #expect(fetchedConfig.revisionMaxBytes == nil)
        #expect(fetchedConfig.configSchemaVersion == 1)

        let fetchedRows = try context.fetch(FetchDescriptor<RetainedBytesRow>())
        #expect(fetchedRows.count == 1)
        let fetchedBytes = try #require(fetchedRows.first)
        #expect(fetchedBytes.itemID == itemID)
        #expect(fetchedBytes.canonicalBytes == 128)
        #expect(fetchedBytes.revisionCount == 0)
        #expect(fetchedBytes.revisionBytes == 0)
        #expect(fetchedBytes.bytesSchemaVersion == 1)
    }
}
