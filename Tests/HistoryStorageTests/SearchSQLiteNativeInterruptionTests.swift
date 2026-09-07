#if DEBUG
import Foundation
import HistoryCore
import SQLite3
import Testing
@testable import HistoryStorage

/// V2-09 §4: row/batch checks cannot interrupt a single long native call.
/// Exercise SQLite's actual VM and the admitted slow regexp, then verify
/// the request releases its WAL reader even when it stops inside the engine.
struct SearchSQLiteNativeInterruptionTests {
    @Test(arguments: [false, true])
    func nativeSQLiteQueryStopsAndAllowsRollback(cancel: Bool) async throws {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        let location = await history.authority.withTestDatabase { $0.storeLocation }
        let reader = NativeReader(location: location)
        // Keep cancellation inside its own task so the assertion/checkpoint
        // continues normally after the VM has observed the cancelled task.
        let task = Task { try await reader.interruptNativeQuery(history: history, cancel: cancel) }
        #expect(try await task.value == SQLITE_INTERRUPT)
        #expect(try await reader.checkpointIsUnblocked())
    }

    @Test func snapshotDeadlineCapsTheNativeRegexpMatcher() async throws {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        _ = try await history.perform(.capture(WSSupport.textCapture(
            String(repeating: "a", count: 1_000), observedAt: Date(timeIntervalSinceReferenceDate: 10)
        )))
        let location = await history.authority.withTestDatabase { $0.storeLocation }
        let worker = SearchWorker()
        await worker.setRegexpEngineDeadline(.seconds(60))
        await worker.setSnapshotLifetime(.milliseconds(100))
        let started = ContinuousClock().now
        await #expect(throws: HistoryFailure.temporarilyUnavailable(.searchEngineDeadline)) {
            _ = try await worker.page(
                HistoryBrowseRequest(
                    kind: .search(text: "a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*b", mode: .regexp), limit: 1
                ), store: location, processMarker: UUID()
            )
        }
        #expect(ContinuousClock().now - started < .seconds(5))
        #expect(try await NativeReader(location: location).checkpointIsUnblocked())
    }

    private actor NativeReader {
        let location: HistoryStoreLocation
        init(location: HistoryStoreLocation) { self.location = location }

        func interruptNativeQuery(history: SQLiteHistory, cancel: Bool) async throws -> Int32 {
            let database = try SQLiteDatabase(url: location.databaseURL, readOnly: true)
            defer { try? database.close() }
            try database.execute("BEGIN DEFERRED")
            defer { try? database.execute("ROLLBACK") }
            // Establish a real snapshot before the Authority appends WAL
            // frames, making the subsequent checkpoint a reader-lifetime proof.
            try database.execute("SELECT changePosition FROM history_state")
            _ = try await history.perform(.capture(WSSupport.textCapture(
                "write while native reader is alive", observedAt: Date(timeIntervalSinceReferenceDate: 20)
            )))
            let deadline = ContinuousClock().now.advanced(by: cancel ? .seconds(60) : .zero)
            try database.setReadInterruptionDeadline(deadline)
            defer { try? database.setReadInterruptionDeadline(nil) }
            if cancel { withUnsafeCurrentTask { $0?.cancel() } }
            do {
                // One sqlite3_step produces the aggregate. No Swift row-loop
                // cancellation check can account for the interrupted result.
                try database.execute("""
                    WITH RECURSIVE numbers(value) AS (
                        SELECT 1 UNION ALL SELECT value + 1 FROM numbers WHERE value < 1000000
                    ) SELECT sum(value) FROM numbers
                    """)
                return SQLITE_DONE
            } catch let failure as SQLiteFailure {
                return failure.primaryCode
            }
        }

        func checkpointIsUnblocked() throws -> Bool {
            let database = try SQLiteDatabase(url: location.databaseURL)
            defer { try? database.close() }
            let statement = try database.prepare("PRAGMA wal_checkpoint(TRUNCATE)")
            defer { statement.finalize() }
            guard try statement.step() else { return false }
            return try statement.integer(at: 0) == 0
        }
    }
}
#endif
