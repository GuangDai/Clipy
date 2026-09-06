/// Current-schema item and position round trip through a fresh context.
/// Byte-backed projections preserve literal Unicode content separately from
/// the opaque content blobs (docs/05-authority-kernel.md §3).
import Foundation
import SwiftData
import Testing
@testable import HistoryStorage

@Test func schemaRoundTripsHistoryItemAndPositionSingleton() throws {
    let configuration = ModelConfiguration(schema: historySchema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: historySchema, configurations: [configuration])
    let context = ModelContext(container)
    context.autosaveEnabled = false

    let itemID = UUID()
    let firstCopiedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let lastCopiedAt = Date(timeIntervalSince1970: 1_700_000_100)
    // §9 create-stamping shape: version ≥ 1, projection written with the
    // item, first/last occurrence summary, and no pin (`nil` is unpinned,
    // §3.1). Blob columns hold opaque versioned payload bytes (§4); the smoke
    // test does not interpret them.
    let item = HistoryItemRow(
        id: itemID,
        contentVersionRaw: 1,
        canonicalBlob: Data([0x01, 0x02]),
        revisionStateBlob: Data([0x03]),
        canonicalSignatureBlob: Data([0x04]),
        title: "\u{FEFF}hello",
        searchBody: "\u{FEFF}hello world",
        effectiveTypeIdentifiersBlob: Data([0x05]),
        firstCopiedAt: firstCopiedAt,
        lastCopiedAt: lastCopiedAt,
        copyCount: 2,
        firstSource: "com.example.first",
        lastSource: nil,
        pinOrdinal: nil
    )
    context.insert(item)

    // §3.2: the singleton sits at position 0 before the first History Commit
    // and owns the configured count-retention policy.
    let singleton = LastChangePositionRow(
        key: "retained-history",
        rawValue: 0,
        maximumUnpinnedItems: 200
    )
    context.insert(singleton)
    try context.save()

    let freshContext = ModelContext(container)
    let items = try freshContext.fetch(FetchDescriptor<HistoryItemRow>())
    #expect(items.count == 1)
    let fetchedItem = try #require(items.first)
    #expect(fetchedItem.id == itemID)
    #expect(fetchedItem.contentVersionRaw == 1)
    #expect(fetchedItem.canonicalBlob == Data([0x01, 0x02]))
    #expect(fetchedItem.revisionStateBlob == Data([0x03]))
    #expect(fetchedItem.canonicalSignatureBlob == Data([0x04]))
    #expect(fetchedItem.titleUTF8 == Data("\u{FEFF}hello".utf8))
    #expect(fetchedItem.searchBodyUTF8 == Data("\u{FEFF}hello world".utf8))
    #expect(fetchedItem.effectiveTypeIdentifiersBlob == Data([0x05]))
    #expect(fetchedItem.firstCopiedAt == firstCopiedAt)
    #expect(fetchedItem.lastCopiedAt == lastCopiedAt)
    #expect(fetchedItem.copyCount == 2)
    #expect(fetchedItem.firstSource == "com.example.first")
    #expect(fetchedItem.lastSource == nil)
    #expect(fetchedItem.pinOrdinal == nil)

    let positions = try freshContext.fetch(FetchDescriptor<LastChangePositionRow>())
    #expect(positions.count == 1)
    let fetchedSingleton = try #require(positions.first)
    #expect(fetchedSingleton.key == "retained-history")
    #expect(fetchedSingleton.rawValue == 0)
    #expect(fetchedSingleton.maximumUnpinnedItems == 200)
}
