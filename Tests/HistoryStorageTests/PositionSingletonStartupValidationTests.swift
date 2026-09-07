/// Durable count policy is validated before a reopened facade is published.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct PositionSingletonStartupValidationTests {
    @Test(arguments: [0, 5_001])
    func existingOutOfRangeRetentionFailsClosedWithoutRepair(storedMaximum: Int) async throws {
        let url = WSSupport.tempStoreURL("sqlite-position-corrupt-\(storedMaximum)")
        defer { WSSupport.removeStore(url) }
        try await Self.seed(at: url)
        do {
            let database = try SQLiteDatabase(url: url)
            try database.execute("PRAGMA ignore_check_constraints = ON")
            try database.execute("UPDATE history_state SET maximumUnpinnedItems = ?", bindings: [.integer(Int64(storedMaximum))])
        }
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await WSSupport.openHistory(storeURL: url)
        }
        let reader = try SQLiteDatabase(url: url)
        let row = try HistoryAuthority.fetchExactlyOnePositionRow(in: reader)
        #expect(row.rawValue == 17)
        #expect(row.maximumUnpinnedItems == storedMaximum)
        let policies = try reader.prepare("SELECT count(*) FROM retention_policies")
        defer { policies.finalize() }
        try #require(try policies.step())
        #expect(try policies.integer(at: 0) == 1)
    }

    @Test func validExistingSingletonIgnoresInitialValue() async throws {
        let url = WSSupport.tempStoreURL("sqlite-position-reopen")
        defer { WSSupport.removeStore(url) }
        try await Self.seed(at: url)
        let reopened = try await SQLiteHistory.open(configuration: .init(persistence: .persistent(storeURL: url), initialMaximumUnpinnedItems: 200))
        #expect(try await reopened.authority.currentPosition().rawValue == 17)
        let reader = try SQLiteDatabase(url: url)
        #expect(try HistoryAuthority.fetchExactlyOnePositionRow(in: reader).maximumUnpinnedItems == 321)
    }

    private static func seed(at url: URL) async throws {
        let history = try await WSSupport.openHistory(storeURL: url)
        for position in 1...17 {
            _ = try await history.perform(.setRetentionPolicy(maximumUnpinnedItems: position.isMultiple(of: 2) ? 320 : 321))
        }
    }
}
