import Foundation
import HistoryCore
import SQLite3
import Testing
@testable import HistoryStorage

/// Settings must diagnose a corrupt database in the same way as other reads,
/// rather than suggesting that retrying a busy History will repair it.
struct SettingsReadFailureClassificationTests {
    @Test func corruptSQLitePageIsNotPresentedAsTemporaryUnavailability() async throws {
        let history = try await WSSupport.makeHistory()
        await history.authority.waitForBlobCleanup()
        guard let location = await history.authority.corruptSettingsRootPageForTest() else { return }
        let reader: HistoryAuthority
        do {
            // The original writer is closed. A new real Authority ensures
            // no cached B-tree page can hide the on-disk corruption. Do not
            // rerun startup: the two Settings reads own this failure test.
            reader = try HistoryAuthority(storeLocation: location)
        } catch {
            Issue.record(error, "Opening the fresh Settings reader before the corrupted table is queried")
            return
        }
        guard await reader.settingsRootPageReadFailsWithSQLiteCorruptForTest() else { return }
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await reader.usage()
        }
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await reader.retentionConfiguration()
        }
    }
}

private extension HistoryAuthority {
    func settingsRootPageReadFailsWithSQLiteCorruptForTest() -> Bool {
        do {
            // A non-indexed column forces the damaged table page to be read.
            try database.execute("SELECT canonicalBytes FROM history_state LIMIT 2")
            Issue.record("Corruption fixture unexpectedly allowed a raw SQLite table read")
            return false
        } catch let failure as SQLiteFailure {
            #expect(failure.primaryCode == SQLITE_CORRUPT, "Raw SQLite read must report actual page corruption")
            return failure.primaryCode == SQLITE_CORRUPT
        } catch {
            Issue.record(error, "Verifying the raw SQLite corruption before Settings failure translation")
            return false
        }
    }

    /// Mutate only this disposable store's actual table page, without relying
    /// on writable_schema, which the system SQLite may forbid. No database
    /// configuration or production corruption checks are weakened.
    func corruptSettingsRootPageForTest() -> HistoryStoreLocation? {
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

            phase = "closing the original SQLite connection and its cached pages"
            try database.close()

            phase = "writing an invalid B-tree page type to the disposable store"
            let offset = UInt64(page - 1).multipliedReportingOverflow(by: UInt64(pageSize))
            try #require(!offset.overflow)
            let file = try FileHandle(forUpdating: storeLocation.databaseURL)
            defer { try? file.close() }
            try #require(try file.seekToEnd() > offset.partialValue)
            try file.seek(toOffset: offset.partialValue)
            let original = try #require(try file.read(upToCount: 1)?.first)
            try #require([UInt8(2), 5, 10, 13].contains(original))
            try file.seek(toOffset: offset.partialValue)
            // SQLite B-tree pages admit only types 2, 5, 10 and 13. This
            // fails in SQLite's pager/B-tree read before History row decoding.
            try file.write(contentsOf: Data([0xFF]))
            try file.synchronize()
            phase = "reading back the corrupted B-tree page byte"
            try file.seek(toOffset: offset.partialValue)
            try #require(try file.read(upToCount: 1) == Data([0xFF]))
            try file.close()
            return storeLocation
        } catch {
            Issue.record(error, "Settings corruption fixture failed while \(phase)")
            return nil
        }
    }
}
