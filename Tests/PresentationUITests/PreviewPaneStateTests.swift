/// PreviewPaneStateTests — the preview-pane state machine's dwell / cancel /
/// suppress / lifecycle semantics (Maccy's `SlideoutController` behavior,
/// replicated in `PreviewPaneState`); pure state tests, no view hosting.
import Foundation
import HistoryCore
import PresentationUI
import Testing

@Suite(.serialized)
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

    /// Zero delay preserves the production task-suspension boundary without
    /// coupling state-machine tests to wall-clock scheduling under CI load.
    private func makeState() -> PreviewPaneState {
        PreviewPaneState(autoOpenDelay: .zero)
    }

    /// Waits for a zero-delay dwell already queued on the MainActor. A clock
    /// deadline can expire before either this test or the dwell regains the
    /// actor on a saturated runner; yielding instead observes causal task
    /// completion independent of how long that scheduling takes. The finite
    /// turn budget still lets a broken production task fail the test.
    private func waitForScheduledDwell(
        _ condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
    }

    @Test func dwellAutoOpensAfterTheConfiguredDelay() async {
        // A nonzero duration exercises the sleep branch; its one-nanosecond
        // value keeps scheduling, rather than wall-clock passage, as the
        // observable boundary under CI load.
        let state = PreviewPaneState(autoOpenDelay: .nanoseconds(1))
        let item = reference()

        state.handleSelectionChange(item)
        #expect(!state.isOpen, "the dwell must not fire synchronously")
        #expect(state.previewedItem == nil)

        await waitForScheduledDwell {
            state.isOpen && state.previewedItem == item
        }
        #expect(state.isOpen, "the dwell task opens the pane asynchronously")
        #expect(state.previewedItem == item)
    }

    @Test func rapidSelectionChangesCancelPendingDwells() async {
        let state = makeState()
        let first = reference()
        let second = reference()

        state.handleSelectionChange(first)
        state.handleSelectionChange(second)

        await waitForScheduledDwell {
            state.isOpen && state.previewedItem == second
        }
        #expect(state.isOpen)
        #expect(
            state.previewedItem == second,
            "the superseded selection never fires (cancel-and-reschedule debounce)"
        )
    }

    @Test func manualToggleOpensImmediatelyAndClosesWithSuppression() {
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
        await waitForScheduledDwell {
            state.isOpen && state.previewedItem == second
        }
        #expect(state.isOpen, "a selection change clears the manual-close suppression")
        #expect(state.previewedItem == second)
    }

    @Test func resigningKeyDisarmsAndBecomingKeyRearms() async {
        let state = makeState()
        let item = reference()

        state.panelResignedKey()
        state.handleSelectionChange(item)
        #expect(!state.isOpen, "no dwell fires while the panel is not key")

        state.panelBecameKey()
        state.handleSelectionChange(item)
        await waitForScheduledDwell { state.isOpen }
        #expect(state.previewedItem == item)
    }

    @Test func disabledAutoOpenPreferenceNeverSchedulesTheDwell() async {
        let state = makeState()
        let item = reference()

        state.isAutoOpenPreferenceEnabled = false
        state.handleSelectionChange(item)
        // Give a (wrongly) scheduled zero-delay dwell every chance to fire:
        // the scheduling guard must have skipped it, so no task exists.
        await Task.yield()
        await Task.yield()

        #expect(!state.isOpen)
        #expect(
            state.previewedItem == nil,
            "with the preference off, selection changes never open the pane"
        )
    }

    @Test func manualToggleStillOpensWhileAutoOpenPreferenceIsDisabled() {
        let state = makeState()
        let item = reference()

        state.isAutoOpenPreferenceEnabled = false
        state.togglePreview(for: item)

        #expect(state.isOpen)
        #expect(state.previewedItem == item)

        // The manual close keeps its suppression semantics under the
        // disabled preference: a same-item re-selection must not reopen.
        state.togglePreview(for: item)
        #expect(!state.isOpen)
        state.handleSelectionChange(item)
        #expect(!state.isOpen)
    }

    @Test func reenabledAutoOpenPreferenceAppliesOnTheNextSelectionChange() async {
        let state = makeState()
        let first = reference()
        let second = reference()

        state.isAutoOpenPreferenceEnabled = false
        state.handleSelectionChange(first)
        await Task.yield()
        #expect(!state.isOpen)

        // Re-enabling alone must not open the pane; the NEXT selection
        // change schedules and fires the dwell again.
        state.isAutoOpenPreferenceEnabled = true
        #expect(!state.isOpen)

        state.handleSelectionChange(second)
        await waitForScheduledDwell {
            state.isOpen && state.previewedItem == second
        }
        #expect(state.isOpen)
        #expect(state.previewedItem == second)
    }

    @Test func togglingAutoOpenPreferenceRetiresTheAlreadyQueuedDwell() async {
        let state = makeState()
        let first = reference()
        let second = reference()

        // Both preference changes happen before the queued dwell can run.
        // Re-enabling must not revive work scheduled for the old selection.
        state.handleSelectionChange(first)
        state.isAutoOpenPreferenceEnabled = false
        state.isAutoOpenPreferenceEnabled = true

        // The exact-item purge has an observable effect only when this
        // item still owns pending/visible work. It must now be a no-op:
        // this proves retirement synchronously, without guessing how many
        // scheduler turns let a cancelled dwell finish.
        state.purge(.item(first.id))
        #expect(state.purgeGeneration == 0)
        #expect(!state.isOpen)
        #expect(state.previewedItem == nil)

        state.handleSelectionChange(second)
        await waitForScheduledDwell { state.previewedItem == second }
        #expect(state.isOpen)
        #expect(state.previewedItem == second)
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

    @Test func refreshingVisibleContentPreservesAnotherItemsPendingDwell() async {
        let state = makeState()
        defer { state.panelClosed() }
        let first = reference()
        let second = reference()
        let updatedFirst = HistoryItemReference(
            id: first.id, contentVersion: ContentVersion(rawValue: 2)
        )
        state.togglePreview(for: first)
        state.handleSelectionChange(second)
        state.refreshOpenPreview(updatedFirst)
        #expect(state.previewedItem == updatedFirst)
        // The zero-delay dwell cannot execute until this test yields the
        // MainActor. Refreshing A must not cancel the already queued B task.
        await waitForScheduledDwell { state.previewedItem == second }
        #expect(state.previewedItem == second)
    }

    @Test func dwellRetargetsAnAlreadyOpenPreview() async {
        let state = makeState()
        let first = reference()
        let second = reference()

        state.togglePreview(for: first)
        #expect(state.previewedItem == first)

        state.handleSelectionChange(second)
        await waitForScheduledDwell {
            state.previewedItem == second
        }
        #expect(state.previewedItem == second)
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
