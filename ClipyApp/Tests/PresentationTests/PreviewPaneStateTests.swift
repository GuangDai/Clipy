/// PreviewPaneStateTests — the preview-pane state machine's dwell / cancel /
/// suppress / lifecycle semantics (Maccy's `SlideoutController` behavior,
/// replicated in `PreviewPaneState`); pure state tests, no view hosting.
import Foundation
@testable import HistoryCore
@testable import ClipyApp
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

    @Test func normalPressureRestoresTheCurrentDwellWithoutAnotherSelectionChange() async {
        let state = makeState()
        let item = reference()
        state.handleSelectionChange(item)
        state.respondToMemoryPressure(.critical)
        state.respondToMemoryPressure(.warning)
        #expect(state.isAutoOpenSuspendedForMemoryPressure)
        #expect(!state.isOpen)

        state.respondToMemoryPressure(.normal)
        await waitForScheduledDwell { state.previewedItem == item }
        #expect(state.isOpen)
        #expect(state.previewedItem == item)
    }

    @Test func pressureRecoveryUsesOnlyTheLatestSelectionAndItsRevisedReference() async {
        let state = makeState()
        let first = reference()
        let latest = reference()
        let revised = HistoryItemReference(
            id: latest.id,
            contentVersion: ContentVersion(rawValue: 2)
        )
        state.handleSelectionChange(first)
        state.respondToMemoryPressure(.critical)
        state.handleSelectionChange(latest)
        state.purge(.revision(old: latest, new: revised))
        // A second pressure notification must retain the same current demand.
        state.respondToMemoryPressure(.critical)
        state.respondToMemoryPressure(.normal)
        await waitForScheduledDwell { state.previewedItem == revised }
        #expect(state.isOpen)
        #expect(state.previewedItem == revised)
    }

    @Test func removedPressureSuspendedTargetCannotReopenOnRecovery() {
        let state = makeState()
        let item = reference()
        state.handleSelectionChange(item)
        state.respondToMemoryPressure(.critical)
        state.purge(.item(item.id))
        #expect(state.purgeGeneration == 1)
        state.respondToMemoryPressure(.normal)
        // The second purge is an exact synchronous oracle: no pending or
        // visible reference may have been resurrected by recovery.
        state.purge(.item(item.id))
        #expect(state.purgeGeneration == 1)
        #expect(!state.isOpen)
    }

    @Test func pressureRecoveryRespectsManualClosePreferenceAndPanelRetirement() {
        for cancellation in ["manual close", "preference", "panel close", "resign key", "selection cleared"] {
            let state = makeState()
            let item = reference()
            state.handleSelectionChange(item)
            state.respondToMemoryPressure(.critical)
            switch cancellation {
            case "manual close":
                state.togglePreview(for: item)
                state.togglePreview(for: item)
            case "preference":
                state.isAutoOpenPreferenceEnabled = false
                state.isAutoOpenPreferenceEnabled = true
            case "panel close":
                state.panelClosed()
                state.panelBecameKey()
            case "resign key":
                state.panelResignedKey()
                state.panelBecameKey()
            default:
                state.handleSelectionChange(nil)
            }
            state.respondToMemoryPressure(.normal)
            state.purge(.item(item.id))
            #expect(state.purgeGeneration == 0, "Retired demand: \(cancellation)")
            #expect(!state.isOpen)
        }
    }

    @Test func criticalPressureStopsDwellButKeepsManualPreviewAndUserPreference() async {
        let state = makeState()
        let item = reference()
        state.handleSelectionChange(item)
        state.respondToMemoryPressure(.critical)
        #expect(state.isAutoOpenSuspendedForMemoryPressure)
        #expect(state.isAutoOpenPreferenceEnabled)
        state.handleSelectionChange(reference())
        #expect(!state.isOpen)
        state.togglePreview(for: item)
        #expect(state.isOpen)
        #expect(state.previewedItem == item)
        state.togglePreview(for: item)
        state.respondToMemoryPressure(.warning)
        #expect(state.isAutoOpenSuspendedForMemoryPressure)
        state.respondToMemoryPressure(.normal)
        #expect(!state.isOpen)
        state.handleSelectionChange(item)
        await waitForScheduledDwell { state.isOpen }
        #expect(state.previewedItem == item)
        state.togglePreview(for: item)
        state.isAutoOpenPreferenceEnabled = false
        state.respondToMemoryPressure(.critical)
        state.respondToMemoryPressure(.normal)
        #expect(!state.isAutoOpenPreferenceEnabled)
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

    @Test func refreshingAClosedPreviewPreservesAPendingDwell() async {
        let state = makeState()
        defer { state.panelClosed() }
        let first = reference()
        let second = reference()
        let updatedFirst = HistoryItemReference(
            id: first.id, contentVersion: ContentVersion(rawValue: 2)
        )
        // An open pane retargets immediately, so a pending dwell exists only
        // while the pane is closed. A refresh aimed at an already-open pane
        // is a no-op here and must not disturb the queued dwell.
        state.handleSelectionChange(second)
        state.refreshOpenPreview(updatedFirst)
        #expect(!state.isOpen)
        #expect(state.previewedItem == nil)
        await waitForScheduledDwell { state.previewedItem == second }
        #expect(state.isOpen)
        #expect(state.previewedItem == second)
    }

    @Test(arguments: [false, true])
    func purgingUnrelatedContentPreservesAPendingDwell(isRevision: Bool) async {
        let state = makeState()
        defer { state.panelClosed() }
        let visible = reference()
        let selected = reference()
        let replacement = HistoryItemReference(
            id: visible.id, contentVersion: ContentVersion(rawValue: 2)
        )
        state.handleSelectionChange(selected)
        // Apply the receipt before the selected item's zero-delay dwell can
        // run. Only an unrelated item belongs to this purge.
        state.purge(isRevision
            ? .revision(old: visible, new: replacement)
            : .item(visible.id))
        #expect(state.purgeGeneration == 0)

        await waitForScheduledDwell { state.previewedItem == selected }
        #expect(state.isOpen)
        #expect(state.previewedItem == selected)
    }

    @Test func selectionChangeRetargetsAnOpenPreviewImmediatelyWithoutDwell() {
        let state = makeState()
        let first = reference()
        let second = reference()

        state.togglePreview(for: first)
        #expect(state.previewedItem == first)

        state.handleSelectionChange(second)
        // No dwell and no yield: once visible, the pane follows the
        // selection on the spot — only the closed→open transition dwells.
        #expect(state.isOpen)
        #expect(state.previewedItem == second)
    }

    @Test func escDismissalSuppressesAutoOpenUntilTheSelectionChanges() async {
        let state = makeState()
        let first = reference()
        let second = reference()

        state.handleSelectionChange(first)
        await waitForScheduledDwell { state.isOpen }
        #expect(state.dismissPreview())
        #expect(!state.isOpen)
        #expect(state.previewedItem == nil)
        #expect(!state.dismissPreview(), "a closed pane has nothing to dismiss")

        state.handleSelectionChange(second)
        await waitForScheduledDwell { state.previewedItem == second }
        #expect(state.isOpen)
    }

    @Test func floatingPreviewTransitionsTrackTheStateMachine() async {
        let state = makeState()
        var events: [PreviewPaneState.FloatingPreviewTransition] = []
        state.onFloatingPreviewTransition = { events.append($0) }
        let first = reference()
        let second = reference()

        state.handleSelectionChange(first)
        #expect(events.isEmpty, "the closed→open transition dwells")
        await waitForScheduledDwell { state.isOpen }
        state.handleSelectionChange(second)
        _ = state.dismissPreview()

        #expect(events == [.show(first), .update(second), .hide])
    }

    // MARK: Pointer lifecycle (both windows)

    /// Zero grace preserves the same scheduling-only boundary as the
    /// zero-delay dwell helper.
    private func makePointerState() -> PreviewPaneState {
        PreviewPaneState(autoOpenDelay: .zero, pointerExitGrace: .zero)
    }

    @Test func pointerExitHidesAnOpenPreviewAfterTheGrace() async {
        let state = makePointerState()
        let item = reference()
        state.pointerEntered(.mainPanel)
        state.handleSelectionChange(item)
        await waitForScheduledDwell { state.isOpen }

        state.pointerExited(.mainPanel)
        #expect(state.isOpen, "the grace, not the exit, owns the hide")
        await waitForScheduledDwell { !state.isOpen }
        #expect(!state.isOpen)
        #expect(state.previewedItem == nil)
    }

    @Test func pointerReentryCancelsTheExitGrace() async {
        let state = makePointerState()
        let item = reference()
        state.pointerEntered(.mainPanel)
        state.handleSelectionChange(item)
        await waitForScheduledDwell { state.isOpen }

        state.pointerExited(.mainPanel)
        // Re-entry is synchronous with the exit: the queued grace task is
        // cancelled before it can get a MainActor turn.
        state.pointerEntered(.mainPanel)
        await Task.yield()
        await Task.yield()

        #expect(state.isOpen)
        #expect(state.previewedItem == item)
    }

    @Test func movingFromPanelToPreviewKeepsThePaneOpen() async {
        let state = makePointerState()
        let item = reference()
        state.pointerEntered(.mainPanel)
        state.handleSelectionChange(item)
        await waitForScheduledDwell { state.isOpen }

        state.pointerEntered(.preview)
        state.pointerExited(.mainPanel)
        await Task.yield()
        await Task.yield()
        #expect(state.isOpen, "the pane stays open while the pointer is over it")

        state.pointerExited(.preview)
        await waitForScheduledDwell { !state.isOpen }
        #expect(!state.isOpen)
    }

    @Test func pointerReentryReDwellsTheCurrentSelectionWithoutSuppression() async {
        let state = makePointerState()
        var events: [PreviewPaneState.FloatingPreviewTransition] = []
        state.onFloatingPreviewTransition = { events.append($0) }
        let item = reference()
        state.pointerEntered(.mainPanel)
        state.handleSelectionChange(item)
        await waitForScheduledDwell { state.isOpen }

        state.pointerExited(.mainPanel)
        await waitForScheduledDwell { !state.isOpen }

        // Lightweight hide: re-entering the rows re-dwells the CURRENT
        // selection and reopens without any selection change, proving the
        // manual-close suppression was never engaged.
        state.pointerEntered(.mainPanel)
        await waitForScheduledDwell { state.isOpen }
        #expect(state.previewedItem == item)
        #expect(events == [.show(item), .hide, .show(item)])
    }

    @Test func manualDismissalSuppressionSurvivesPointerReentry() async {
        let state = makePointerState()
        let item = reference()
        state.pointerEntered(.mainPanel)
        state.handleSelectionChange(item)
        await waitForScheduledDwell { state.isOpen }
        #expect(state.dismissPreview())

        state.pointerExited(.mainPanel)
        state.pointerEntered(.mainPanel)
        await Task.yield()
        await Task.yield()

        #expect(!state.isOpen, "manual close keeps its suppression across pointer cycles")
        #expect(state.previewedItem == nil)
    }

    @Test func pointerExitBeforeTheDwellFiresRetiresIt() async {
        let state = makePointerState()
        let item = reference()
        state.pointerEntered(.mainPanel)
        state.handleSelectionChange(item)
        // Synchronously before the zero-delay dwell gets a turn: an absent
        // pointer never opens the pane.
        state.pointerExited(.mainPanel)
        await Task.yield()
        await Task.yield()
        #expect(!state.isOpen)

        state.pointerEntered(.mainPanel)
        await waitForScheduledDwell { state.isOpen }
        #expect(state.previewedItem == item)
    }

    @Test func panelClosedClearsPointerPresenceAndStaleSelectionDemand() async {
        let state = makePointerState()
        let item = reference()
        state.pointerEntered(.mainPanel)
        state.handleSelectionChange(item)
        await waitForScheduledDwell { state.isOpen }

        state.panelClosed()
        #expect(!state.isOpen)

        // A stale pointer cycle after close cannot reopen the pane: the
        // retained selection demand was retired and auto-open is disarmed
        // until the panel becomes key again.
        state.pointerExited(.mainPanel)
        state.pointerEntered(.mainPanel)
        await Task.yield()
        await Task.yield()
        #expect(!state.isOpen)
        #expect(state.previewedItem == nil)
    }

    @Test func togglingWithNoSelectionKeepsThePaneClosed() {
        let state = makeState()
        state.togglePreview(for: nil)
        #expect(!state.isOpen)
        #expect(state.previewedItem == nil)
    }

    /// Clear removes the pending exact target and cancels its task before
    /// the queued zero-delay dwell can reopen the pane.
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

    /// The republished pager channel (the floating pane's ⌥⌘←/→ chords
    /// arrive through the key main panel): direction sticks, the generation
    /// advances monotonically, and pane visibility/lifecycle never touches
    /// it — like the ⌘R retry generation, it is a pure request counter the
    /// consuming view gates.
    @Test func pagerRequestsRepublishDirectionAndAdvanceMonotonically() {
        let state = makeState()
        #expect(state.previewPagerRequestGeneration == 0)

        state.requestPreviewPage(.previous)
        #expect(state.previewPagerRequestGeneration == 1)
        #expect(state.previewPagerRequestDirection == .previous)

        state.requestPreviewPage(.next)
        #expect(state.previewPagerRequestGeneration == 2)
        #expect(state.previewPagerRequestDirection == .next)

        // Pane lifecycle does not consume or reset the channel.
        state.panelClosed()
        #expect(state.previewPagerRequestGeneration == 2)
        #expect(state.previewPagerRequestDirection == .next)
    }

    /// The retry and pager channels are independent republish counters.
    @Test func pagerAndRetryRequestsAreIndependentChannels() {
        let state = makeState()
        state.requestPreviewRetry()
        #expect(state.previewRetryRequestGeneration == 1)
        #expect(state.previewPagerRequestGeneration == 0)
        state.requestPreviewPage(.previous)
        #expect(state.previewRetryRequestGeneration == 1)
        #expect(state.previewPagerRequestGeneration == 1)
    }
}
