/// PanelSessionSelectionTests.swift — Card 14A's pure open/reopen and
/// keyboard-selection contract. The first displayed row is the newest item
/// in the authoritative ordering; arrows clamp at the visible boundaries.
import HistoryCore
import PresentationUI
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
        #expect(surface.selection == rows[1].item.id)

        let replacement = [rows[0], rows[2]]
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
}
