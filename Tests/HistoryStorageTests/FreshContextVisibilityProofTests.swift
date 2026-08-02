/// Fresh-context visibility proof (docs/06-cross-cutting.md §7 item 2 —
/// BLOCKER-class platform proof): after a committed receipt, a newly created
/// serialized read context sees the commit immediately, WITHOUT cross-context
/// notifications or manual refresh (docs/04-coherence.md §3: "This guarantee
/// does not depend on cross-context notifications or manual refresh. The
/// transaction completed before the receipt, and the later serialized read
/// creates a new context against the same `ModelContainer`.").
///
/// Storage-side proof, mirroring `TransactionBoundaryProofTests`' stance
/// (docs/05-authority-kernel.md §5: "For each read or commit: 1. create a
/// context from the Authority-owned `ModelContainer` … 4. retain no row or
/// context after returning from the isolated helper" — a fresh context per
/// isolated operation):
///
/// (1) A directly constructed Authority (`WSSupport.makeAuthority`) commits a
/// capture, then a FRESH `ModelContext` from a SEPARATE `ModelContainer`
/// (`WSSupport.makeContainer`) over the same store file sees the row and the
/// singleton position immediately — that is what no-refresh visibility means.
/// A second commit (Copy Coalescing) produces copyCount 2 and position 2 in a
/// second fresh container.
///
/// (2) The Authority's OWN fresh-context reads prove the same clause from the
/// read side: after `commitCapture`, `currentPosition()` — a new operation-
/// local context per §5 — returns the commit's position immediately; after a
/// second (distinct) commit, `recentPage(limit: 10, after: nil)` — another
/// new operation-local context — includes both rows at position 2.
///
/// Header cites: 06 §7 item 2 (fresh-context visibility); 04 §3 (read-after-
/// commit, no cross-context notification or manual refresh); 05 §5 (context
/// confinement: fresh context per isolated operation).
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData
import Testing
@testable import HistoryStorage

struct FreshContextVisibilityProofTests {

/// §7 item 2 (docs/06-cross-cutting.md): after a committed capture, a newly
/// created serialized read context — a FRESH `ModelContext` from a SEPARATE
/// `ModelContainer` over the same on-disk store — sees the row and the
/// singleton position immediately (docs/04-coherence.md §3). After a SECOND
/// commit (Copy Coalescing), a second fresh context sees copyCount 2 and
/// position 2. No cross-context notification or manual refresh is used at any
/// point.
@Test func freshSeparateContainerSeesCommittedCaptureAndCoalesceWithoutRefresh() async throws {
    let storeURL = WSSupport.tempStoreURL("fresh-context-visibility-separate-container")
    defer { WSSupport.removeStore(storeURL) }

    let authority = try await WSSupport.makeAuthority(storeURL: storeURL)
    let ingest = IngestPreparationActor()

    // ── First commit: insert on an empty store — position 1. ──
    let firstText = "fresh-context insert"
    let firstObservedAt = Date(timeIntervalSinceReferenceDate: 700_100_000)
    let firstBundle = try await ingest.prepare(
        WSSupport.textCapture(firstText, observedAt: firstObservedAt, source: "com.example.fcv.one")
    )
    let firstReceipt = try await authority.commitCapture(firstBundle)
    guard case let .committed(firstCommit) = firstReceipt else {
        Issue.record("§7.2: expected a .committed receipt for the first capture, got \(firstReceipt)")
        return
    }
    // §7.2: Change Position 1 for the first History Commit.
    #expect(firstCommit.position.rawValue == 1, "§7.2: first commit should advance the singleton 0 → 1")
    guard case .inserted = firstCommit.outcome else {
        Issue.record("§7.2: expected .inserted for the first capture, got \(firstCommit.outcome)")
        return
    }

    // §7.2 + 04 §3: a FRESH INDEPENDENT container over the same store file
    // sees the commit immediately — no cross-context notification, no manual
    // refresh. The Authority's operation-local context had autosave disabled
    // and the kernel calls no save() (05 §10); durability here is the
    // transaction closure's own doing.
    let firstVerification = try WSSupport.makeContainer(storeURL: storeURL)
    let firstRows = try WSSupport.fetchRows(firstVerification)
    // §7.2: "sees the commit" — exactly one durable row.
    #expect(firstRows.count == 1, "§7.2: fresh container should see exactly one row after the first commit")
    let firstRow = try #require(firstRows.first)
    #expect(firstRow.title == firstText, "§7.2: fresh container should see the committed row's title")
    #expect(firstRow.copyCount == 1, "§7.2: initial occurrence count is 1")
    // §7.2: the durable singleton matches the receipt's position.
    let firstPosition = try WSSupport.fetchPosition(firstVerification)
    #expect(firstPosition.rawValue == 1, "§7.2: fresh container should see singleton at position 1")

    // ── Second commit: Copy Coalescing (same canonical text) — position 2. ──
    let secondObservedAt = Date(timeIntervalSinceReferenceDate: 700_100_500)
    let secondBundle = try await ingest.prepare(
        WSSupport.textCapture(firstText, observedAt: secondObservedAt, source: "com.example.fcv.two")
    )
    let secondReceipt = try await authority.commitCapture(secondBundle)
    guard case let .committed(secondCommit) = secondReceipt else {
        Issue.record("§7.2: expected a .committed receipt for the coalescing capture, got \(secondReceipt)")
        return
    }
    // §7.2: Change Position 2 for the second History Commit.
    #expect(secondCommit.position.rawValue == 2, "§7.2: second commit should advance the singleton 1 → 2")
    guard case .coalesced = secondCommit.outcome else {
        Issue.record("§7.2: expected .coalesced for the second capture, got \(secondCommit.outcome)")
        return
    }

    // §7.2 + 04 §3: a SECOND fresh independent container sees the coalesced
    // state — copyCount 2 and position 2 — again with no notification or
    // refresh between the commit and this read.
    let secondVerification = try WSSupport.makeContainer(storeURL: storeURL)
    let secondRows = try WSSupport.fetchRows(secondVerification)
    // §7.2: "the second context sees copyCount 2" — still one row (coalesced).
    #expect(secondRows.count == 1, "§7.2: coalescing must not add a second row")
    let secondRow = try #require(secondRows.first)
    #expect(secondRow.copyCount == 2, "§7.2: fresh container should see copyCount 2 after coalescing")
    #expect(secondRow.lastCopiedAt == secondObservedAt, "§7.2: lastCopiedAt should reflect the coalescing observation")
    // §7.2: "position 2" — the singleton advanced once for the coalescing commit.
    let secondPosition = try WSSupport.fetchPosition(secondVerification)
    #expect(secondPosition.rawValue == 2, "§7.2: fresh container should see singleton at position 2")
}

/// §7 item 2 (docs/06-cross-cutting.md) from the read side: the Authority's
/// own fresh-context reads see each commit immediately. After `commitCapture`,
/// `currentPosition()` — which creates a new operation-local `ModelContext`
/// per docs/05-authority-kernel.md §5 — returns the commit's position without
/// any refresh. After a second (distinct) commit, `recentPage(limit: 10,
/// after: nil)` — another new operation-local context — includes both rows,
/// stamped at position 2 (docs/04-coherence.md §3).
@Test func authorityFreshContextReadsReturnCommittedPositionAndRowsImmediately() async throws {
    let storeURL = WSSupport.tempStoreURL("fresh-context-visibility-authority-reads")
    defer { WSSupport.removeStore(storeURL) }

    let authority = try await WSSupport.makeAuthority(storeURL: storeURL)
    let ingest = IngestPreparationActor()

    // ── First commit: insert text A — position 1. ──
    let textA = "fresh-context authority alpha"
    let observedAtA = Date(timeIntervalSinceReferenceDate: 700_110_000)
    let bundleA = try await ingest.prepare(
        WSSupport.textCapture(textA, observedAt: observedAtA, source: "com.example.fcv.auth.a")
    )
    let receiptA = try await authority.commitCapture(bundleA)
    guard case let .committed(commitA) = receiptA else {
        Issue.record("§7.2: expected a .committed receipt for capture A, got \(receiptA)")
        return
    }
    // §7.2: Change Position 1 for the first History Commit.
    #expect(commitA.position.rawValue == 1, "§7.2: first commit should be at position 1")

    // §7.2 + 05 §5: `currentPosition()` creates a new operation-local context
    // and reads the singleton — it returns the commit's position immediately,
    // without any cross-context notification or manual refresh (04 §3).
    let positionAfterA = try await authority.currentPosition()
    #expect(
        positionAfterA == commitA.position,
        "§7.2: currentPosition() must return the commit's position immediately (fresh context per §5)"
    )

    // ── Second commit: insert text B (distinct content) — position 2. ──
    let textB = "fresh-context authority bravo"
    let observedAtB = Date(timeIntervalSinceReferenceDate: 700_110_500)
    let bundleB = try await ingest.prepare(
        WSSupport.textCapture(textB, observedAt: observedAtB, source: "com.example.fcv.auth.b")
    )
    let receiptB = try await authority.commitCapture(bundleB)
    guard case let .committed(commitB) = receiptB else {
        Issue.record("§7.2: expected a .committed receipt for capture B, got \(receiptB)")
        return
    }
    // §7.2: Change Position 2 for the second History Commit.
    #expect(commitB.position.rawValue == 2, "§7.2: second commit should be at position 2")

    // §7.2 + 05 §5: `currentPosition()` still returns the latest position.
    let positionAfterB = try await authority.currentPosition()
    #expect(
        positionAfterB == commitB.position,
        "§7.2: currentPosition() must return position 2 after the second commit"
    )

    // §7.2 + 04 §3: `recentPage(limit:after:)` creates ANOTHER new operation-
    // local context (05 §5) and reads scalar rows + the singleton. It must
    // include both rows and be stamped at position 2 — no refresh needed.
    let page = try await authority.recentPage(limit: 10, after: nil)
    // §7.2: the page position equals the latest durable commit's position.
    #expect(
        page.position == commitB.position,
        "§7.2: recentPage must be stamped at the latest commit's position (position 2)"
    )
    // §7.2: "includes both rows" — two distinct items are present.
    #expect(page.rows.count == 2, "§7.2: recentPage should include both committed rows")
    let titles = page.rows.map(\.title)
    #expect(Set(titles) == [textA, textB], "§7.2: both committed titles should be visible in the page")
    // §7.2: unpinned lane is sorted by lastCopiedAt descending, so the later
    // capture (B) appears first (05 §14.1).
    #expect(page.rows.first?.title == textB, "§7.2: most-recently-copied row should sort first in the unpinned lane")
}
}
