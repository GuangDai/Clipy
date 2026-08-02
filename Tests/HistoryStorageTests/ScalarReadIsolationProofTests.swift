/// Scalar read isolation proof (docs/06-cross-cutting.md §7.5): the
/// recent/search/startup read paths do NOT decode Canonical or revision blobs —
/// they read only scalar projection fields, the small
/// `effectiveTypeIdentifiersBlob`, and signature metadata. This file proves
/// that behaviorally: it hand-crafts fully valid v1 rows via the production
/// codecs, then CORRUPTS only the two content blobs in place
/// (`canonicalBlob` and `revisionStateBlob`) via a direct context write behind
/// the Authority's back, leaving every scalar/projection/signature column
/// valid. The scalar read paths must still succeed (they never touch the
/// corrupted blobs); the lineage-decoding detail/paste paths must FAIL
/// (proving the corruption is real — the control).
///
/// Spec citations:
/// - docs/06-cross-cutting.md §7.5 (scalar read isolation)
/// - docs/05-authority-kernel.md §13 (startup — Signature Index built from
///   signature metadata, never content blobs),
///   §14.1 (recentPage — scalar-only two-lane fetch),
///   §14.2 (searchCorpusSnapshot — scalar-only full-corpus fetch)
/// - The §7.5 performance claim (no fault-in by SwiftData) is a platform
///   concern proven by the performance runner, not here; this file proves the
///   correctness stance — scalar paths must not depend on content blobs.
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData
import Testing
@testable import HistoryStorage

struct ScalarReadIsolationProofTests {

/// Builds a fully valid v1 `HistoryItemRow` from a real prepared capture:
/// every blob comes from the production codecs over the bundle's validated
/// values (Canonical Content, signature entries, empty revision lineage for a
/// Canonical-state item, and the §15 projection). The row id is the bundle's
/// freshly minted candidate ID. (Copied from WS5's `makeRow` — same stance:
/// hand-crafted but production-codec-valid rows for storage-side proofs.)
private static func makeRow(
    from bundle: PreparedCaptureBundle,
    observedAt: Date,
    source: String?
) throws -> HistoryItemRow {
    try HistoryItemRow(
        id: bundle.domain.candidateID.rawValue,
        contentVersionRaw: 1,
        canonicalBlob: CanonicalBlobCodec.encode(bundle.domain.canonical),
        revisionStateBlob: RevisionStateBlobCodec.encode(revisions: [], activeRevisionID: nil),
        canonicalSignatureBlob: SignatureBlobCodec.encode(bundle.signatureEntries),
        projectionSchemaVersion: bundle.projection.schemaVersion,
        title: bundle.projection.title,
        searchBody: bundle.projection.searchBody,
        effectiveTypeIdentifiersBlob: EffectiveTypeIdentifiersBlobCodec
            .encode(bundle.projection.effectiveTypeIdentifiers),
        firstCopiedAt: observedAt,
        lastCopiedAt: observedAt,
        copyCount: 1,
        firstSource: source,
        lastSource: source,
        pinOrdinal: nil
    )
}

/// §7.5 (docs/06-cross-cutting.md §7.5; docs/05-authority-kernel.md §13,
/// §14.1, §14.2): with the Canonical and revision blobs corrupted in place
/// but all scalar/projection/signature columns valid, the scalar read paths
/// (startup, recentPage, searchCorpusSnapshot) succeed with correct scalar
/// projections, while the lineage-decoding paths (details, pastePayload) fail
/// closed with `.persistence(.corruptStoredValue)` — proving both that the
/// corruption is real and that the scalar paths never touched the content
/// blobs.
@Test func corruptedContentBlobsLeaveScalarReadPathsIntactButBreakLineagePaths() async throws {
    let storeURL = WSSupport.tempStoreURL("scalar-read-isolation")
    defer { WSSupport.removeStore(storeURL) }

    // ── Arrange: one fully valid v1 row written directly into the store ──
    let observedAt = Date(timeIntervalSinceReferenceDate: 700_020_000)
    let text = "scalar isolation proof row"
    let source = "com.example.scalar"
    let preparation = IngestPreparationActor()
    let bundle = try await preparation.prepare(
        WSSupport.textCapture(text, observedAt: observedAt, source: source)
    )
    let itemID = bundle.domain.candidateID

    let seedContainer = try WSSupport.makeContainer(storeURL: storeURL)
    let seedContext = ModelContext(seedContainer)
    let row = try Self.makeRow(from: bundle, observedAt: observedAt, source: source)
    seedContext.insert(row)
    try seedContext.save()

    // ── Corrupt ONLY the two content blobs in place, leaving all scalar,
    //    projection, and signature columns valid (§7.5). Invalid under every
    //    codec: a truncated/malformed payload that no version tag matches.
    //    Done in a CLEAN second context over the same on-disk store so the
    //    corruption is durable and visible to every later container open. ──
    let corruptContainer = try WSSupport.makeContainer(storeURL: storeURL)
    let corruptContext = ModelContext(corruptContainer)
    let fetchedRows = try corruptContext.fetch(FetchDescriptor<HistoryItemRow>())
    let targetRow = try #require(fetchedRows.first)
    targetRow.canonicalBlob = Data([0x00, 0xFF, 0x00])
    targetRow.revisionStateBlob = Data([0x01])
    try corruptContext.save()

    // ── (a) §13: STARTUP succeeds — the Signature Index is built from
    //        signature metadata, not content blobs (§13 step 8 decodes
    //        signature blobs; Canonical/revision blobs are never touched). ──
    let authority = try await WSSupport.makeAuthority(storeURL: storeURL)

    // ── (b) §14.1: recentPage returns the row with correct scalar
    //        projections. The scalar-only fetch avoids faulting the corrupted
    //        content blobs entirely (§14.1 `propertiesToFetch`). ──
    let recentPage = try await authority.recentPage(limit: 10, after: nil)
    // §7.5: the page carries the corrupted row's scalar projection intact.
    #expect(
        recentPage.rows.count == 1,
        "§7.5/§14.1: recentPage must return the row despite corrupted content blobs"
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
        "§7.5/§14.2: searchCorpusSnapshot must include the row despite corrupted content blobs"
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
    //        blob first (FactLoaders §hydrate). The corruption IS real — these
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
