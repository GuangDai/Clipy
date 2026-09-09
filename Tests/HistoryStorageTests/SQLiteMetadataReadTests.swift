import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct SQLiteMetadataReadTests {
    @Test func scalarPageValuesKeepLiteralTextAndFullUnsignedCounters() throws {
        let database = try SQLiteDatabase(url: nil)
        let values = try Self.validValues()
        let statement = try database.prepare("SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?", bindings: values)
        defer { statement.finalize() }
        try #require(try statement.step())
        let row = try ScalarReadRow(statement, limits: .standard).toHistoryRow(limits: .standard)
        #expect(row.item.contentVersion.rawValue == UInt64.max)
        #expect(row.copyCount == UInt64.max)
        #expect(row.title.utf8.elementsEqual("\u{FEFF}literal\u{0}".utf8))
        #expect(row.typeIdentifiers == ["public.utf8-plain-text"])
        #expect(row.lastCopiedAt == Date(timeIntervalSinceReferenceDate: 4))
        #expect(row.lastSource == "com.example.source")
        #expect(row.pinnedPosition == 3)
        #expect(row.sourceCount == 2)
    }

    @Test func wrongSQLTypesAndInvalidMetadataAreRejectedWithoutCoercion() throws {
        let database = try SQLiteDatabase(url: nil)
        let corruptions: [(Int, SQLiteValue)] = [
            (0, .text("10000000-0000-0000-0000-00000000000a")),
            (1, .integer(1)), (1, .blob(Data(repeating: 1, count: 7))), (1, .blob(sqliteUInt64(0))),
            (2, .text("apparently valid title")), (2, .blob(Data([0xFF]))),
            (2, .blob(Data(repeating: 0x61, count: HistoryLimits.standard.maximumStoredTitleUTF8Bytes + 1))),
            (3, .blob(Data([0xFF]))), (3, .text("not a blob")),
            (4, .integer(4)), (4, .real(.infinity)),
            (5, .integer(1)), (5, .blob(sqliteUInt64(0))),
            (6, .blob(Data("source".utf8))),
            (6, .text(String(repeating: "s", count: HistoryLimits.standard.maximumSourceApplicationObservationUTF8Bytes + 1))),
            (7, .real(3)), (7, .integer(-1)),
            (8, .real(2)), (8, .integer(-1)), (8, .text("2")),
        ]
        for (column, value) in corruptions {
            var values = try Self.validValues()
            values[column] = value
            let statement = try database.prepare("SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?", bindings: values)
            defer { statement.finalize() }
            try #require(try statement.step())
            #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
                try ScalarReadRow(statement, limits: .standard).toHistoryRow(limits: .standard)
            }
        }
    }

    @Test func singletonReadUsesTheCallersTransactionAndPreservesUInt64Range() throws {
        let database = try SQLiteDatabase(url: nil)
        try SQLiteHistorySchema.create(in: database)
        try database.execute("""
            INSERT INTO history_state(key, changePosition, maximumUnpinnedItems)
            VALUES ('retained-history', ?, 321)
            """, bindings: [.blob(sqliteUInt64(UInt64.max))])
        let result = try database.readTransaction {
            try HistoryAuthority.decodePositionRow(
                HistoryAuthority.fetchExactlyOnePositionRow(in: database), limits: .standard
            )
        }
        #expect(result.position.rawValue == UInt64.max)
        #expect(result.retention.maximumUnpinnedItems == 321)
        try database.execute("PRAGMA ignore_check_constraints = ON")
        try database.execute("UPDATE history_state SET maximumUnpinnedItems = -1")
        #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try HistoryAuthority.decodePositionRow(
                HistoryAuthority.fetchExactlyOnePositionRow(in: database), limits: .standard
            )
        }
    }

    @Test func singletonMissingOrWrongPositionTypeFailsExplicitly() throws {
        let database = try SQLiteDatabase(url: nil)
        try SQLiteHistorySchema.create(in: database)
        #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
            try HistoryAuthority.fetchExactlyOnePositionRow(in: database)
        }
        // BLOB affinity alone does not reject an eight-character TEXT value;
        // the reader must check SQLite's storage class before decoding bytes.
        try database.execute("""
            INSERT INTO history_state(key, changePosition, maximumUnpinnedItems)
            VALUES ('retained-history', '12345678', 200)
            """)
        #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try HistoryAuthority.fetchExactlyOnePositionRow(in: database)
        }
    }

    private static func validValues() throws -> [SQLiteValue] {
        [
            .text("10000000-0000-0000-0000-00000000000A"), .blob(sqliteUInt64(UInt64.max)),
            .blob(Data("\u{FEFF}literal\u{0}".utf8)),
            .blob(try EffectiveTypeIdentifiersBlobCodec.encode(["public.utf8-plain-text"])),
            .real(4), .blob(sqliteUInt64(UInt64.max)), .text("com.example.source"), .integer(3), .integer(2),
        ]
    }
}
