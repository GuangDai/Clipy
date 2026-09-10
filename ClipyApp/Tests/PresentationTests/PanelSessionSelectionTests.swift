/// PanelSessionSelectionTests.swift — Card 14A's pure open/reopen and
/// keyboard-selection contract. The first displayed row is the newest item
/// in the authoritative ordering; arrows clamp at the visible boundaries.
@testable import HistoryCore
@testable import ClipyApp
import Testing

@MainActor
struct PanelSessionSelectionTests {
    private let rows = [
        fixtureRow(
            id: "00000000-0000-0000-0000-000000001401",
            title: "newest"
        ),
        fixtureRow(
            id: "00000000-0000-0000-0000-000000001402",
            title: "middle"
        ),
        fixtureRow(
            id: "00000000-0000-0000-0000-000000001403",
            title: "oldest"
        ),
    ]

    @Test func openSelectsNewestAndEmptyOpenSelectsNothing() {
        #expect(PanelSessionSelection.preparedSelection(in: rows) == rows[0].item.id)
        #expect(PanelSessionSelection.preparedSelection(in: []) == nil)
    }

    @Test func detailsAndItsInlineEditorCannotSubmitTheRetainedListSelection() {
        let surface = HistoryPanelSurfaceState(
            viewState: HistoryViewState(history: ScriptedHistory()),
            previewState: PreviewPaneState()
        )
        surface.beginSession(rows: rows)
        #expect(surface.selectedReference(in: rows) == rows[0].item)

        // The search header remains above a pushed Details destination. Its
        // Return callback must not paste the list's old selection, including
        // while Details switches its own content to the inline editor.
        surface.detailsPath = [rows[1].item]
        #expect(surface.selection == rows[0].item.id)
        #expect(surface.selectedReference(in: rows) == nil)

        surface.detailsPath = []
        #expect(surface.selectedReference(in: rows) == rows[0].item)
        surface.endSession()
    }

    @Test func arrowsMoveAndClampInAuthoritativeDisplayOrder() {
        let newest = rows[0].item.id
        let middle = rows[1].item.id
        let oldest = rows[2].item.id

        #expect(
            PanelSessionSelection.movedSelection(
                newest,
                in: rows,
                direction: .next
            ) == middle
        )
        #expect(
            PanelSessionSelection.movedSelection(
                middle,
                in: rows,
                direction: .next
            ) == oldest
        )
        #expect(
            PanelSessionSelection.movedSelection(
                oldest,
                in: rows,
                direction: .next
            ) == oldest
        )
        #expect(
            PanelSessionSelection.movedSelection(
                newest,
                in: rows,
                direction: .previous
            ) == newest
        )
    }

    @Test func missingSelectionRecoversToBoundaryByDirection() {
        let missing = fixtureRow(
            id: "00000000-0000-0000-0000-000000001404",
            title: "missing"
        ).item.id
        #expect(
            PanelSessionSelection.movedSelection(
                missing,
                in: rows,
                direction: .next
            ) == rows[0].item.id
        )
        #expect(
            PanelSessionSelection.movedSelection(
                nil,
                in: rows,
                direction: .previous
            ) == rows[2].item.id
        )
    }

    @Test func surfaceOwnsOneOpenCloseSessionGeneration() {
        let viewState = HistoryViewState(history: ScriptedHistory())
        let previewState = PreviewPaneState()
        let surface = HistoryPanelSurfaceState(
            viewState: viewState,
            previewState: previewState
        )

        surface.beginSession(rows: rows)
        #expect(surface.isSessionActive)
        #expect(surface.sessionGeneration == 1)
        #expect(surface.selection == rows[0].item.id)

        surface.moveSelection(in: rows, direction: .next)
        #expect(surface.selection == rows[1].item.id)

        surface.endSession()
        #expect(!surface.isSessionActive)
        #expect(surface.selection == nil)

        surface.endSession()
        #expect(surface.sessionGeneration == 1)

        surface.beginSession(rows: rows)
        #expect(surface.sessionGeneration == 2)
        #expect(surface.selection == rows[0].item.id)
    }

    @Test func authoritativeReplacementClearsRemovedSelectionWithoutJumping() {
        let viewState = HistoryViewState(history: ScriptedHistory())
        let surface = HistoryPanelSurfaceState(
            viewState: viewState,
            previewState: PreviewPaneState()
        )

        surface.beginSession(rows: rows)
        surface.moveSelection(in: rows, direction: .next)
        let selectedID = rows[1].item.id
        #expect(surface.selection == selectedID)
        #expect(surface.selectedReference(in: rows)?.id == selectedID)

        let replacement = [rows[0], rows[2]]

        // The displayed rows are already authoritative when SwiftUI schedules
        // its onChange reconciliation. AppDelegate's Return action target must
        // therefore disable immediately rather than execute the stale ID.
        #expect(surface.selectedReference(in: replacement) == nil)
        surface.reconcileSessionSelection(rows: replacement)

        #expect(surface.selection == nil)
        #expect(surface.selectedReference(in: replacement) == nil)

        surface.reconcileSessionSelection(rows: rows)
        #expect(
            surface.selection == nil,
            "A later page must not turn an intentional clear into a new selection."
        )
    }

    @Test func queryRestartLoadingGapDoesNotMasqueradeAsAuthoritativeRemoval() {
        let viewState = HistoryViewState(history: ScriptedHistory())
        let surface = HistoryPanelSurfaceState(
            viewState: viewState,
            previewState: PreviewPaneState()
        )

        surface.beginSession(rows: rows)
        surface.moveSelection(in: rows, direction: .next)
        let selectedID = rows[1].item.id
        #expect(surface.selection == selectedID)

        // HistoryViewState clears rows synchronously while a replacement
        // observation is loading. This is a generation transition, not an
        // authoritative statement that the selected item was removed.
        surface.reconcileSessionSelection(
            rows: [],
            hasAuthoritativeFirstPage: false
        )
        #expect(surface.selection == selectedID)

        // Once the replacement settles, absence is authoritative. Selection
        // clears and a later page must not silently jump back to newest.
        let replacement = [rows[0], rows[2]]
        surface.reconcileSessionSelection(
            rows: replacement,
            hasAuthoritativeFirstPage: true
        )
        #expect(surface.selection == nil)

        surface.reconcileSessionSelection(
            rows: rows,
            hasAuthoritativeFirstPage: true
        )
        #expect(surface.selection == nil)
    }

    @Test func authoritativeEmptyReplacementClearsAfterLoadingSettles() {
        let viewState = HistoryViewState(history: ScriptedHistory())
        let surface = HistoryPanelSurfaceState(
            viewState: viewState,
            previewState: PreviewPaneState()
        )

        surface.beginSession(rows: rows)
        let selectedID = rows[0].item.id
        #expect(surface.selection == selectedID)

        surface.reconcileSessionSelection(
            rows: [],
            hasAuthoritativeFirstPage: false
        )
        #expect(surface.selection == selectedID)

        // `rows` did not change, but an authoritative empty page arrived. The
        // view's authoritative-page onChange drives this exact owner call.
        surface.reconcileSessionSelection(
            rows: [],
            hasAuthoritativeFirstPage: true
        )
        #expect(surface.selection == nil)
    }

    @Test func failedReplacementDoesNotClaimAuthoritativeRemoval() {
        let viewState = HistoryViewState(history: ScriptedHistory())
        let surface = HistoryPanelSurfaceState(
            viewState: viewState,
            previewState: PreviewPaneState()
        )

        surface.beginSession(rows: rows)
        surface.moveSelection(in: rows, direction: .next)
        let selectedID = rows[1].item.id

        // A failed first-page request has stopped loading, but it still did
        // not publish an authoritative page for this generation.
        surface.reconcileSessionSelection(
            rows: [],
            hasAuthoritativeFirstPage: false
        )
        #expect(surface.selection == selectedID)
        #expect(surface.selectedReference(in: []) == nil)
    }

    @Test func firstAuthoritativePageSelectsNewestAfterEmptyOpen() {
        let viewState = HistoryViewState(history: ScriptedHistory())
        let surface = HistoryPanelSurfaceState(
            viewState: viewState,
            previewState: PreviewPaneState()
        )

        surface.beginSession(rows: [])
        #expect(surface.selection == nil)

        surface.reconcileSessionSelection(rows: rows)

        #expect(surface.selection == rows[0].item.id)
    }

    // MARK: Input mode and hover selection (Maccy NavigationManager)

    private func makeSurface(
        previewState: PreviewPaneState = PreviewPaneState()
    ) -> HistoryPanelSurfaceState {
        HistoryPanelSurfaceState(
            viewState: HistoryViewState(history: ScriptedHistory()),
            previewState: previewState
        )
    }

    /// Yields until a zero-delay scheduled dwell completes — the same
    /// scheduling-only boundary PreviewPaneStateTests uses, independent of
    /// wall-clock passage on a saturated runner.
    private func waitForScheduledDwell(
        _ condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
    }

    @Test func hoverSelectsImmediatelyInMouseMode() {
        let surface = makeSurface()
        surface.beginSession(rows: rows)
        surface.notePointerMovement()
        #expect(surface.inputMode == .mouse)

        surface.handleRowHover(rows[2].item.id)
        #expect(surface.selection == rows[2].item.id)
        #expect(surface.deferredHoverSelection == nil)
    }

    @Test func hoverDefersDuringKeyboardNavigationAndAppliesOnNextMouseMovement() {
        let surface = makeSurface()
        surface.beginSession(rows: rows)

        // A session starts in keyboard mode: hover alone must not select.
        #expect(surface.inputMode == .keyboard)
        surface.handleRowHover(rows[1].item.id)
        #expect(surface.selection == rows[0].item.id)
        #expect(surface.deferredHoverSelection == rows[1].item.id)

        // Only a real mouse movement flips back to pointer control and
        // applies the deferral — never a scroll.
        surface.notePointerMovement()
        #expect(surface.inputMode == .mouse)
        #expect(surface.selection == rows[1].item.id)
        #expect(surface.deferredHoverSelection == nil)
    }

    @Test func arrowMovementRestoresKeyboardMode() {
        let surface = makeSurface()
        surface.beginSession(rows: rows)
        surface.notePointerMovement()
        #expect(surface.inputMode == .mouse)

        surface.moveSelection(in: rows, direction: .next)
        #expect(surface.inputMode == .keyboard)
        #expect(surface.selection == rows[1].item.id)

        surface.handleRowHover(rows[2].item.id)
        #expect(
            surface.selection == rows[1].item.id,
            "hover only defers while keyboard-navigating"
        )
        surface.notePointerMovement()
        #expect(surface.selection == rows[2].item.id)
    }

    @Test func endSessionRetiresInputModeAndDeferredHover() {
        let surface = makeSurface()
        surface.beginSession(rows: rows)
        surface.handleRowHover(rows[1].item.id)
        #expect(surface.deferredHoverSelection == rows[1].item.id)

        surface.endSession()
        #expect(surface.deferredHoverSelection == nil)

        // The next session restarts in keyboard mode with no stale
        // deferral able to jump the fresh preselection.
        surface.beginSession(rows: rows)
        #expect(surface.inputMode == .keyboard)
        #expect(surface.selection == rows[0].item.id)
    }

    @Test func hoverSelectionDwellsAndOpensTheFloatingPreview() async {
        let previewState = PreviewPaneState(autoOpenDelay: .zero)
        var events: [PreviewPaneState.FloatingPreviewTransition] = []
        previewState.onFloatingPreviewTransition = { events.append($0) }
        let surface = makeSurface(previewState: previewState)

        surface.beginSession(rows: rows)
        // The hover → selection → dwell → show chain: hover drives the
        // ID-only selection, then the panel's selection onChange forwards
        // the exact reference (mirrored here) and the dwell opens the pane.
        surface.notePointerMovement()
        surface.handleRowHover(rows[1].item.id)
        #expect(surface.selection == rows[1].item.id)

        previewState.handleSelectionChange(
            PreviewSelectionResolution.resolve(
                selectedID: surface.selection,
                rows: rows
            ).reference
        )
        await waitForScheduledDwell { previewState.isOpen }
        #expect(previewState.previewedItem == rows[1].item)
        #expect(events == [.show(rows[1].item)])
    }
}
