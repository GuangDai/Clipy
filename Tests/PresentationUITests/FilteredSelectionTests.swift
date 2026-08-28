/// FilteredSelectionTests — wave-2 filter/selection consistency: with an
/// active type/pinned filter, keyboard selection walks the DISPLAYED lanes
/// (the same `displayedPinnedRows` + `displayedUnpinnedRows` arrays
/// HistoryListView renders) and can never land on — or Return-paste — an
/// invisible row; the open-session default retargets from a filtered-out
/// newest row to the newest displayed row; clearing the filter restores the
/// full authoritative walk. Driven through the scripted `ClipboardHistory`
/// double and the same `HistoryPanelSurfaceState` seams the panel view
/// calls, exactly like `PanelSessionSelectionTests`.
import Foundation
import HistoryCore
import PresentationUI
import Testing

@MainActor
struct FilteredSelectionTests {

    // MARK: - Arrow walk

    /// Arrows move through the displayed lanes only: the filtered-out image
    /// and link rows are skipped, and the walk clamps at the displayed
    /// boundaries exactly as `PanelSessionSelectionTests` pins for the
    /// unfiltered ordering.
    @Test func arrowsSkipFilteredOutRows() async {
        let (state, history) = activatedMixedState()
        #expect(await pollUntil { state.rows.count == 5 })

        let surface = beginSurfaceSession(rows: state.rows)
        // Default selection: the first authoritative row (pinned-text),
        // which the text filter keeps visible.
        #expect(surface.selection == state.rows[0].item.id)

        state.typeFilter = .text
        let displayed = displayedSelectionRows(of: state)
        #expect(displayed.map(\.title) == ["pinned-text", "recent-text"])

        surface.moveSelection(in: displayed, direction: .next)
        // pinned-image/link and recent-image/pdf are never visited.
        #expect(surface.selection == state.rows[2].item.id)
        surface.moveSelection(in: displayed, direction: .next)
        #expect(surface.selection == state.rows[2].item.id)
        surface.moveSelection(in: displayed, direction: .previous)
        #expect(surface.selection == state.rows[0].item.id)

        // A selection that predates the filter (a row the filter now hides)
        // recovers to the displayed boundary by direction instead of staying
        // on — and Return-pasting — an invisible row.
        surface.selection = state.rows[1].item.id
        surface.moveSelection(in: displayed, direction: .next)
        #expect(surface.selection == state.rows[0].item.id)
        surface.selection = state.rows[4].item.id
        surface.moveSelection(in: displayed, direction: .previous)
        #expect(surface.selection == state.rows[2].item.id)

        state.deactivate()
        await history.finishObservation()
    }

    /// With no filter active the displayed lanes ARE the authoritative rows
    /// (observation merges pinned-first, docs/03b-instruction-set.md §8), so
    /// the displayed walk is byte-identical to the pre-filter one.
    @Test func unfilteredDisplayedWalkIsTheAuthoritativeWalk() async {
        let (state, history) = activatedMixedState()
        #expect(await pollUntil { state.rows.count == 5 })

        #expect(state.typeFilter == .all)
        #expect(!state.showsPinnedOnly)
        #expect(displayedSelectionRows(of: state) == state.rows)

        let surface = beginSurfaceSession(rows: state.rows)
        surface.moveSelection(in: displayedSelectionRows(of: state), direction: .next)
        #expect(surface.selection == state.rows[1].item.id)
        surface.moveSelection(in: displayedSelectionRows(of: state), direction: .next)
        #expect(surface.selection == state.rows[2].item.id)

        state.deactivate()
        await history.finishObservation()
    }

    /// Clearing the filter restores the full walk: rows the filter skipped
    /// are visited again in authoritative order.
    @Test func clearedFilterRestoresTheFullWalk() async {
        let (state, history) = activatedMixedState()
        #expect(await pollUntil { state.rows.count == 5 })

        let surface = beginSurfaceSession(rows: state.rows)
        state.typeFilter = .text
        surface.moveSelection(
            in: displayedSelectionRows(of: state),
            direction: .next
        )
        // Under the filter the walk went pinned-text → recent-text.
        #expect(surface.selection == state.rows[2].item.id)

        state.typeFilter = .all
        #expect(displayedSelectionRows(of: state) == state.rows)
        surface.moveSelection(
            in: displayedSelectionRows(of: state),
            direction: .previous
        )
        // The full walk visits the rows the filter hid, in lane order.
        #expect(surface.selection == state.rows[1].item.id)

        state.deactivate()
        await history.finishObservation()
    }

    // MARK: - Default selection under a filter

    /// The open-session default picks the newest authoritative row; when the
    /// active filter hides that row the panel retargets to the newest
    /// DISPLAYED row (HistoryPanelView applies
    /// `retargetHiddenSelectionToDisplayedDefault` right after
    /// `beginSession`/`reconcileSessionSelection`).
    @Test func openDefaultRetargetsToNewestDisplayedRow() async {
        let (state, history) = activatedMixedState()
        #expect(await pollUntil { state.rows.count == 5 })

        // Pinned-only narrows the rendered set to the pinned lane; the
        // open default is still the first authoritative row (pinned-text).
        state.showsPinnedOnly = true
        let surface = beginSurfaceSession(rows: state.rows)
        #expect(surface.selection == state.rows[0].item.id)

        state.typeFilter = .links
        // The default (pinned-text) no longer renders; the retarget moves
        // the selection to the newest displayed row (pinned-link).
        surface.retargetHiddenSelectionToDisplayedDefault(
            displayedRows: displayedSelectionRows(of: state)
        )
        #expect(surface.selection == state.rows[1].item.id)

        state.deactivate()
        await history.finishObservation()
    }

    /// The empty-open path: the panel opens before the first page, the
    /// arriving page's reconcile picks the newest authoritative row, and the
    /// same retarget then lands on the newest displayed row.
    @Test func firstPageDefaultRetargetsToNewestDisplayedRow() async {
        let (state, history) = activatedMixedState()
        #expect(await pollUntil { state.rows.count == 5 })

        state.typeFilter = .text
        let surface = beginSurfaceSession(rows: [])
        #expect(surface.selection == nil)

        // The view's reconcile order: authoritative membership first (this
        // picks the newest authoritative row for the awaiting session), then
        // the displayed-default retarget.
        surface.reconcileSessionSelection(rows: state.rows)
        #expect(surface.selection == state.rows[0].item.id)
        surface.retargetHiddenSelectionToDisplayedDefault(
            displayedRows: displayedSelectionRows(of: state)
        )
        // rows[0] is pinned-text (visible), so this is a no-op …
        #expect(surface.selection == state.rows[0].item.id)

        // … and with the newest row filtered out the retarget retargets.
        state.showsPinnedOnly = true
        state.typeFilter = .links
        let second = beginSurfaceSession(rows: [])
        second.reconcileSessionSelection(rows: state.rows)
        #expect(second.selection == state.rows[0].item.id)
        second.retargetHiddenSelectionToDisplayedDefault(
            displayedRows: displayedSelectionRows(of: state)
        )
        #expect(second.selection == state.rows[1].item.id)

        state.deactivate()
        await history.finishObservation()
    }

    // MARK: - Retarget invariants

    /// A rendered selection is never moved by the retarget, a nil selection
    /// is never re-picked (an intentional clear after authoritative removal
    /// stays clear), and a filter matching nothing clears to no selection.
    @Test func retargetKeepsVisibleAndNilSelections() async {
        let (state, history) = activatedMixedState()
        #expect(await pollUntil { state.rows.count == 5 })

        let surface = beginSurfaceSession(rows: state.rows)

        // Visible selection: untouched.
        state.typeFilter = .links
        surface.selection = state.rows[1].item.id
        surface.retargetHiddenSelectionToDisplayedDefault(
            displayedRows: displayedSelectionRows(of: state)
        )
        #expect(surface.selection == state.rows[1].item.id)

        // Intentionally cleared: never re-picked.
        surface.selection = nil
        surface.retargetHiddenSelectionToDisplayedDefault(
            displayedRows: displayedSelectionRows(of: state)
        )
        #expect(surface.selection == nil)

        // A filter matching nothing leaves no selection to paste.
        state.showsPinnedOnly = true
        state.typeFilter = .images
        surface.selection = state.rows[0].item.id
        #expect(displayedSelectionRows(of: state).isEmpty)
        surface.retargetHiddenSelectionToDisplayedDefault(
            displayedRows: displayedSelectionRows(of: state)
        )
        #expect(surface.selection == nil)

        state.deactivate()
        await history.finishObservation()
    }

    // MARK: - Fixtures

    /// The displayed lanes in render order — the exact composition
    /// HistoryPanelView hands to the selection walk and the retarget.
    private func displayedSelectionRows(
        of state: HistoryViewState
    ) -> [HistoryRow] {
        state.displayedPinnedRows + state.displayedUnpinnedRows
    }

    /// One activated view state over a five-row mixed-type page in
    /// authoritative lane order (two pinned, three recent). The caller owns
    /// `deactivate`/`finishObservation`.
    private func activatedMixedState() -> (HistoryViewState, ScriptedHistory) {
        let history = ScriptedHistory(
            observedFirstPage: fixturePage(
                rows: [
                    filterSelectionRow(
                        id: "00000000-0000-0000-0000-00000000F201",
                        title: "pinned-text",
                        typeIdentifiers: ["public.utf8-plain-text"],
                        pinned: 0
                    ),
                    filterSelectionRow(
                        id: "00000000-0000-0000-0000-00000000F202",
                        title: "pinned-link",
                        typeIdentifiers: ["public.url"],
                        pinned: 1
                    ),
                    filterSelectionRow(
                        id: "00000000-0000-0000-0000-00000000F203",
                        title: "recent-text",
                        typeIdentifiers: ["public.utf16-plain-text"]
                    ),
                    filterSelectionRow(
                        id: "00000000-0000-0000-0000-00000000F204",
                        title: "recent-image",
                        typeIdentifiers: ["public.png"]
                    ),
                    filterSelectionRow(
                        id: "00000000-0000-0000-0000-00000000F205",
                        title: "recent-pdf",
                        typeIdentifiers: ["com.adobe.pdf"]
                    ),
                ],
                next: nil
            )
        )
        let state = HistoryViewState(history: history)
        state.activate()
        return (state, history)
    }

    /// One session-owning surface already begun over `rows` — the same
    /// composition AppDelegate and the panel view drive.
    private func beginSurfaceSession(
        rows: [HistoryRow]
    ) -> HistoryPanelSurfaceState {
        let surface = HistoryPanelSurfaceState(
            viewState: HistoryViewState(history: ScriptedHistory()),
            previewState: PreviewPaneState()
        )
        surface.beginSession(rows: rows)
        return surface
    }

    /// One canned row with explicit representation types — the same fixture
    /// shape as `HistoryRowFilteringTests`. Fixed UUID literals keep
    /// assertions readable; the force unwrap cannot fail for a well-formed
    /// literal, and a malformed one must fail loudly.
    private func filterSelectionRow(
        id rawValue: String,
        title: String,
        typeIdentifiers: [String],
        pinned: Int? = nil
    ) -> HistoryRow {
        HistoryRow(
            item: HistoryItemReference(
                id: HistoryItemID(rawValue: UUID(uuidString: rawValue)!),
                contentVersion: ContentVersion(rawValue: 1)
            ),
            title: title,
            typeIdentifiers: typeIdentifiers,
            lastCopiedAt: Date(timeIntervalSince1970: 1_787_000_000),
            copyCount: 1,
            lastSource: nil,
            pinnedPosition: pinned,
            search: nil
        )
    }
}
