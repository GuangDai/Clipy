import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

/// Real SQLite persistence and independent persisted-value assertions (06 §8).
enum WSSupport {
    static func tempStoreURL(_ testName: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipy-ws-\(testName)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("history.sqlite")
    }

    static func removeStore(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    static func makeHistory(maximumUnpinned: Int = 200) async throws -> SQLiteHistory {
        try await SQLiteHistory.open(configuration: HistoryConfiguration(
            persistence: .temporary, initialMaximumUnpinnedItems: maximumUnpinned
        ))
    }

    static func openHistory(storeURL: URL, maximumUnpinned: Int = 200) async throws -> SQLiteHistory {
        try await SQLiteHistory.open(configuration: HistoryConfiguration(
            persistence: .persistent(storeURL: storeURL), initialMaximumUnpinnedItems: maximumUnpinned
        ))
    }

    static func makeDatabase(storeURL: URL) throws -> SQLiteDatabase {
        try SQLiteDatabase(url: storeURL)
    }

    static func makeAuthority(
        storeURL: URL, limits: HistoryLimits = .standard, maximumUnpinned: Int = 200
    ) async throws -> HistoryAuthority {
        let authority = try HistoryAuthority(
            storeLocation: HistoryStoreLocation(persistence: .persistent(storeURL: storeURL)),
            limits: limits
        )
        try await authority.performStartup(initialMaximumUnpinnedItems: maximumUnpinned)
        return authority
    }

    static func textCapture(
        _ text: String, observedAt: Date, source: String? = nil,
        lineageHint: HistoryItemID? = nil,
        extra: [(typeIdentifier: String, bytes: [UInt8])] = []
    ) -> ClipboardCapture {
        var representations = [CapturedRepresentation(
            typeIdentifier: "public.utf8-plain-text", bytes: Data(text.utf8)
        )]
        representations += extra.map { CapturedRepresentation(typeIdentifier: $0.typeIdentifier, bytes: Data($0.bytes)) }
        return ClipboardCapture(
            representations: representations,
            origin: CopyOriginObservation(sourceApplication: source, lineageHint: lineageHint),
            observedAt: observedAt
        )
    }

    struct StoredItem: Equatable, Sendable {
        let id: UUID
        let contentVersionRaw: UInt64
        let titleUTF8: Data
        let searchBodyUTF8: Data
        let effectiveTypeIdentifiersBlob: Data
        let firstCopiedAt: Date
        let lastCopiedAt: Date
        let copyCount: UInt64
        let firstSource: String?
        let lastSource: String?
        let pinOrdinal: Int?
        let canonicalBytes: Int
        let revisionCount: Int
        let revisionBytes: Int
        let currentContentID: UUID
        let canonicalContentID: UUID
        let effectiveMatchesCanonical: Bool
    }

    static func fetchRows(_ database: SQLiteDatabase) throws -> [StoredItem] {
        let rows = try database.prepare("""
            SELECT i.id,i.contentVersion,i.titleUTF8,i.searchBodyUTF8,i.effectiveTypeIdentifiersBlob,
                   i.firstCopiedAt,i.lastCopiedAt,i.copyCount,i.firstSource,i.lastSource,i.pinOrdinal,
                   i.canonicalBytes,i.revisionCount,i.revisionBytes,i.currentContentID,c.id,
                   i.effectiveMatchesCanonical
            FROM history_items i LEFT JOIN contents c ON c.itemID=i.id AND c.revisionOrdinal=0
            ORDER BY i.id
            """)
        var result: [StoredItem] = []
        while try rows.step() {
            let matchesCanonical = try rows.integer(at: 16)
            try #require(matchesCanonical == 0 || matchesCanonical == 1)
            result.append(try StoredItem(
                id: #require(UUID(uuidString: rows.text(at: 0))),
                contentVersionRaw: sqliteUInt64(rows.blob(at: 1)),
                titleUTF8: rows.blob(at: 2), searchBodyUTF8: rows.blob(at: 3),
                effectiveTypeIdentifiersBlob: rows.blob(at: 4),
                firstCopiedAt: Date(timeIntervalSinceReferenceDate: rows.real(at: 5)),
                lastCopiedAt: Date(timeIntervalSinceReferenceDate: rows.real(at: 6)),
                copyCount: sqliteUInt64(rows.blob(at: 7)),
                firstSource: rows.optionalText(at: 8), lastSource: rows.optionalText(at: 9),
                pinOrdinal: rows.isNull(at: 10) ? nil : Int(rows.integer(at: 10)),
                canonicalBytes: Int(rows.integer(at: 11)), revisionCount: Int(rows.integer(at: 12)),
                revisionBytes: Int(rows.integer(at: 13)),
                currentContentID: #require(UUID(uuidString: rows.text(at: 14))),
                canonicalContentID: #require(UUID(uuidString: rows.text(at: 15))),
                effectiveMatchesCanonical: matchesCanonical == 1
            ))
        }
        return result
    }

    struct PositionState: Equatable, Sendable {
        let key: String
        let rawValue: UInt64
        let maximumUnpinnedItems: Int?
        let retainedItemCount: Int
        let pinnedItemCount: Int
        let canonicalBytes: Int
        let revisionBytes: Int
    }

    static func fetchPosition(_ database: SQLiteDatabase) throws -> PositionState {
        let row = try database.prepare("SELECT key,changePosition,maximumUnpinnedItems,retainedItemCount,pinnedItemCount,canonicalBytes,revisionBytes FROM history_state")
        #expect(try row.step())
        let result = try PositionState(
            key: row.text(at: 0), rawValue: sqliteUInt64(row.blob(at: 1)),
            maximumUnpinnedItems: row.isNull(at: 2) ? nil : Int(row.integer(at: 2)), retainedItemCount: Int(row.integer(at: 3)),
            pinnedItemCount: Int(row.integer(at: 4)), canonicalBytes: Int(row.integer(at: 5)),
            revisionBytes: Int(row.integer(at: 6))
        )
        #expect(try !row.step())
        return result
    }

    static func fetchCanonical(itemID: UUID, in database: SQLiteDatabase) throws -> CanonicalContent {
        let rows = try database.prepare("""
            SELECT r.exactType,r.fingerprint,r.byteCount,r.inlineBytes,r.blobID
            FROM representations r JOIN contents c ON c.id=r.contentID
            WHERE c.itemID=? AND c.revisionOrdinal=0 ORDER BY r.ordinal
            """, bindings: [.text(itemID.uuidString)])
        var values: [CanonicalRepresentation] = []
        while try rows.step() {
            values.append(try CanonicalRepresentation(
                content: ContentRepresentation(typeIdentifier: rows.text(at: 0), bytes: payload(
                    rows, countColumn: 2, inlineColumn: 3, blobColumn: 4, in: database
                )),
                fingerprint: ContentFingerprint(rawValue: sqliteUInt64(rows.blob(at: 1)))
            ))
        }
        return try CanonicalContent(representations: values)
    }

    static func fetchSignatureEntries(itemID: UUID, in database: SQLiteDatabase) throws -> [ContentSignatureEntry] {
        let rows = try database.prepare("""
            SELECT r.exactType,r.fingerprint,r.byteCount FROM representations r
            JOIN contents c ON c.id=r.contentID WHERE c.itemID=? AND c.revisionOrdinal=0 ORDER BY r.ordinal
            """, bindings: [.text(itemID.uuidString)])
        var values: [ContentSignatureEntry] = []
        while try rows.step() {
            values.append(try ContentSignatureEntry(
                typeIdentifier: rows.text(at: 0),
                fingerprint: ContentFingerprint(rawValue: sqliteUInt64(rows.blob(at: 1))),
                byteCount: Int(rows.integer(at: 2))
            ))
        }
        return values
    }

    struct StoredLineage: Equatable, Sendable {
        let revisions: [ContentRevision]
        let activeRevisionID: RevisionID?
    }

    static func fetchLineage(itemID: UUID, in database: SQLiteDatabase) throws -> StoredLineage {
        let item = try database.prepare("SELECT currentContentID FROM history_items WHERE id=?", bindings: [.text(itemID.uuidString)])
        #expect(try item.step())
        let currentID = try #require(UUID(uuidString: item.text(at: 0)))
        let rows = try database.prepare("SELECT id,createdAt FROM contents WHERE itemID=? AND revisionOrdinal>0 ORDER BY revisionOrdinal", bindings: [.text(itemID.uuidString)])
        var revisions: [ContentRevision] = []
        while try rows.step() {
            let id = try #require(UUID(uuidString: rows.text(at: 0)))
            let representations = try database.prepare("SELECT exactType,byteCount,inlineBytes,blobID FROM representations WHERE contentID=? ORDER BY ordinal", bindings: [.text(id.uuidString)])
            var values: [ContentRepresentation] = []
            while try representations.step() {
                values.append(try ContentRepresentation(typeIdentifier: representations.text(at: 0), bytes: payload(
                    representations, countColumn: 1, inlineColumn: 2, blobColumn: 3, in: database
                )))
            }
            revisions.append(try ContentRevision(id: RevisionID(rawValue: id),
                createdAt: Date(timeIntervalSinceReferenceDate: rows.real(at: 1)),
                content: EffectiveContent(representations: values)))
        }
        return StoredLineage(revisions: revisions, activeRevisionID: revisions.first { $0.id.rawValue == currentID }?.id)
    }

    private static func payload(
        _ row: SQLiteStatement, countColumn: Int32, inlineColumn: Int32, blobColumn: Int32,
        in database: SQLiteDatabase
    ) throws -> Data {
        let count = try Int(row.integer(at: countColumn))
        if let bytes = try row.optionalBlob(at: inlineColumn) {
            #expect(bytes.count == count)
            return bytes
        }
        let id = try #require(UUID(uuidString: row.text(at: blobColumn)))
        let location = try database.prepare("PRAGMA database_list")
        #expect(try location.step())
        let url = try URL(fileURLWithPath: location.text(at: 2))
        let store = try HistoryStoreLocation(persistence: .persistent(storeURL: url))
        return try ImmutableBlobStore(root: store.rootURL).read(id: id, expectedByteCount: count)
    }

    /// Explicit fixture policy writes avoid the public sweep before the capture under test.
    static func seedRetentionConfig(
        storeURL: URL, age: AgeRetention? = nil, storage: StorageRetention? = nil,
        revisions: RevisionRetention? = nil
    ) throws {
        let database = try makeDatabase(storeURL: storeURL)
        try database.execute("""
            UPDATE retention_policies SET ageMaxSeconds=?,storageMaxBytes=?,revisionMaxCount=?,revisionMaxBytes=?
            WHERE key='retention-expansion'
            """, bindings: [
                age.map { .real($0.maxAge) } ?? .null,
                storage.map { .integer(Int64($0.maxTotalBytes)) } ?? .null,
                (revisions?.maxRevisionsPerItem).map { .integer(Int64($0)) } ?? .null,
                (revisions?.maxRevisionBytesPerItem).map { .integer(Int64($0)) } ?? .null
            ])
        #expect(try database.changedRowCount == 1)
    }
}
