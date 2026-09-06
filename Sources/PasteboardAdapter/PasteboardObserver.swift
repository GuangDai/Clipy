/// PasteboardObserver — changeCount-polled observation that drives
/// `history.perform(.capture(...))` (docs/01-architecture.md §5.1; roadmap
/// docs/roadmap/04-pasteboardadapter.md deliverable 3).
///
/// NSPasteboard exposes no change notification, so polling `changeCount` is
/// the v1 mechanism. The observer is main-actor confined with the adapter
/// and its `Timer` on the main `RunLoop`; the registered handler receives
/// only immutable `Sendable` `CaptureOutcome` values — the frozen capture
/// plus the partial-freeze record (audit SPEC-IMPL-005), so the
/// composition root, not the adapter, judges a partial freeze
/// (docs/01-architecture.md §6 boundary rule). Paste orchestration stays
/// owned by the composition root, never by this observer
/// (docs/01-architecture.md §5.6).
import AppKit
import Foundation
import HistoryCore

/// changeCount-polled observation (01 §5.1; roadmap 04). Main-actor
/// confined; polls the pasteboard's `changeCount` on a main-`RunLoop`
/// `Timer` and delivers one capture outcome per distinct change count. A
/// freeze whose start/end generations differ receives exactly one immediate
/// retry before delivery (REVIEW Card 5B).
@MainActor
public final class PasteboardObserver {
    private let adapter: PasteboardAdapter
    private let pollInterval: TimeInterval
    private var timer: Timer?
    private var lastChangeCount: Int
    private var handler: (@MainActor (CaptureOutcome) -> Void)?
    private var accessBehaviorHandler:
        (@MainActor (PasteboardAccessBehavior) -> Void)?
    private var lastAccessBehavior: PasteboardAccessBehavior
    private var accessBehaviorProvider:
        @MainActor () -> PasteboardAccessBehavior

    /// Creates an observer over `adapter`'s pasteboard. `pollInterval` is
    /// the polling cadence in seconds (0.5 s in production; tests tighten
    /// it).
    public init(adapter: PasteboardAdapter, pollInterval: TimeInterval = 0.5) {
        self.adapter = adapter
        self.pollInterval = pollInterval
        self.lastChangeCount = adapter.pasteboard.changeCount
        self.timer = nil
        self.handler = nil
        self.accessBehaviorHandler = nil
        self.lastAccessBehavior = adapter.captureAccessBehavior
        self.accessBehaviorProvider = { adapter.captureAccessBehavior }
    }

#if DEBUG
    /// DEBUG-only AppKit-boundary substitution. Hosted app tests need to prove
    /// a live allow→deny transition without mutating the user's General
    /// pasteboard privacy setting. Release has no configurable access source.
    public func setAccessBehaviorProviderForTesting(
        _ provider: @escaping @MainActor () -> PasteboardAccessBehavior
    ) {
        accessBehaviorProvider = provider
    }
#endif

    /// By default captures the CURRENT pasteboard immediately, then polls.
    /// `captureCurrent == false` baselines the current generation without
    /// delivery; the app uses that privacy-preserving form when the user
    /// explicitly resumes after a pause, so values copied while paused stay
    /// excluded. The handler runs on the main actor once per later distinct
    /// `changeCount` whose outcome
    /// is non-nil (a change that clears the pasteboard or yields nothing
    /// retainable is recorded but not delivered; a PARTIAL freeze — a
    /// declared representation's bytes unavailable — IS delivered, marked
    /// by `CaptureOutcome.declaredUnavailable`, for the handler owner to
    /// judge). Calling `start` again while running replaces the handler
    /// without re-capturing.
    public func start(
        captureCurrent: Bool = true,
        onAccessBehaviorChanged:
            (@MainActor (PasteboardAccessBehavior) -> Void)? = nil,
        handler: @escaping @MainActor (CaptureOutcome) -> Void
    ) {
        self.handler = handler
        self.accessBehaviorHandler = onAccessBehaviorChanged
        guard timer == nil else { return }

        let accessBehavior = accessBehaviorProvider()
        lastAccessBehavior = accessBehavior
        guard accessBehavior == .allowed else {
            onAccessBehaviorChanged?(accessBehavior)
            return
        }

        let initialChangeCount = adapter.pasteboard.changeCount
        lastChangeCount = initialChangeCount

        // The timer is added to the main run loop's common modes explicitly
        // rather than via `Timer.scheduledTimer` (which would silently bind
        // to whatever run loop and mode happen to be current). Its block
        // therefore always executes on the main thread, and
        // `MainActor.assumeIsolated` — runtime-checked, not an unchecked
        // escape hatch — turns that guarantee into a synchronous main-actor
        // `poll()`. A `Task { @MainActor … }` hop would instead sit on the
        // main dispatch queue, which a caller spinning the run loop manually
        // (`RunLoop.main.run(mode:before:)` — PasteboardAdapterTests'
        // spinMainRunLoop) does not drain, so the poll would never land.
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Both callbacks may synchronously stop or restart observation
        // (01 §5.1 lifecycle ownership). Install the timer first so stop()
        // can cancel this start; a replacement timer owns its own capture.
        onAccessBehaviorChanged?(accessBehavior)
        guard self.timer === timer else { return }
        // The access callback can also run a nested poll on this same timer.
        // Its newer generation has already been consumed; do not duplicate
        // that delivery with a second initial read after the callback returns.
        if captureCurrent, lastChangeCount == initialChangeCount {
            deliverCurrentOutcome()
        }
    }

    /// Stops polling and drops the handler. Safe to call when stopped; safe
    /// to `start(handler:)` again afterwards.
    public func stop() {
        timer?.invalidate()
        timer = nil
        handler = nil
        accessBehaviorHandler = nil
    }

    /// One poll tick: delivers an outcome only when `changeCount` moved.
    private func poll() {
        guard let activeTimer = timer else { return }
        let accessBehavior = accessBehaviorProvider()
        if accessBehavior != lastAccessBehavior {
            lastAccessBehavior = accessBehavior
            accessBehaviorHandler?(accessBehavior)
        }
        guard self.timer === activeTimer, accessBehavior == .allowed else { return }

        let changeCount = adapter.pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        deliverCurrentOutcome()
    }

#if DEBUG
    /// Deterministic owner-test entry for one production poll cycle. It avoids
    /// timing assertions while exercising the same access preflight and
    /// capture path as the main-RunLoop timer.
    package func pollForTesting() {
        poll()
    }
#endif

    /// Freezes one observed generation for delivery. Ownership movement
    /// during that freeze gets one synchronous retry: a stable complete retry
    /// replaces the superseded first attempt, while another unstable or
    /// otherwise incomplete attempt leaves one content-free generation-race
    /// outcome for the owner. There is no delay, task, or retry loop.
    private func deliverCurrentOutcome() {
        guard let activeTimer = timer else { return }
        let observedChangeCount = lastChangeCount
        guard let outcome = captureOutcomeWithOneOwnershipRetry(
            observing: activeTimer,
            observedChangeCount: observedChangeCount
        ) else {
            // Keep the generation sampled before this read. Another process
            // may write after the adapter found a stable empty pasteboard;
            // resampling here would mark that unread value as already seen.
            return
        }
        // A promised-data accessor may reenter the main run loop. A stop or
        // restart during that read owns a different timer/baseline, so this
        // old read must neither advance it nor call a retired handler. A
        // same-session start only replaces the handler and uses this result.
        // A nested poll can also consume a newer pasteboard generation while
        // retaining the same timer; its delivery supersedes this outer read.
        guard self.timer === activeTimer,
              lastChangeCount == observedChangeCount,
              let handler else { return }
        switch outcome {
        case let .complete(value):
            lastChangeCount = value.changeCount
        case let .declaredUnavailable(value):
            lastChangeCount = value.changeCount
        case let .concealed(value):
            lastChangeCount = value.changeCount
        case let .unsupportedMultiItem(value):
            lastChangeCount = value.changeCount
        case let .changedDuringRead(value):
            lastChangeCount = value.endChangeCount
        }
        handler(outcome)
    }

    /// Card 5B's bounded retry is deliberately one additional freeze, not a
    /// general retry policy. Partial bytes from the retry cannot replace the
    /// first content-free ownership-race result.
    private func captureOutcomeWithOneOwnershipRetry(
        observing activeTimer: Timer,
        observedChangeCount: Int
    ) -> CaptureOutcome? {
        guard let firstOutcome = adapter.captureOutcome() else { return nil }
        guard case .changedDuringRead = firstOutcome else {
            return firstOutcome
        }
        guard self.timer === activeTimer,
              lastChangeCount == observedChangeCount else { return nil }

        guard let retryOutcome = adapter.captureOutcome() else {
            return firstOutcome
        }
        switch retryOutcome {
        case .complete, .changedDuringRead:
            return retryOutcome
        case .declaredUnavailable, .concealed, .unsupportedMultiItem:
            return firstOutcome
        }
    }
}
