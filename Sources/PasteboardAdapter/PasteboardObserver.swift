/// PasteboardObserver — changeCount-polled observation that drives
/// `history.perform(.capture(...))` (docs/architecture.md; roadmap
/// docs/testing.md deliverable 3).
///
/// NSPasteboard exposes no change notification, so polling `changeCount` is
/// the v1 mechanism. The observer is main-actor confined with the adapter
/// and its `Timer` on the main `RunLoop`; the registered handler receives
/// only immutable `Sendable` `CaptureOutcome` values — the frozen capture
/// plus the partial-freeze record (audit SPEC-IMPL-005), so the
/// composition root, not the adapter, judges a partial freeze
/// (docs/architecture.md boundary rule). Paste orchestration stays
/// owned by the composition root, never by this observer
/// (docs/architecture.md).
import AppKit
import Foundation
import HistoryCore

/// changeCount-polled observation (01 §5.1; roadmap 04). Main-actor
/// confined; polls the pasteboard's `changeCount` on a main-`RunLoop`
/// `Timer` and freezes each nonempty ownership generation once. An empty
/// generation remains eligible until its owner publishes declarations. A
/// freeze whose start/end generations differ receives exactly one immediate
/// retry before delivery (REVIEW Card 5B).
@MainActor
public final class PasteboardObserver {
    private let adapter: PasteboardAdapter
    private let pollInterval: TimeInterval
    private var timer: Timer?
    private var lastChangeCount: Int
    private var awaitingDeclarationsChangeCount: Int?
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
        self.awaitingDeclarationsChangeCount = nil
        self.timer = nil
        self.handler = nil
        self.accessBehaviorHandler = nil
        self.lastAccessBehavior = adapter.captureAccessBehavior
        self.accessBehaviorProvider = { adapter.captureAccessBehavior }
    }

    isolated deinit {
        // The run loop retains its timer, whose callback retains us weakly.
        // Dropping the observer must also remove that now-useless poll source.
        timer?.invalidate()
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
    /// excluded. The handler runs on the main actor for each non-nil freeze
    /// outcome. An empty ownership generation is checked for later declarations
    /// without accessing payloads; values with nothing retainable are not
    /// delivered. A PARTIAL freeze — a
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
        awaitingDeclarationsChangeCount = nil

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
        awaitingDeclarationsChangeCount = nil
        handler = nil
        accessBehaviorHandler = nil
    }

    /// One poll tick: a changed ownership generation is frozen once. If that
    /// generation was empty, inspect declarations until its owner publishes
    /// items; writeObjects can add them without changing ownership again.
    private func poll() {
        guard let activeTimer = timer else { return }
        let accessBehavior = accessBehaviorProvider()
        if accessBehavior != lastAccessBehavior {
            lastAccessBehavior = accessBehavior
            accessBehaviorHandler?(accessBehavior)
        }
        guard self.timer === activeTimer, accessBehavior == .allowed else { return }

        let changeCount = adapter.pasteboard.changeCount
        if changeCount == lastChangeCount {
            guard awaitingDeclarationsChangeCount == changeCount else { return }
            // An intentional permanent clear only incurs this metadata read.
            // No payload accessor, extra timer, task, or queued capture exists.
            let types = adapter.pasteboard.types
            guard self.timer === activeTimer,
                  lastChangeCount == changeCount,
                  awaitingDeclarationsChangeCount == changeCount,
                  types?.isEmpty == false else { return }
        }
        lastChangeCount = changeCount
        awaitingDeclarationsChangeCount = nil
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
        let shouldContinue: @MainActor () -> Bool = {
            guard self.timer === activeTimer,
                  self.lastChangeCount == observedChangeCount else { return false }
            // A promised-data provider can spin the run loop without changing
            // clipboard ownership. Recheck access at each payload boundary so
            // a revocation abandons this freeze before any sibling read or
            // delivery, rather than waiting for the next timer tick.
            let accessBehavior = self.accessBehaviorProvider()
            if accessBehavior != self.lastAccessBehavior {
                self.lastAccessBehavior = accessBehavior
                self.accessBehaviorHandler?(accessBehavior)
            }
            return self.timer === activeTimer
                && self.lastChangeCount == observedChangeCount
                && accessBehavior == .allowed
        }
        let didObserveEmptyPasteboard: @MainActor (Int) -> Void = { generation in
            guard self.timer === activeTimer,
                  self.lastChangeCount == observedChangeCount else { return }
            self.awaitingDeclarationsChangeCount = generation
        }
        guard let firstOutcome = adapter.captureOutcome(
            shouldContinue: shouldContinue,
            didObserveEmptyPasteboard: didObserveEmptyPasteboard
        ) else { return nil }
        guard shouldContinue() else { return nil }
        guard case .changedDuringRead = firstOutcome else {
            return firstOutcome
        }

        guard let retryOutcome = adapter.captureOutcome(
            shouldContinue: shouldContinue,
            didObserveEmptyPasteboard: didObserveEmptyPasteboard
        ) else {
            guard shouldContinue() else { return nil }
            return firstOutcome
        }
        guard shouldContinue() else { return nil }
        switch retryOutcome {
        case .complete, .changedDuringRead:
            return retryOutcome
        case .declaredUnavailable, .concealed, .unsupportedMultiItem:
            return firstOutcome
        }
    }
}
