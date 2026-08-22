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

    /// Creates an observer over `adapter`'s pasteboard. `pollInterval` is
    /// the polling cadence in seconds (0.5 s in production; tests tighten
    /// it).
    public init(adapter: PasteboardAdapter, pollInterval: TimeInterval = 0.5) {
        self.adapter = adapter
        self.pollInterval = pollInterval
        self.lastChangeCount = adapter.pasteboard.changeCount
        self.timer = nil
        self.handler = nil
    }

    /// Captures the CURRENT pasteboard immediately, then polls: the handler
    /// runs on the main actor once per distinct `changeCount` whose outcome
    /// is non-nil (a change that clears the pasteboard or yields nothing
    /// retainable is recorded but not delivered; a PARTIAL freeze — a
    /// declared representation's bytes unavailable — IS delivered, marked
    /// by `CaptureOutcome.declaredUnavailable`, for the handler owner to
    /// judge). Calling `start` again while running replaces the handler
    /// without re-capturing.
    public func start(handler: @escaping @MainActor (CaptureOutcome) -> Void) {
        self.handler = handler
        guard timer == nil else { return }

        lastChangeCount = adapter.pasteboard.changeCount
        deliverCurrentOutcome(to: handler)

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
    }

    /// Stops polling and drops the handler. Safe to call when stopped; safe
    /// to `start(handler:)` again afterwards.
    public func stop() {
        timer?.invalidate()
        timer = nil
        handler = nil
    }

    /// One poll tick: delivers an outcome only when `changeCount` moved.
    private func poll() {
        let changeCount = adapter.pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        guard let handler else { return }
        deliverCurrentOutcome(to: handler)
    }

    /// Freezes one observed generation for delivery. Ownership movement
    /// during that freeze gets one synchronous retry: a stable complete retry
    /// replaces the superseded first attempt, while another unstable or
    /// otherwise incomplete attempt leaves one content-free generation-race
    /// outcome for the owner. There is no delay, task, or retry loop.
    private func deliverCurrentOutcome(
        to handler: @MainActor (CaptureOutcome) -> Void
    ) {
        guard let outcome = captureOutcomeWithOneOwnershipRetry() else {
            lastChangeCount = adapter.pasteboard.changeCount
            return
        }
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
    private func captureOutcomeWithOneOwnershipRetry() -> CaptureOutcome? {
        guard let firstOutcome = adapter.captureOutcome() else { return nil }
        guard case .changedDuringRead = firstOutcome else {
            return firstOutcome
        }

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
