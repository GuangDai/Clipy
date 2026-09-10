/// PreviewPaneState.swift — the floating preview-pane state machine:
/// Maccy-style dwell-to-peek auto-open on selection change plus a manual
/// dismiss (Esc), replicated from Maccy's `SlideoutController`
/// (Maccy/Observables/SlideoutController.swift) onto HistoryCore DTOs.
///
/// Semantics replicated from Maccy:
/// - a selection change ARMS a dwell task (`autoOpenDelay`, default 200 ms)
///   while the preview is closed; when it fires, the preview opens on the
///   selected item. Every selection change cancels the pending task first —
///   the cancel-and-reschedule pair IS the debounce, so rapid arrow-key
///   movement never opens intermediate items;
/// - an OPEN preview follows keyboard selection immediately. Mouse selection
///   dwells before retargeting, so crossing another row on the way to the
///   preview's actions cannot replace the content being operated on;
/// - a manual close suppresses auto-open until the selection changes again
///   (`isAutoOpenSuppressed`), so the pane does not bounce back open under
///   the user's cursor;
/// - the panel's key status arms/disarms auto-open
///   (`panelBecameKey`/`panelResignedKey`); becoming key also RE-DWELLS the
///   retained current selection, because a summon publishes its preselected
///   row without any ordering guarantee against AppKit's key-window
///   callback (a selection change that arrives while still disarmed is
///   dropped by the dwell gate, and no later selection change follows);
///   panel close leaves auto-open disarmed until the next key-window
///   activation;
/// - the user's preview auto-open preference
///   (`isAutoOpenPreferenceEnabled`, default on) gates dwell scheduling
///   independently of key status: while off, selection changes never open
///   the pane, and the next selection change after re-enabling auto-opens
///   again;
/// - pointer presence across BOTH windows owns a lightweight exit
///   lifecycle: leaving the main panel AND the pane hides the preview
///   after a 150 ms grace (cancelled by re-entry into either). Unlike a
///   manual close this never engages the auto-open suppression, so
///   re-entering the rows re-dwells the current selection and reopens.
///   The whole lifecycle is gated on the panel's input mode
///   (`isPointerInteractionActive`): it activates only once a REAL mouse
///   movement takes pointer control, because SwiftUI `.onHover` delivers
///   synthesized exit events during window/frame churn and a keyboard
///   session has no pointer to ever re-enter — an unguarded exit would
///   cancel the pending dwell and the preview could never open.
///
/// The pane itself is the separate `FloatingPreviewPanel` window; this state
/// publishes imperative `onFloatingPreviewTransition` events (show / update
/// / hide) that the AppDelegate wiring maps onto that panel, while SwiftUI
/// content observes `previewedItem` directly.
///
/// Pure Foundation + HistoryCore: no AppKit, no SwiftData (01 §8).
import Foundation
import HistoryCore

/// The preview pane's open/closed/retarget state (01 §6: main-actor UI
/// state over HistoryCore DTOs only).
@MainActor @Observable
final class PreviewPaneState {

    /// The imperative transition the floating preview window must apply.
    /// `show` opens the pane on an item (closed→open); `update` retargets
    /// an already-open pane; `hide` orders it out.
    enum FloatingPreviewTransition: Equatable {
        case show(HistoryItemReference)
        case update(HistoryItemReference)
        case hide
    }

    /// A pointer-bearing surface whose presence keeps an open floating
    /// preview alive: the main browsing panel or the preview pane itself.
    enum PreviewPointerSurface: Equatable, Hashable {
        case mainPanel
        case preview
    }

    /// Whether the preview pane is visible.
    private(set) var isOpen = false

    /// Shared with the panel's Escape action so the topmost information
    /// popover closes before the preview, search, Quick Look, or the panel.
    var isInformationPresented = false

    /// The item whose content the preview pane renders; `nil` while
    /// closed. Reference-exact (item ID + Content Version) like every other
    /// panel surface (04 §9 fence convention).
    private(set) var previewedItem: HistoryItemReference?

    /// The screen/user size ceiling for a content-fitted preview; never a
    /// minimum and independent of the number of rows in the browsing list.
    var availablePreviewHeight: CGFloat = PanelGeometry.height

    /// The AppDelegate-owned wiring to the floating preview window. Set
    /// once by the composition shell; every state transition that changes
    /// what a window must show publishes exactly one event here.
    var onFloatingPreviewTransition: ((FloatingPreviewTransition) -> Void)?

    /// The dwell delay before a selection change auto-opens the preview
    /// (Maccy's `previewDelay` default: 200 ms). The property is
    /// package (GOV-3): only this module schedules the dwell; the public
    /// `init(autoOpenDelay:)` parameter remains the seam.
    let autoOpenDelay: Duration

    /// The grace between the pointer leaving BOTH surfaces and the
    /// lightweight pointer-exit hide (150 ms). Distinct from
    /// `autoOpenDelay`: this hide never engages the manual-close
    /// suppression, so pointer re-entry re-dwells the current selection.
    let pointerExitGrace: Duration

    /// Whether dwell auto-open is armed. The panel's key status drives this
    /// (`panelBecameKey`/`panelResignedKey`) so a background panel never
    /// opens a preview. Package (GOV-3): arming is driven only by the
    /// in-module panel lifecycle methods.
    private(set) var isAutoOpenEnabled = true

    /// The user-preference half of the auto-open gate
    /// (`PanelAppearanceSettings.isPreviewAutoOpenEnabled`, pushed in by
    /// `HistoryPanelView`). Unlike `isAutoOpenEnabled` — the transient
    /// key-status arming — this is a durable preference: while false, a
    /// selection change never schedules the dwell and a dwell already in
    /// flight never fires; manual dismissal and its suppression are
    /// unaffected. Re-enabling restores auto-open on the NEXT selection
    /// change (it never opens the pane by itself).
    /// Package (GOV-3): `HistoryPanelView` pushes the preference from the
    /// injected appearance snapshot inside this module.
    var isAutoOpenPreferenceEnabled = true {
        didSet {
            if !isAutoOpenPreferenceEnabled {
                cancelPendingAutoOpen()
            }
        }
    }

    /// The pending dwell task; cancelled by every selection change, manual
    /// toggle, or panel transition.
    private var autoOpenTask: Task<Void, Never>?

    /// Exact target captured by the pending dwell, including a current
    /// selection waiting for memory pressure to recover. Purges can therefore
    /// invalidate only work owned by the removed/revised item.
    private var pendingAutoOpenItem: HistoryItemReference?

    /// Monotonic local observation of receipt-confirmed purges. A purge of
    /// the visible item can leave a different item's pending dwell intact;
    /// dwell validity therefore follows its exact target and cancellation,
    /// rather than this surface-wide count (review Card 9B).
    private(set) var purgeGeneration = 0

    /// Set by a manual close; cleared by the next selection change. While
    /// set, dwell auto-open does not fire (Maccy's `autoOpenSuppressed`).
    private var isAutoOpenSuppressed = false
    private(set) var isAutoOpenSuspendedForMemoryPressure = false

    /// The panel's pointer-vs-keyboard input mode, pushed in by
    /// `HistoryPanelView` exactly like the auto-open preference above:
    /// the entire pointer lifecycle below is inert until a REAL mouse
    /// movement flips the panel into pointer interaction. SwiftUI
    /// `.onHover` also delivers SYNTHESIZED exit events during
    /// window/frame churn (the content-fit resize fires shortly after
    /// summon), and in keyboard mode — every session's start — the
    /// pointer is not over the panel, so an unguarded exit would cancel
    /// the pending dwell with no re-entry ever following: the preview
    /// could never open. Deactivation retires presence and any pending
    /// grace so stale pointer state cannot leak into a keyboard-driven
    /// session. Package (GOV-3): only the in-module panel view pushes
    /// this.
    var isPointerInteractionActive = false {
        didSet {
            guard !isPointerInteractionActive else { return }
            pointerPresence = []
            cancelPendingPointerExit()
        }
    }

    /// Surfaces currently under the pointer. The floating preview hides
    /// (lightweight, no suppression) only once BOTH have been empty for
    /// `pointerExitGrace`. Mutated only while
    /// `isPointerInteractionActive` is set.
    private var pointerPresence: Set<PreviewPointerSurface> = []

    /// The pending pointer-exit grace task; cancelled by any re-entry.
    private var pointerExitTask: Task<Void, Never>?

    /// The latest selection reference, retained across a pointer-exit hide
    /// so pointer re-entry can re-dwell the CURRENT selection without a
    /// selection change (the list selection is still on it).
    private var currentSelectionReference: HistoryItemReference?

    /// V2-09 §8: critical pressure stops speculative dwell work but retains
    /// only its current exact target. Normal resumes that demand, preserving
    /// manual-close, preference and panel-lifecycle cancellation. Repeated
    /// normal events cannot postpone an already running dwell.
    func respondToMemoryPressure(_ pressure: DisplayMemoryPressure) {
        switch pressure {
        case .normal:
            guard isAutoOpenSuspendedForMemoryPressure else { return }
            isAutoOpenSuspendedForMemoryPressure = false
            if let pendingAutoOpenItem {
                scheduleAutoOpen(for: pendingAutoOpenItem)
            }
        case .warning:
            break
        case .critical:
            isAutoOpenSuspendedForMemoryPressure = true
            autoOpenTask?.cancel()
            autoOpenTask = nil
        }
    }

    init(
        autoOpenDelay: Duration = .milliseconds(200),
        pointerExitGrace: Duration = .milliseconds(150)
    ) {
        self.autoOpenDelay = autoOpenDelay
        self.pointerExitGrace = pointerExitGrace
    }

    // MARK: - Selection dwell (Maccy `scheduleRetarget(lead:)`)

    /// The list selection changed. Cancels any pending dwell and clears the
    /// manual-close suppression. A `nil` selection closes an open preview
    /// immediately (nothing to preview). Keyboard selection and an explicit
    /// row click retarget an open preview immediately; pointer transit dwells.
    /// Opening a closed pane still respects the user's auto-open preference.
    func handleSelectionChange(_ item: HistoryItemReference?, isExplicit: Bool = false) {
        currentSelectionReference = item
        cancelPendingAutoOpen()
        isAutoOpenSuppressed = false
        guard let item else {
            if isOpen { closePreview() }
            return
        }
        if isOpen {
            guard previewedItem != item else { return }
            if isPointerInteractionActive, !isExplicit, previewedItem?.id != item.id,
               isAutoOpenEnabled, isAutoOpenPreferenceEnabled {
                scheduleAutoOpen(for: item)
                return
            }
            previewedItem = item
            onFloatingPreviewTransition?(.update(item))
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
    /// Closed/manual-suppressed panes stay closed. A different selected item's
    /// pending dwell keeps its original schedule.
    func refreshOpenPreview(_ item: HistoryItemReference) {
        guard isOpen,
              let previewedItem,
              previewedItem.id == item.id,
              item.contentVersion.rawValue > previewedItem.contentVersion.rawValue
        else { return }
        if pendingAutoOpenItem?.id == item.id {
            cancelPendingAutoOpen()
        }
        self.previewedItem = item
        onFloatingPreviewTransition?(.update(item))
    }

    // MARK: - Manual toggle (Maccy `togglePreview()`)

    /// The manual open/close surface: opens the preview for the current
    /// selection immediately; an open preview closes and stays closed
    /// (auto-open suppressed) until the selection changes.
    func togglePreview(for item: HistoryItemReference?) {
        cancelPendingAutoOpen()
        if isOpen {
            closePreview()
            isAutoOpenSuppressed = true
        } else if let item {
            previewedItem = item
            isOpen = true
            isAutoOpenSuppressed = false
            onFloatingPreviewTransition?(.show(item))
        }
    }

    /// The panel's Esc chain: dismisses an open floating preview as a
    /// manual close (auto-open suppressed until the selection changes).
    /// Returns whether the preview was open, so the chain can stop.
    @discardableResult
    func dismissPreview() -> Bool {
        guard isOpen else { return false }
        cancelPendingAutoOpen()
        closePreview()
        isAutoOpenSuppressed = true
        return true
    }

    /// Monotonic republished ⌘R retry requests. The floating pane is never
    /// the key window, so its own `.keyboardShortcut` cannot fire; the main
    /// panel's hidden shortcut captures the chord and republishes it here,
    /// and the pane's `HistoryPreviewView` applies it exactly like its
    /// Retry button (only while the loader exposes a retryable failure).
    private(set) var previewRetryRequestGeneration = 0

    func requestPreviewRetry() {
        previewRetryRequestGeneration += 1
    }

    /// The floating preview's page-step direction (the PDF pager).
    enum PreviewPagerDirection: Equatable, Sendable {
        case previous
        case next
    }

    /// Monotonic republished ⌥⌘←/→ pager requests, the exact twin of the
    /// ⌘R retry channel above: the floating pane is never key, so the main
    /// panel's hidden shortcuts capture the chords and republish them
    /// here, and the pane's `HistoryPreviewView` applies each request
    /// exactly like its pager buttons (the same `selectPDFPage` guards
    /// keep out-of-range steps inert). The quick-look overlay keeps its
    /// in-view shortcuts: the panel's copies are gated off while it is
    /// open, so a chord never double-handles.
    private(set) var previewPagerRequestGeneration = 0
    private(set) var previewPagerRequestDirection: PreviewPagerDirection = .next

    func requestPreviewPage(_ direction: PreviewPagerDirection) {
        previewPagerRequestDirection = direction
        previewPagerRequestGeneration += 1
    }

    // MARK: - Panel lifecycle (Maccy FloatingPanel ⇄ SlideoutController)

    /// The panel became key: arm dwell auto-open, then re-dwell the CURRENT
    /// selection when the pane is closed. The session's preselected row can
    /// reach `handleSelectionChange` before AppKit delivers this callback
    /// (a re-summon after `panelClosed` finds auto-open disarmed), and no
    /// later selection change follows in that flow — so key status is itself
    /// a dwell trigger, Maccy's becoming-key re-dwell of the lead selection.
    /// An already-pending dwell keeps its schedule (becoming key must not
    /// postpone it), manual-close suppression and the user preference keep
    /// their veto, and `scheduleAutoOpen` applies the critical-pressure
    /// deferral exactly like a selection change.
    func panelBecameKey() {
        isAutoOpenEnabled = true
        armAndDwellCurrentSelection()
    }

    /// The panel lost key: disarm dwell auto-open and drop any pending fire.
    func panelResignedKey() {
        isAutoOpenEnabled = false
        cancelPendingAutoOpen()
    }

    /// The panel closed: hide the pane and keep automatic opening disarmed
    /// until AppKit reports that the panel became key again. Selection
    /// changes published while the panel is hidden therefore cannot leak
    /// into the next visible session (review Card 9E). Package (GOV-3): the
    /// panel-close path that resets this state is this module's
    /// `HistoryPanelView`; `panelBecameKey`/`panelResignedKey` above remain
    /// the ClipyApp panel seam.
    func panelClosed() {
        cancelPendingAutoOpen()
        cancelPendingPointerExit()
        pointerPresence = []
        currentSelectionReference = nil
        if isOpen { closePreview() }
        previewedItem = nil
        isAutoOpenSuppressed = false
        isAutoOpenEnabled = false
    }

    // MARK: - Pointer lifecycle (both windows)

    /// The pointer entered a surface. Re-entry cancels a pending
    /// pointer-exit grace. Re-entry into the MAIN PANEL also re-dwells the
    /// current selection when the pane is closed and unsuppressed — the
    /// pointer-exit hide is lightweight, so the preview reopens without
    /// any selection change. A manual (Esc) close keeps its suppression
    /// across pointer cycles; only a selection change lifts it.
    /// Inert unless `isPointerInteractionActive` (keyboard-mode sessions
    /// get deterministic dwell-open instead).
    func pointerEntered(_ surface: PreviewPointerSurface) {
        guard isPointerInteractionActive else { return }
        pointerPresence.insert(surface)
        cancelPendingPointerExit()
        if surface == .preview, isOpen {
            // Keep the preview's current content while its controls are in
            // use. A transit across another row is not a new preview intent.
            cancelPendingAutoOpen()
            currentSelectionReference = previewedItem
        }
        guard surface == .mainPanel else { return }
        guard !isOpen,
              pendingAutoOpenItem == nil,
              let currentSelectionReference,
              isAutoOpenEnabled,
              isAutoOpenPreferenceEnabled,
              !isAutoOpenSuppressed,
              !isAutoOpenSuspendedForMemoryPressure
        else { return }
        scheduleAutoOpen(for: currentSelectionReference)
    }

    /// The pointer left a surface. Only once BOTH surfaces are empty: any
    /// pending dwell retires immediately (never open for an absent
    /// pointer), and an OPEN pane hides after `pointerExitGrace`.
    /// Inert unless `isPointerInteractionActive`, and a no-op for a
    /// surface the pointer never entered: `.onHover` synthesizes exit
    /// events during window/frame churn, and with an empty presence such
    /// an event must cancel nothing and start no grace.
    func pointerExited(_ surface: PreviewPointerSurface) {
        guard isPointerInteractionActive else { return }
        guard pointerPresence.contains(surface) else { return }
        pointerPresence.remove(surface)
        guard pointerPresence.isEmpty else { return }
        cancelPendingAutoOpen()
        guard isOpen, !isInformationPresented else { return }
        cancelPendingPointerExit()
        let grace = pointerExitGrace
        // Same MainActor/weak-self discipline as the dwell task.
        pointerExitTask = Task { [weak self] in
            if grace > .zero {
                try? await Task.sleep(for: grace)
            }
            guard !Task.isCancelled, let self, self.pointerPresence.isEmpty,
                  !self.isInformationPresented
            else { return }
            self.pointerExitTask = nil
            // Lightweight hide: no manual-close suppression — pointer
            // re-entry re-dwells the current selection and reopens.
            self.closePreview()
        }
    }

    /// Applies one receipt-confirmed panel purge. Clear All drops every
    /// target; Clear Unpinned also drops rebuildable preview state because
    /// pre-receipt pin state is not authoritative; Remove drops that item;
    /// Revise retargets only the old exact reference.
    func purge(_ scope: HistorySurfacePurge.Scope) {
        let invalidatesPending: Bool
        let invalidatesVisible: Bool
        switch scope {
        case .all:
            invalidatesPending = pendingAutoOpenItem != nil
            invalidatesVisible = previewedItem != nil
            currentSelectionReference = nil
        case .unpinned:
            invalidatesPending = pendingAutoOpenItem != nil
            invalidatesVisible = previewedItem != nil
            currentSelectionReference = nil
        case .item(let id):
            invalidatesPending = pendingAutoOpenItem?.id == id
            invalidatesVisible = previewedItem?.id == id
            if currentSelectionReference?.id == id {
                currentSelectionReference = nil
            }
        case .revision(let old, let new):
            invalidatesPending = pendingAutoOpenItem == old
            invalidatesVisible = previewedItem == old
            if currentSelectionReference == old {
                currentSelectionReference = new
            }

            guard invalidatesPending || invalidatesVisible else { return }
            purgeGeneration += 1
            if invalidatesPending {
                cancelPendingAutoOpen()
                scheduleAutoOpen(for: new)
            }
            if invalidatesVisible {
                previewedItem = new
                onFloatingPreviewTransition?(.update(new))
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

    /// The one key-status re-dwell trigger for the retained current
    /// selection, called only from `panelBecameKey` — never from the
    /// selection binding, so a binding echo cannot restart a dwell. The
    /// gates mirror `handleSelectionChange`'s closed→open path (arming was
    /// just applied by the caller); a pending dwell — including one
    /// retained for memory-pressure recovery — is left untouched.
    private func armAndDwellCurrentSelection() {
        guard !isOpen,
              pendingAutoOpenItem == nil,
              let currentSelectionReference,
              isAutoOpenPreferenceEnabled,
              !isAutoOpenSuppressed
        else { return }
        scheduleAutoOpen(for: currentSelectionReference)
    }

    private func scheduleAutoOpen(for item: HistoryItemReference) {
        pendingAutoOpenItem = item
        guard !isAutoOpenSuspendedForMemoryPressure else { return }
        let delay = autoOpenDelay
        // Inherits the MainActor from this isolated context; `weak self`
        // keeps a released pane from being pinned by its own dwell task.
        autoOpenTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            guard let self,
                  self.pendingAutoOpenItem == item,
                  self.isAutoOpenEnabled,
                  self.isAutoOpenPreferenceEnabled,
                  !self.isAutoOpenSuspendedForMemoryPressure,
                  !self.isAutoOpenSuppressed
            else {
                return
            }
            self.pendingAutoOpenItem = nil
            self.autoOpenTask = nil
            let wasOpen = self.isOpen
            self.previewedItem = item
            self.isOpen = true
            self.onFloatingPreviewTransition?(wasOpen ? .update(item) : .show(item))
        }
    }

    private func closePreview() {
        isOpen = false
        previewedItem = nil
        onFloatingPreviewTransition?(.hide)
    }

    private func cancelPendingAutoOpen() {
        autoOpenTask?.cancel()
        autoOpenTask = nil
        pendingAutoOpenItem = nil
    }

    private func cancelPendingPointerExit() {
        pointerExitTask?.cancel()
        pointerExitTask = nil
    }
}
