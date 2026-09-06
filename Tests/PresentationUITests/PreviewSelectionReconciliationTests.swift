/// PreviewSelectionReconciliationTests — exact-reference selection
/// reconciliation against authoritative observed rows (review Card 9A).
/// This pure seam proves the state transition SwiftUI's `onChange` consumes
/// without relying on view-host timing.
import Foundation
import HistoryCore
import PresentationUI
import Testing

@MainActor
struct PreviewSelectionReconciliationTests {

    private let selectedID = HistoryItemID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000009A1")!
    )

    private func row(
        id: HistoryItemID? = nil,
        version: UInt64,
        pinnedPosition: Int? = nil
    ) -> HistoryRow {
        HistoryRow(
            item: HistoryItemReference(
                id: id ?? selectedID,
                contentVersion: ContentVersion(rawValue: version)
            ),
            title: "selected",
            typeIdentifiers: ["public.utf8-plain-text"],
            lastCopiedAt: Date(timeIntervalSince1970: 1_787_000_000),
            copyCount: 1,
            lastSource: nil,
            pinnedPosition: pinnedPosition,
            search: nil
        )
    }

    @Test func sameIDRevisionResolvesToTheObservedExactReference() {
        let v1 = PreviewSelectionResolution.resolve(
            selectedID: selectedID,
            rows: [row(version: 1)]
        )
        let v2 = PreviewSelectionResolution.resolve(
            selectedID: selectedID,
            rows: [row(version: 2)]
        )

        #expect(v1.selectedID == selectedID)
        #expect(v1.reference?.contentVersion == ContentVersion(rawValue: 1))
        #expect(v2.selectedID == selectedID)
        #expect(v2.reference?.contentVersion == ContentVersion(rawValue: 2))
        #expect(v2 != v1, "ContentVersion is part of the observed change key")
        #expect(
            v2.previewTarget(previewedItem: v1.reference) == v2.reference,
            "an already-previewed item advances immediately to its observed version"
        )
    }

    @Test(arguments: [(UInt64(1), UInt64(2)), (UInt64(2), UInt64(1)), (UInt64(2), UInt64(2))])
    func sameItemTargetUsesTheNewestReceiptOrObservedVersion(
        observed: UInt64, pane: UInt64
    ) {
        let selection = PreviewSelectionResolution.resolve(
            selectedID: selectedID,
            rows: [row(version: observed)]
        )
        #expect(selection.previewTarget(previewedItem: row(version: pane).item)
            == row(version: 2).item)
    }

    @Test func lateObservationCannotRegressAReceiptAdvancedPane() {
        let preview = PreviewPaneState(autoOpenDelay: .zero)
        let old = row(version: 1).item
        let current = row(version: 3).item
        preview.togglePreview(for: old)
        preview.purge(.revision(old: old, new: current))

        // The intermediate observation can arrive after the v3 receipt.
        preview.refreshOpenPreview(row(version: 2).item)
        #expect(preview.previewedItem == current)
        let selection = PreviewSelectionResolution.resolve(
            selectedID: selectedID, rows: [row(version: 2)]
        )
        #expect(selection.previewTarget(previewedItem: preview.previewedItem) == current)
    }

    @Test func crossItemChangeKeepsTheDwellTargetUntilPaneStateRetargets() {
        let previous = HistoryItemReference(
            id: HistoryItemID(
                rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000009A2")!
            ),
            contentVersion: ContentVersion(rawValue: 1)
        )
        let selected = PreviewSelectionResolution.resolve(
            selectedID: selectedID,
            rows: [
                row(id: previous.id, version: 1),
                row(version: 2),
            ]
        )

        #expect(selected.previewTarget(previewedItem: previous) == previous)
    }

    @Test(arguments: [(UInt64(1), UInt64(2)), (UInt64(2), UInt64(1)), (UInt64(2), UInt64(2))])
    func crossItemPreviewUsesItsOwnNewestReference(observed: UInt64, pane: UInt64) {
        let previewID = HistoryItemID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000009A4")!
        )
        let selection = PreviewSelectionResolution.resolve(
            selectedID: selectedID,
            rows: [row(id: previewID, version: observed), row(version: 9)]
        )
        #expect(selection.reference == row(version: 9).item)
        #expect(selection.previewTarget(previewedItem: row(id: previewID, version: pane).item)
            == row(id: previewID, version: 2).item)
    }

    @Test func removedCrossItemDwellTargetDoesNotRemainPreviewable() {
        let removed = HistoryItemReference(
            id: HistoryItemID(
                rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000009A3")!
            ),
            contentVersion: ContentVersion(rawValue: 1)
        )
        let selected = PreviewSelectionResolution.resolve(
            selectedID: selectedID,
            rows: [row(version: 2)]
        )

        #expect(selected.reference?.id == selectedID)
        #expect(selected.previewTarget(previewedItem: removed) == nil)
    }

    @Test func disappearingRowClearsSelectionAndPreviewReference() {
        let resolution = PreviewSelectionResolution.resolve(
            selectedID: selectedID,
            rows: []
        )

        #expect(resolution.selectedID == nil)
        #expect(resolution.reference == nil)
        #expect(resolution.previewTarget(previewedItem: row(version: 1).item) == nil)
    }

    /// A revise commit evicts only the old exact reference. The ID-only list
    /// selection survives so the next authoritative row can retarget it to
    /// the new version, while stale details and preview content disappear.
    @Test func receiptFirstRevisionRetargetsPreviewAndPurgesOldExactState() {
        let history = ScriptedHistory()
        let preview = PreviewPaneState(autoOpenDelay: .zero)
        let surface = HistoryPanelSurfaceState(
            history: history,
            previewState: preview
        )
        let old = row(version: 1).item
        let current = row(version: 2).item
        let other = row(
            id: HistoryItemID(
                rawValue: UUID(
                    uuidString: "00000000-0000-0000-0000-0000000009B1"
                )!
            ),
            version: 1
        ).item
        surface.detailsPath = [old, current, other]
        surface.selection = selectedID
        preview.togglePreview(for: old)

        let purge = HistorySurfacePurge(
            generation: 1,
            scope: .revision(old: old, new: current)
        )
        surface.apply(purge)

        #expect(surface.detailsPath == [current, other])
        #expect(surface.selection == selectedID)
        #expect(preview.isOpen)
        #expect(preview.previewedItem == current)
        #expect(surface.appliedPurgeGeneration == 1)
        #expect(surface.detailsPurgeGeneration == 1)
        #expect(preview.purgeGeneration == 1)
        #expect(surface.thumbnails.purgeGeneration == 1)

        // The same observation firing twice cannot advance any owner again.
        surface.apply(purge)
        #expect(surface.appliedPurgeGeneration == 1)
        #expect(surface.detailsPurgeGeneration == 1)
        #expect(preview.purgeGeneration == 1)
        #expect(surface.thumbnails.purgeGeneration == 1)
    }

    /// If authoritative observation advances the visible preview before the
    /// revise receipt arrives, applying that receipt must produce the same
    /// visible new reference rather than closing or rolling it back.
    @Test func observationFirstRevisionKeepsTheSameNewPreviewResult() {
        let history = ScriptedHistory()
        let preview = PreviewPaneState(autoOpenDelay: .zero)
        let surface = HistoryPanelSurfaceState(
            history: history,
            previewState: preview
        )
        let old = row(version: 1).item
        let current = row(version: 2).item
        surface.detailsPath = [old]
        surface.selection = selectedID
        preview.togglePreview(for: old)

        // This is the production Card 9A observation-before-receipt path.
        preview.refreshOpenPreview(current)
        surface.apply(
            HistorySurfacePurge(
                generation: 1,
                scope: .revision(old: old, new: current)
            )
        )

        #expect(surface.detailsPath.isEmpty)
        #expect(surface.selection == selectedID)
        #expect(preview.isOpen)
        #expect(preview.previewedItem == current)
    }

    /// An editor-owned authoritative advance replaces only the active path
    /// tail before the matching receipt purge is published. The purge still
    /// advances its owner generation, but it no longer removes the already
    /// current Details destination or increments details-purge identity.
    @Test func editorAdvanceRetargetsExactPathBeforeRevisionPurge() {
        let history = ScriptedHistory()
        let preview = PreviewPaneState(autoOpenDelay: .zero)
        let surface = HistoryPanelSurfaceState(
            history: history,
            previewState: preview
        )
        let old = row(version: 1).item
        let current = row(version: 2).item
        surface.detailsPath = [old]
        surface.selection = selectedID

        #expect(
            surface.advanceOpenDetailsReference(from: old, to: current)
        )
        #expect(surface.detailsPath == [current])
        #expect(surface.detailsPurgeGeneration == 0)
        #expect(surface.selection == selectedID)

        surface.apply(
            HistorySurfacePurge(
                generation: 1,
                scope: .revision(old: old, new: current)
            )
        )

        #expect(surface.detailsPath == [current])
        #expect(surface.detailsPurgeGeneration == 0)
        #expect(surface.appliedPurgeGeneration == 1)
        #expect(surface.selection == selectedID)
    }

    @Test func editorAdvanceRejectsNonTailForeignAndRegressingPaths() {
        let history = ScriptedHistory()
        let preview = PreviewPaneState(autoOpenDelay: .zero)
        let surface = HistoryPanelSurfaceState(
            history: history,
            previewState: preview
        )
        let old = row(version: 2).item
        let newer = row(version: 3).item
        let other = row(
            id: HistoryItemID(
                rawValue: UUID(
                    uuidString: "00000000-0000-0000-0000-0000000009B2"
                )!
            ),
            version: 3
        ).item
        let older = HistoryItemReference(
            id: old.id,
            contentVersion: ContentVersion(rawValue: 1)
        )
        surface.detailsPath = [old, other]

        #expect(!surface.advanceOpenDetailsReference(from: old, to: newer))
        #expect(!surface.advanceOpenDetailsReference(from: other, to: older))
        #expect(surface.detailsPath == [old, other])
        #expect(surface.detailsPurgeGeneration == 0)
    }

    /// `onChange` is latest-value observation, so two remove receipts can
    /// coalesce. A generation gap must reset this surface rather than leave
    /// sensitive state belonging to the skipped first purge.
    @Test func skippedPurgeGenerationFailsClosedToWholeSurfaceReset() {
        let history = ScriptedHistory()
        let preview = PreviewPaneState(autoOpenDelay: .zero)
        let surface = HistoryPanelSurfaceState(
            history: history,
            previewState: preview
        )
        let skippedItem = row(version: 1).item
        let latestItem = row(
            id: HistoryItemID(
                rawValue: UUID(
                    uuidString: "00000000-0000-0000-0000-0000000009B3"
                )!
            ),
            version: 1
        ).item
        surface.detailsPath = [skippedItem, latestItem]
        surface.selection = skippedItem.id
        preview.togglePreview(for: skippedItem)

        surface.apply(
            HistorySurfacePurge(
                generation: 2,
                scope: .item(latestItem.id)
            )
        )

        #expect(surface.appliedPurgeGeneration == 2)
        #expect(surface.detailsPath.isEmpty)
        #expect(surface.selection == nil)
        #expect(!preview.isOpen)
        #expect(surface.thumbnails.purgeGeneration == 1)
    }

    /// Request-time rows cannot prove whether off-query/page derived state is
    /// pinned. Clear Unpinned therefore retires navigation/preview/cache state
    /// owner-locally; the authoritative pinned row remains and can be reopened.
    @Test func clearUnpinnedFailsClosedForRebuildableDerivedSurfaceState() {
        let history = ScriptedHistory()
        let preview = PreviewPaneState(autoOpenDelay: .zero)
        let surface = HistoryPanelSurfaceState(
            history: history,
            previewState: preview
        )
        let pinned = row(version: 1, pinnedPosition: 0).item
        let unpinned = row(
            id: HistoryItemID(
                rawValue: UUID(
                    uuidString: "00000000-0000-0000-0000-0000000009B4"
                )!
            ),
            version: 1
        ).item
        surface.detailsPath = [pinned, unpinned]
        surface.selection = pinned.id
        preview.togglePreview(for: pinned)

        surface.apply(
            HistorySurfacePurge(
                generation: 1,
                scope: .unpinned
            )
        )

        #expect(surface.detailsPath.isEmpty)
        #expect(surface.selection == nil)
        #expect(!preview.isOpen)
        #expect(preview.previewedItem == nil)
        #expect(surface.detailsPurgeGeneration == 1)
        #expect(preview.purgeGeneration == 1)
        #expect(surface.thumbnails.purgeGeneration == 1)
    }

    /// Like a newly constructed details view, a newly constructed panel
    /// surface treats the owner's retained purge generation as history. The
    /// old Clear All is not replayed over navigation created afterward.
    @Test func newPanelSurfaceDoesNotReplayItsBaselineClear() {
        let history = ScriptedHistory()
        let preview = PreviewPaneState(autoOpenDelay: .zero)
        let surface = HistoryPanelSurfaceState(
            history: history,
            previewState: preview,
            baselinePurgeGeneration: 4
        )
        let laterItem = row(version: 1).item
        surface.detailsPath = [laterItem]
        surface.selection = laterItem.id
        preview.togglePreview(for: laterItem)

        surface.apply(
            HistorySurfacePurge(generation: 4, scope: .all)
        )

        #expect(surface.detailsPath == [laterItem])
        #expect(surface.selection == laterItem.id)
        #expect(preview.previewedItem == laterItem)
        #expect(surface.detailsPurgeGeneration == 0)
        #expect(surface.thumbnails.purgeGeneration == 0)
    }

    /// Remove scopes to one item; Clear resets the entire surface and fences
    /// a dwell task scheduled before the receipt-confirmed generation.
    @Test func surfaceRemoveAndClearPurgeOnlyAfterAppliedGeneration() async {
        let history = ScriptedHistory()
        let preview = PreviewPaneState(autoOpenDelay: .zero)
        let surface = HistoryPanelSurfaceState(
            history: history,
            previewState: preview
        )
        let removed = row(version: 1).item
        let other = row(
            id: HistoryItemID(
                rawValue: UUID(
                    uuidString: "00000000-0000-0000-0000-0000000009B2"
                )!
            ),
            version: 1
        ).item

        surface.detailsPath = [removed, other]
        surface.selection = removed.id
        preview.togglePreview(for: removed)
        surface.apply(
            HistorySurfacePurge(generation: 1, scope: .item(removed.id))
        )

        #expect(surface.detailsPath == [other])
        #expect(surface.selection == nil)
        #expect(!preview.isOpen)
        #expect(surface.detailsPurgeGeneration == 1)

        surface.detailsPath = [other]
        surface.selection = other.id
        preview.handleSelectionChange(other)
        surface.apply(HistorySurfacePurge(generation: 2, scope: .all))
        await Task.yield()
        await Task.yield()

        #expect(surface.detailsPath.isEmpty)
        #expect(surface.selection == nil)
        #expect(!preview.isOpen)
        #expect(preview.previewedItem == nil)
        #expect(surface.appliedPurgeGeneration == 2)
        #expect(surface.detailsPurgeGeneration == 2)
        #expect(preview.purgeGeneration == 2)
        #expect(surface.thumbnails.purgeGeneration == 2)
    }
}
