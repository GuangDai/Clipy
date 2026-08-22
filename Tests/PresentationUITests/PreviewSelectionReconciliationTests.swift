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
        version: UInt64
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
            pinnedPosition: nil,
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
}
