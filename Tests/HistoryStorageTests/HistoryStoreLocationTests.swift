import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

/// V2-09 §§5/6: each database owns its content directory, and a disposable
/// directory outlives every search that still holds its location.
struct HistoryStoreLocationTests {
    @Test func siblingDatabasesCleanOnlyTheirOwnUnreferencedBlobs() throws {
        let parent = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let sentinel = parent.appendingPathComponent("unrelated.txt")
        let sentinelBytes = Data("keep the caller's files".utf8)
        try sentinelBytes.write(to: sentinel)
        let firstURL = parent.appendingPathComponent("first.sqlite")
        let secondURL = parent.appendingPathComponent("second.sqlite")
        var first: HistoryStoreLocation? = try HistoryStoreLocation(persistence: .persistent(storeURL: firstURL))
        var second: HistoryStoreLocation? = try HistoryStoreLocation(persistence: .persistent(storeURL: secondURL))
        let firstRoot = try #require(first?.rootURL)
        let secondRoot = try #require(second?.rootURL)
        #expect(firstRoot != secondRoot)
        let firstBlobs = try ImmutableBlobStore(root: firstRoot)
        let secondBlobs = try ImmutableBlobStore(root: secondRoot)
        let firstDB = try SQLiteDatabase(url: firstURL)
        let secondDB = try SQLiteDatabase(url: secondURL)
        let firstBytes = Data(repeating: 0xA1, count: 70_000)
        let secondBytes = Data(repeating: 0xB2, count: 80_000)
        let firstKept = try firstBlobs.write(firstBytes)
        let secondKept = try secondBlobs.write(secondBytes)
        try reference(firstKept, in: firstDB)
        try reference(secondKept, in: secondDB)
        let firstOrphan = try firstBlobs.write(Data("first rollback".utf8))
        let secondOrphan = try secondBlobs.write(Data("second rollback".utf8))

        #expect(try clean(firstBlobs, using: firstDB) == 1)
        #expect(try firstBlobs.read(id: firstKept.id, expectedByteCount: firstKept.byteCount) == firstBytes)
        #expect(try secondBlobs.read(id: secondKept.id, expectedByteCount: secondKept.byteCount) == secondBytes)
        // A's cleanup must not even remove B's unreferenced content.
        #expect(try secondBlobs.read(id: secondOrphan.id, expectedByteCount: secondOrphan.byteCount)
            == Data("second rollback".utf8))
        #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try firstBlobs.read(id: firstOrphan.id, expectedByteCount: firstOrphan.byteCount)
        }

        #expect(try clean(secondBlobs, using: secondDB) == 1)
        #expect(try firstBlobs.read(id: firstKept.id, expectedByteCount: firstKept.byteCount) == firstBytes)
        #expect(try secondBlobs.read(id: secondKept.id, expectedByteCount: secondKept.byteCount) == secondBytes)
        #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try secondBlobs.read(id: secondOrphan.id, expectedByteCount: secondOrphan.byteCount)
        }
        try firstDB.close()
        try secondDB.close()
        first = nil
        second = nil
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
        #expect(try firstBlobs.read(id: firstKept.id, expectedByteCount: firstKept.byteCount) == firstBytes)
        #expect(try secondBlobs.read(id: secondKept.id, expectedByteCount: secondKept.byteCount) == secondBytes)
        #expect(try Data(contentsOf: sentinel) == sentinelBytes)
    }

    @Test func disposableDirectoryLivesUntilTheSearchLocationIsReleased() throws {
        var owner: HistoryStoreLocation? = try HistoryStoreLocation(persistence: .temporary)
        var searchLocation = owner
        weak var releasedLocation = owner
        let databaseURL = try #require(owner?.databaseURL)
        let contentRoot = try #require(owner?.rootURL)
        let ownedDirectory = databaseURL.deletingLastPathComponent()
        let blobs = try ImmutableBlobStore(root: contentRoot)
        let bytes = Data("still readable by the active search".utf8)
        let content = try blobs.write(bytes)
        let writer = try SQLiteDatabase(url: databaseURL)
        try reference(content, in: writer)
        let reader = try SQLiteDatabase(url: databaseURL)
        try reader.readTransaction {
            #expect(try isReferenced(content.id, in: reader))
            try writer.close()
            owner = nil
            #expect(releasedLocation != nil)
            #expect(FileManager.default.fileExists(atPath: ownedDirectory.path))
            #expect(try isReferenced(content.id, in: reader))
            #expect(try blobs.read(id: content.id, expectedByteCount: content.byteCount) == bytes)
        }
        try reader.close()
        withExtendedLifetime(searchLocation) {
            #expect(FileManager.default.fileExists(atPath: ownedDirectory.path))
        }
        searchLocation = nil
        #expect(releasedLocation == nil)
        #expect(!FileManager.default.fileExists(atPath: ownedDirectory.path))
        #expect(FileManager.default.fileExists(atPath: ownedDirectory.deletingLastPathComponent().path))
    }

    private func reference(_ blob: ImmutableBlobReference, in database: SQLiteDatabase) throws {
        let item = UUID().uuidString
        let content = UUID().uuidString
        try database.writeTransaction {
            try SQLiteHistorySchema.create(in: database)
            try database.execute("""
                INSERT INTO history_items (
                    id, contentVersion, currentContentID, titleUTF8, searchBodyUTF8,
                    effectiveTypeIdentifiersBlob, firstCopiedAt, lastCopiedAt, copyCount,
                    canonicalBytes, revisionCount, revisionBytes
                ) VALUES (?, ?, ?, ?, ?, ?, 1.0, 1.0, ?, ?, 0, 0)
                """, bindings: [
                    .text(item), .blob(sqliteUInt64(1)), .text(content),
                    .blob(Data("blob".utf8)), .blob(Data("blob".utf8)), .blob(Data()),
                    .blob(sqliteUInt64(1)), .integer(Int64(blob.byteCount)),
                ])
            try database.execute("""
                INSERT INTO contents (
                    id, itemID, revisionOrdinal, createdAt, titleUTF8, contentByteCount, representationCount
                ) VALUES (?, ?, 0, 1.0, ?, ?, 1)
                """, bindings: [
                    .text(content), .text(item), .blob(Data("blob".utf8)), .integer(Int64(blob.byteCount)),
                ])
            try database.execute("""
                INSERT INTO representations (contentID, ordinal, exactType, typeKey, byteCount, inlineBytes, blobID)
                VALUES (?, 0, 'public.data', 'public.data', ?, NULL, ?)
                """, bindings: [.text(content), .integer(Int64(blob.byteCount)), .text(blob.id.uuidString)])
        }
    }

    private func isReferenced(_ id: UUID, in database: SQLiteDatabase) throws -> Bool {
        let statement = try database.prepare(
            "SELECT 1 FROM representations WHERE blobID = ? LIMIT 1", bindings: [.text(id.uuidString)]
        )
        defer { statement.finalize() }
        return try statement.step()
    }

    private func clean(_ blobs: ImmutableBlobStore, using database: SQLiteDatabase) throws -> Int {
        var removed = 0
        // Two blobs and at most two shard directories fit in the first batch;
        // subsequent calls also traverse staging and restart enumeration.
        for _ in 0..<4 {
            removed += try blobs.cleanupBatch(limit: 8) { try isReferenced($0, in: database) }
        }
        return removed
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipy-location-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
