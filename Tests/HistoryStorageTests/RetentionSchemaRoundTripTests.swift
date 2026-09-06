import Foundation
import Testing
@testable import HistoryStorage
import SwiftData

/// The current retention configuration and byte-accounting rows preserve
/// their complete field values in the application schema (V2-02 §3.3).
@Suite("Retention schema round trip")
struct RetentionSchemaRoundTripTests {

    @Test("an in-memory container round-trips both retention rows completely")
    func retentionRowsRoundTrip() throws {
        let configuration = ModelConfiguration(
            schema: historySchema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: historySchema,
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
