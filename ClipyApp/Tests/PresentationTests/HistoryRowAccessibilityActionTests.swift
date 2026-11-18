/// The row's default activation and named actions each forward one intent.
/// SearchAndAccessibilityJourneyUITests exercises default activation through AXPress.
import Foundation
@testable import HistoryCore
@testable import ClipyApp
import Testing

@MainActor
struct HistoryRowAccessibilityActionTests {

    // MARK: - Router recorder

    /// Synchronous probe for the row's five callback lanes, shaped after
    /// `SynchronousPasteCallRecorder` in `ScriptedHistory.swift`: the row's
    /// callbacks are MainActor-isolated and the row is driven directly on
    /// the main actor, so hits are observable immediately — no actor hop,
    /// no `@unchecked Sendable`, no timed negative waits.
    @MainActor
    final class RowCallbackRecorder {
        private(set) var copies: [HistoryItemReference] = []
        private(set) var pins: [(id: HistoryItemID, placement: PinnedPlacement)] = []
        private(set) var unpins: [HistoryItemID] = []
        private(set) var removals: [HistoryItemID] = []
        private(set) var details: [HistoryItemReference] = []

        func recordCopy(_ item: HistoryItemReference) {
            copies.append(item)
        }

        func recordPin(_ id: HistoryItemID, at placement: PinnedPlacement) {
            pins.append((id, placement))
        }

        func recordUnpin(_ id: HistoryItemID) {
            unpins.append(id)
        }

        func recordRemove(_ id: HistoryItemID) {
            removals.append(id)
        }

        func recordDetails(_ item: HistoryItemReference) {
            details.append(item)
        }
    }

    /// Router-layer row: direct recorders behind every lane, an unpinned or
    /// pinned fixture row, and the list's default `.comfortable` density.
    /// `pinnedOrdinal` follows the list's own derivation (`position + 1`
    /// for pinned rows, `nil` for the Recent section; 03b §8).
    private func makeRoutedRow(
        _ row: HistoryRow,
        recorder: RowCallbackRecorder
    ) -> HistoryRowView {
        HistoryRowView(
            row: row,
            pinnedOrdinal: row.pinnedPosition.map { $0 + 1 },
            density: .comfortable,
            thumbnails: ThumbnailStore(history: ScriptedHistory()),
            onCopy: { recorder.recordCopy($0) },
            onPin: { id, placement in recorder.recordPin(id, at: placement) },
            onUnpin: { id in recorder.recordUnpin(id) },
            onRemove: { id in recorder.recordRemove(id) },
            onShowDetails: { recorder.recordDetails($0) }
        )
    }

    /// Asserts the one hit lane plus the four silent ones — the router
    /// contract is exclusivity: one activation, one callback, no side
    /// effects on the other intents (V2-07 §9).
    private func assertSoleLaneHit(
        _ recorder: RowCallbackRecorder,
        copies expectedCopies: [HistoryItemReference] = [],
        pins expectedPins: [(id: HistoryItemID, placement: PinnedPlacement)] = [],
        unpins expectedUnpins: [HistoryItemID] = [],
        removals expectedRemovals: [HistoryItemID] = [],
        details expectedDetails: [HistoryItemReference] = []
    ) {
        #expect(recorder.copies == expectedCopies)
        // Tuple element types cannot conform to Equatable, so the pins lane
        // is asserted field-by-field (the repo's existing tuple-array
        // discipline, e.g. SearchDebugInstrumentationTests zip/allSatisfy).
        #expect(recorder.pins.count == expectedPins.count)
        for (recorded, expected) in zip(recorder.pins, expectedPins) {
            #expect(recorded.id == expected.id)
            #expect(recorded.placement == expected.placement)
        }
        #expect(recorder.unpins == expectedUnpins)
        #expect(recorder.removals == expectedRemovals)
        #expect(recorder.details == expectedDetails)
    }

    // MARK: - Router layer (one action, one lane)

    /// Default activation (VoiceOver press / double-activation) is the
    /// paste hand-off: the row hands its exact `HistoryItemReference` to
    /// `onCopy` — the UI never touches the pasteboard itself
    /// (01 §5.6; 03b §12).
    @Test func defaultActionRoutesToPaste() {
        let row = fixtureRow(id: "00000000-0000-0000-0000-00000000B601", title: "ax-default-paste")
        let recorder = RowCallbackRecorder()

        makeRoutedRow(row, recorder: recorder).performAccessibilityAction(.paste)

        assertSoleLaneHit(recorder, copies: [row.item])
    }

    /// The rotor's Pin action on an UNPINNED row routes to
    /// `onPin(id, .first)` — the single state-changing pin operation
    /// assistive technology gets, never the menu's two placement variants
    /// (V2-07 §9; 03b §12 `.placePinned` example).
    @Test func namedPinRoutesUnpinnedRowToPinAtFirst() {
        let row = fixtureRow(id: "00000000-0000-0000-0000-00000000B602", title: "ax-pin-unpinned")
        let recorder = RowCallbackRecorder()

        makeRoutedRow(row, recorder: recorder).performAccessibilityAction(.togglePin)

        assertSoleLaneHit(
            recorder,
            pins: [(id: row.item.id, placement: .first)]
        )
    }

    /// The same rotor action on a PINNED row (pinnedPosition 0) flips to
    /// `onUnpin(id)` — the toggle is one action whose direction is derived
    /// from the row's own pinned state, exactly like the ⌘P shortcut
    /// (V2-07 §9; 03b §12 `.unpin` example). The action NAME stays private
    /// to the view; this pins the route, not the copy.
    @Test func namedPinRoutesPinnedRowToUnpin() {
        let row = fixtureRow(
            id: "00000000-0000-0000-0000-00000000B603",
            title: "ax-unpin-pinned",
            pinned: 0
        )
        let recorder = RowCallbackRecorder()

        makeRoutedRow(row, recorder: recorder).performAccessibilityAction(.togglePin)

        assertSoleLaneHit(recorder, unpins: [row.item.id])
    }

    /// The rotor's Remove action routes to `onRemove(id)` with the row's
    /// item ID — the same destructive intent as ⌫ and the menu's Remove
    /// (03b §12 `.remove` example).
    @Test func namedRemoveRoutesToRemove() {
        let row = fixtureRow(id: "00000000-0000-0000-0000-00000000B604", title: "ax-remove")
        let recorder = RowCallbackRecorder()

        makeRoutedRow(row, recorder: recorder).performAccessibilityAction(.remove)

        assertSoleLaneHit(recorder, removals: [row.item.id])
    }

    /// The rotor's Show Details action routes to `onShowDetails` with the
    /// row's exact reference — the same details push ⌘I and the menu's
    /// Show Details perform.
    @Test func namedShowDetailsRoutesToOnShowDetails() {
        let row = fixtureRow(id: "00000000-0000-0000-0000-00000000B605", title: "ax-show-details")
        let recorder = RowCallbackRecorder()

        makeRoutedRow(row, recorder: recorder).performAccessibilityAction(.showDetails)

        assertSoleLaneHit(recorder, details: [row.item])
    }
}
