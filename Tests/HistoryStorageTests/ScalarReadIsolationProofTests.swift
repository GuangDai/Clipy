/// Scalar read isolation proof (docs/06-cross-cutting.md §7.5): the
/// recent/search read paths do NOT decode Canonical or revision blobs, while
/// current hard-capped startup decodes Canonical for authoritative Signature
/// Index coverage but still does not decode revision bytes. This file proves
/// that behaviorally: it captures a valid row, then corrupts only the
/// `revisionStateBlob`, leaving Canonical/signature/projection scalars valid.
/// Startup/recent/search must still succeed; lineage-decoding detail/paste
/// paths must fail (proving the corruption is real — the control).
///
/// Spec citations:
/// - docs/06-cross-cutting.md §7.5 (scalar read isolation)
/// - docs/05-authority-kernel.md §13 (startup — authoritative Canonical /
///   signature coverage, without revision decode),
///   §14.1 (recentPage — scalar-only two-lane fetch),
///   §14.2 (searchCorpusSnapshot — scalar-only full-corpus fetch)
/// - The §7.5 performance question (whether SwiftData suppresses faulting of
///   non-requested external-storage attributes) still requires a
///   supported-platform trace; neither this test nor the current runner proves
///   it. This file proves only the correctness stance — recent/search do not
///   depend on content blobs, and startup's coverage pass does not depend on
///   revision state.
import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

struct ScalarReadIsolationProofTests {

/// Creates the full current store through the public capture path. Only its
/// immutable business ID escapes this owner before the corruption fixture.
private static func seedCurrentItem(
    at storeURL: URL, text: String, observedAt: Date, source: String
) async throws -> HistoryItemID {
    let history = try await WSSupport.openHistory(storeURL: storeURL)
    let receipt = try await history.perform(.capture(
        WSSupport.textCapture(text, observedAt: observedAt, source: source)
    ))
    guard case let .committed(commit) = receipt,
          case let .inserted(item) = commit.outcome else {
        throw FixtureFailure.expectedInsert
    }
    return item.id
}

private enum FixtureFailure: Error { case expectedInsert }

/// §7.5 (docs/06-cross-cutting.md §7.5; docs/05-authority-kernel.md §13,
/// §14.1, §14.2): with only revision state corrupted, startup and the scalar
/// recent/search paths succeed, while lineage-decoding details/paste fail
/// closed with `.persistence(.corruptStoredValue)`.
@Test func corruptedRevisionBlobLeavesScalarReadPathsIntactButBreaksLineagePaths() async throws {
    let storeURL = WSSupport.tempStoreURL("scalar-read-isolation")
    defer { WSSupport.removeStore(storeURL) }

    // ── Arrange: a real capture owns all current bootstrap/accounting rows. ──
    let observedAt = Date(timeIntervalSinceReferenceDate: 700_020_000)
    let text = "scalar isolation proof row"
    let source = "com.example.scalar"
    let itemID = try await Self.seedCurrentItem(
        at: storeURL, text: text, observedAt: observedAt, source: source
    )

    // ── Corrupt ONLY revision state in place, leaving Canonical, signature,
    //    projection, and scalar columns valid (§7.5). Invalid under every
    //    codec: a truncated/malformed payload that no version tag matches.
    //    Done in a CLEAN second context over the same on-disk store so the
    //    corruption is durable and visible to every later container open. ──
    do {
        let corruptContainer = try WSSupport.makeContainer(storeURL: storeURL)
        let corruptContext = ModelContext(corruptContainer)
        let fetchedRows = try corruptContext.fetch(FetchDescriptor<HistoryItemRow>())
        let targetRow = try #require(fetchedRows.first)
        #expect(targetRow.searchBodyUTF8 == Data(text.utf8))
        targetRow.revisionStateBlob = Data([0x01])
        try corruptContext.save()
    }

    // ── (a) §13: STARTUP succeeds — Canonical/signature coverage is valid;
    //        the index build does not decode revision state. ──
    let authority = try await WSSupport.makeAuthority(storeURL: storeURL)

    // ── (b) §14.1: recentPage returns the row with correct scalar
    //        projections. The scalar-only path never accesses or decodes the
    //        corrupt revision blob (§14.1 `propertiesToFetch`). Actual
    //        external-storage fault suppression remains the separate macOS
    //        performance proof named in the file header. ──
    let recentPage = try await authority.recentPage(limit: 10, after: nil)
    // §7.5: the page carries the corrupted row's scalar projection intact.
    #expect(
        recentPage.rows.count == 1,
        "§7.5/§14.1: recentPage must return the row despite corrupt revision state"
    )
    let recentRow = try #require(recentPage.rows.first)
    #expect(
        recentRow.item.id == itemID,
        "§7.5: recentPage row id is the item's business ID"
    )
    #expect(
        recentRow.item.contentVersion.rawValue == 1,
        "§7.5: recentPage Content Version decoded from scalar column"
    )
    #expect(
        recentRow.title == text,
        "§7.5: recentPage title from scalar projection column"
    )
    #expect(
        recentRow.typeIdentifiers == ["public.utf8-plain-text"],
        "§7.5: recentPage type identifiers from the small scalar blob"
    )
    #expect(
        recentRow.lastCopiedAt == observedAt,
        "§7.5: recentPage lastCopiedAt from scalar column"
    )
    #expect(
        recentRow.copyCount == 1,
        "§7.5: recentPage copyCount from scalar column"
    )
    #expect(
        recentRow.lastSource == source,
        "§7.5: recentPage lastSource from scalar column"
    )
    #expect(
        recentRow.pinnedPosition == nil,
        "§7.5: recentPage pinOrdinal from scalar column (unpinned)"
    )

    // ── (c) §14.2: searchCorpusSnapshot returns the corpus row with correct
    //        scalar projections. Like recentPage, the corpus fetch is
    //        scalar-only — no content blob decode (§14.2). ──
    let corpusRequest = HistoryBrowseRequest(
        kind: .search(text: "", mode: .exact),
        limit: 10,
        after: nil
    )
    let corpusResult = try await authority.searchCorpusSnapshot(for: corpusRequest)
    let corpusRows = corpusResult.snapshot.rows
    // §7.5: the snapshot includes the corrupted row's scalar projection.
    #expect(
        corpusRows.count == 1,
        "§7.5/§14.2: searchCorpusSnapshot must include the row despite corrupt revision state"
    )
    let corpusRow = try #require(corpusRows.first)
    #expect(
        corpusRow.id == itemID,
        "§7.5: corpus row id is the item's business ID"
    )
    #expect(
        corpusRow.contentVersion.rawValue == 1,
        "§7.5: corpus Content Version decoded from scalar column"
    )
    #expect(
        corpusRow.title == text,
        "§7.5: corpus title from scalar projection column"
    )
    #expect(
        corpusRow.searchBody == text,
        "§7.5: corpus searchBody from scalar projection column"
    )
    #expect(
        corpusRow.typeIdentifiers == ["public.utf8-plain-text"],
        "§7.5: corpus type identifiers from the small scalar blob"
    )
    #expect(
        corpusRow.lastCopiedAt == observedAt,
        "§7.5: corpus lastCopiedAt from scalar column"
    )
    #expect(
        corpusRow.copyCount == 1,
        "§7.5: corpus copyCount from scalar column"
    )
    #expect(
        corpusRow.lastSource == source,
        "§7.5: corpus lastSource from scalar column"
    )
    #expect(
        corpusRow.pinOrdinal == nil,
        "§7.5: corpus pinOrdinal from scalar column (unpinned)"
    )

    // ── (d) CONTROL: details and pastePayload decode full lineage via
    //        `HistoryItemRowHydration.hydrate`, which decodes the Canonical
    //        blobs (FactLoaders §hydrate). The corruption IS real — these
    //        paths must fail closed with `.persistence(.corruptStoredValue)`,
    //        proving the scalar paths' success is because they never touched
    //        the blobs, not because the blobs were uncorrupted. ──
    // §7.5 control: details decodes lineage → corrupt blob → failure.
    await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
        try await authority.details(for: itemID)
    }
    // §7.5 control: pastePayload decodes lineage → corrupt blob → failure.
    await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
        try await authority.pastePayload(for: itemID)
    }
}
}
