import Foundation
import HistoryCore
import PresentationUI
import Testing

@MainActor
struct QuickLookReferenceTests {
    private func row(version: UInt64 = 1) -> HistoryRow {
        fixtureRow(
            id: "00000000-0000-0000-0000-000000009901",
            title: "Quick Look item",
            contentVersion: version
        )
    }

    private func surface(history: any ClipboardHistory = ScriptedHistory()) -> HistoryPanelSurfaceState {
        let surface = HistoryPanelSurfaceState(history: history, previewState: PreviewPaneState())
        surface.beginSession(rows: [row()])
        surface.quickLookReference = row().item
        return surface
    }

    @Test func receiptFirstClosesQuickLookWithoutReopeningForStaleRows() {
        let surface = surface()
        surface.apply(HistorySurfacePurge(
            generation: 1, scope: .revision(old: row().item, new: row(version: 2).item)
        ))
        #expect(surface.quickLookReference == nil)
        surface.reconcileSessionSelection(rows: [row()])
        #expect(surface.resolvedQuickLookReference(in: [row()]) == nil)
        surface.reconcileSessionSelection(rows: [row(version: 2)])
        #expect(surface.quickLookReference == nil)
        #expect(surface.selection == row().item.id)
    }

    @Test func observationFirstHidesOldContentBeforeReconciliation() {
        let surface = surface()
        let updatedRows = [row(version: 2)]
        // The render decision must already hide v1 before SwiftUI's onChange
        // callback mutates the stored trigger-time reference.
        #expect(surface.quickLookReference == row().item)
        #expect(surface.resolvedQuickLookReference(in: updatedRows) == nil)
        surface.reconcileSessionSelection(rows: updatedRows)
        #expect(surface.quickLookReference == nil)
        surface.apply(HistorySurfacePurge(
            generation: 1, scope: .revision(old: row().item, new: row(version: 2).item)
        ))
        #expect(surface.quickLookReference == nil)
    }

    @Test func olderRowsDoNotReplaceANewerQuickLookTarget() {
        let surface = surface()
        surface.quickLookReference = row(version: 2).item
        #expect(surface.resolvedQuickLookReference(in: [row()]) == row(version: 2).item)
        surface.reconcileSessionSelection(rows: [row()])
        #expect(surface.quickLookReference == row(version: 2).item)
    }

    @Test func filteredTargetClosesWithoutChangingAnotherVisibleSelection() {
        let surface = surface()
        let other = fixtureRow(id: "00000000-0000-0000-0000-000000009902", title: "visible")
        surface.selection = other.item.id
        #expect(surface.resolvedQuickLookReference(in: [other]) == nil)
        surface.retargetHiddenSelectionToDisplayedDefault(displayedRows: [other])
        #expect(surface.quickLookReference == nil)
        #expect(surface.selection == other.item.id)
    }

    @Test func loadingGapPreservesQuickLookButAnAuthoritativeEmptyPageClosesIt() {
        let surface = surface()
        surface.reconcileSessionSelection(rows: [], hasAuthoritativeFirstPage: false)
        #expect(surface.resolvedQuickLookReference(
            in: [], hasAuthoritativeFirstPage: false
        ) == row().item)
        surface.reconcileSessionSelection(rows: [])
        #expect(surface.quickLookReference == nil)
        #expect(surface.selection == nil)
    }

    @Test(arguments: [false, true])
    func dismissedQuickLookCannotPublishALateDetailsCompletion(revised: Bool) async throws {
        let history = PausableDetailsHistory()
        let item = row().item
        let content = [HistoryRepresentation(
            typeIdentifier: "public.utf8-plain-text", bytes: Data("old sensitive content".utf8)
        )]
        await history.scriptDetails(HistoryDetails(
            item: item,
            canonical: content,
            effective: content,
            revisions: [],
            occurrence: CopyOccurrenceSummary(
                firstCopiedAt: Date(timeIntervalSince1970: 1),
                lastCopiedAt: Date(timeIntervalSince1970: 1),
                count: 1,
                firstSource: nil,
                lastSource: nil
            ),
            pinnedPosition: nil
        ))
        let surface = surface(history: history)
        let loader = PreviewContentLoader(history: history)
        let load = Task {
            await loader.load(item: surface.resolvedQuickLookReference(in: [row()]))
        }
        try #require(await pollUntil { await history.detailRequests == [item.id] })

        let latestRows = revised ? [row(version: 2)] : []
        #expect(surface.resolvedQuickLookReference(in: latestRows) == nil)
        surface.reconcileSessionSelection(rows: latestRows)
        // The overlay is removed with an identity transition. Its embedded
        // HistoryPreviewView.onDisappear invokes this real loader operation.
        loader.clear()
        await history.resumeDetails(for: item.id)
        await load.value
        #expect(surface.quickLookReference == nil)
        #expect(loader.requestedItem == nil)
        #expect(loader.phase == .unsupported)
        #expect(loader.occurrence == nil)
    }
}
