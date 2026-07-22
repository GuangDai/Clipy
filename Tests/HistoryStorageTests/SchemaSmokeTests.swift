/// Schema v1 smoke tests (roadmap step 4): an in-memory `ModelContainer`
/// built from `v1Schema` accepts one `HistoryItemRow` plus the
/// `LastChangePositionRow` singleton, and every field round-trips through a
/// fresh fetch (docs/05-authority-kernel.md §3).
///
/// These keep the schema honest while the WS gates land per
/// docs/roadmap/README.md §3 (docs/06-cross-cutting.md §8); this target later
/// hosts WS1–WS21 against both persistent temporary stores and in-memory
/// configurations (docs/06-cross-cutting.md §5). Rows are internal, so this
/// same-package test target reaches them via `@testable import`.
import Foundation
import SwiftData
import Testing
@testable import HistoryStorage

@Test func v1SchemaRoundTripsHistoryItemAndPositionSingleton() throws {
    let configuration = ModelConfiguration(schema: v1Schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: v1Schema, configurations: [configuration])
    let context = ModelContext(container)

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
        projectionSchemaVersion: 1,
        title: "hello",
        searchBody: "hello world",
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
    // and owns the current v1 retention policy.
    let singleton = LastChangePositionRow(
        key: "retained-history",
        rawValue: 0,
        maximumUnpinnedItems: 200
    )
    context.insert(singleton)
    try context.save()

    let items = try context.fetch(FetchDescriptor<HistoryItemRow>())
    #expect(items.count == 1)
    let fetchedItem = try #require(items.first)
    #expect(fetchedItem.id == itemID)
    #expect(fetchedItem.contentVersionRaw == 1)
    #expect(fetchedItem.canonicalBlob == Data([0x01, 0x02]))
    #expect(fetchedItem.revisionStateBlob == Data([0x03]))
    #expect(fetchedItem.canonicalSignatureBlob == Data([0x04]))
    #expect(fetchedItem.projectionSchemaVersion == 1)
    #expect(fetchedItem.title == "hello")
    #expect(fetchedItem.searchBody == "hello world")
    #expect(fetchedItem.effectiveTypeIdentifiersBlob == Data([0x05]))
    #expect(fetchedItem.firstCopiedAt == firstCopiedAt)
    #expect(fetchedItem.lastCopiedAt == lastCopiedAt)
    #expect(fetchedItem.copyCount == 2)
    #expect(fetchedItem.firstSource == "com.example.first")
    #expect(fetchedItem.lastSource == nil)
    #expect(fetchedItem.pinOrdinal == nil)

    let positions = try context.fetch(FetchDescriptor<LastChangePositionRow>())
    #expect(positions.count == 1)
    let fetchedSingleton = try #require(positions.first)
    #expect(fetchedSingleton.key == "retained-history")
    #expect(fetchedSingleton.rawValue == 0)
    #expect(fetchedSingleton.maximumUnpinnedItems == 200)
}
