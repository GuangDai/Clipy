/// WS-read-closure A — Step-7 closure of the DEFERRED public-read / observation
/// / no-emission clauses of WS1, WS2, WS5, WS6, WS7, WS8
/// (docs/06-cross-cutting.md §8; phasing note docs/roadmap/README.md §3:
/// "Several also carry public-read / observation / no-emission clauses checkable
/// only at step 7 (reads + observation)").
///
/// All six tests are facade-driven: they replay each gate's core arrange
/// through the public `SwiftDataHistory` facade and then assert the read clause
/// that was deferred from the step-5/6 commit-side tests:
///
/// - WS1 (§8 WS1): "an observed page containing the same reference" —
///   `observe(.recent)` first page contains the capture's reference.
/// - WS2 (§8 WS2): public-read occurrence-count / no-second-row —
///   `browse(.recent)` shows ONE row carrying the winner reference.
/// - WS5 (§8 WS5): no public emission on failure — a FAILED public action
///   (`.remove` on an absent id) publishes no observation; the pre-existing
///   first page is the only page a pre-registered `observe` stream yields.
/// - WS6 (§8 WS6): "Effective-derived … paste updated" — after a revision,
///   `pastePayload(for:)` returns the NEW Effective bytes and `details(for:)`
///   reflects the revised content (active-revision title + effective bytes).
/// - WS7 (§8 WS7): "no observation emission" — a same-content `.unchanged`
///   revision registered BEFORE the no-op yields only the first page.
/// - WS8 (§8 WS8): "assert public order" — after pin/reorder/unpin,
///   `browse(.recent)` row order is pinned-lane-then-unpinned-recency with
///   the exact `pinnedPosition` values.
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct WSReadClosureATests {

/// A `.replace` revision request (docs/03a-instruction-set.md §5) substituting
/// `bytes` for the item's single `public.utf8-plain-text` representation, based
/// on the OCC token `expected`.
private static func replaceTextRequest(
    itemID: HistoryItemID,
    expected: ContentVersion,
    bytes: Data
) -> RevisionRequest {
    RevisionRequest(
        itemID: itemID,
        expected: expected,
        intent: .replace(RevisionDraft(decisions: [
            RevisionDecision(
                typeIdentifier: "public.utf8-plain-text",
                action: .replace(bytes: bytes)
            ),
        ]))
    )
}

/// A `.replace` revision request whose only decision carries the Canonical
/// representation into Effective unchanged — byte-equal to the current
/// Effective Content of a Canonical-state item, so §11 step 5 turns it into a
/// no-op (docs/02-domain.md §2.5 rule 7).
private static func inheritCanonicalRequest(
    itemID: HistoryItemID,
    expected: ContentVersion
) -> RevisionRequest {
    RevisionRequest(
        itemID: itemID,
        expected: expected,
        intent: .replace(RevisionDraft(decisions: [
            RevisionDecision(
                typeIdentifier: "public.utf8-plain-text",
                action: .inheritCanonical
            ),
        ]))
    )
}

/// WS1 read clause (docs/06-cross-cutting.md §8 WS1): after a raw text capture
/// on an empty store, `observe(.recent)` yields a first page containing the
/// same reference (the step-7 observation clause deferred from
/// `WS1CaptureInsertTests`). The stream is drained to exactly one page and
/// terminated via `break` (the `onTermination` handler cancels the producer
/// task and unregisters the subscriber — no observer leaks).
@Test func observeRecentAfterRawCaptureYieldsFirstPageContainingSameReference() async throws {
    let storeURL = WSSupport.tempStoreURL("ws7-read-ws1-observe")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // Arrange (WS1 core): one normalized raw text capture on an empty store.
    let text = "ws7 read closure ws1 observe"
    let observedAt = Date(timeIntervalSinceReferenceDate: 700_030_000)
    let source = "com.example.ws7read.ws1"
    let receipt = try await history.perform(.capture(
        WSSupport.textCapture(text, observedAt: observedAt, source: source)
    ))
    guard case let .committed(commit) = receipt else {
        Issue.record("WS1 read: expected a .committed receipt, got \(receipt)")
        return
    }
    guard case let .inserted(reference) = commit.outcome else {
        Issue.record("WS1 read: expected .inserted(reference), got \(commit.outcome)")
        return
    }

    // Act: observe the recent lane. Registration completes inside `observe`
    // before the stream is returned (docs/04-coherence.md §5 step 1).
    let stream = await history.observe(HistoryObservationRequest(kind: .recent, limit: 10))

    // WS1: "an observed page containing the same reference" — the first page
    // carries exactly one row naming the capture's reference. Bounded drain:
    // break after one page terminates the stream cleanly.
    for try await page in stream {
        #expect(
            page.rows.count == 1,
            "WS1 (§8): observe first page contains exactly one row"
        )
        let row = try #require(page.rows.first)
        #expect(
            row.item.id == reference.id,
            "WS1 (§8): the observed row's reference matches the capture receipt"
        )
        #expect(
            row.item.contentVersion == reference.contentVersion,
            "WS1 (§8): the observed row's Content Version matches the receipt"
        )
        break
    }
}

/// WS2 read clause (docs/06-cross-cutting.md §8 WS2): after coalescing a repeat
/// capture, `browse(.recent)` shows ONE row carrying the winner reference (the
/// step-7 public-read occurrence-count / no-second-row clause deferred from
/// `WS2CopyCoalescingTests`).
@Test func browseRecentAfterCoalescingShowsOneRowWithWinnerReference() async throws {
    let storeURL = WSSupport.tempStoreURL("ws7-read-ws2-browse")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // Arrange (WS2 core): insert, then coalesce an identical re-capture.
    let text = "ws7 read closure ws2 coalesce"
    let firstObservedAt = Date(timeIntervalSinceReferenceDate: 700_030_100)
    let secondObservedAt = Date(timeIntervalSinceReferenceDate: 700_030_220)
    let firstSource = "com.example.ws7read.ws2.first"
    let secondSource = "com.example.ws7read.ws2.second"

    let insertReceipt = try await history.perform(.capture(
        WSSupport.textCapture(text, observedAt: firstObservedAt, source: firstSource)
    ))
    guard case let .committed(insertCommit) = insertReceipt,
          case let .inserted(insertedReference) = insertCommit.outcome
    else {
        Issue.record("WS2 read arrange: expected .committed(.inserted), got \(insertReceipt)")
        return
    }

    let coalesceReceipt = try await history.perform(.capture(
        WSSupport.textCapture(text, observedAt: secondObservedAt, source: secondSource)
    ))
    guard case let .committed(coalesceCommit) = coalesceReceipt,
          case let .coalesced(coalescedReference) = coalesceCommit.outcome
    else {
        Issue.record("WS2 read arrange: expected .committed(.coalesced), got \(coalesceReceipt)")
        return
    }
    #expect(coalescedReference.id == insertedReference.id)

    // Act: browse the recent lane.
    let page = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))

    // WS2: "no second row" + "same History Item ID" — the public browse page
    // shows exactly one row naming the coalesced winner.
    #expect(
        page.rows.count == 1,
        "WS2 (§8): browse shows exactly one row after coalescing"
    )
    let row = try #require(page.rows.first)
    #expect(
        row.item.id == insertedReference.id,
        "WS2 (§8): the browse row carries the winner reference"
    )
    // WS2: occurrence-count clause (public read) — count 2.
    #expect(
        row.copyCount == 2,
        "WS2 (§8): the browse row shows occurrence count 2"
    )
    // WS2: monotone last-copied time (public read).
    #expect(
        row.lastCopiedAt == secondObservedAt,
        "WS2 (§8): the browse row's lastCopiedAt moved forward"
    )
    // WS2: the page position matches the coalesce commit's position.
    #expect(
        page.position == coalesceCommit.position,
        "WS2 (§8): the browse page position matches the coalesce commit"
    )
}

/// WS5 read clause (docs/06-cross-cutting.md §8 WS5): no public emission on
/// failure — a FAILED public action (`.remove` on an absent id) followed by an
/// `observe(.recent)` stream yields only the pre-existing first page and
/// nothing else within a bounded drain. The observe loop yields only on
/// invalidation (docs/04-coherence.md §5 steps 6–8), and a failed action
/// publishes none (docs/04-coherence.md §4: "no invalidation for a failed
/// commit"), so no second page can arrive before the `break` terminates the
/// stream. (The direct-Authority over-bound WS5 store is a storage-side proof
/// already closed in `WS5DedupIndexUnavailableTests`; this is its public
/// no-emission companion.)
@Test func failedRemoveOnAbsentIDProducesNoObservationEmissionBeyondPreExistingFirstPage() async throws {
    let storeURL = WSSupport.tempStoreURL("ws7-read-ws5-no-emission")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // Arrange: one pre-existing item.
    let text = "ws7 read closure ws5 pre-existing"
    let observedAt = Date(timeIntervalSinceReferenceDate: 700_030_200)
    let captureReceipt = try await history.perform(.capture(
        WSSupport.textCapture(text, observedAt: observedAt, source: "com.example.ws7read.ws5")
    ))
    guard case let .committed(captureCommit) = captureReceipt,
          case let .inserted(reference) = captureCommit.outcome
    else {
        Issue.record("WS5 read arrange: expected .committed(.inserted), got \(captureReceipt)")
        return
    }
    let preExistingPosition = captureCommit.position

    // An absent ID (freshly minted, never captured) for the failed action.
    let absentID = HistoryItemID(rawValue: UUID())

    // Register the observer BEFORE the failed action (docs/04-coherence.md §5
    // step 1: subscribe before query). Registration completes inside `observe`.
    let stream = await history.observe(HistoryObservationRequest(kind: .recent, limit: 10))

    // Act: the failed public action — `.remove` on an absent id throws
    // `.notFound` (docs/02-domain.md §6). No commit, no invalidation
    // (docs/04-coherence.md §4).
    await #expect(throws: HistoryFailure.notFound(absentID)) {
        try await history.perform(.remove(absentID))
    }

    // WS5: "no … invalidation is produced" (public companion) — the observe
    // stream yields exactly the pre-existing first page and nothing more. The
    // inner loop blocks on the invalidation stream (§5 steps 6–8); the failed
    // action published no invalidation (§4), so no second page can arrive.
    // Breaking after one page terminates the stream cleanly
    // (`onTermination` → producer cancelled, subscriber unregistered).
    var pageCount = 0
    for try await page in stream {
        pageCount += 1
        #expect(
            page.rows.count == 1,
            "WS5 (§8): the pre-existing first page still shows one row"
        )
        let row = try #require(page.rows.first)
        #expect(
            row.item.id == reference.id,
            "WS5 (§8): the pre-existing first page carries the pre-existing item"
        )
        #expect(
            page.position == preExistingPosition,
            "WS5 (§8): the page position is unchanged from the pre-existing commit"
        )
        break
    }
    #expect(
        pageCount == 1,
        "WS5 (§8): a failed action produces no observation emission beyond the first page"
    )
}

/// WS6 read clause (docs/06-cross-cutting.md §8 WS6): after a byte-changing
/// revision, `pastePayload(for:)` returns the NEW Effective bytes (the "paste
/// updated" clause) and `details(for:)` reflects the revised content (active
/// revision title + effective bytes). These are the step-7 read clauses
/// deferred from `WS6RevisionOCCTests`.
@Test func pastePayloadReturnsNewEffectiveBytesAndDetailsReflectRevisionAfterRevision() async throws {
    let storeURL = WSSupport.tempStoreURL("ws7-read-ws6-paste-details")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // Arrange (WS6 core): capture text, then append a changing revision.
    let canonicalText = "ws7 read closure ws6 canonical"
    let revisedText = "ws7 read closure ws6 revised effective"
    let observedAt = Date(timeIntervalSinceReferenceDate: 700_030_300)
    let captureReceipt = try await history.perform(.capture(
        WSSupport.textCapture(canonicalText, observedAt: observedAt, source: "com.example.ws7read.ws6")
    ))
    guard case let .committed(captureCommit) = captureReceipt,
          case let .inserted(reference) = captureCommit.outcome
    else {
        Issue.record("WS6 read arrange: expected .committed(.inserted), got \(captureReceipt)")
        return
    }
    let itemID = reference.id
    let version1 = reference.contentVersion

    let reviseReceipt = try await history.perform(.revise(
        Self.replaceTextRequest(itemID: itemID, expected: version1, bytes: Data(revisedText.utf8))
    ))
    guard case let .committed(reviseCommit) = reviseReceipt,
          case let .revised(revisedReference) = reviseCommit.outcome
    else {
        Issue.record("WS6 read arrange: expected .committed(.revised), got \(reviseReceipt)")
        return
    }
    #expect(revisedReference.contentVersion.rawValue == 2)

    // Act + assert: pastePayload returns the NEW Effective bytes.
    let payload = try await history.pastePayload(for: itemID)
    #expect(
        payload.item.id == itemID,
        "WS6 (§8): paste payload names the revised item"
    )
    let pasteBytes = try #require(payload.representations.first(where: { $0.typeIdentifier == "public.utf8-plain-text" })?.bytes)
    #expect(
        pasteBytes == Data(revisedText.utf8),
        "WS6 (§8): paste payload carries the revised Effective bytes, not the Canonical bytes"
    )
    #expect(
        payload.lineageHint == itemID,
        "WS6 (§8): paste payload carries the item's lineage hint"
    )

    // Act + assert: details reflects the revision.
    let details = try await history.details(for: itemID)
    #expect(
        details.item.contentVersion == revisedReference.contentVersion,
        "WS6 (§8): details reference names the current Content Version"
    )
    // WS6: "Effective-derived … updated" — the effective bytes in details are
    // the revised bytes, not the Canonical bytes (revision never changes
    // Canonical Content, docs/02-domain.md §2.6).
    let effectiveBytes = try #require(details.effective.first(where: { $0.typeIdentifier == "public.utf8-plain-text" })?.bytes)
    #expect(
        effectiveBytes == Data(revisedText.utf8),
        "WS6 (§8): details effective content carries the revised bytes"
    )
    // Canonical bytes are untouched by the revision.
    let canonicalBytes = try #require(details.canonical.first(where: { $0.typeIdentifier == "public.utf8-plain-text" })?.bytes)
    #expect(
        canonicalBytes == Data(canonicalText.utf8),
        "WS6 (§8): details canonical content is untouched by the revision"
    )
    // WS6: the active revision summary's title reflects the revised text.
    let activeRevision = try #require(details.revisions.first(where: { $0.isActive }))
    #expect(
        activeRevision.title == revisedText,
        "WS6 (§8): the active revision's title reflects the revised Effective Content"
    )
    // Exactly one revision after one changing replace.
    #expect(
        details.revisions.count == 1,
        "WS6 (§8): details shows exactly one revision"
    )
}

/// WS7 read clause (docs/06-cross-cutting.md §8 WS7): "no observation emission"
/// — after a same-content `.unchanged` revision, an `observe` stream registered
/// BEFORE the no-op yields only the first page and nothing more. The observe
/// loop yields only on invalidation (§5 steps 6–8), and `.unchanged` is not a
/// History Commit so it publishes no invalidation (docs/02-domain.md §13;
/// docs/04-coherence.md §4), so no second page can arrive before the `break`.
@Test func sameContentRevisionNoOpYieldsNoObservationEmissionBeyondFirstPage() async throws {
    let storeURL = WSSupport.tempStoreURL("ws7-read-ws7-no-emission")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // Arrange (WS7 core): one Canonical-state item at Content Version 1.
    let text = "ws7 read closure ws7 no-op target"
    let observedAt = Date(timeIntervalSinceReferenceDate: 700_030_400)
    let captureReceipt = try await history.perform(.capture(
        WSSupport.textCapture(text, observedAt: observedAt, source: "com.example.ws7read.ws7")
    ))
    guard case let .committed(captureCommit) = captureReceipt,
          case let .inserted(reference) = captureCommit.outcome
    else {
        Issue.record("WS7 read arrange: expected .committed(.inserted), got \(captureReceipt)")
        return
    }
    let preNoOpPosition = captureCommit.position

    // Register the observer BEFORE the no-op (docs/04-coherence.md §5 step 1).
    let stream = await history.observe(HistoryObservationRequest(kind: .recent, limit: 10))

    // Act: a `.replace` draft whose only decision is `.inheritCanonical` on a
    // Canonical-state item — byte-equal to the current Effective Content, so
    // §11 step 5 turns it into a no-op (docs/02-domain.md §2.5 rule 7).
    let receipt = try await history.perform(.revise(
        Self.inheritCanonicalRequest(itemID: reference.id, expected: reference.contentVersion)
    ))
    guard case .unchanged = receipt else {
        Issue.record("WS7 read: expected a .unchanged receipt, got \(receipt)")
        return
    }

    // WS7: "no observation emission" — the observe stream yields exactly the
    // first page and nothing more. The inner loop blocks on the invalidation
    // stream; `.unchanged` published no invalidation (§4, §13), so no second
    // page can arrive before the `break` terminates the stream.
    var pageCount = 0
    for try await page in stream {
        pageCount += 1
        #expect(
            page.rows.count == 1,
            "WS7 (§8): the first page reflects the unchanged single-item state"
        )
        let row = try #require(page.rows.first)
        #expect(
            row.item.id == reference.id,
            "WS7 (§8): the first page carries the no-op target item"
        )
        #expect(
            page.position == preNoOpPosition,
            "WS7 (§8): the page position is unchanged — no commit, no advance"
        )
        break
    }
    #expect(
        pageCount == 1,
        "WS7 (§8): a same-content no-op revision produces no observation emission"
    )
}

/// WS8 read clause (docs/06-cross-cutting.md §8 WS8): "assert public order" —
/// after pinning three items, moving the last before the first, and unpinning
/// the middle, `browse(.recent)` row order equals the pinned-lane order (by
/// ordinal) then unpinned recency, with the exact expected `pinnedPosition`
/// values (the step-7 public-read clause deferred from `WS8PinOrderTests`).
@Test func browseRecentAfterPinReorderUnpinShowsPinnedLaneOrderThenUnpinnedRecency() async throws {
    let storeURL = WSSupport.tempStoreURL("ws7-read-ws8-browse-order")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // Arrange (WS8 core): three distinct captures at monotone fixed times.
    let observedA = Date(timeIntervalSinceReferenceDate: 700_030_500)
    let observedB = Date(timeIntervalSinceReferenceDate: 700_030_600)
    let observedC = Date(timeIntervalSinceReferenceDate: 700_030_700)
    let captureA = try await history.perform(.capture(
        WSSupport.textCapture("ws7 read ws8 item a", observedAt: observedA, source: "com.example.ws7read.ws8.a")
    ))
    guard case let .committed(commitA) = captureA,
          case let .inserted(referenceA) = commitA.outcome
    else {
        Issue.record("WS8 read arrange: expected .committed(.inserted) for a, got \(captureA)")
        return
    }
    let captureB = try await history.perform(.capture(
        WSSupport.textCapture("ws7 read ws8 item b", observedAt: observedB, source: "com.example.ws7read.ws8.b")
    ))
    guard case let .committed(commitB) = captureB,
          case let .inserted(referenceB) = commitB.outcome
    else {
        Issue.record("WS8 read arrange: expected .committed(.inserted) for b, got \(captureB)")
        return
    }
    let captureC = try await history.perform(.capture(
        WSSupport.textCapture("ws7 read ws8 item c", observedAt: observedC, source: "com.example.ws7read.ws8.c")
    ))
    guard case let .committed(commitC) = captureC,
          case let .inserted(referenceC) = commitC.outcome
    else {
        Issue.record("WS8 read arrange: expected .committed(.inserted) for c, got \(captureC)")
        return
    }
    let idA = referenceA.id
    let idB = referenceB.id
    let idC = referenceC.id

    // Pin all three with `.last` (a→0, b→1, c→2).
    _ = try await history.perform(.placePinned(idA, at: .last))
    _ = try await history.perform(.placePinned(idB, at: .last))
    _ = try await history.perform(.placePinned(idC, at: .last))

    // Move the last before the first: [a, b, c] → [c, a, b].
    _ = try await history.perform(.placePinned(idC, at: .before(idA)))

    // Unpin the item now occupying the middle position (a): [c, b] + a unpinned.
    _ = try await history.perform(.unpin(idA))

    // Act: browse the recent lane.
    let page = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))

    // WS8: "assert public order" — pinned lane first (by ordinal: c→0, b→1),
    // then unpinned by recency (a, the only unpinned item). The exact expected
    // ID sequence is [c, b, a] and pinnedPosition values are [0, 1, nil].
    let rowIDs = page.rows.map(\.item.id)
    #expect(
        rowIDs == [idC, idB, idA],
        "WS8 (§8): browse row order is pinned-lane-then-unpinned-recency [c, b, a]"
    )
    let pinnedPositions = page.rows.map(\.pinnedPosition)
    #expect(
        pinnedPositions == [0, 1, nil],
        "WS8 (§8): pinnedPosition values are [0, 1, nil] for the pinned-then-unpinned order"
    )
    // WS8: "Content Versions remain unchanged" — pin/reorder/unpin never
    // advances Content Version (docs/02-domain.md §13: `.assignPin` preserves).
    #expect(
        page.rows.map(\.item.contentVersion.rawValue) == [1, 1, 1],
        "WS8 (§8): all three rows remain at Content Version 1"
    )
}
}
