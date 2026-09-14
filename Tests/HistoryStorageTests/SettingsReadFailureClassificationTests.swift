import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

/// Settings must diagnose a corrupt database in the same way as other reads,
/// rather than suggesting that retrying a busy History will repair it.
struct SettingsReadFailureClassificationTests {
    @Test func corruptSQLitePageIsNotPresentedAsTemporaryUnavailability() async throws {
        let history = try await WSSupport.makeHistory()
        await history.authority.waitForBlobCleanup()
        guard await history.authority.corruptSettingsRootPageForTest() else { return }
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.usage()
        }
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.retentionConfiguration()
        }
    }
}

private extension HistoryAuthority {
    /// Mutate only this disposable store's actual table page, without relying
    /// on writable_schema, which the system SQLite may forbid. No database
    /// configuration or production corruption checks are weakened.
    func corruptSettingsRootPageForTest() -> Bool {
        var phase = "locating the history_state root page"
        do {
            let root = try database.prepare("SELECT rootpage FROM sqlite_schema WHERE name='history_state'")
            defer { root.finalize() }
            try #require(try root.step())
            let page = try root.integer(at: 0)
            try #require(page > 1)
            root.finalize()

            phase = "reading the SQLite page size"
            let size = try database.prepare("PRAGMA page_size")
            defer { size.finalize() }
            try #require(try size.step())
            let pageSize = try size.integer(at: 0)
            try #require(pageSize >= 512)
            size.finalize()

            phase = "checkpointing WAL before the physical corruption"
            let checkpoint = try database.prepare("PRAGMA wal_checkpoint(TRUNCATE)")
            defer { checkpoint.finalize() }
            try #require(try checkpoint.step())
            try #require(try checkpoint.integer(at: 0) == 0)
            try #require(try checkpoint.integer(at: 1) == 0)
            checkpoint.finalize()

            phase = "releasing cached SQLite pages"
            try database.execute("PRAGMA shrink_memory")

            phase = "writing an invalid B-tree page type to the disposable store"
            let offset = UInt64(page - 1).multipliedReportingOverflow(by: UInt64(pageSize))
            try #require(!offset.overflow)
            let file = try FileHandle(forWritingTo: storeLocation.databaseURL)
            defer { try? file.close() }
            try #require(try file.seekToEnd() > offset.partialValue)
            try file.seek(toOffset: offset.partialValue)
            // SQLite B-tree pages admit only types 2, 5, 10 and 13. This
            // fails in SQLite's pager/B-tree read before History row decoding.
            try file.write(contentsOf: Data([0xFF]))
            try file.synchronize()
            try file.close()
            return true
        } catch {
            Issue.record(error, "Settings corruption fixture failed while \(phase)")
            return false
        }
    }
}
