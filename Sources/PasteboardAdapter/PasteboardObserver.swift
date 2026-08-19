/// PasteboardObserver — changeCount-polled observation that drives
/// `history.perform(.capture(...))` (docs/01-architecture.md §5.1; roadmap
/// docs/roadmap/04-pasteboardadapter.md deliverable 3).
///
/// NSPasteboard exposes no change notification, so polling `changeCount` is
/// the v1 mechanism. The observer is main-actor confined with the adapter
/// and its `Timer` on the main `RunLoop`; the registered handler receives
/// only immutable `Sendable` `ClipboardCapture` values (docs/01-architecture.md
/// §6 boundary rule). Paste orchestration stays owned by the composition
/// root, never by this observer (docs/01-architecture.md §5.6).
import AppKit
import Foundation
import HistoryCore

/// changeCount-polled observation (01 §5.1; roadmap 04). Main-actor
/// confined; polls the pasteboard's `changeCount` on a main-`RunLoop`
/// `Timer` and delivers one frozen capture per distinct change count.
@MainActor
public final class PasteboardObserver {
    private let adapter: PasteboardAdapter
    private let pollInterval: TimeInterval
    private var timer: Timer?
    private var lastChangeCount: Int
    private var handler: (@MainActor (ClipboardCapture) -> Void)?

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
    /// runs on the main actor once per distinct `changeCount` whose capture
    /// is non-nil (a change that clears the pasteboard or yields nothing
    /// retainable is recorded but not delivered). Calling `start` again
    /// while running replaces the handler without re-capturing.
    public func start(handler: @escaping @MainActor (ClipboardCapture) -> Void) {
        self.handler = handler
        guard timer == nil else { return }

        lastChangeCount = adapter.pasteboard.changeCount
        if let capture = adapter.capture() {
            handler(capture)
        }

        // The timer closure is a @Sendable context, so the main-actor
        // `poll()` hop goes through a task rather than a direct call —
        // the sanctioned pattern for RunLoop-delivered callbacks under
        // strict concurrency.
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
    }

    /// Stops polling and drops the handler. Safe to call when stopped; safe
    /// to `start(handler:)` again afterwards.
    public func stop() {
        timer?.invalidate()
        timer = nil
        handler = nil
    }

    /// One poll tick: delivers a capture only when `changeCount` moved.
    private func poll() {
        let changeCount = adapter.pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        guard let handler else { return }
        if let capture = adapter.capture() {
            handler(capture)
        }
    }
}
