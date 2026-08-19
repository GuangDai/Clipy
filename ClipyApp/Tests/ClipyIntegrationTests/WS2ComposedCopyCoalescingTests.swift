/// WS2Composed — Copy Coalescing through the composed app stack
/// (docs/06-cross-cutting.md §8 WS2; docs/roadmap/06-clipyapp.md
/// "Acceptance"): the same value copied twice (two pasteboard writes → two
/// adapter freezes) coalesces into ONE item through the real dedup/coalesce
/// commit path, with the occurrence folded and the row reflected by the real
/// PresentationUI `HistoryViewState` observe loop.
import AppKit
import Foundation
import HistoryCore
import HistoryStorage
import PasteboardAdapter
import PresentationUI
import Testing

struct WS2ComposedCopyCoalescingTests {

    /// WS2 (docs/06-cross-cutting.md §8): re-copying the same value (a new
    /// pasteboard changeCount with identical bytes, later observation)
    /// commits `.coalesced` at Change Position 2 with the SAME History Item
    /// ID and Content Version, occurrence count 2 with a monotone
    /// last-copied time, and no second row — and the panel's view state
    /// shows one row carrying copyCount 2 (03b §8).
    @Test @MainActor
    func secondCopyOfSameValueCoalescesIntoOneItemInViewState() async throws {
        try ComposedSupport.requireUsablePasteboard()
        let history = try await ComposedSupport.openMemoryHistory()

        let text = "clipy composed coalescing probe"
        let firstObservedAt = Date(timeIntervalSinceReferenceDate: 700_200_100)
        let secondObservedAt = Date(timeIntervalSinceReferenceDate: 700_200_220)
        let pasteboard = ComposedSupport.makePasteboard()
        let adapter = PasteboardAdapter(pasteboard: pasteboard)

        // First copy: insert (the WS1 path this gate builds on).
        ComposedSupport.setPasteboardContents(text, on: pasteboard)
        let firstCapture = try #require(adapter.capture(observedAt: firstObservedAt))
        let insertReceipt = try await history.perform(.capture(firstCapture))
        let inserted = try #require(
            ComposedSupport.insertedReference(from: insertReceipt, "WS2 arrange")
        )

        // Second copy: clearContents bumps the changeCount; identical bytes
        // under the identical type identifier (the byte-exact confirmation
        // behind Copy Coalescing, docs/02-domain.md D7), later observation.
        ComposedSupport.setPasteboardContents(text, on: pasteboard)
        let secondCapture = try #require(adapter.capture(observedAt: secondObservedAt))
        #expect(secondCapture.representations == firstCapture.representations)

        let receipt = try await history.perform(.capture(secondCapture))
        let commit = try #require(
            ComposedSupport.commit(of: receipt, "WS2"),
            "WS2: the repeat copy is a History Commit"
        )
        #expect(
            commit.position.rawValue == 2,
            "WS2: coalescing advances Change Position exactly once"
        )
        let coalesced = try #require(
            ComposedSupport.coalescedReference(from: receipt, "WS2")
        )
        #expect(coalesced.id == inserted.id, "WS2: same History Item ID")
        #expect(
            coalesced.contentVersion == inserted.contentVersion,
            "WS2: same Content Version — coalescing mints no version"
        )

        // Occurrence fold through the detail read (03b §9): count 2, first
        // observation untouched, last moved forward (monotone, 05 §9).
        let details = try await history.details(for: inserted.id)
        #expect(details.occurrence.count == 2)
        #expect(details.occurrence.firstCopiedAt == firstObservedAt)
        #expect(details.occurrence.lastCopiedAt == secondObservedAt)

        // No second row — asserted through the composed panel surface: the
        // REAL HistoryViewState observe loop (04 §5 snapshot replacement)
        // renders one row with copyCount 2.
        let viewState = HistoryViewState(history: history)
        defer { viewState.deactivate() }
        viewState.activate()
        let settled = await ComposedSupport.waitFor {
            viewState.rows.count == 1 && viewState.rows.first?.copyCount == 2
        }
        #expect(settled, "WS2: the view state observes one coalesced row")
        #expect(viewState.rows.first?.item.id == inserted.id)
        #expect(viewState.rows.first?.copyCount == 2)
        #expect(viewState.failure == nil)
    }
}
