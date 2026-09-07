import Foundation
import HistoryCore
import SQLite3
import Testing
@testable import HistoryStorage

/// Real SQLite exercises the storage primitive: byte fidelity, durability,
/// transaction failure and snapshot isolation, without a fake SQL writer.
struct SQLiteDatabaseTests {
    @Test func bindingsPreserveEmptyValuesNULAndLeadingBOM() throws {
        let database = try SQLiteDatabase(url: nil)
        try database.execute("CREATE TABLE values_test (n, i, r, t, b, e, z)")
        let original = Data([0, 255, 128, 0, 17])
        let text = "\u{FEFF}前\0后🦋"
        try database.execute(
            "INSERT INTO values_test VALUES (?, ?, ?, ?, ?, ?, ?)",
            bindings: [
                .null, .integer(Int64.min), .real(1.25), .text(text),
                .blob(original), .blob(Data()), .text(""),
            ]
        )
        let result = try database.prepare("SELECT * FROM values_test")
        #expect(try result.step())
        #expect(try result.isNull(at: 0))
        #expect(try result.integer(at: 1) == Int64.min)
        #expect(try result.real(at: 2) == 1.25)
        #expect(try result.textByteCount(at: 3) == text.utf8.count)
        #expect(try result.text(at: 3).utf8.elementsEqual(text.utf8))
        #expect(try result.blobByteCount(at: 4) == original.count)
        #expect(try result.blob(at: 4) == original)
        #expect(try result.blob(at: 5).isEmpty)
        #expect(try !result.isNull(at: 5))
        #expect(try result.text(at: 6).isEmpty)
        #expect(try !result.isNull(at: 6))
        #expect(try !result.step())
        #expect(try !result.step()) // SQLITE_DONE must not rerun the statement.
    }

    @Test func boundDataIsCopiedBeforeItsOwnerChanges() throws {
        let database = try SQLiteDatabase(url: nil)
        var source = Data(repeating: 0xAB, count: 100_000)
        let statement = try database.prepare("SELECT ?", bindings: [.blob(source)])
        source.resetBytes(in: 0..<source.count)
        source.removeAll()
        #expect(try statement.step())
        #expect(try statement.blob(at: 0) == Data(repeating: 0xAB, count: 100_000))
    }

    @Test func strictColumnReadsRejectCoercionAndMalformedUTF8() throws {
        let database = try SQLiteDatabase(url: nil)
        let row = try database.prepare("SELECT 12, '12', NULL, CAST(x'FF' AS TEXT)")
        #expect(try row.step())
        #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try row.text(at: 0)
        }
        #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try row.integer(at: 1)
        }
        #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try row.blob(at: 2)
        }
        #expect(try row.optionalText(at: 2) == nil)
        #expect(try row.optionalBlob(at: 2) == nil)
        #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try row.text(at: 3)
        }
    }

    @Test func unsignedTokensRoundTripAndSortAcrossSignedMaximum() throws {
        let database = try SQLiteDatabase(url: nil)
        try database.execute("CREATE TABLE tokens (value BLOB PRIMARY KEY)")
        let values: [UInt64] = [UInt64.max, 0, UInt64(Int64.max) + 1, 1, UInt64(Int64.max)]
        for value in values {
            try database.execute("INSERT INTO tokens VALUES (?)", bindings: [.blob(sqliteUInt64(value))])
        }
        let statement = try database.prepare("SELECT value FROM tokens ORDER BY value")
        var actual: [UInt64] = []
        while try statement.step() { actual.append(try sqliteUInt64(statement.blob(at: 0))) }
        #expect(actual == values.sorted())
        #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try sqliteUInt64(Data(repeating: 0, count: 7))
        }
    }

    @Test func thrownMutationRollsBackAndConnectionCanCommitAgain() throws {
        let database = try SQLiteDatabase(url: nil)
        try database.execute("CREATE TABLE items (value INTEGER NOT NULL)")
        #expect(throws: FixtureError.abort) {
            try database.writeTransaction {
                try database.execute("INSERT INTO items VALUES (1)")
                throw FixtureError.abort
            }
        }
        try database.writeTransaction {
            try database.execute("INSERT INTO items VALUES (2)")
        }
        let statement = try database.prepare("SELECT value FROM items")
        #expect(try statement.step())
        #expect(try statement.integer(at: 0) == 2)
        #expect(try !statement.step())
    }

    @Test func deferredConstraintCommitFailureRollsBackEverything() throws {
        let database = try SQLiteDatabase(url: nil)
        try database.execute("CREATE TABLE parents (id INTEGER PRIMARY KEY)")
        try database.execute("""
            CREATE TABLE children (
                parent INTEGER REFERENCES parents(id) DEFERRABLE INITIALLY DEFERRED
            )
            """)
        do {
            try database.writeTransaction {
                try database.execute("INSERT INTO parents VALUES (1)")
                try database.execute("INSERT INTO children VALUES (2)")
            }
            Issue.record("Expected foreign-key failure at COMMIT")
        } catch let failure as SQLiteFailure {
            #expect(failure.isConstraint)
            #expect(failure.code == (SQLITE_CONSTRAINT | (3 << 8)))
        }
        let count = try database.prepare("SELECT count(*) FROM parents")
        #expect(try count.step())
        #expect(try count.integer(at: 0) == 0)
        count.finalize()
        try database.writeTransaction {
            try database.execute("INSERT INTO parents VALUES (2)")
            try database.execute("INSERT INTO children VALUES (2)")
        }
    }

    @Test func persistentCommitSurvivesCloseAndReopen() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        let database = try SQLiteDatabase(url: url)
        try database.execute("CREATE TABLE payloads (value BLOB NOT NULL)")
        let bytes = Data(repeating: 0xEC, count: 200_000)
        try database.writeTransaction {
            try database.execute("INSERT INTO payloads VALUES (?)", bindings: [.blob(bytes)])
        }
        try database.close()
        let reopened = try SQLiteDatabase(url: url)
        let statement = try reopened.prepare("SELECT value FROM payloads")
        #expect(try statement.step())
        #expect(try statement.blob(at: 0) == bytes)
        statement.finalize()
        try reopened.close()
    }

    @Test func WALReaderKeepsOneSnapshotWhileWriterCommits() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        let writer = try SQLiteDatabase(url: url)
        try writer.execute("CREATE TABLE items (value INTEGER)")
        try writer.execute("INSERT INTO items VALUES (1)")
        let reader = try SQLiteDatabase(url: url)
        try reader.readTransaction {
            #expect(try countItems(reader) == 1)
            try writer.writeTransaction { try writer.execute("INSERT INTO items VALUES (2)") }
            #expect(try countItems(reader) == 1)
        }
        #expect(try countItems(reader) == 2)
        try reader.close()
        try writer.close()
    }

    @Test(arguments: [false, true])
    func openingWaitDoesNotChangeNormalConnectionContention(readOnly: Bool) throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        let initial = try SQLiteDatabase(url: url)
        try initial.execute("CREATE TABLE items (value INTEGER)")
        try initial.close()
        let reopened = try SQLiteDatabase(url: url, readOnly: readOnly)
        let timeout = try reopened.prepare("PRAGMA busy_timeout")
        #expect(try timeout.step())
        #expect(try timeout.integer(at: 0) == 0)
        timeout.finalize()
        try reopened.close()
    }

    @Test func competingWriterReportsBusyWithoutLosingFirstTransaction() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        let first = try SQLiteDatabase(url: url)
        try first.execute("CREATE TABLE items (value INTEGER)")
        let second = try SQLiteDatabase(url: url)
        try first.writeTransaction {
            try first.execute("INSERT INTO items VALUES (1)")
            do {
                try second.writeTransaction { try second.execute("INSERT INTO items VALUES (2)") }
                Issue.record("Expected a busy writer")
            } catch let failure as SQLiteFailure {
                #expect(failure.primaryCode == SQLITE_BUSY)
                #expect(failure.historyFailure == .persistence(.transaction))
            }
        }
        #expect(try countItems(second) == 1)
        try second.close()
        try first.close()
    }

    @Test func diskFullRollsBackAndRetainsPreviouslyCommittedContent() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLiteDatabase(url: directory.appendingPathComponent("history.sqlite"))
        try database.execute("CREATE TABLE items (value BLOB)")
        try database.execute("INSERT INTO items VALUES (x'1234')")
        try database.execute("PRAGMA max_page_count = 8")
        do {
            try database.writeTransaction {
                try database.execute("INSERT INTO items VALUES (?)", bindings: [.blob(Data(repeating: 7, count: 1_000_000))])
            }
            Issue.record("Expected SQLite's page limit to fail the write")
        } catch let failure as SQLiteFailure {
            #expect(failure.primaryCode == SQLITE_FULL)
            #expect(failure.historyFailure == .temporarilyUnavailable(.insufficientDiskSpace))
        }
        let row = try database.prepare("SELECT value FROM items")
        #expect(try row.step())
        #expect(try row.blob(at: 0) == Data([0x12, 0x34]))
        #expect(try !row.step())
        row.finalize()
        try database.close()
    }

    @Test func closedAndFinalizedHandlesFailWithoutDereferencingFreedMemory() throws {
        let database = try SQLiteDatabase(url: nil)
        let row = try database.prepare("SELECT 1")
        #expect(throws: SQLiteFailure(code: SQLITE_MISUSE)) { try row.integer(at: 0) }
        #expect(try row.step())
        #expect(throws: SQLiteFailure(code: SQLITE_BUSY)) { try database.close() }
        #expect(try row.integer(at: 0) == 1)
        row.finalize()
        #expect(throws: SQLiteFailure(code: SQLITE_MISUSE)) { try row.step() }
        try database.close()
        try database.close()
        #expect(throws: SQLiteFailure(code: SQLITE_MISUSE)) { try database.execute("SELECT 1") }
    }

    @Test func corruptDatabaseBytesAreNotAcceptedAsAnEmptyStore() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        try Data(repeating: 0x78, count: 8192).write(to: url)
        #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try SQLiteDatabase(url: url)
        }
    }

    private enum FixtureError: Error { case abort }

    private func countItems(_ database: SQLiteDatabase) throws -> Int64 {
        let statement = try database.prepare("SELECT count(*) FROM items")
        defer { statement.finalize() }
        guard try statement.step() else { throw FixtureError.abort }
        return try statement.integer(at: 0)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipy-sqlite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
