import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct SQLiteHistorySchemaTests {
    private let firstItem = "00000000-0000-0000-0000-000000000001"
    private let secondItem = "00000000-0000-0000-0000-000000000002"
    private let firstCanonical = "00000000-0000-0000-0000-000000000011"
    private let firstActive = "00000000-0000-0000-0000-000000000012"
    private let secondCanonical = "00000000-0000-0000-0000-000000000021"
    private let secondActive = "00000000-0000-0000-0000-000000000022"

    private func makeDatabase() throws -> SQLiteDatabase {
        let database = try SQLiteDatabase(url: nil)
        try database.writeTransaction { try SQLiteHistorySchema.create(in: database) }
        return database
    }

    private func insertItem(
        _ id: String, current: String, title: Data = Data("title".utf8),
        in database: SQLiteDatabase
    ) throws {
        try database.execute("""
            INSERT INTO history_items (
                id, contentVersion, currentContentID, titleUTF8, searchBodyUTF8,
                effectiveTypeIdentifiersBlob, firstCopiedAt, lastCopiedAt, copyCount,
                canonicalBytes, revisionCount, revisionBytes
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 1, 1)
            """, bindings: [
                .text(id), .blob(sqliteUInt64(2)), .text(current), .blob(title),
                .blob(title), .blob(Data()), .real(1), .real(2), .blob(sqliteUInt64(1)),
            ])
    }

    private func insertContent(
        _ id: String, item: String, ordinal: Int64, bytes: Data,
        exactType: String, fingerprint: UInt64?, in database: SQLiteDatabase
    ) throws {
        try database.execute("""
            INSERT INTO contents
                (id, itemID, revisionOrdinal, createdAt, titleUTF8, contentByteCount, representationCount)
            VALUES (?, ?, ?, ?, ?, ?, 1)
            """, bindings: [
                .text(id), .text(item), .integer(ordinal), .real(Double(ordinal + 1)),
                .blob(bytes), .integer(Int64(bytes.count)),
            ])
        try database.execute("""
            INSERT INTO representations
                (contentID, ordinal, exactType, typeKey, byteCount, fingerprint, inlineBytes, blobID)
            VALUES (?, 0, ?, ?, ?, ?, ?, NULL)
            """, bindings: [
                .text(id), .text(exactType), .text(exactType.precomposedStringWithCanonicalMapping),
                .integer(Int64(bytes.count)), fingerprint.map { .blob(sqliteUInt64($0)) } ?? .null,
                .blob(bytes),
            ])
    }

    private func integer(_ sql: String, in database: SQLiteDatabase) throws -> Int64 {
        let statement = try database.prepare(sql)
        defer { statement.finalize() }
        #expect(try statement.step())
        return try statement.integer(at: 0)
    }

    @Test func canonicalCandidatesStaySeparateFromCurrentContentAndPreserveExactSpelling() throws {
        let database = try makeDatabase()
        let exactType = "com.example.e\u{301}"
        let title = Data([0xEF, 0xBB, 0xBF, 0x00, 0x41])
        try database.writeTransaction {
            try insertItem(firstItem, current: firstActive, title: title, in: database)
            try insertContent(firstCanonical, item: firstItem, ordinal: 0, bytes: Data([0x61]),
                              exactType: exactType, fingerprint: 7, in: database)
            try insertContent(firstActive, item: firstItem, ordinal: 1, bytes: Data([0x62]),
                              exactType: exactType, fingerprint: nil, in: database)
            try insertItem(secondItem, current: secondActive, in: database)
            try insertContent(secondCanonical, item: secondItem, ordinal: 0, bytes: Data([0x7A]),
                              exactType: exactType, fingerprint: 9, in: database)
            try insertContent(secondActive, item: secondItem, ordinal: 1, bytes: Data([0x61]),
                              exactType: exactType, fingerprint: nil, in: database)
        }
        // Reopen's schema recognition must neither rebuild nor replace rows.
        try database.writeTransaction { try SQLiteHistorySchema.create(in: database) }
        let candidates = try database.prepare("""
            SELECT c.itemID, r.exactType FROM representations r
            JOIN contents c ON c.id = r.contentID
            WHERE c.revisionOrdinal = 0 AND r.typeKey = ? AND r.byteCount = 1 AND r.fingerprint = ?
            ORDER BY c.itemID
            """, bindings: [.text("com.example.é"), .blob(sqliteUInt64(7))])
        defer { candidates.finalize() }
        #expect(try candidates.step())
        #expect(try candidates.text(at: 0) == firstItem)
        #expect(try candidates.text(at: 1).utf8.elementsEqual(exactType.utf8))
        #expect(try !candidates.step())
        candidates.finalize()

        let current = try database.prepare("""
            SELECT i.titleUTF8, r.inlineBytes FROM history_items i
            JOIN representations r ON r.contentID = i.currentContentID
            WHERE i.id = ?
            """, bindings: [.text(firstItem)])
        defer { current.finalize() }
        #expect(try current.step())
        #expect(try current.blob(at: 0) == title)
        #expect(try current.blob(at: 1) == Data([0x62]))
        current.finalize()

        try database.writeTransaction {
            try database.execute("DELETE FROM history_items WHERE id = ?", bindings: [.text(firstItem)])
        }
        #expect(try integer("SELECT count(*) FROM contents", in: database) == 2)
        #expect(try integer("SELECT count(*) FROM representations", in: database) == 2)
    }

    @Test func payloadLocationAndNormalizedTypeUniquenessRejectAmbiguousRepresentations() throws {
        let database = try makeDatabase()
        try database.writeTransaction {
            try insertItem(firstItem, current: firstCanonical, in: database)
            try insertContent(firstCanonical, item: firstItem, ordinal: 0, bytes: Data([0x61]),
                              exactType: "com.example.e\u{301}", fingerprint: 7, in: database)
        }
        let insert = """
            INSERT INTO representations
                (contentID, ordinal, exactType, typeKey, byteCount, inlineBytes, blobID)
            VALUES (?, 1, ?, ?, 1, ?, ?)
            """
        // Neither both locations nor neither location can describe a payload.
        let invalidLocations: [[SQLiteValue]] = [
            [.blob(Data([0x62])), .text(secondCanonical)], [.null, .null],
        ]
        for locations in invalidLocations {
            #expect(throws: SQLiteFailure.self) {
                try database.writeTransaction {
                    try database.execute(insert, bindings: [
                        .text(firstCanonical), .text("public.html"), .text("public.html"),
                    ] + locations)
                }
            }
        }
        #expect(throws: SQLiteFailure.self) {
            try database.writeTransaction {
                try database.execute(insert, bindings: [
                    .text(firstCanonical), .text("com.example.é"), .text("com.example.é"),
                    .blob(Data([0x62])), .null,
                ])
            }
        }
        #expect(try integer("SELECT count(*) FROM representations", in: database) == 1)
    }

    @Test func missingCurrentContentRejectsTheWholeTransaction() throws {
        let database = try makeDatabase()
        #expect(throws: SQLiteFailure.self) {
            try database.writeTransaction {
                try insertItem(firstItem, current: firstCanonical, in: database)
                // The deferred reference permits normal item→content insert
                // order, but an absent content row cannot survive COMMIT.
            }
        }
        #expect(try integer("SELECT count(*) FROM history_items", in: database) == 0)
    }

    @Test func unrelatedSQLiteFileIsRejectedWithoutAddingOrDeletingTables() throws {
        let database = try SQLiteDatabase(url: nil)
        try database.execute("CREATE TABLE unrelated (value INTEGER NOT NULL)")
        try database.execute("INSERT INTO unrelated VALUES (42)")
        #expect(throws: HistoryFailure.persistence(.openStore)) {
            try database.writeTransaction { try SQLiteHistorySchema.create(in: database) }
        }
        #expect(try integer("SELECT value FROM unrelated", in: database) == 42)
        #expect(try integer("SELECT count(*) FROM sqlite_master WHERE name = 'history_state'", in: database) == 0)
    }
}
