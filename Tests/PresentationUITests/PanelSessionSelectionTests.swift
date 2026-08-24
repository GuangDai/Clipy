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
}
