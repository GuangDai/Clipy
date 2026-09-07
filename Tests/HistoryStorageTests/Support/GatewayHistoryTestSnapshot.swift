import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

/// Failure/denial proofs compare real metadata and every immutable content's
/// bytes. No retired SwiftData blob encoding is synthesized for an assertion.
struct GatewayHistoryTestSnapshot: Sendable, Equatable {
    struct Content: Sendable, Equatable {
        let id: UUID
        let ordinal: Int
        let createdAt: Date
        let representations: [ContentRepresentation]
        let fingerprints: [ContentFingerprint?]
    }
    struct Item: Sendable, Equatable {
        let id: UUID
        let contentVersionRaw: UInt64
        let currentContentID: UUID
        let titleUTF8: Data
        let searchBodyUTF8: Data
        let effectiveTypes: Data
        let firstCopiedAt: Date
        let lastCopiedAt: Date
        let firstSource: String?
        let lastSource: String?
        let copyCount: UInt64
        let pinOrdinal: Int?
        let canonicalBytes: Int
        let revisionCount: Int
        let revisionBytes: Int
        let contents: [Content]
    }
    struct Change: Sendable, Equatable {
        let sequence: UInt64
        let changePositionRaw: UInt64
        let changeKindRaw: Int16
        let affectedItemsBlob: Data
        let createdAt: Date
    }
    struct Journal: Sendable, Equatable {
        let key: String
        let compactionFloorRaw: UInt64
        let journalBytes: UInt64
        let configSchemaVersion: UInt16
    }
    struct Totals: Sendable, Equatable {
        let items: Int64
        let pinned: Int64
        let canonicalBytes: Int64
        let revisionBytes: Int64
    }
    let position: UInt64
    let totals: Totals
    let items: [Item]
    let changes: [Change]
    let journal: [Journal]

    static func read(from authority: HistoryAuthority) async throws -> Self {
        try await authority.withTestDatabase { authority in
            try authority.database.readTransaction { try read(in: authority) }
        }
    }

    static func read(in authority: isolated HistoryAuthority) throws -> Self {
        let database = authority.database
        let position = try authority.readPositionInLocalContext().rawValue
        let aggregate = try database.prepare("SELECT retainedItemCount, pinnedItemCount, canonicalBytes, revisionBytes FROM history_state")
        try #require(try aggregate.step())
        let totals = try Totals(items: aggregate.integer(at: 0), pinned: aggregate.integer(at: 1),
            canonicalBytes: aggregate.integer(at: 2), revisionBytes: aggregate.integer(at: 3))
        let ids = try database.prepare("SELECT id, titleUTF8, searchBodyUTF8, effectiveTypeIdentifiersBlob FROM history_items ORDER BY id")
        var items: [Item] = []
        while try ids.step() {
            let id = HistoryItemID(rawValue: try #require(UUID(uuidString: try ids.text(at: 0))))
            let item = try #require(try HistoryItemRowHydration.metadata(itemID: id, in: database))
            let contentIDs = try database.prepare("SELECT id FROM contents WHERE itemID = ? ORDER BY revisionOrdinal", bindings: [.text(id.rawValue.uuidString)])
            var contents: [Content] = []
            while try contentIDs.step() {
                let contentID = try #require(UUID(uuidString: try contentIDs.text(at: 0)))
                let content = try HistoryItemRowHydration.content(id: contentID, itemID: id, in: database, blobStore: authority.blobStore)
                contents.append(Content(id: contentID, ordinal: content.metadata.ordinal,
                    createdAt: content.metadata.createdAt, representations: content.content.representations,
                    fingerprints: content.fingerprints))
            }
            items.append(Item(id: id.rawValue, contentVersionRaw: item.contentVersion.rawValue,
                currentContentID: item.currentContentID,
                titleUTF8: try ids.blob(at: 1), searchBodyUTF8: try ids.blob(at: 2), effectiveTypes: try ids.blob(at: 3),
                firstCopiedAt: item.occurrence.firstCopiedAt, lastCopiedAt: item.occurrence.lastCopiedAt,
                firstSource: item.occurrence.firstSource, lastSource: item.occurrence.lastSource,
                copyCount: item.occurrence.count,
                pinOrdinal: item.pinOrdinal?.rawValue, canonicalBytes: item.canonicalBytes,
                revisionCount: item.revisionCount, revisionBytes: item.revisionBytes, contents: contents))
        }
        let records = try database.prepare("SELECT sequence, changePositionRaw, changeKindRaw, affectedItemsBlob, createdAt FROM history_change_records ORDER BY sequence")
        var changes: [Change] = []
        while try records.step() {
            changes.append(Change(sequence: try sqliteUInt64(records.blob(at: 0)),
                changePositionRaw: try sqliteUInt64(records.blob(at: 1)),
                changeKindRaw: try #require(Int16(exactly: try records.integer(at: 2))),
                affectedItemsBlob: try records.blob(at: 3),
                createdAt: try Date(timeIntervalSinceReferenceDate: records.real(at: 4))))
        }
        let configs = try database.prepare("SELECT key, compactionFloorRaw, journalBytes, configSchemaVersion FROM journal_config ORDER BY key")
        var journal: [Journal] = []
        while try configs.step() {
            journal.append(Journal(key: try configs.text(at: 0),
                compactionFloorRaw: try sqliteUInt64(configs.blob(at: 1)),
                journalBytes: try sqliteUInt64(configs.blob(at: 2)),
                configSchemaVersion: try #require(UInt16(exactly: try configs.integer(at: 3)))))
        }
        return Self(position: position, totals: totals, items: items, changes: changes, journal: journal)
    }
}
