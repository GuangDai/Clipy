import Foundation
import HistoryCore
import SQLite3
import Testing
@testable import HistoryStorage

struct RetentionCancellationTests {
    private let policies = HistoryRetentionPolicies(
        age: nil, storage: StorageRetention(maxTotalBytes: 2_000), revisions: nil
    )

    @Test func cancellationBetweenBatchesLeavesPolicyHistoryAndJournalUntouched() async throws {
        let history = try await fixture()
        let before = try await history.usage()
        let configuration = try await history.retentionConfiguration()
        let journalCount = try await countJournal(history)
        let gate = SuspensionGate()
        await history.authority.setSuspensionHandler { point in
            if point == .retentionPlanningBatch { await gate.park(at: point.rawValue) }
        }
        let sweep = Task { try await history.perform(.setRetentionPolicies(policies)) }
        await gate.waitForPark(AuthoritySuspensionPoint.retentionPlanningBatch.rawValue)
        // This read and payload must complete while the sweep is parked:
        // planning has released both the actor and every SQLite statement.
        let page = try await history.browse(.init(kind: .recent, limit: 1))
        let item = try #require(page.rows.first?.item)
        #expect(try await history.pastePayload(for: item.id).item == item)
        sweep.cancel()
        await history.authority.setSuspensionHandler(nil)
        await gate.resume(AuthoritySuspensionPoint.retentionPlanningBatch.rawValue)
        await #expect(throws: CancellationError.self) { _ = try await sweep.value }
        #expect(try await history.usage() == before)
        #expect(try await history.retentionConfiguration() == configuration)
        #expect(try await countJournal(history) == journalCount)
        _ = try await history.perform(.setRetentionPolicies(policies))
        #expect(try await history.usage().itemCount == 31)
    }

    @Test func concurrentPinInvalidatesPreparedRetirementBeforeAnyWrite() async throws {
        let history = try await fixture()
        let originalConfiguration = try await history.retentionConfiguration()
        let page = try await history.browse(.init(kind: .recent, limit: 200))
        let oldest = try #require(page.rows.last?.item)
        let gate = SuspensionGate()
        await history.authority.setSuspensionHandler { point in
            if point == .retentionPlanningBatch { await gate.park(at: point.rawValue) }
        }
        let sweep = Task { try await history.perform(.setRetentionPolicies(policies)) }
        await gate.waitForPark(AuthoritySuspensionPoint.retentionPlanningBatch.rawValue)
        _ = try await history.perform(.placePinned(oldest.id, at: .last))
        let position = try await history.usage().position
        await history.authority.setSuspensionHandler(nil)
        await gate.resume(AuthoritySuspensionPoint.retentionPlanningBatch.rawValue)
        await #expect(throws: HistoryFailure.snapshotExpired(current: position)) { _ = try await sweep.value }
        #expect(try await history.usage().itemCount == 130)
        #expect(try await history.retentionConfiguration().policies == originalConfiguration.policies)
        _ = try await history.perform(.setRetentionPolicies(policies))
        #expect(try await history.pastePayload(for: oldest.id).item == oldest)
        #expect(try await history.usage().itemCount == 31)
    }

    @Test func sqliteCancellationInterruptsCascadingDeleteAndConnectionCanCommitAgain() async throws {
        let history = try await WSSupport.makeHistory()
        try await history.authority.withTestDatabase { authority in
            try authority.database.execute("CREATE TABLE cancellation_parent (id INTEGER PRIMARY KEY)")
            try authority.database.execute("""
                CREATE TABLE cancellation_child (
                    parent INTEGER REFERENCES cancellation_parent(id) ON DELETE CASCADE
                )
                """)
            try authority.database.execute("CREATE INDEX cancellation_child_parent ON cancellation_child(parent)")
            try authority.database.execute("""
                WITH RECURSIVE numbers(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM numbers WHERE n < 2_000)
                INSERT INTO cancellation_parent SELECT n FROM numbers
                """)
            try authority.database.execute("INSERT INTO cancellation_child SELECT id FROM cancellation_parent")
        }
        let mutation = Task {
            do {
                try await history.authority.withTestDatabase { authority in
                    try authority.database.writeTransaction(checkingCancellation: true) {
                        try authority.database.execute("INSERT INTO cancellation_parent VALUES (2001)")
                        withUnsafeCurrentTask { $0?.cancel() }
                        // No Swift cancellation checkpoint intervenes here.
                        // SQLite itself must interrupt this statement.
                        do {
                            try authority.database.execute("DELETE FROM cancellation_parent WHERE id > 0")
                            Issue.record("Cascading DELETE completed despite cancellation")
                        } catch let failure as SQLiteFailure {
                            #expect(failure.primaryCode == SQLITE_INTERRUPT)
                            throw failure
                        }
                    }
                }
            } catch is CancellationError {
                // Gateway cancellation/failure auditing uses the default
                // transaction mode and must still be writable in this task.
                try await history.authority.withTestDatabase { authority in
                    try authority.database.writeTransaction {
                        try authority.database.execute("CREATE TABLE cancellation_audit (value INTEGER)")
                        try authority.database.execute("INSERT INTO cancellation_audit VALUES (1)")
                    }
                }
                throw CancellationError()
            }
        }
        await #expect(throws: CancellationError.self) { try await mutation.value }
        try await history.authority.withTestDatabase { authority in
            let row = try authority.database.prepare("""
                SELECT (SELECT count(*) FROM cancellation_parent), (SELECT count(*) FROM cancellation_child)
                """)
            #expect(try row.step())
            #expect(try row.integer(at: 0) == 2_000)
            #expect(try row.integer(at: 1) == 2_000)
            row.finalize()
            let audit = try authority.database.prepare("SELECT value FROM cancellation_audit")
            #expect(try audit.step())
            #expect(try audit.integer(at: 0) == 1)
            audit.finalize()
            try authority.database.writeTransaction {
                try authority.database.execute("INSERT INTO cancellation_parent VALUES (2001)")
            }
        }
    }

    private func fixture() async throws -> SQLiteHistory {
        let history = try await WSSupport.makeHistory()
        _ = try await history.seedPerformanceFixture(rowCount: 130) { index in
            let prefix = "retention-\(index)-"
            return WSSupport.textCapture(
                prefix + String(repeating: "x", count: 64 - prefix.utf8.count),
                observedAt: Date(timeIntervalSinceReferenceDate: Double(index + 1))
            )
        }
        return history
    }

    private func countJournal(_ history: SQLiteHistory) async throws -> Int64 {
        try await history.authority.withTestDatabase { authority in
            let row = try authority.database.prepare("SELECT count(*) FROM history_change_records")
            defer { row.finalize() }
            #expect(try row.step())
            return try row.integer(at: 0)
        }
    }
}
