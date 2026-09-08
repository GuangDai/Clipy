/// Selection follows authoritative filtered pages. A filter restart retires
/// old executable rows immediately; replacement pages restore keyboard lanes.
import Foundation
import HistoryCore
import PresentationUI
import Testing

@MainActor
struct FilteredSelectionTests {
    @Test(arguments: [false, true])
    func hiddenSelectionCannotPasteBeforeRetarget(pinnedOnly: Bool) async throws {
        let (state, history) = activatedMixedState()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.count == 5 })
        let original = state.rows
        let hidden = original[pinnedOnly ? 2 : 3]
        let visible = original[0]
        let surface = beginSurfaceSession(rows: original)
        surface.selection = hidden.item.id
        let recorder = FilteredPasteRecorder()
        state.onPaste = { recorder.items.append($0) }

        state.typeFilter = pinnedOnly ? .all : .text
        state.showsPinnedOnly = pinnedOnly
        #expect(state.rows.isEmpty)
        let filter = HistoryFilter(type: pinnedOnly ? .all : .text, pinnedOnly: pinnedOnly)
        surface.reconcileSessionSelection(rows: state.rows, hasAuthoritativeFirstPage: false, filter: filter)
        #expect(surface.selection == hidden.item.id)
        #expect(surface.selectedReference(in: state.displayedRows) == nil)
        state.requestPasteFromDisplayedRow(hidden.item)
        #expect(recorder.items.isEmpty)

        let matching = pinnedOnly ? Array(original.prefix(2)) : [original[0], original[2]]
        try await publish(matching, filter: filter, to: state, history: history)
        surface.reconcileSessionSelection(rows: state.rows, hasAuthoritativeFirstPage: true, filter: filter)
        surface.retargetHiddenSelectionToDisplayedDefault(displayedRows: state.displayedRows)
        #expect(surface.selectedReference(in: state.displayedRows) == visible.item)
        state.requestPasteFromDisplayedRow(visible.item)
        #expect(recorder.items == [visible.item])
        await history.finishObservation()
    }

    @Test func observedUnpinRemovesItemFromAuthoritativePinnedPage() async throws {
        let pinned = filterSelectionRow(
            id: "00000000-0000-0000-0000-00000000F210", title: "only pinned item",
            typeIdentifiers: ["public.utf8-plain-text"], pinned: 0
        )
        let history = ScriptedHistory(observedFirstPage: fixturePage(rows: [pinned], next: nil))
        let state = HistoryViewState(history: history)
        state.showsPinnedOnly = true
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.hasAuthoritativeFirstPage })
        #expect(await history.observeRequests.last?.filter == HistoryFilter(pinnedOnly: true))
        let surface = beginSurfaceSession(rows: state.rows)
        surface.reconcileSessionSelection(rows: state.rows, hasAuthoritativeFirstPage: true,
                                          filter: .init(pinnedOnly: true))
        #expect(surface.selectedReference(in: state.displayedRows) == pinned.item)

        // The writer omits the now-unpinned item from this filtered snapshot.
        await history.emitObservedPage(fixturePage(rows: [], next: nil))
        try #require(await pollUntil { state.rows.isEmpty })
        #expect(surface.selectedReference(in: state.displayedRows) == nil)
        surface.reconcileSessionSelection(rows: state.rows, hasAuthoritativeFirstPage: true,
                                          filter: .init(pinnedOnly: true))
        surface.retargetHiddenSelectionToDisplayedDefault(displayedRows: state.displayedRows)
        #expect(surface.selection == nil)
        await history.finishObservation()
    }

    @Test func arrowsWalkAuthoritativeFilteredRowsAndRecoverHiddenSelection() async throws {
        let (state, history) = activatedMixedState()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.count == 5 })
        let original = state.rows
        let surface = beginSurfaceSession(rows: original)
        state.typeFilter = .text
        try await publish([original[0], original[2]], filter: .init(type: .text), to: state, history: history)
        let displayed = displayedSelectionRows(of: state)
        #expect(displayed.map(\.title) == ["pinned-text", "recent-text"])
        surface.moveSelection(in: displayed, direction: .next)
        #expect(surface.selection == original[2].item.id)
        surface.moveSelection(in: displayed, direction: .next)
        #expect(surface.selection == original[2].item.id)
        surface.moveSelection(in: displayed, direction: .previous)
        #expect(surface.selection == original[0].item.id)
        surface.selection = original[1].item.id
        surface.moveSelection(in: displayed, direction: .next)
        #expect(surface.selection == original[0].item.id)
        surface.selection = original[4].item.id
        surface.moveSelection(in: displayed, direction: .previous)
        #expect(surface.selection == original[2].item.id)
        await history.finishObservation()
    }

    @Test func unfilteredDisplayedWalkIsTheAuthoritativeWalk() async throws {
        let (state, history) = activatedMixedState()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.count == 5 })
        #expect(state.typeFilter == .all)
        #expect(!state.showsPinnedOnly)
        #expect(displayedSelectionRows(of: state) == state.rows)
        let surface = beginSurfaceSession(rows: state.rows)
        surface.moveSelection(in: state.displayedRows, direction: .next)
        #expect(surface.selection == state.rows[1].item.id)
        surface.moveSelection(in: state.displayedRows, direction: .next)
        #expect(surface.selection == state.rows[2].item.id)
        await history.finishObservation()
    }

    @Test func clearedFilterRestoresTheFullWalk() async throws {
        let (state, history) = activatedMixedState()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.count == 5 })
        let original = state.rows
        let surface = beginSurfaceSession(rows: original)
        state.typeFilter = .text
        try await publish([original[0], original[2]], filter: .init(type: .text), to: state, history: history)
        surface.moveSelection(in: state.displayedRows, direction: .next)
        #expect(surface.selection == original[2].item.id)
        state.typeFilter = .all
        #expect(state.displayedRows.isEmpty)
        try await publish(original, filter: .all, to: state, history: history)
        surface.moveSelection(in: state.displayedRows, direction: .previous)
        #expect(surface.selection == original[1].item.id)
        await history.finishObservation()
    }

    @Test func openDefaultRetargetsToNewestMatchingRow() async throws {
        let (state, history) = activatedMixedState()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.count == 5 })
        let original = state.rows
        state.showsPinnedOnly = true
        try await publish(Array(original.prefix(2)), filter: .init(pinnedOnly: true), to: state, history: history)
        let surface = beginSurfaceSession(rows: state.rows)
        surface.reconcileSessionSelection(rows: state.rows, hasAuthoritativeFirstPage: true,
                                          filter: .init(pinnedOnly: true))
        #expect(surface.selection == original[0].item.id)
        state.typeFilter = .links
        let links = HistoryFilter(type: .links, pinnedOnly: true)
        surface.reconcileSessionSelection(rows: state.rows, hasAuthoritativeFirstPage: false, filter: links)
        #expect(surface.selection == original[0].item.id)
        try await publish([original[1]], filter: links, to: state, history: history)
        surface.reconcileSessionSelection(rows: state.rows, hasAuthoritativeFirstPage: true, filter: links)
        surface.retargetHiddenSelectionToDisplayedDefault(displayedRows: state.displayedRows)
        #expect(surface.selection == original[1].item.id)

        // An authoritative removal under the same filter must clear rather
        // than repick; filter replacement and item deletion differ here.
        await history.emitObservedPage(fixturePage(rows: [], next: nil))
        try #require(await pollUntil { state.rows.isEmpty })
        surface.reconcileSessionSelection(rows: state.rows, hasAuthoritativeFirstPage: true, filter: links)
        #expect(surface.selection == nil)
        await history.finishObservation()
    }

    @Test func clearingAnEmptyFilterRestoresSelectionButSameQueryDeletionDoesNotRepick() async throws {
        let (state, history) = activatedMixedState()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.count == 5 })
        let original = state.rows
        let surface = beginSurfaceSession(rows: original)
        state.typeFilter = .images
        state.showsPinnedOnly = true
        let emptyFilter = HistoryFilter(type: .images, pinnedOnly: true)
        try await publish([], filter: emptyFilter, to: state, history: history)
        surface.reconcileSessionSelection(rows: state.rows, filter: emptyFilter)
        #expect(surface.selection == nil)

        state.typeFilter = .all
        state.showsPinnedOnly = false
        surface.reconcileSessionSelection(
            rows: state.rows, hasAuthoritativeFirstPage: false, filter: .all
        )
        #expect(surface.selection == nil)
        try await publish(original, filter: .all, to: state, history: history)
        surface.reconcileSessionSelection(rows: state.rows, filter: .all)
        #expect(surface.selection == original[0].item.id)

        // A later removal still clears the selection even with other visible
        // rows available under the same filter.
        let remaining = Array(original.dropFirst())
        await history.emitObservedPage(fixturePage(rows: remaining, next: nil))
        try #require(await pollUntil { state.rows == remaining })
        surface.reconcileSessionSelection(rows: state.rows, filter: .all)
        #expect(surface.selection == nil)
        surface.reconcileSessionSelection(rows: state.rows, filter: .all)
        #expect(surface.selection == nil)
        await history.finishObservation()
    }

    @Test func firstMatchingPageSelectsDefaultAfterEmptyOpen() async throws {
        let (state, history) = activatedMixedState()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.count == 5 })
        let original = state.rows
        state.typeFilter = .text
        let surface = beginSurfaceSession(rows: state.rows)
        #expect(surface.selection == nil)
        try await publish([original[0], original[2]], filter: .init(type: .text), to: state, history: history)
        surface.reconcileSessionSelection(rows: state.rows, hasAuthoritativeFirstPage: true, filter: .init(type: .text))
        surface.retargetHiddenSelectionToDisplayedDefault(displayedRows: state.displayedRows)
        #expect(surface.selection == original[0].item.id)

        state.showsPinnedOnly = true
        state.typeFilter = .links
        let second = beginSurfaceSession(rows: state.rows)
        #expect(second.selection == nil)
        try await publish([original[1]], filter: .init(type: .links, pinnedOnly: true), to: state, history: history)
        second.reconcileSessionSelection(rows: state.rows, hasAuthoritativeFirstPage: true,
                                         filter: .init(type: .links, pinnedOnly: true))
        second.retargetHiddenSelectionToDisplayedDefault(displayedRows: state.displayedRows)
        #expect(second.selection == original[1].item.id)
        await history.finishObservation()
    }

    @Test func retargetKeepsVisibleAndNilSelections() async throws {
        let (state, history) = activatedMixedState()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.count == 5 })
        let original = state.rows
        let surface = beginSurfaceSession(rows: original)
        state.typeFilter = .links
        try await publish([original[1]], filter: .init(type: .links), to: state, history: history)
        surface.selection = original[1].item.id
        surface.retargetHiddenSelectionToDisplayedDefault(displayedRows: state.displayedRows)
        #expect(surface.selection == original[1].item.id)
        surface.selection = nil
        surface.retargetHiddenSelectionToDisplayedDefault(displayedRows: state.displayedRows)
        #expect(surface.selection == nil)

        state.showsPinnedOnly = true
        state.typeFilter = .images
        try await publish([], filter: .init(type: .images, pinnedOnly: true), to: state, history: history)
        surface.selection = original[0].item.id
        #expect(state.displayedRows.isEmpty)
        surface.retargetHiddenSelectionToDisplayedDefault(displayedRows: state.displayedRows)
        #expect(surface.selection == nil)
        await history.finishObservation()
    }

    private func publish(
        _ rows: [HistoryRow], filter: HistoryFilter,
        to state: HistoryViewState, history: ScriptedHistory
    ) async throws {
        try #require(await pollUntil { await history.observeRequests.last?.filter == filter })
        #expect(state.rows.isEmpty)
        await history.emitObservedPage(fixturePage(rows: rows, next: nil))
        try #require(await pollUntil { state.hasAuthoritativeFirstPage && state.rows == rows })
        #expect(state.displayedRows == rows)
    }

    // MARK: - Fixtures

    /// The displayed lanes in render order — the exact composition
    /// HistoryPanelView hands to the selection walk and the retarget.
    private func displayedSelectionRows(
        of state: HistoryViewState
    ) -> [HistoryRow] {
        state.displayedRows
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
            ),
            repeatsObservedFirstPage: false
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

@MainActor
private final class FilteredPasteRecorder {
    var items: [HistoryItemReference] = []
}
