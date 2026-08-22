/// PreviewPaneState.swift — the preview-pane state machine: Maccy-style
/// dwell-to-peek auto-open on selection change plus a manual toggle
/// (⌃Space), replicated from Maccy's `SlideoutController`
/// (Maccy/Observables/SlideoutController.swift) onto HistoryCore DTOs.
///
/// Semantics replicated from Maccy:
/// - a selection change ARMS a dwell task (`autoOpenDelay`, default 200 ms);
///   when it fires, the preview retargets to the selected item and opens if
///   closed. Every selection change cancels the pending task first — the
///   cancel-and-reschedule pair IS the debounce, so rapid arrow-key
///   movement never opens intermediate items;
/// - a manual close suppresses auto-open until the selection changes again
///   (`isAutoOpenSuppressed`), so the pane does not bounce back open under
///   the user's cursor;
/// - the panel's key status arms/disarms auto-open
///   (`panelBecameKey`/`panelResignedKey`); panel close leaves auto-open
///   disarmed until the next key-window activation.
///
/// Pure Foundation + HistoryCore: no AppKit, no SwiftData (01 §8); the view
/// layer renders `previewedItem` and ClipyApp's panel observes `isOpen`.
import Foundation
import HistoryCore

/// The preview pane's open/closed/retarget state (01 §6: main-actor UI
/// state over HistoryCore DTOs only).
@MainActor @Observable
public final class PreviewPaneState {

    /// Whether the preview column is visible.
    public private(set) var isOpen = false

    /// The item whose content the preview column renders; `nil` while
    /// closed. Reference-exact (item ID + Content Version) like every other
    /// panel surface (04 §9 fence convention).
    public private(set) var previewedItem: HistoryItemReference?

    /// The dwell delay before a selection change auto-opens or retargets
    /// the preview (Maccy's `previewDelay` default: 200 ms).
    public let autoOpenDelay: Duration

    /// Whether dwell auto-open is armed. The panel's key status drives this
    /// (`panelBecameKey`/`panelResignedKey`) so a background panel never
    /// grows a preview.
    public private(set) var isAutoOpenEnabled = true

    /// The pending dwell task; cancelled by every selection change, manual
    /// toggle, or panel transition.
    private var autoOpenTask: Task<Void, Never>?

    /// Set by a manual close; cleared by the next selection change. While
    /// set, dwell auto-open does not fire (Maccy's `autoOpenSuppressed`).
    private var isAutoOpenSuppressed = false

    public init(autoOpenDelay: Duration = .milliseconds(200)) {
        self.autoOpenDelay = autoOpenDelay
    }

    // MARK: - Selection dwell (Maccy `scheduleRetarget(lead:)`)

    /// The list selection changed. Cancels any pending dwell, clears the
    /// manual-close suppression, and — when auto-open is armed — schedules
    /// the dwell that retargets/opens the preview. A `nil` selection closes
    /// an open preview immediately (nothing to preview).
    public func handleSelectionChange(_ item: HistoryItemReference?) {
        cancelPendingAutoOpen()
        isAutoOpenSuppressed = false
        guard let item else {
            if isOpen { closePreview() }
            return
        }
        guard isAutoOpenEnabled, !isAutoOpenSuppressed else { return }
        scheduleAutoOpen(for: item)
    }

    /// Advances the exact reference of the item already visible in preview.
    /// Observation can revise an item without changing the list's ID-only
    /// selection; that is content coherence, not a new cross-item dwell.
    /// Closed/manual-suppressed panes stay closed.
    package func refreshOpenPreview(_ item: HistoryItemReference) {
        guard isOpen, previewedItem?.id == item.id else { return }
        cancelPendingAutoOpen()
        previewedItem = item
    }

    // MARK: - Manual toggle (Maccy `togglePreview()`)

    /// The ⌃Space surface: opens the preview for the current selection
    /// immediately; an open preview closes and stays closed (auto-open
    /// suppressed) until the selection changes.
    public func togglePreview(for item: HistoryItemReference?) {
        cancelPendingAutoOpen()
        if isOpen {
            closePreview()
            isAutoOpenSuppressed = true
        } else if let item {
            previewedItem = item
            isOpen = true
            isAutoOpenSuppressed = false
        }
    }

    // MARK: - Panel lifecycle (Maccy FloatingPanel ⇄ SlideoutController)

    /// The panel became key: arm dwell auto-open.
    public func panelBecameKey() {
        isAutoOpenEnabled = true
    }

    /// The panel lost key: disarm dwell auto-open and drop any pending fire.
    public func panelResignedKey() {
        isAutoOpenEnabled = false
        cancelPendingAutoOpen()
    }

    /// The panel closed: clear the pane and keep automatic opening disarmed
    /// until AppKit reports that the panel became key again. Selection
    /// changes published while the panel is hidden therefore cannot leak
    /// into the next visible session (review Card 9E).
    public func panelClosed() {
        cancelPendingAutoOpen()
        isOpen = false
        previewedItem = nil
        isAutoOpenSuppressed = false
        isAutoOpenEnabled = false
    }

    // MARK: - Private

    private func scheduleAutoOpen(for item: HistoryItemReference) {
        let delay = autoOpenDelay
        // Inherits the MainActor from this isolated context; `weak self`
        // keeps a released pane from being pinned by its own dwell task.
        autoOpenTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            guard let self, self.isAutoOpenEnabled, !self.isAutoOpenSuppressed else {
                return
            }
            self.previewedItem = item
            self.isOpen = true
        }
    }

    private func closePreview() {
        isOpen = false
        previewedItem = nil
    }

    private func cancelPendingAutoOpen() {
        autoOpenTask?.cancel()
        autoOpenTask = nil
    }
}
