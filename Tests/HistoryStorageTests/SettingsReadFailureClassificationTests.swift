import HistoryCore
import Testing
@testable import HistoryStorage

/// Settings must diagnose a corrupt database in the same way as other reads,
/// rather than suggesting that retrying a busy History will repair it.
struct SettingsReadFailureClassificationTests {
    @Test func corruptSQLiteSchemaIsNotPresentedAsTemporaryUnavailability() async throws {
        let history = try await WSSupport.makeHistory()
        await history.authority.waitForBlobCleanup()
        try await history.authority.withTestDatabase { authority in
            // An invalid root page produces real SQLITE_CORRUPT on prepare,
            // before column decoding can throw a HistoryFailure of its own.
            try authority.database.execute("PRAGMA writable_schema = ON")
            try authority.database.execute("""
                UPDATE sqlite_schema SET rootpage=2147483647 WHERE name='history_state'
                """)
            try authority.database.execute("PRAGMA writable_schema = RESET")
        }
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.usage()
        }
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.retentionConfiguration()
        }
    }
}
