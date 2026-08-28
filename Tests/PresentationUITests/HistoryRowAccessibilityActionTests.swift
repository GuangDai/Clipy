/// HistoryRowAccessibilityActionTests — the row's accessibility activation
/// surface converges on the SAME intents the panel's selection shortcuts
/// already route: default/named AX activation and ⏎ (copy), ⌫ (remove),
/// ⌘P (pin toggle), ⌘I (details) all dispatch through
/// `HistoryRowView.performAccessibilityAction` into the identical
/// `HistoryViewState` wiring `HistoryListView.rowContent` installs
/// (docs/v2/V2-07-ux.md §9; docs/01-architecture.md §5.6 paste hand-off;
/// docs/03b-instruction-set.md §12 mutating caller examples).
///
/// Three layers, mirroring the suite conventions of
/// `HistoryViewStateTests`: (1) ROUTER tests hand the row direct recorders
/// and pin each `HistoryRowAccessibilityAction` case to exactly one
/// callback lane; (2) one INTENT test wires the row verbatim as the list
/// does against a real `HistoryViewState` + `ScriptedHistory` and asserts
/// the paste hand-off and the recorded `HistoryAction`s; (3) one GUARD
/// FINGERPRINT test proves the paste route keeps the displayed-row
/// admission fence — synchronously, with no timed negative wait.
///
/// Residual risk, accepted: the router/intent layers drive the dispatch
/// method, not the four `accessibilityAction` modifier shells in `body` —
/// their equivalence to the dispatch table is guaranteed by inspection
/// only. The default action does have an end-to-end external pin: the
/// running-app `kAXPressAction` journey in
/// `SearchAndAccessibilityJourneyUITests` presses a real row and observes
/// the paste. The three NAMED actions have no equivalent runtime journey.
import Foundation
import HistoryCore
import PresentationUI
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
            now: Date(timeIntervalSince1970: 1_787_000_100),
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

    // MARK: - Intent layer (the list's verbatim wiring)

    /// AX activations and the selection shortcuts are ONE intent set: with
    /// the exact closures `HistoryListView.rowContent` installs, default
    /// activation lands in `onPaste` with the displayed row's reference,
    /// the pin toggle forwards `.placePinned(id, at: .first)`, Remove
    /// forwards `.remove(id)`, and Show Details reaches the panel-injected
    /// details closure (01 §5.6; 03b §12; V2-07 §9). `onShowDetails` is
    /// the one lane the list passes through from its caller; the recorder
    /// plays that injected role here.
    @Test func accessibilityActionsRouteThroughTheListIntentWiring() async {
        let row = fixtureRow(id: "00000000-0000-0000-0000-00000000B606", title: "ax-intent-row")
        let history = ScriptedHistory(
            observedFirstPage: fixturePage(rows: [row], next: nil)
        )
        let state = HistoryViewState(history: history)
        let pastes = SynchronousPasteCallRecorder()
        state.onPaste = { item in
            pastes.record(item)
        }
        let detailsRecorder = RowCallbackRecorder()
        state.activate()
        #expect(await pollUntil { state.rows == [row] })

        // Verbatim `HistoryListView.rowContent` wiring: onCopy admits
        // through the displayed-row fence, and the mutations go through
        // the same view-state methods ⌘P/⌫ use.
        let rowView = HistoryRowView(
            row: row,
            now: Date(timeIntervalSince1970: 1_787_000_100),
            pinnedOrdinal: nil,
            density: .comfortable,
            thumbnails: ThumbnailStore(history: history),
            onCopy: { state.requestPasteFromDisplayedRow($0) },
            onPin: { id, placement in state.pin(id, at: placement) },
            onUnpin: { id in state.unpin(id) },
            onRemove: { id in state.remove(id) },
            onShowDetails: { detailsRecorder.recordDetails($0) }
        )

        rowView.performAccessibilityAction(.paste)
        // requestPasteFromDisplayedRow → onPaste is synchronous and
        // MainActor-isolated, so the hit needs no poll.
        #expect(pastes.received == [row.item])

        rowView.performAccessibilityAction(.togglePin)
        #expect(
            await pollUntil {
                await history.performActions.contains { action in
                    if case .placePinned(let id, at: .first) = action {
                        return id == row.item.id
                    }
                    return false
                }
            }
        )

        rowView.performAccessibilityAction(.remove)
        #expect(
            await pollUntil {
                await history.performActions.contains { action in
                    if case .remove(let id) = action { return id == row.item.id }
                    return false
                }
            }
        )

        rowView.performAccessibilityAction(.showDetails)
        #expect(detailsRecorder.details == [row.item])

        state.deactivate()
        await history.finishObservation()
    }

    // MARK: - Guard fingerprint

    /// The paste route keeps the displayed-row admission fence: before
    /// `activate()` there are no authoritative rows, so a default AX
    /// activation through wiring verbatim to the list's is rejected by
    /// `requestPasteFromDisplayedRow`'s `rows.contains` guard and `onPaste`
    /// never fires — provable synchronously, with no timed negative wait.
    /// This is the verbatim wiring's fingerprint: if the row's closure ever
    /// drifts to the guard-free public `requestPaste`, this turns red. (The
    /// list's own private `rowContent` is not rendered here; its closure is
    /// pinned verbatim by the INTENT test above.)
    @Test func unactivatedStatePasteActivationKeepsPasteRecorderEmpty() {
        let row = fixtureRow(id: "00000000-0000-0000-0000-00000000B607", title: "never-activated")
        let state = HistoryViewState(history: ScriptedHistory())
        let pastes = SynchronousPasteCallRecorder()
        state.onPaste = { item in
            pastes.record(item)
        }
        #expect(state.rows.isEmpty)

        let rowView = HistoryRowView(
            row: row,
            now: Date(timeIntervalSince1970: 1_787_000_100),
            pinnedOrdinal: nil,
            density: .comfortable,
            thumbnails: ThumbnailStore(history: ScriptedHistory()),
            onCopy: { state.requestPasteFromDisplayedRow($0) },
            onPin: { id, placement in state.pin(id, at: placement) },
            onUnpin: { id in state.unpin(id) },
            onRemove: { id in state.remove(id) },
            onShowDetails: { _ in }
        )

        rowView.performAccessibilityAction(.paste)

        #expect(state.rows.isEmpty)
        #expect(pastes.received.isEmpty)
    }
}
