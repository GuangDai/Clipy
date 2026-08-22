/// PreviewPaneStateTests — the preview-pane state machine's dwell / cancel /
/// suppress / lifecycle semantics (Maccy's `SlideoutController` behavior,
/// replicated in `PreviewPaneState`); pure state tests, no view hosting.
import Foundation
import HistoryCore
import PresentationUI
import Testing

@MainActor
struct PreviewPaneStateTests {

    /// A fresh reference (package-only `HistoryItemID`/`ContentVersion`
    /// initializers are reachable from in-package test targets).
    private func reference(_ version: UInt64 = 1) -> HistoryItemReference {
        HistoryItemReference(
            id: HistoryItemID(rawValue: UUID()),
            contentVersion: ContentVersion(rawValue: version)
        )
    }

    /// A state with a short dwell so tests stay fast (production default is
    /// Maccy's 200 ms).
    private func makeState() -> PreviewPaneState {
        PreviewPaneState(autoOpenDelay: .milliseconds(30))
    }

    @Test func dwellAutoOpensAfterTheConfiguredDelay() async {
        let state = makeState()
        let item = reference()

        state.handleSelectionChange(item)
        #expect(!state.isOpen, "the dwell must not fire synchronously")
        #expect(state.previewedItem == nil)

        let opened = await pollUntil(timeout: .seconds(10)) {
            state.isOpen && state.previewedItem == item
        }
        #expect(opened, "the dwell fires after the delay and opens the pane")
    }

    @Test func rapidSelectionChangesCancelPendingDwells() async {
        let state = makeState()
        let first = reference()
        let second = reference()

        state.handleSelectionChange(first)
        state.handleSelectionChange(second)

        let opened = await pollUntil(timeout: .seconds(10)) {
            state.isOpen && state.previewedItem == second
        }
        #expect(opened)
        #expect(
            state.previewedItem == second,
            "the superseded selection never fires (cancel-and-reschedule debounce)"
        )
    }

    @Test func manualToggleOpensImmediatelyAndClosesWithSuppression() async {
        let state = makeState()
        let item = reference()

        state.togglePreview(for: item)
        #expect(state.isOpen)
        #expect(state.previewedItem == item)

        state.togglePreview(for: item)
        #expect(!state.isOpen)
        #expect(state.previewedItem == nil)

        // The manual close suppresses auto-open until the selection changes:
        // re-selecting nothing new must not reopen the pane. (A new
        // selection change to a DIFFERENT item lifts the suppression —
        // covered by `manualCloseSuppressionLiftsOnSelectionChange`.)
        try? await Task.sleep(for: .milliseconds(120))
        #expect(!state.isOpen)
    }

    @Test func manualCloseSuppressionLiftsOnSelectionChange() async {
        let state = makeState()
        let first = reference()
        let second = reference()

        state.togglePreview(for: first)
        state.togglePreview(for: first)  // closed + suppressed
        #expect(!state.isOpen)

        state.handleSelectionChange(second)
        let reopened = await pollUntil(timeout: .seconds(10)) {
            state.isOpen && state.previewedItem == second
        }
        #expect(reopened, "a selection change clears the manual-close suppression")
    }

    @Test func resigningKeyDisarmsAndBecomingKeyRearms() async {
        let state = makeState()
        let item = reference()

        state.panelResignedKey()
        state.handleSelectionChange(item)
        try? await Task.sleep(for: .milliseconds(120))
        #expect(!state.isOpen, "no dwell fires while the panel is not key")

        state.panelBecameKey()
        state.handleSelectionChange(item)
        let opened = await pollUntil(timeout: .seconds(10)) { state.isOpen }
        #expect(opened)
    }

    @Test func panelClosedDisarmsAutoOpenUntilThePanelBecomesKeyAgain() {
        let state = makeState()
        let first = reference()
        let second = reference()

        state.togglePreview(for: first)
        #expect(state.isOpen)

        state.panelClosed()
        #expect(!state.isOpen)
        #expect(state.previewedItem == nil)
        #expect(!state.isAutoOpenEnabled)

        // A selection published by the hidden panel must not reopen or queue
        // a preview for the next session.
        state.handleSelectionChange(second)
        #expect(!state.isOpen)
        #expect(state.previewedItem == nil)

        // AppKit's windowDidBecomeKey callback is the sole lifecycle input
        // that re-arms selection-driven preview opening. Reactivation alone
        // does not synthesize a selection change or reopen the pane.
        state.panelBecameKey()
        #expect(state.isAutoOpenEnabled)
        #expect(!state.isOpen)
        #expect(state.previewedItem == nil)
    }

    @Test func clearingTheSelectionClosesAnOpenPreviewImmediately() {
        let state = makeState()
        let item = reference()

        state.togglePreview(for: item)
        #expect(state.isOpen)

        state.handleSelectionChange(nil)
        #expect(!state.isOpen)
        #expect(state.previewedItem == nil)
    }

    @Test func sameItemRevisionRefreshesOnlyAnAlreadyOpenPreview() {
        let state = makeState()
        let version1 = reference(1)
        let version2 = HistoryItemReference(
            id: version1.id,
            contentVersion: ContentVersion(rawValue: 2)
        )

        state.togglePreview(for: version1)
        state.refreshOpenPreview(version2)
        #expect(state.isOpen)
        #expect(state.previewedItem == version2)

        state.togglePreview(for: version2)
        state.refreshOpenPreview(version1)
        #expect(!state.isOpen)
        #expect(state.previewedItem == nil)
    }

    @Test func dwellRetargetsAnAlreadyOpenPreview() async {
        let state = makeState()
        let first = reference()
        let second = reference()

        state.togglePreview(for: first)
        #expect(state.previewedItem == first)

        state.handleSelectionChange(second)
        let retargeted = await pollUntil(timeout: .seconds(10)) {
            state.previewedItem == second
        }
        #expect(retargeted)
        #expect(state.isOpen, "retargeting keeps the pane open")
    }

    @Test func togglingWithNoSelectionKeepsThePaneClosed() {
        let state = makeState()
        state.togglePreview(for: nil)
        #expect(!state.isOpen)
        #expect(state.previewedItem == nil)
    }

    /// Purge generation, not cooperative task cancellation, is the final
    /// fence: a zero-delay dwell scheduled before Clear cannot reopen the
    /// pane after the destructive receipt is applied.
    @Test func clearPurgeFencesQueuedDwellCompletion() async {
        let state = PreviewPaneState(autoOpenDelay: .zero)
        let item = reference()

        state.handleSelectionChange(item)
        state.purge(.all)
        await Task.yield()
        await Task.yield()

        #expect(state.purgeGeneration == 1)
        #expect(!state.isOpen)
        #expect(state.previewedItem == nil)
    }

    /// Exact revision eviction does not close an unrelated visible preview.
    @Test func exactPurgePreservesUnrelatedPreview() {
        let state = makeState()
        let visible = reference()
        let revisedElsewhere = reference()
        state.togglePreview(for: visible)

        let replacement = HistoryItemReference(
            id: revisedElsewhere.id,
            contentVersion: ContentVersion(rawValue: 2)
        )
        state.purge(.revision(old: revisedElsewhere, new: replacement))

        #expect(state.purgeGeneration == 0)
        #expect(state.isOpen)
        #expect(state.previewedItem == visible)
    }
}
