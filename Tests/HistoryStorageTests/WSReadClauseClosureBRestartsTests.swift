/// WS read-clause closure proofs, part 2: WS14/WS16/WS19/WS21.
/// Split out of WSReadClauseClosureBTests.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

extension WSReadClauseClosureBTests {
// MARK: - WS14 (docs/06-cross-cutting.md §8, step-7 read clause)

/// WS14 (docs/06-cross-cutting.md §8): after insert, coalesce, and a revision,
/// reopen the store and assert `browse(.recent)` + `details` results equal the
/// pre-restart public results — the reads are reconstructed purely from durable
/// state (docs/05-authority-kernel.md §13).
@Test func browseAndDetailsAfterRestartEqualPreRestartResults() async throws {
    let storeURL = WSSupport.tempStoreURL("ws14-read-clause")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    let source = "com.example.ws14r"
    let plainText = "public.utf8-plain-text"

    // Capture item A at version 1.
    guard let refA = await Self.captureText(
        history, "ws14 read alpha",
        observedAt: Date(timeIntervalSinceReferenceDate: 700_530_000),
        source: "\(source).a1", clause: "WS14 arrange A"
    ) else { return }

    // Capture item B.
    guard let refB = await Self.captureText(
        history, "ws14 read bravo",
        observedAt: Date(timeIntervalSinceReferenceDate: 700_530_100),
        source: "\(source).b", clause: "WS14 arrange B"
    ) else { return }

    // Revise A: replace its effective bytes (version 1 → 2).
    let revisedText = "ws14 read alpha revised"
    let reviseReceipt = try await history.perform(.revise(RevisionRequest(
        itemID: refA.id,
        expected: refA.contentVersion,
        intent: .replace(RevisionDraft(decisions: [
            RevisionDecision(
                typeIdentifier: plainText,
                action: .replace(bytes: Data(revisedText.utf8))
            ),
        ]))
    )))
    guard case let .committed(reviseCommit) = reviseReceipt,
          case .revised = reviseCommit.outcome else {
        Issue.record("WS14 arrange: expected .committed(.revised), got \(reviseReceipt)")
        return
    }

    // Capture the PRE-RESTART public results into local values.
    let preRestartPage = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
    let preRestartDetailsA = try await history.details(for: refA.id)
    let preRestartDetailsB = try await history.details(for: refB.id)

    // RESTART: reopen the facade over the same on-disk store
    // (docs/05-authority-kernel.md §13 startup reruns).
    let restartedHistory = try await WSSupport.openHistory(storeURL: storeURL)

    // WS14: post-restart `browse(.recent)` equals the pre-restart result
    // (docs/06-cross-cutting.md §8 WS14). HistoryPage is Equatable; all fields
    // (position, rows, next) are derived from the same durable state.
    let postRestartPage = try await restartedHistory.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
    #expect(
        postRestartPage == preRestartPage,
        "WS14: browse(.recent) results equal pre-restart public results"
    )

    // WS14: post-restart `details` for A equals the pre-restart result —
    // canonical bytes, effective bytes, revision lineage, occurrence, and pin
    // position all reconstruct from durable blobs and scalar fields.
    let postRestartDetailsA = try await restartedHistory.details(for: refA.id)
    #expect(
        postRestartDetailsA == preRestartDetailsA,
        "WS14: details(for: A) results equal pre-restart public results"
    )

    // WS14: post-restart `details` for B (a Canonical-state item with no
    // revisions) also matches.
    let postRestartDetailsB = try await restartedHistory.details(for: refB.id)
    #expect(
        postRestartDetailsB == preRestartDetailsB,
        "WS14: details(for: B) results equal pre-restart public results"
    )
}

// MARK: - WS16 (docs/06-cross-cutting.md §8, step-7 read clause)

/// WS16 (docs/06-cross-cutting.md §8): after `perform(.remove(id))`, the ID is
/// absent from `browse(.recent)` and `details(for:)` / `pastePayload(for:)`
/// throw `.notFound(id)` (docs/06-cross-cutting.md §8 WS16; docs/02-domain.md
/// §6 — the detail/paste planners reject a missing target as `.notFound`).
@Test func removedIDAbsentFromBrowseAndDetailsPastePayloadThrowNotFound() async throws {
    let storeURL = WSSupport.tempStoreURL("ws16-read-clause")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // Arrange: capture one item, then remove it.
    let source = "com.example.ws16r"
    guard let ref = await Self.captureText(
        history, "ws16 read target",
        observedAt: Date(timeIntervalSinceReferenceDate: 700_540_000),
        source: source, clause: "WS16 arrange"
    ) else { return }

    let removeReceipt = try await history.perform(.remove(ref.id))
    guard case let .committed(removeCommit) = removeReceipt,
          case .removed(count: 1) = removeCommit.outcome else {
        Issue.record("WS16 arrange: expected .committed(.removed(count: 1)), got \(removeReceipt)")
        return
    }

    // WS16: "the ID absent from subsequent browse" — the removed item does not
    // appear in `browse(.recent)` (docs/06-cross-cutting.md §8 WS16).
    let page = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
    #expect(
        page.rows.allSatisfy { $0.item.id != ref.id },
        "WS16: the removed ID is absent from browse(.recent)"
    )
    #expect(
        page.rows.isEmpty,
        "WS16: browse(.recent) shows zero rows after removing the only item"
    )

    // WS16: "detail/paste" on the absent ID returns `.notFound`
    // (docs/06-cross-cutting.md §8 WS16; docs/02-domain.md §6).
    await #expect(throws: HistoryFailure.notFound(ref.id)) {
        try await history.details(for: ref.id)
    }
    await #expect(throws: HistoryFailure.notFound(ref.id)) {
        try await history.pastePayload(for: ref.id)
    }
}

// MARK: - WS19 (docs/06-cross-cutting.md §8, step-7 read clause)

/// WS19 (docs/06-cross-cutting.md §8): after the out-of-order coalesce — an
/// identical capture whose `observedAt` is earlier than the stored
/// `lastCopiedAt` — `browse(.recent)` shows one row with the winner unchanged:
/// same ID, preserved Content Version, incremented occurrence count, and
/// `lastCopiedAt` held at the later time (docs/02-domain.md §3.1).
@Test func browseShowsOneRowAfterOutOfOrderCoalesceWithWinnerUnchanged() async throws {
    let storeURL = WSSupport.tempStoreURL("ws19-read-clause")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    let text = "ws19 read out-of-order probe"
    // t1 < t2: the repeat observation arrives OUT OF ORDER.
    let laterObservedAt = Date(timeIntervalSinceReferenceDate: 700_550_900) // t2
    let earlierObservedAt = Date(timeIntervalSinceReferenceDate: 700_550_100) // t1
    let source = "com.example.ws19r"

    // Arrange: first capture at the LATER time t2.
    guard let insertedRef = await Self.captureText(
        history, text,
        observedAt: laterObservedAt,
        source: source, clause: "WS19 arrange"
    ) else { return }

    // Act: identical capture at t1 < t2, no source — coalesces without moving
    // recency or source backward (docs/02-domain.md §3.1).
    let coalesceReceipt = try await history.perform(.capture(
        WSSupport.textCapture(text, observedAt: earlierObservedAt)
    ))
    guard case let .committed(commit) = coalesceReceipt,
          case .coalesced = commit.outcome else {
        Issue.record("WS19: expected .committed(.coalesced), got \(coalesceReceipt)")
        return
    }

    // WS19: `browse(.recent)` shows one row — the winner unchanged.
    let page = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
    #expect(
        page.rows.count == 1,
        "WS19: browse shows one row after out-of-order coalesce"
    )
    let row = try #require(page.rows.first)
    // WS19: "the winner ID is unchanged" (docs/06-cross-cutting.md §8 WS19).
    #expect(
        row.item.id == insertedRef.id,
        "WS19: the winner ID is unchanged"
    )
    // WS19: Content Version preserved by the coalesce (docs/02-domain.md §13).
    #expect(
        row.item.contentVersion == insertedRef.contentVersion,
        "WS19: Content Version is preserved"
    )
    // WS19: "occurrence count increments" (docs/02-domain.md §3.1).
    #expect(
        row.copyCount == 2,
        "WS19: the occurrence count incremented to 2"
    )
    // WS19: "lastCopiedAt does not move backward" (docs/02-domain.md §3.1).
    #expect(
        row.lastCopiedAt == laterObservedAt,
        "WS19: lastCopiedAt stayed at t2 (no backward move)"
    )
}

// MARK: - WS21 (docs/06-cross-cutting.md §8, step-7 read clause)

/// WS21 (docs/06-cross-cutting.md §8): after `setRetentionPolicy` lowers the
/// cap below the current unpinned count, `browse(.recent)` shows exactly the
/// policy-surviving rows — the newest item alone survives when the cap is
/// lowered to 1 (docs/02-domain.md §12 eviction order: `lastCopiedAt`
/// ascending).
@Test func browseShowsPolicySurvivorsAfterRetentionPolicyCommit() async throws {
    let storeURL = WSSupport.tempStoreURL("ws21-read-clause")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // Three unpinned captures with strictly increasing observation times:
    // eviction order is `lastCopiedAt` ascending (docs/02-domain.md §12),
    // so alpha and bravo are the victims and charlie is the survivor.
    let source = "com.example.ws21r"
    guard (await Self.captureText(
        history, "ws21 read alpha",
        observedAt: Date(timeIntervalSinceReferenceDate: 700_560_000),
        source: source, clause: "WS21 arrange alpha"
    )) != nil else { return }
    guard (await Self.captureText(
        history, "ws21 read bravo",
        observedAt: Date(timeIntervalSinceReferenceDate: 700_560_100),
        source: source, clause: "WS21 arrange bravo"
    )) != nil else { return }
    guard let charlieRef = await Self.captureText(
        history, "ws21 read charlie",
        observedAt: Date(timeIntervalSinceReferenceDate: 700_560_200),
        source: source, clause: "WS21 arrange charlie"
    ) else { return }

    // Lower the cap to 1: the two oldest unpinned items retire in the same
    // History Commit (docs/02-domain.md §12, §13).
    let receipt = try await history.perform(.setRetentionPolicy(maximumUnpinnedItems: 1))
    guard case let .committed(commit) = receipt,
          case let .retentionPolicySet(removedCount) = commit.outcome else {
        Issue.record("WS21: expected .committed(.retentionPolicySet(removedCount:)), got \(receipt)")
        return
    }
    // WS21: two oldest items retired (alpha and bravo).
    #expect(
        removedCount == 2,
        "WS21: two oldest unpinned items retired in the same commit"
    )

    // WS21: `browse(.recent)` shows exactly the one policy-surviving row —
    // charlie, the newest item (docs/06-cross-cutting.md §8 WS21).
    let page = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
    #expect(
        page.rows.count == 1,
        "WS21: browse shows exactly the one policy survivor"
    )
    let row = try #require(page.rows.first)
    #expect(
        row.item.id == charlieRef.id,
        "WS21: the survivor is the newest item (charlie)"
    )
}
}
