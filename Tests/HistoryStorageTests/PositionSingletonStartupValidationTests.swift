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
        maximumUnpinnedItems: Int
    ) throws {
        let schema = historySchema
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
        try context.save()
    }

    private static func seedValidCurrentStore(at storeURL: URL) async throws {
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        // Real commits establish position 17, policy 321 and their complete
        // current journal/Gateway companions. No missing owner is bootstrapped
        // from a historical partial schema when the next owner opens it.
        for position in 1...17 {
            let maximum = position.isMultiple(of: 2) ? 320 : 321
            let receipt = try await history.perform(.setRetentionPolicy(
                maximumUnpinnedItems: maximum
            ))
            guard case .committed(let commit) = receipt else {
                Issue.record("Expected the fixture's count-policy commit")
                throw HistoryFailure.persistence(.invariantViolation)
            }
            #expect(commit.position.rawValue == UInt64(position))
        }
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
        try await Self.seedValidCurrentStore(at: storeURL)

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
