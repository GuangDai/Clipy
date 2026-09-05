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
///   disarmed until the next key-window activation;
/// - the user's preview auto-open preference
///   (`isAutoOpenPreferenceEnabled`, default on) gates dwell scheduling
///   independently of key status: while off, selection changes never open
///   the pane, but the manual ⌃Space toggle still works, and the next
///   selection change after re-enabling auto-opens again.
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
    /// the preview (Maccy's `previewDelay` default: 200 ms). The property is
    /// package (GOV-3): only this module schedules the dwell; the public
    /// `init(autoOpenDelay:)` parameter remains the seam.
    package let autoOpenDelay: Duration

    /// Whether dwell auto-open is armed. The panel's key status drives this
    /// (`panelBecameKey`/`panelResignedKey`) so a background panel never
    /// grows a preview. Package (GOV-3): arming is driven only by the
    /// in-module panel lifecycle methods.
    package private(set) var isAutoOpenEnabled = true

    /// The user-preference half of the auto-open gate
    /// (`PanelAppearanceSettings.isPreviewAutoOpenEnabled`, pushed in by
    /// `HistoryPanelView`). Unlike `isAutoOpenEnabled` — the transient
    /// key-status arming — this is a durable preference: while false, a
    /// selection change never schedules the dwell and a dwell already in
    /// flight never fires; the manual ⌃Space toggle and the manual-close
    /// suppression are unaffected. Re-enabling restores auto-open on the
    /// NEXT selection change (it never opens the pane by itself).
    /// Package (GOV-3): `HistoryPanelView` pushes the preference from the
    /// injected appearance snapshot inside this module.
    package var isAutoOpenPreferenceEnabled = true {
        didSet {
            if !isAutoOpenPreferenceEnabled {
                cancelPendingAutoOpen()
            }
        }
    }

    /// The pending dwell task; cancelled by every selection change, manual
    /// toggle, or panel transition.
    private var autoOpenTask: Task<Void, Never>?

    /// Exact target captured by the pending dwell. Purges can therefore
    /// invalidate only work owned by the removed/revised item.
    private var pendingAutoOpenItem: HistoryItemReference?

    /// Monotonic local invalidation fence. Cancellation remains an efficiency
    /// hint; a completion must also belong to the current generation before
    /// it can reopen or retarget the pane (review Card 9B).
    package private(set) var purgeGeneration = 0

    /// Set by a manual close; cleared by the next selection change. While
    /// set, dwell auto-open does not fire (Maccy's `autoOpenSuppressed`).
    private var isAutoOpenSuppressed = false

    public init(autoOpenDelay: Duration = .milliseconds(200)) {
        self.autoOpenDelay = autoOpenDelay
    }

    // MARK: - Selection dwell (Maccy `scheduleRetarget(lead:)`)

    /// The list selection changed. Cancels any pending dwell, clears the
    /// manual-close suppression, and — when auto-open is armed by both the
    /// panel's key status and the user preference — schedules the dwell that
    /// retargets/opens the preview. A `nil` selection closes
    /// an open preview immediately (nothing to preview).
    public func handleSelectionChange(_ item: HistoryItemReference?) {
        cancelPendingAutoOpen()
        isAutoOpenSuppressed = false
        guard let item else {
            if isOpen { closePreview() }
            return
        }
        guard isAutoOpenEnabled,
              isAutoOpenPreferenceEnabled,
              !isAutoOpenSuppressed
        else { return }
        scheduleAutoOpen(for: item)
    }

    /// Advances the exact reference of the item already visible in preview.
    /// Observation can revise an item without changing the list's ID-only
    /// selection; that is content coherence, not a new cross-item dwell.
    /// Closed/manual-suppressed panes stay closed.
    package func refreshOpenPreview(_ item: HistoryItemReference) {
        guard isOpen,
              let previewedItem,
              previewedItem.id == item.id,
              item.contentVersion.rawValue > previewedItem.contentVersion.rawValue
        else { return }
        cancelPendingAutoOpen()
        self.previewedItem = item
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
    /// into the next visible session (review Card 9E). Package (GOV-3): the
    /// panel-close path that resets this state is this module's
    /// `HistoryPanelView`; `panelBecameKey`/`panelResignedKey` above remain
    /// the ClipyApp panel seam.
    package func panelClosed() {
        cancelPendingAutoOpen()
        isOpen = false
        previewedItem = nil
        isAutoOpenSuppressed = false
        isAutoOpenEnabled = false
    }

    /// Applies one receipt-confirmed panel purge. Clear All drops every
    /// target; Clear Unpinned also drops rebuildable preview state because
    /// pre-receipt pin state is not authoritative; Remove drops that item;
    /// Revise retargets only the old exact reference.
    package func purge(_ scope: HistorySurfacePurge.Scope) {
        let invalidatesPending: Bool
        let invalidatesVisible: Bool
        switch scope {
        case .all:
            invalidatesPending = pendingAutoOpenItem != nil
            invalidatesVisible = previewedItem != nil
        case .unpinned:
            invalidatesPending = pendingAutoOpenItem != nil
            invalidatesVisible = previewedItem != nil
        case .item(let id):
            invalidatesPending = pendingAutoOpenItem?.id == id
            invalidatesVisible = previewedItem?.id == id
        case .revision(let old, let new):
            invalidatesPending = pendingAutoOpenItem == old
            invalidatesVisible = previewedItem == old

            guard invalidatesPending || invalidatesVisible else { return }
            purgeGeneration += 1
            if invalidatesPending {
                cancelPendingAutoOpen()
                scheduleAutoOpen(for: new)
            }
            if invalidatesVisible {
                previewedItem = new
            }
            return
        }

        guard invalidatesPending || invalidatesVisible || scope == .all else {
            return
        }
        purgeGeneration += 1
        if invalidatesPending {
            cancelPendingAutoOpen()
        }
        if invalidatesVisible {
            closePreview()
        }
    }

    // MARK: - Private

    private func scheduleAutoOpen(for item: HistoryItemReference) {
        let delay = autoOpenDelay
        let generation = purgeGeneration
        pendingAutoOpenItem = item
        // Inherits the MainActor from this isolated context; `weak self`
        // keeps a released pane from being pinned by its own dwell task.
        autoOpenTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            guard let self,
                  self.purgeGeneration == generation,
                  self.pendingAutoOpenItem == item,
                  self.isAutoOpenEnabled,
                  self.isAutoOpenPreferenceEnabled,
                  !self.isAutoOpenSuppressed
            else {
                return
            }
            self.pendingAutoOpenItem = nil
            self.autoOpenTask = nil
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
        pendingAutoOpenItem = nil
    }
}
