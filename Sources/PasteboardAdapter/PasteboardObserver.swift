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
/// `Timer` and freezes each complete ownership generation once. Empty or
/// incomplete publication remains eligible until its owner publishes bytes.
/// A freeze whose start/end generations differ receives one immediate retry;
/// another race leaves the unread latest generation for a later poll.
@MainActor
public final class PasteboardObserver {
    private let adapter: PasteboardAdapter
    private let pollInterval: TimeInterval
    private var timer: Timer?
    private var lastChangeCount: Int
    private var awaitingDeclarationsChangeCount: Int?
    private struct PendingCapture {
        let changeCount: Int
        let retryDelay: TimeInterval
        var remainingDelay: TimeInterval
        var failureWasDelivered: Bool
    }
    private var pendingCapture: PendingCapture?
    private var isReading = false
    private var initialCaptureChangeCount: Int?
    /// Whether the current callback is importing the generation already
    /// present at startup, including publication delayed until access allows.
    public private(set) var isDeliveringInitialCapture = false
    private var handler: (@MainActor (CaptureOutcome) -> Void)?
    private var accessBehaviorHandler:
        (@MainActor (PasteboardAccessBehavior) -> Void)?
    private var lastAccessBehavior: PasteboardAccessBehavior
    private var accessBehaviorProvider:
        @MainActor () -> PasteboardAccessBehavior

    /// Creates an observer over `adapter`'s pasteboard. `pollInterval` is
    /// the polling cadence in seconds (0.1 s in production; tests tighten
    /// it).
    public init(adapter: PasteboardAdapter, pollInterval: TimeInterval = 0.1) {
        self.adapter = adapter
        self.pollInterval = pollInterval
        self.lastChangeCount = adapter.pasteboard.changeCount
        self.awaitingDeclarationsChangeCount = nil
        self.pendingCapture = nil
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
    /// without accessing payloads. Declared but unavailable or empty payloads
    /// are retried with a capped delay; nothing retainable is delivered. A PARTIAL freeze — a
    /// declared representation's bytes unavailable — IS delivered, marked
    /// by `CaptureOutcome.declaredUnavailable`, for the handler owner to
    /// judge. Calling `start` again while running replaces the handler
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

        let initialChangeCount = adapter.pasteboard.changeCount
        lastChangeCount = initialChangeCount
        awaitingDeclarationsChangeCount = nil
        pendingCapture = nil
        initialCaptureChangeCount = captureCurrent ? initialChangeCount : nil

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
        timer.tolerance = min(0.01, pollInterval / 10)
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
            if isReading || accessBehavior != .allowed {
                // A provider may synchronously replace this session. The old
                // read will retire when it returns; keep the new session's
                // current value eligible without nesting another provider.
                scheduleRetry(changeCount: initialChangeCount, after: nil, immediately: true)
            } else {
                deliverCurrentOutcome()
            }
        }
    }

    /// Stops polling and drops the handler. Safe to call when stopped; safe
    /// to `start(handler:)` again afterwards.
    public func stop() {
        timer?.invalidate()
        timer = nil
        awaitingDeclarationsChangeCount = nil
        pendingCapture = nil
        initialCaptureChangeCount = nil
        handler = nil
        accessBehaviorHandler = nil
    }

    /// One poll tick. New ownership always bypasses an older retry delay.
    /// Empty ownership waits through metadata reads only; incomplete declared
    /// payloads use the same timer with an exponential delay capped at 1 s.
    private func poll() {
        guard let activeTimer = timer else { return }
        let accessBehavior = accessBehaviorProvider()
        if accessBehavior != lastAccessBehavior {
            lastAccessBehavior = accessBehavior
            accessBehaviorHandler?(accessBehavior)
        }
        guard self.timer === activeTimer, accessBehavior == .allowed else { return }
        // A promised-data provider can pump the main run loop. A nested tick
        // still checks access above, but cannot recursively read providers or
        // consume a generation which the outer freeze has not completed.
        guard !isReading else { return }

        let changeCount = adapter.pasteboard.changeCount
        if changeCount == lastChangeCount {
            if awaitingDeclarationsChangeCount == changeCount {
                // An intentional permanent clear only incurs this metadata
                // read. No payload accessor, extra timer, or task exists.
                let types = adapter.pasteboard.types
                guard self.timer === activeTimer,
                      lastChangeCount == changeCount,
                      awaitingDeclarationsChangeCount == changeCount,
                      types?.contains(where: {
                          $0.rawValue != PasteboardLineageHint.typeIdentifier
                      }) == true else { return }
            } else if var pending = pendingCapture, pending.changeCount == changeCount {
                pending.remainingDelay -= pollInterval
                pendingCapture = pending
                guard pending.remainingDelay <= 0 else { return }
            } else {
                return
            }
        } else {
            pendingCapture = nil
            initialCaptureChangeCount = nil
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

    private struct CaptureAttempt {
        let outcome: CaptureOutcome?
        let sampledChangeCount: Int
        let emptyChangeCount: Int?
        let noRetainableChangeCount: Int?
    }

    /// A poll retains only its retry counters, never partial payload bytes.
    /// Providers run serially, with at most one immediate ownership retry.
    /// Later polls recover incomplete publication instead of consuming it.
    private func deliverCurrentOutcome() {
        guard let activeTimer = timer, !isReading else { return }
        let observedChangeCount = lastChangeCount
        let previousPending = pendingCapture
        isReading = true
        let attempt = captureOutcomeWithOneOwnershipRetry(
            observing: activeTimer,
            observedChangeCount: observedChangeCount
        )
        isReading = false
        // A promised-data accessor may reenter the main run loop. A stop or
        // restart during that read owns a different timer/baseline, so this
        // old read must neither advance it nor call a retired handler. A
        // same-session start only replaces the handler and uses this result.
        guard self.timer === activeTimer,
              lastChangeCount == observedChangeCount else { return }

        guard let attempt else {
            // Access may have been revoked without changing ownership. That
            // unread generation stays eligible when access becomes allowed.
            scheduleRetry(changeCount: observedChangeCount, after: previousPending)
            return
        }
        if let emptyChangeCount = attempt.emptyChangeCount {
            lastChangeCount = emptyChangeCount
            awaitingDeclarationsChangeCount = emptyChangeCount
            pendingCapture = nil
            return
        }
        if let noRetainableChangeCount = attempt.noRetainableChangeCount {
            lastChangeCount = noRetainableChangeCount
            scheduleRetry(changeCount: noRetainableChangeCount, after: previousPending)
            return
        }
        guard let outcome = attempt.outcome else {
            // A stable metadata-only generation has no content to await.
            // Do not resample after the read: a newly written value has not
            // been inspected and must remain eligible on the next tick.
            lastChangeCount = attempt.sampledChangeCount
            pendingCapture = nil
            return
        }
        awaitingDeclarationsChangeCount = nil
        switch outcome {
        case let .complete(value):
            lastChangeCount = value.changeCount
            pendingCapture = nil
        case let .declaredUnavailable(value):
            lastChangeCount = value.changeCount
            scheduleRetry(changeCount: value.changeCount, after: previousPending)
        case let .concealed(value):
            lastChangeCount = value.changeCount
            pendingCapture = nil
        case let .unsupportedMultiItem(value):
            lastChangeCount = value.changeCount
            pendingCapture = nil
        case let .changedDuringRead(value):
            lastChangeCount = value.endChangeCount
            scheduleRetry(changeCount: value.endChangeCount, after: previousPending, immediately: true)
        }
        if var pending = pendingCapture {
            // Report unavailable/racing publication once while waiting for
            // this generation. Its eventual complete value still delivers.
            guard !pending.failureWasDelivered else { return }
            pending.failureWasDelivered = true
            pendingCapture = pending
        }
        let previousInitialDelivery = isDeliveringInitialCapture
        isDeliveringInitialCapture = initialCaptureChangeCount == lastChangeCount
        defer { isDeliveringInitialCapture = previousInitialDelivery }
        if pendingCapture == nil { initialCaptureChangeCount = nil }
        handler?(outcome)
    }

    private func scheduleRetry(
        changeCount: Int,
        after previousPending: PendingCapture?,
        immediately: Bool = false
    ) {
        let previous = previousPending.flatMap {
            $0.changeCount == changeCount ? $0 : nil
        }
        let initialDelay = min(pollInterval, 1)
        let retryDelay = previous.map { min($0.retryDelay * 2, 1) } ?? initialDelay
        pendingCapture = PendingCapture(
            changeCount: changeCount,
            retryDelay: retryDelay,
            remainingDelay: immediately ? 0 : retryDelay,
            failureWasDelivered: previous?.failureWasDelivered ?? false
        )
    }

    /// One additional freeze per poll is the complete synchronous retry
    /// budget. Its actual latest-generation facts replace the older race.
    private func captureOutcomeWithOneOwnershipRetry(
        observing activeTimer: Timer,
        observedChangeCount: Int
    ) -> CaptureAttempt? {
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
        let read: @MainActor () -> CaptureAttempt? = {
            let sampledChangeCount = self.adapter.pasteboard.changeCount
            var emptyChangeCount: Int?
            var noRetainableChangeCount: Int?
            let outcome = self.adapter.captureOutcome(
                shouldContinue: shouldContinue,
                didObserveEmptyPasteboard: { emptyChangeCount = $0 },
                didObserveNoRetainableContent: { noRetainableChangeCount = $0 }
            )
            guard shouldContinue() else { return nil }
            return CaptureAttempt(
                outcome: outcome,
                sampledChangeCount: sampledChangeCount,
                emptyChangeCount: emptyChangeCount,
                noRetainableChangeCount: noRetainableChangeCount
            )
        }
        guard let firstAttempt = read() else { return nil }
        guard case .changedDuringRead? = firstAttempt.outcome else { return firstAttempt }
        return read()
    }
}
