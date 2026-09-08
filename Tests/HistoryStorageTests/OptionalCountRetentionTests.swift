import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

/// V2-09 §9: nil is a durable disabled count policy, while explicit count
/// changes still retire oldest unpinned items in one atomic History commit.
struct OptionalCountRetentionTests {
    @Test func oldNonnullableCountLayoutIsRejectedWithoutChangingItsStoredValue() async throws {
        let url = WSSupport.tempStoreURL("optional-count-old-layout")
        defer { WSSupport.removeStore(url) }
        do {
            let database = try SQLiteDatabase(url: url)
            try database.writeTransaction {
                try SQLiteHistorySchema.create(in: database)
                try database.execute("DROP TABLE history_state")
                try database.execute("""
                    CREATE TABLE history_state (
                        key TEXT PRIMARY KEY NOT NULL CHECK (key = 'retained-history'),
                        changePosition BLOB NOT NULL CHECK (length(changePosition) = 8),
                        maximumUnpinnedItems INTEGER NOT NULL CHECK (maximumUnpinnedItems > 0),
                        retainedItemCount INTEGER NOT NULL DEFAULT 0 CHECK (retainedItemCount >= 0),
                        pinnedItemCount INTEGER NOT NULL DEFAULT 0 CHECK (pinnedItemCount >= 0),
                        canonicalBytes INTEGER NOT NULL DEFAULT 0 CHECK (canonicalBytes >= 0),
                        revisionBytes INTEGER NOT NULL DEFAULT 0 CHECK (revisionBytes >= 0)
                    )
                    """)
                try database.execute("""
                    INSERT INTO history_state(key, changePosition, maximumUnpinnedItems)
                    VALUES ('retained-history', ?, 321)
                    """, bindings: [.blob(sqliteUInt64(17))])
            }
        }
        await #expect(throws: HistoryFailure.persistence(.openStore)) {
            try await SQLiteHistory.open(configuration: .init(
                persistence: .persistent(storeURL: url), initialMaximumUnpinnedItems: nil
            ))
        }
        let database = try SQLiteDatabase(url: url)
        let row = try database.prepare("""
            SELECT changePosition, maximumUnpinnedItems,
                (SELECT "notnull" FROM pragma_table_info('history_state') WHERE name='maximumUnpinnedItems'),
                (SELECT count(*) FROM retention_policies)
            FROM history_state
            """)
        defer { row.finalize() }
        #expect(try row.step())
        #expect(try sqliteUInt64(row.blob(at: 0)) == 17)
        #expect(try row.integer(at: 1) == 321)
        #expect(try row.integer(at: 2) == 1)
        #expect(try row.integer(at: 3) == 0)
    }

    @Test func disablingReopensAsNilAndReapplyingDoesNotAdvancePosition() async throws {
        let url = WSSupport.tempStoreURL("optional-count-reopen")
        defer { WSSupport.removeStore(url) }
        let before = try await Self.seedDisabledPolicy(at: url)
        let history = try await SQLiteHistory.open(configuration: .init(
            persistence: .persistent(storeURL: url), initialMaximumUnpinnedItems: 1
        ))
        #expect(try await history.retentionConfiguration().maximumUnpinnedItems == nil)
        #expect(try await history.usage().position == before)
        let receipt = try await history.perform(.setRetentionPolicy(maximumUnpinnedItems: nil))
        guard case .unchanged = receipt else {
            Issue.record("Reapplying disabled count retention must be unchanged")
            return
        }
        #expect(try await history.usage().position == before)
        // Reopen's supplied count is only a fresh-store default; it must not
        // silently enable the persisted disabled policy and retire this row.
        _ = try await history.perform(.capture(Self.capture("second", at: 2)))
        #expect(try await history.usage().itemCount == 2)
    }

    @Test func enablingCountFromNilRollsBackTogetherThenRetiresOnlyOldestUnpinned() async throws {
        let url = WSSupport.tempStoreURL("optional-count-atomic")
        defer { WSSupport.removeStore(url) }
        let history = try await SQLiteHistory.open(configuration: .init(
            persistence: .persistent(storeURL: url), initialMaximumUnpinnedItems: nil
        ))
        for (index, text) in ["oldest pinned", "middle unpinned", "newest unpinned"].enumerated() {
            _ = try await history.perform(.capture(Self.capture(text, at: Double(index))))
        }
        let rows = try await history.browse(.init(kind: .recent, limit: 3)).rows
        let pinned = try #require(rows.last?.item.id)
        _ = try await history.perform(.placePinned(pinned, at: .last))
        let before = try TransactionStoreSnapshot.read(from: url)
        await history.authority.setTransactionFailureInjection(.beforeSingletonUpdate)
        await #expect(throws: HistoryFailure.persistence(.transaction)) {
            try await history.perform(.setRetentionPolicy(maximumUnpinnedItems: 1))
        }
        #expect(try TransactionStoreSnapshot.read(from: url) == before)
        #expect(try await history.retentionConfiguration().maximumUnpinnedItems == nil)

        let receipt = try await history.perform(.setRetentionPolicy(maximumUnpinnedItems: 1))
        guard case .committed(let commit) = receipt,
              case .retentionPolicySet(let removed) = commit.outcome else {
            Issue.record("Enabling count must commit the policy and its retirement")
            return
        }
        #expect(removed == 1)
        #expect(commit.position.rawValue == before.positions[0].rawValue + 1)
        #expect(commit.hasDestructiveRetentionEffects)
        let survivors = try await history.browse(.init(kind: .recent, limit: 3)).rows
        #expect(survivors.map(\.item.id) == [pinned, rows[0].item.id])
        #expect(try await history.retentionConfiguration().maximumUnpinnedItems == 1)
    }

    @Test func disabledCountStillHonorsByteBudgetAndPinnedProtection() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(
            persistence: .temporary, initialMaximumUnpinnedItems: nil
        ))
        _ = try await history.perform(.capture(Self.capture(String(repeating: "a", count: 16), at: 1)))
        let pinned = try #require(try await history.browse(.init(kind: .recent, limit: 1)).rows.first?.item.id)
        _ = try await history.perform(.placePinned(pinned, at: .last))
        _ = try await history.perform(.capture(Self.capture(String(repeating: "b", count: 16), at: 2)))
        _ = try await history.perform(.setRetentionPolicies(.init(
            age: nil, storage: .init(maxTotalBytes: 16), revisions: nil
        )))
        let before = try await history.usage()
        #expect(before.itemCount == 1 && before.pinnedItemCount == 1)
        #expect(try await history.retentionConfiguration().maximumUnpinnedItems == nil)
        await #expect(throws: HistoryFailure.capacityExceeded(.storageBytes)) {
            try await history.perform(.capture(Self.capture(String(repeating: "c", count: 16), at: 3)))
        }
        let after = try await history.usage()
        #expect(after.position == before.position && after.canonicalBytes == 16)
        #expect(try await history.pastePayload(for: pinned).representations.first?.bytes == Data(repeating: 0x61, count: 16))
    }

    @Test func disabledCountStillRunsAgeRetentionOnCapture() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(
            persistence: .temporary, initialMaximumUnpinnedItems: nil
        ))
        _ = try await history.perform(.setRetentionPolicies(.init(
            age: .init(maxAge: 1), storage: nil, revisions: nil
        )))
        _ = try await history.perform(.capture(Self.capture("old pinned", at: 100)))
        let pinned = try #require(try await history.browse(.init(kind: .recent, limit: 1)).rows.first?.item.id)
        _ = try await history.perform(.placePinned(pinned, at: .last))
        _ = try await history.perform(.capture(Self.capture("expired unpinned", at: 101)))
        let receipt = try await history.perform(.capture(Self.capture("new unpinned", at: 103)))
        guard case .committed(let commit) = receipt, case .inserted(let inserted) = commit.outcome else {
            Issue.record("Age retention must remain active with count disabled")
            return
        }
        #expect(commit.hasDestructiveRetentionEffects)
        let rows = try await history.browse(.init(kind: .recent, limit: 3)).rows
        #expect(rows.map(\.item.id) == [pinned, inserted.id])
        #expect(try await history.retentionConfiguration().maximumUnpinnedItems == nil)
    }

    private static func seedDisabledPolicy(at url: URL) async throws -> ChangePosition {
        let history = try await SQLiteHistory.open(configuration: .init(
            persistence: .persistent(storeURL: url), initialMaximumUnpinnedItems: 1
        ))
        _ = try await history.perform(.capture(capture("first", at: 1)))
        let receipt = try await history.perform(.setRetentionPolicy(maximumUnpinnedItems: nil))
        guard case .committed(let commit) = receipt else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        guard case .retentionPolicySet(let removed) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        #expect(removed == 0)
        #expect(!commit.hasDestructiveRetentionEffects)
        return commit.position
    }

    private static func capture(_ text: String, at time: Double) -> ClipboardCapture {
        WSSupport.textCapture(text, observedAt: Date(timeIntervalSinceReferenceDate: time))
    }
}
