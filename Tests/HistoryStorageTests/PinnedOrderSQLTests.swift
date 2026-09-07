import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

/// Actual persisted constraints and constant-size order validation. A bad
/// ordinal is never manufactured by bypassing the UNIQUE index.
struct PinnedOrderSQLTests {
    @Test func duplicateOrdinalIsRejectedAtTheActualSQLiteWrite() async throws {
        let history = try await WSSupport.makeHistory()
        let first = try await capture("pin unique first", in: history)
        let second = try await capture("pin unique second", in: history)
        _ = try await history.perform(.placePinned(first.id, at: .last))
        _ = try await history.perform(.placePinned(second.id, at: .last))
        let before = try await history.usage()
        try await history.authority.withTestDatabase { authority in
            do {
                try authority.database.execute(
                    "UPDATE history_items SET pinOrdinal = 0 WHERE id = ?",
                    bindings: [.text(second.id.rawValue.uuidString)]
                )
                Issue.record("The UNIQUE pin index accepted duplicate ordinal zero")
            } catch let failure as SQLiteFailure {
                #expect(failure.isConstraint)
            }
            let order = try authority.database.prepare(
                "SELECT id, pinOrdinal FROM history_items WHERE pinOrdinal IS NOT NULL ORDER BY pinOrdinal"
            )
            #expect(try order.step())
            #expect(try order.text(at: 0) == first.id.rawValue.uuidString)
            #expect(try order.integer(at: 1) == 0)
            #expect(try order.step())
            #expect(try order.text(at: 0) == second.id.rawValue.uuidString)
            #expect(try order.integer(at: 1) == 1)
            #expect(try !order.step())
        }
        #expect(try await history.usage() == before)
    }

    @Test func negativeOrdinalIsRejectedAtTheActualSQLiteWrite() async throws {
        let history = try await WSSupport.makeHistory()
        let item = try await capture("pin negative ordinal", in: history)
        _ = try await history.perform(.placePinned(item.id, at: .last))
        try await history.authority.withTestDatabase { authority in
            do {
                try authority.database.execute(
                    "UPDATE history_items SET pinOrdinal = -1 WHERE id = ?",
                    bindings: [.text(item.id.rawValue.uuidString)]
                )
                Issue.record("The pin ordinal CHECK accepted a negative value")
            } catch let failure as SQLiteFailure {
                #expect(failure.isConstraint)
            }
        }
        let page = try await history.browse(.init(kind: .recent, limit: 1))
        #expect(page.rows.first?.pinnedPosition == 0)
    }

    @Test func nonUniqueExistingPinIndexIsRejectedWithoutRepairingStore() async throws {
        let url = WSSupport.tempStoreURL("pin-nonunique-index")
        defer { WSSupport.removeStore(url) }
        try await seedNonUniqueIndex(at: url)
        let before = try TransactionStoreSnapshot.read(from: url)
        await #expect(throws: HistoryFailure.persistence(.openStore)) {
            try await SQLiteHistory.open(configuration: .init(persistence: .persistent(storeURL: url)))
        }
        #expect(try TransactionStoreSnapshot.read(from: url) == before)
        let database = try SQLiteDatabase(url: url, readOnly: true)
        let index = try database.prepare("""
            SELECT "unique", partial FROM pragma_index_list('history_items')
            WHERE name = 'history_items_pinned_order'
            """)
        #expect(try index.step())
        #expect(try index.integer(at: 0) == 0)
        #expect(try index.integer(at: 1) == 1)
        #expect(try !index.step())
    }

    @Test(arguments: [Int64(1), Int64.max])
    func storedGapIsRejectedWithoutRepairingOrOverflowing(_ invalidOrdinal: Int64) async throws {
        let history = try await WSSupport.makeHistory()
        let item = try await capture("pin gap", in: history)
        _ = try await history.perform(.placePinned(item.id, at: .last))
        let before = try await history.usage()
        // This remains UNIQUE and nonnegative. Only the dense-order
        // invariant is damaged, so validation must reject it explicitly.
        try await history.authority.withTestDatabase { authority in
            try authority.database.execute(
                "UPDATE history_items SET pinOrdinal = ? WHERE id = ?",
                bindings: [.integer(invalidOrdinal), .text(item.id.rawValue.uuidString)]
            )
        }
        await #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
            try await history.perform(.placePinned(item.id, at: .first))
        }
        #expect(try await history.usage() == before)
        try await history.authority.withTestDatabase { authority in
            let row = try authority.database.prepare(
                "SELECT pinOrdinal FROM history_items WHERE id = ?",
                bindings: [.text(item.id.rawValue.uuidString)]
            )
            #expect(try row.step())
            #expect(try row.integer(at: 0) == invalidOrdinal)
        }
    }

    @Test func realOrdinalInsideValidEndpointsIsRejectedWithoutRepair() async throws {
        let history = try await WSSupport.makeHistory()
        var items: [HistoryItemReference] = []
        for index in 0..<4 {
            let item = try await capture("real ordinal \(index)", in: history)
            items.append(item)
            _ = try await history.perform(.placePinned(item.id, at: .last))
        }
        let before = try await history.usage()
        let damaged = items[1]
        let target = items[0]
        try await history.authority.withTestDatabase { authority in
            try authority.database.execute(
                "UPDATE history_items SET pinOrdinal = ? WHERE id = ?",
                bindings: [.real(1.5), .text(damaged.id.rawValue.uuidString)]
            )
            let range = try authority.database.prepare("""
                SELECT count(*),count(DISTINCT pinOrdinal),min(pinOrdinal),max(pinOrdinal)
                FROM history_items WHERE pinOrdinal IS NOT NULL
                """)
            #expect(try range.step())
            // All of these pass for 0, 1.5, 2, 3. The integer storage-class
            // check is necessary; uniqueness plus endpoints is insufficient.
            #expect(try range.integer(at: 0) == 4 && range.integer(at: 1) == 4)
            #expect(try range.integer(at: 2) == 0 && range.integer(at: 3) == 3)
        }
        await #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
            try await history.perform(.placePinned(target.id, at: .last))
        }
        #expect(try await history.usage() == before)
        try await history.authority.withTestDatabase { authority in
            let value = try authority.database.prepare(
                "SELECT pinOrdinal FROM history_items WHERE id = ?",
                bindings: [.text(damaged.id.rawValue.uuidString)]
            )
            #expect(try value.step())
            #expect(try value.real(at: 0) == 1.5)
        }
    }

    private func capture(_ text: String, in history: SQLiteHistory) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(WSSupport.textCapture(
            text, observedAt: Date(timeIntervalSince1970: 1_000)
        )))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return item
    }

    private func seedNonUniqueIndex(at url: URL) async throws {
        let history = try await WSSupport.openHistory(storeURL: url)
        let first = try await capture("nonunique index first", in: history)
        let second = try await capture("nonunique index second", in: history)
        _ = try await history.perform(.placePinned(first.id, at: .last))
        _ = try await history.perform(.placePinned(second.id, at: .last))
        // This fixture changes only the index definition. It inserts no
        // duplicate ordinals and checks rejection of an unsupported store,
        // not a compatibility rebuild or silent index repair.
        try await history.authority.withTestDatabase { authority in
            try authority.database.writeTransaction {
                try authority.database.execute("DROP INDEX history_items_pinned_order")
                try authority.database.execute("""
                    CREATE INDEX history_items_pinned_order ON history_items(pinOrdinal)
                    WHERE pinOrdinal IS NOT NULL
                    """)
            }
        }
    }
}
