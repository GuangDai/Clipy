/// An old model-table store is rejected without changing its contents.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct SchemaSmokeTests {
    @Test func previousModelStoreIsRejectedWithoutDeletingOrRecreatingIt() async throws {
        let url = WSSupport.tempStoreURL("sqlite-reject-previous-store")
        defer { WSSupport.removeStore(url) }
        do {
            let database = try SQLiteDatabase(url: url)
            try database.execute("CREATE TABLE Z_METADATA (payload BLOB)")
            try database.execute("INSERT INTO Z_METADATA VALUES (?)", bindings: [.blob(Data([0x01, 0x02]))])
        }
        await #expect(throws: HistoryFailure.persistence(.openStore)) {
            try await WSSupport.openHistory(storeURL: url)
        }
        let reader = try SQLiteDatabase(url: url)
        let original = try reader.prepare("SELECT payload FROM Z_METADATA")
        defer { original.finalize() }
        try #require(try original.step())
        #expect(try original.blob(at: 0) == Data([0x01, 0x02]))
        let current = try reader.prepare("SELECT count(*) FROM sqlite_master WHERE name = 'history_items'")
        defer { current.finalize() }
        try #require(try current.step())
        #expect(try current.integer(at: 0) == 0)
    }
}
