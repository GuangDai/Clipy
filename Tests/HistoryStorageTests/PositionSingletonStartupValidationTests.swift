/// Startup validation for the existing position/retention singleton. A
/// durable singleton is not trusted merely because its row count is one:
/// its scalar policy must decode before the facade can be published (05 §13).
import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

struct PositionSingletonStartupValidationTests {
    private static func seedSingleton(
        at storeURL: URL,
        position: UInt64,
        maximumUnpinnedItems: Int,
        includeValidRetentionConfig: Bool = false
    ) throws {
        let schema = Schema(versionedSchema: HistorySchemaV2.self)
        let configuration = ModelConfiguration(
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        context.insert(LastChangePositionRow(
            key: "retained-history",
            rawValue: position,
            maximumUnpinnedItems: maximumUnpinnedItems
        ))
        if includeValidRetentionConfig {
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
        }
        try context.save()
    }

    @Test(arguments: [0, 5_001])
    func existingOutOfRangeRetentionFailsClosedWithoutRepair(
        storedMaximum: Int
    ) async throws {
        let storeURL = WSSupport.tempStoreURL(
            "position-singleton-corrupt-\(storedMaximum)"
        )
        defer { WSSupport.removeStore(storeURL) }
        try Self.seedSingleton(
            at: storeURL,
            position: 17,
            maximumUnpinnedItems: storedMaximum
        )

        // Exercise the production open order, not the helper directly: the
        // facade must not be published when §13 validates the existing row.
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await SwiftDataHistory.open(
                configuration: HistoryConfiguration(
                    persistence: .persistent(storeURL: storeURL),
                    initialMaximumUnpinnedItems: 200
                )
            )
        }

        // A new container proves startup did not repair either boundary
        // value, advance Change Position, or continue to the later config
        // bootstrap step after detecting the corrupt position singleton.
        let context = ModelContext(try WSSupport.makeContainer(storeURL: storeURL))
        let rows = try context.fetch(FetchDescriptor<LastChangePositionRow>())
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.rawValue == 17)
        #expect(row.maximumUnpinnedItems == storedMaximum)
        #expect(
            try context.fetchCount(
                FetchDescriptor<RetentionExpansionConfigRow>()
            ) == 0
        )
    }

    @Test("valid existing singleton ignores initial value and preserves durable scalars")
    func validExistingSingletonIgnoresInitialValue() async throws {
        let storeURL = WSSupport.tempStoreURL("position-singleton-valid-existing")
        defer { WSSupport.removeStore(storeURL) }
        try Self.seedSingleton(
            at: storeURL,
            position: 17,
            maximumUnpinnedItems: 321,
            includeValidRetentionConfig: true
        )

        _ = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(
                persistence: .persistent(storeURL: storeURL),
                initialMaximumUnpinnedItems: 200
            )
        )

        // The caller's 200 is only a fresh-store bootstrap value. Startup
        // validated the durable 321 and left both singleton scalars intact.
        let context = ModelContext(try WSSupport.makeContainer(storeURL: storeURL))
        let rows = try context.fetch(FetchDescriptor<LastChangePositionRow>())
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.rawValue == 17)
        #expect(row.maximumUnpinnedItems == 321)
        #expect(
            try context.fetchCount(
                FetchDescriptor<RetentionExpansionConfigRow>()
            ) == 1
        )
    }
}
