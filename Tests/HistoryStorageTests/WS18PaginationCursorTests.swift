/// WS18 — Pagination and cursor expiry (docs/06-cross-cutting.md §8 WS18;
/// docs/04-coherence.md §6): cursor pagination across pages with no overlap or
/// gap, cursor expiry after an intervening commit (`.snapshotExpired`), cursor
/// shape mismatch against a different query shape or limit, and the
/// pinned/unpinned two-lane fetch with anchor-based continuation.
///
/// Facade-driven (the WS1 stance): every path crosses the public
/// `SwiftDataHistory.browse(_:)` interface and the real `HistoryAuthority`
/// read path. Page-level assertions use the `HistoryRow.item.id` values
/// directly — the page is the authoritative read result (04 §2), so no
/// independent second `ModelContainer` is needed for read-page assertions.
///
/// Spec: docs/06-cross-cutting.md §8 WS18; cursor semantics:
/// docs/04-coherence.md §6 (cursor binds complete query shape + page
/// ChangePosition + last-row ordering anchor + process marker; shape mismatch,
/// generation mismatch, or position mismatch → `.snapshotExpired`); recent-page
/// fetch: docs/05-authority-kernel.md §14.1 (scalar-only two-lane fetch).
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct WS18PaginationCursorTests {

/// Captures `count` single-line text items with strictly increasing
/// `observedAt` values and returns their item IDs in capture order (oldest
/// first). Each capture is a History Commit advancing the Change Position by 1.
private static func captureItems(
    _ history: SwiftDataHistory,
    count: Int,
    base: Double = 700_018_000
) async throws -> [HistoryItemID] {
    var ids: [HistoryItemID] = []
    for index in 0..<count {
        let observedAt = Date(timeIntervalSinceReferenceDate: base + Double(index) * 1_000)
        let receipt = try await history.perform(
            .capture(WSSupport.textCapture(
                "ws18 item \(index)",
                observedAt: observedAt,
                source: "com.example.ws18"
            ))
        )
        guard case .committed(let commit) = receipt,
              case .inserted(let reference) = commit.outcome else {
            Issue.record("WS18: expected .committed/.inserted for capture \(index), got \(receipt)")
            return ids
        }
        ids.append(reference.id)
    }
    return ids
}

/// WS18 (docs/06-cross-cutting.md §8): browse with a small limit resumes the
/// continuation page with no overlap or gap across the full result set. The
/// cursor binds the snapshot position, so every page reports the same
/// ChangePosition as long as no commit intervenes (04 §6).
@Test func paginationResumesContinuationPageWithNoOverlapOrGap() async throws {
    let storeURL = WSSupport.tempStoreURL("ws18-pagination")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // Arrange: 7 unpinned items with strictly increasing observedAt. After 7
    // commits the Change Position is 7. The unpinned lane sorts by
    // lastCopiedAt DESC (newest first, 05 §14.1), so the expected order is
    // ids[6] (latest) down to ids[0] (earliest).
    let ids = try await Self.captureItems(history, count: 7)
    let expectedPage1 = [ids[6], ids[5], ids[4]]
    let expectedPage2 = [ids[3], ids[2], ids[1]]
    let expectedPage3 = [ids[0]]

    // WS18/04 §6: page 1 — 3 rows newest-first, a continuation cursor, and
    // the snapshot position (7).
    let page1 = try await history.browse(
        HistoryBrowseRequest(kind: .recent, limit: 3)
    )
    #expect(page1.rows.count == 3, "WS18: page1 has 3 rows")
    #expect(
        page1.rows.map(\.item.id) == expectedPage1,
        "WS18/05 §14.1: page1 is newest-first (ids[6], ids[5], ids[4])"
    )
    let page1Cursor = try #require(page1.next, "WS18: page1 has a continuation cursor")
    #expect(page1.position.rawValue == 7, "WS18/04 §6: page1 binds snapshot position 7")

    // WS18: page 2 — the NEXT 3 rows, no overlap with page1, no gap.
    let page2 = try await history.browse(
        HistoryBrowseRequest(kind: .recent, limit: 3, after: page1Cursor)
    )
    #expect(page2.rows.count == 3, "WS18: page2 has 3 rows")
    #expect(
        page2.rows.map(\.item.id) == expectedPage2,
        "WS18: page2 continues from page1 with no gap (ids[3], ids[2], ids[1])"
    )
    let page2Cursor = try #require(page2.next, "WS18: page2 has a continuation cursor")
    #expect(
        Set(page1.rows.map(\.item.id))
            .isDisjoint(with: Set(page2.rows.map(\.item.id))),
        "WS18: page1 and page2 share no rows (no overlap)"
    )

    // WS18: page 3 — the remaining 1 row, next == nil (last page).
    let page3 = try await history.browse(
        HistoryBrowseRequest(kind: .recent, limit: 3, after: page2Cursor)
    )
    #expect(page3.rows.count == 1, "WS18: page3 has 1 row")
    #expect(
        page3.rows.map(\.item.id) == expectedPage3,
        "WS18: page3 is the last row (ids[0])"
    )
    #expect(page3.next == nil, "WS18: page3 has no continuation cursor (last page)")

    // WS18/04 §6: the cursor binds the snapshot position — all pages report
    // the same ChangePosition because no commit intervened.
    #expect(page2.position == page1.position, "WS18/04 §6: page2 position == page1 position")
    #expect(page3.position == page1.position, "WS18/04 §6: page3 position == page1 position")

    // WS18: the three pages collectively cover all 7 items exactly once —
    // no overlap, no gap across the full result set.
    let allPageIDs = page1.rows.map(\.item.id)
        + page2.rows.map(\.item.id)
        + page3.rows.map(\.item.id)
    #expect(Set(allPageIDs) == Set(ids), "WS18: union of all pages == all 7 items")
    #expect(allPageIDs.count == 7, "WS18: exactly 7 rows across all pages")
}

/// WS18/04 §6 step 3: after any intervening commit, reusing an old cursor
/// fails with `.snapshotExpired(current:)` — the cursor's bound position no
/// longer equals the durable position. The `current:` argument is the new
/// position.
@Test func cursorExpiresAfterInterveningCommit() async throws {
    let storeURL = WSSupport.tempStoreURL("ws18-cursor-expiry")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    _ = try await Self.captureItems(history, count: 7)
    // Position is now 7; capture page1's continuation cursor (bound to 7).
    let page1 = try await history.browse(
        HistoryBrowseRequest(kind: .recent, limit: 3)
    )
    let staleCursor = try #require(page1.next, "WS18: page1 has a cursor to expire")
    #expect(page1.position.rawValue == 7, "WS18: page1 binds snapshot position 7")

    // WS18: commit any capture — an 8th distinct item advances the position
    // to 8 (04 §6 step 3: "any intervening commit expires the cursor").
    let extraReceipt = try await history.perform(
        .capture(WSSupport.textCapture(
            "ws18 extra item",
            observedAt: Date(timeIntervalSinceReferenceDate: 700_025_000),
            source: "com.example.ws18.extra"
        ))
    )
    guard case .committed(let extraCommit) = extraReceipt else {
        Issue.record("WS18: expected .committed for the intervening capture, got \(extraReceipt)")
        return
    }
    #expect(
        extraCommit.position.rawValue == 8,
        "WS18: the intervening capture advances the position to 8"
    )

    // WS18/04 §6 step 3: reusing the cursor bound to position 7 against the
    // new durable position 8 fails explicitly (no silent skip or repeat).
    await #expect(throws: HistoryFailure.snapshotExpired(current: ChangePosition(rawValue: 8))) {
        try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 3, after: staleCursor)
        )
    }
}

/// WS18/04 §6 step 1: a cursor whose query shape no longer matches the
/// request returns `.snapshotExpired(current:)` — not a silent skip. The
/// shape check binds the complete normalized query shape (kind, term+mode for
/// search, and limit).
@Test func cursorShapeMismatchAgainstSearchAndDifferentLimitExpires() async throws {
    let storeURL = WSSupport.tempStoreURL("ws18-cursor-shape")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    _ = try await Self.captureItems(history, count: 7)
    // Position is now 7; capture a recent(limit: 3) continuation cursor.
    let page1 = try await history.browse(
        HistoryBrowseRequest(kind: .recent, limit: 3)
    )
    let recentCursor = try #require(page1.next, "WS18: page1 has a cursor to test")

    // WS18/04 §6 step 1: a recent cursor against a .search request is a
    // shape mismatch (kind + term + mode differ) → `.snapshotExpired` (05
    // §16: "cursor shape … mismatch → `.snapshotExpired`").
    await #expect(throws: HistoryFailure.snapshotExpired(current: ChangePosition(rawValue: 7))) {
        try await history.browse(
            HistoryBrowseRequest(
                kind: .search(text: "ws18", mode: .exact),
                limit: 3,
                after: recentCursor
            )
        )
    }

    // WS18/04 §6 step 1: a recent(limit: 3) cursor against a recent(limit: 2)
    // request is also a shape mismatch (limit is part of the query shape) →
    // `.snapshotExpired`.
    await #expect(throws: HistoryFailure.snapshotExpired(current: ChangePosition(rawValue: 7))) {
        try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 2, after: recentCursor)
        )
    }
}

/// WS18/05 §14.1: the recent-page fetch merges two lanes — pinned (by
/// pinOrdinal ascending) then unpinned (by lastCopiedAt DESC). A
/// continuation cursor crosses from the pinned lane into the unpinned lane
/// with no duplication. The cursor binds the snapshot position (04 §6), so
/// both pages report the same ChangePosition.
@Test func pinnedUnpinnedLaneCrossingResumesWithoutDuplication() async throws {
    let storeURL = WSSupport.tempStoreURL("ws18-lane-crossing")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // Arrange: 3 items with strictly increasing observedAt (positions 1–3).
    let ids = try await Self.captureItems(history, count: 3)

    // Pin item 0 (oldest) first → pinOrdinal 0; pin item 1 → pinOrdinal 1.
    // Each pin is a History Commit: positions advance to 5.
    let pinA = try await history.perform(.placePinned(ids[0], at: .first))
    guard case .committed(let pinACommit) = pinA else {
        Issue.record("WS18: expected .committed for first pin, got \(pinA)")
        return
    }
    #expect(pinACommit.position.rawValue == 4, "WS18: first pin advances to position 4")
    let pinB = try await history.perform(.placePinned(ids[1], at: .last))
    guard case .committed(let pinBCommit) = pinB else {
        Issue.record("WS18: expected .committed for second pin, got \(pinB)")
        return
    }
    #expect(pinBCommit.position.rawValue == 5, "WS18: second pin advances to position 5")

    // WS18/05 §14.1: browse with limit 2 → page1 is the pinned lane
    // (pinOrdinal ascending): [ids[0], ids[1]].
    let page1 = try await history.browse(
        HistoryBrowseRequest(kind: .recent, limit: 2)
    )
    #expect(page1.rows.count == 2, "WS18: page1 has 2 pinned rows")
    #expect(
        page1.rows.map(\.item.id) == [ids[0], ids[1]],
        "WS18/05 §14.1: page1 is pinned lane (pinOrdinal ascending)"
    )
    #expect(
        page1.rows.allSatisfy { $0.pinnedPosition != nil },
        "WS18: page1 rows are all pinned"
    )
    let laneCursor = try #require(page1.next, "WS18: page1 has a continuation cursor")
    #expect(page1.position.rawValue == 5, "WS18: page1 binds snapshot position 5")

    // WS18/05 §14.1: page2 crosses into the unpinned lane — the remaining
    // item (ids[2], newest by observedAt) with no duplication of page1 rows.
    let page2 = try await history.browse(
        HistoryBrowseRequest(kind: .recent, limit: 2, after: laneCursor)
    )
    #expect(page2.rows.count == 1, "WS18: page2 has 1 unpinned row")
    #expect(
        page2.rows.map(\.item.id) == [ids[2]],
        "WS18/05 §14.1: page2 crosses into unpinned lane (ids[2])"
    )
    #expect(
        page2.rows.allSatisfy { $0.pinnedPosition == nil },
        "WS18: page2 rows are all unpinned"
    )
    #expect(page2.next == nil, "WS18: page2 is the last page")

    // WS18: no duplication across the lane crossing.
    #expect(
        Set(page1.rows.map(\.item.id))
            .isDisjoint(with: Set(page2.rows.map(\.item.id))),
        "WS18: pinned and unpinned pages share no rows"
    )

    // WS18/04 §6: the cursor binds the snapshot position — the continuation
    // page reports the same ChangePosition as page1.
    #expect(
        page2.position == page1.position,
        "WS18/04 §6: continuation position == page1 position"
    )
}
}
