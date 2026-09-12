/// HistoryPanelView.swift — the floating-panel browsing surface: compact
/// search/action toolbar, history list inside the panel NavigationStack,
/// and a failure banner.
///
/// The panel is user-resizable (01 §8 keeps the AppKit window in ClipyApp):
/// the hosting window owns the live frame through `PanelGeometry`'s
/// persisted/clamped size, so this view carries NO fixed root frame — the
/// browsing column flexes with the window. The preview is a transient
/// FLOATING pane (`FloatingPreviewPanel`, a child window beside this panel)
/// driven by `PreviewPaneState`; it never enters this view's layout or the
/// window's geometry. A Space-triggered
/// quick-look overlay (`HistoryQuickLookOverlay`) can cover the whole
/// surface.
/// Owning spec: docs/01-architecture.md §5.2/§5.4/§5.6/§5.7 (gesture →
/// action, browse, paste hand-off via `requestPaste`, thumbnail), §6
/// (main-actor UI built only from HistoryCore DTOs);
/// docs/03b-instruction-set.md §10 (typed failures surfaced via
/// `FailurePresentation`); docs/04-coherence.md §5 (observation lifecycle:
/// activate/deactivate, snapshot replacement); UX principles and
/// accessibility per docs/v2/V2-07-ux.md §3/§9.
import Foundation
import HistoryCore
import SwiftUI

/// Pure Card 14A ordering rule shared by panel-open preparation and arrow
/// commands. `HistoryViewState.rows` is already the authoritative displayed
/// order, so this value never re-sorts or invents a parallel cursor model.
enum PanelSelectionDirection: Equatable {
    case previous
    case next
}

enum PanelSessionSelection {
    static func preparedSelection(
        in rows: [HistoryRow]
    ) -> HistoryItemID? {
        rows.first?.item.id
    }

    static func movedSelection(
        _ selection: HistoryItemID?,
        in rows: [HistoryRow],
        direction: PanelSelectionDirection
    ) -> HistoryItemID? {
        guard !rows.isEmpty else { return nil }
        guard let selection,
              let currentIndex = rows.firstIndex(where: {
                  $0.item.id == selection
              })
        else {
            return direction == .next
                ? rows.first?.item.id
                : rows.last?.item.id
        }
        let offset = direction == .next ? 1 : -1
        let targetIndex = min(
            max(rows.startIndex, currentIndex + offset),
            rows.index(before: rows.endIndex)
        )
        return rows[targetIndex].item.id
    }
}

/// Pointer-vs-keyboard arbitration for hover selection (Maccy's
/// `NavigationManager.isKeyboardNavigating`). A session starts in keyboard
/// mode and arrow/shortcut movement keeps it there; only a REAL
/// mouse-movement event — an `NSTrackingArea` on the list area, never
/// SwiftUI hover, which also fires when content scrolls beneath a
/// STATIONARY pointer — restores pointer control.
enum PanelInputMode: Equatable {
    case mouse
    case keyboard
}

/// The list selection reconciled against the latest authoritative rows.
/// The ID remains the list-control identity, while `reference` is the exact
/// content target consumed by preview. A row removal clears both; a same-ID
/// ContentVersion advance changes this value (review Card 9A).
struct PreviewSelectionResolution: Equatable {
    let selectedID: HistoryItemID?
    let reference: HistoryItemReference?
    private let availableReferences: [HistoryItemID: HistoryItemReference]

    static func resolve(
        selectedID: HistoryItemID?,
        rows: [HistoryRow]
    ) -> PreviewSelectionResolution {
        let availableReferences = Dictionary(
            rows.map { ($0.item.id, $0.item) },
            uniquingKeysWith: { first, _ in first }
        )
        guard let selectedID,
              let reference = availableReferences[selectedID]
        else {
            return PreviewSelectionResolution(
                selectedID: nil,
                reference: nil,
                availableReferences: availableReferences
            )
        }
        return PreviewSelectionResolution(
            selectedID: selectedID,
            reference: reference,
            availableReferences: availableReferences
        )
    }

    /// Keeps PreviewPaneState's cross-item dwell target, but immediately
    /// advances the exact reference when observation revises that same item.
    /// A missing selected row invalidates preview immediately.
    func previewTarget(
        previewedItem: HistoryItemReference?
    ) -> HistoryItemReference? {
        guard reference != nil,
              let previewedItem,
              let observed = availableReferences[previewedItem.id]
        else { return nil }
        // A revision receipt can advance the pane before observation catches
        // up. Both are authoritative references; use the newer ContentVersion
        // (including revert's new version, 02 §11), never the stale page. This
        // lookup follows the displayed item's ID even while another selection
        // is dwelling or auto-open is disabled.
        return observed.contentVersion.rawValue >= previewedItem.contentVersion.rawValue
            ? observed : previewedItem
    }
}

/// The footer's context-keyed shortcut cheat-sheet (V2-07 §9): one pure
/// mapping owns the hint literals so the panel can never advertise a chord
/// its shortcut surfaces do not implement. Chords verified against
/// `hiddenShortcuts` (Esc clears an active search before closing the panel)
/// and HistoryListView's selection shortcuts (⏎ paste, ⌘I details); the
/// arrows move the selection through SearchHeaderView's arrow-key seam and
/// bare Space is the quick-look toggle.
enum PanelFooterShortcutHints {
    static func text(
        isSearchActive: Bool,
        bundle: Bundle? = nil
    ) -> String {
        PanelFooterCopy.text(
            isSearchActive
                ? "↑↓ Select · Esc Clear"
                : "⏎ Paste · Space Quick Look · ⌘I Details",
            bundle: bundle ?? .main
        )
    }
}

/// State owned by one AppDelegate-hosted panel surface and purged only after
/// `HistoryViewState` publishes a receipt-confirmed destructive/effective
/// commit (review Card 9B). Keeping the coordination beside the panel avoids
/// a global cache bus: navigation, selection, preview, and thumbnail storage
/// all have the same lifetime and one monotonic applied generation.
@MainActor @Observable
final class HistoryPanelSurfaceState {
    var detailsPath: [HistoryItemReference] = []
    var selection: HistoryItemID?
    /// The exact item the Space-triggered quick-look overlay renders.
    /// Reference-exact like the preview target and retired by the same
    /// purge/session transitions as the selection, so overlay content can
    /// never outlive its authoritative row (review Card 9B).
    var quickLookReference: HistoryItemReference?
    let thumbnails: ThumbnailStore
    private(set) var appliedPurgeGeneration = 0
    private(set) var sessionGeneration = 0
    private(set) var isSessionActive = false
    private(set) var memoryPressure: DisplayMemoryPressure = .normal
    private(set) var memoryPressureGeneration = 0
    var isAtListRoot: Bool { detailsPath.isEmpty }

    func respondToMemoryPressure(_ pressure: DisplayMemoryPressure) {
        memoryPressure = pressure
        memoryPressureGeneration += 1
        thumbnails.respondToMemoryPressure(pressure)
        previewState.respondToMemoryPressure(pressure)
    }
    private(set) var detailsPurgeGeneration = 0

    private let previewState: PreviewPaneState
    /// A panel can open before its first authoritative page arrives because
    /// `HistoryViewState.activate()` clears the previous snapshot
    /// synchronously. This one-shot bit distinguishes that empty bootstrap
    /// from an intentional nil selection after a selected row is retired.
    private var isAwaitingInitialSelection = false
    /// The last authoritative filter distinguishes user navigation from a
    /// selected row disappearing in a later commit under the same query.
    private var selectionFilter = HistoryFilter.all

    /// Hover selects only in mouse mode; in keyboard mode the hovered row
    /// is remembered and applied — WITHOUT scrolling — when the mouse next
    /// moves (Maccy's `hoverSelectionWhileKeyboardNavigating` deferral).
    private(set) var inputMode: PanelInputMode = .keyboard
    private(set) var deferredHoverSelection: HistoryItemID?

    init(
        history: any ClipboardHistory,
        previewState: PreviewPaneState,
        baselinePurgeGeneration: Int = 0
    ) {
        self.previewState = previewState
        thumbnails = ThumbnailStore(history: history)
        appliedPurgeGeneration = baselinePurgeGeneration
    }

    /// Composition-root initializer for the one AppDelegate-owned panel
    /// surface. PresentationUI reads the current purge baseline internally so
    /// a surface created after an earlier commit never replays stale work.
    convenience init(
        viewState: HistoryViewState,
        previewState: PreviewPaneState
    ) {
        self.init(
            history: viewState.history,
            previewState: previewState,
            baselinePurgeGeneration:
                viewState.surfacePurge?.generation ?? 0
        )
    }

    /// Applies each monotonic purge at most once. Clear All removes all local
    /// state; Clear Unpinned also retires rebuildable derived navigation state
    /// because pre-receipt pin state is not authoritative. Remove scopes to
    /// one item; Revise scopes to the old exact reference. The quick-look
    /// overlay's exact reference follows the selection/details clearing of
    /// each scope.
    func apply(_ purge: HistorySurfacePurge) {
        guard purge.generation > appliedPurgeGeneration else { return }
        let expectedGeneration = appliedPurgeGeneration + 1
        appliedPurgeGeneration = purge.generation

        // SwiftUI observation is latest-value delivery, not an event queue.
        // If two receipts coalesce before one render, an exact purge was
        // skipped; reset this one surface so sensitive state from that commit
        // cannot survive (review Card 9B). The common consecutive path stays
        // precise.
        let scope: HistorySurfacePurge.Scope =
            purge.generation == expectedGeneration ? purge.scope : .all

        switch scope {
        case .all:
            detailsPurgeGeneration += 1
            detailsPath.removeAll()
            isAwaitingInitialSelection = false
            selection = nil
            quickLookReference = nil
            deferredHoverSelection = nil
        case .unpinned:
            detailsPurgeGeneration += 1
            detailsPath.removeAll()
            isAwaitingInitialSelection = false
            selection = nil
            quickLookReference = nil
            deferredHoverSelection = nil
        case .item(let id):
            if detailsPath.contains(where: { $0.id == id }) {
                detailsPurgeGeneration += 1
            }
            detailsPath.removeAll { $0.id == id }
            if selection == id {
                isAwaitingInitialSelection = false
                selection = nil
            }
            if quickLookReference?.id == id {
                quickLookReference = nil
            }
            if deferredHoverSelection == id {
                deferredHoverSelection = nil
            }
        case .revision(let old, _):
            if detailsPath.contains(old) {
                detailsPurgeGeneration += 1
            }
            detailsPath.removeAll { $0 == old }
            if quickLookReference == old {
                quickLookReference = nil
            }
        }
        previewState.purge(scope)
        thumbnails.purge(scope)
    }

    /// Starts one AppDelegate-owned panel session. Selection follows the
    /// authoritative display order; the view observes `sessionGeneration`
    /// only to move first responder into search (Card 14A/14D).
    func beginSession(rows: [HistoryRow]) {
        sessionGeneration += 1
        isSessionActive = true
        selectionFilter = .all
        inputMode = .keyboard
        deferredHoverSelection = nil
        thumbnails.isSurfaceActive = true
        detailsPath.removeAll()
        quickLookReference = nil
        selection = PanelSessionSelection.preparedSelection(in: rows)
        isAwaitingInitialSelection = selection == nil
    }

    /// Ends one session and retires content-bearing transient UI state. The
    /// raw search draft intentionally survives reopen; selection/details/
    /// preview/quick look do not (approved Card 14A close policy).
    func endSession() {
        guard isSessionActive else { return }
        isSessionActive = false
        thumbnails.isSurfaceActive = false
        detailsPath.removeAll()
        isAwaitingInitialSelection = false
        selection = nil
        quickLookReference = nil
        inputMode = .keyboard
        deferredHoverSelection = nil
        previewState.panelClosed()
    }

    /// Retargets only the currently open exact Details destination after that
    /// child has crossed an authoritative editor read/receipt boundary. This
    /// is not a purge: selection, preview, thumbnails, generations, and other
    /// path entries are untouched. A later revision purge naming `old` then
    /// cannot pop the already-retargeted `new` destination.
    @discardableResult
    func advanceOpenDetailsReference(
        from old: HistoryItemReference,
        to new: HistoryItemReference
    ) -> Bool {
        guard old.id == new.id,
              new.contentVersion >= old.contentVersion,
              detailsPath.last == old
        else { return false }
        detailsPath[detailsPath.count - 1] = new
        return true
    }

    func reconcileSessionSelection(
        rows: [HistoryRow],
        hasAuthoritativeFirstPage: Bool = true,
        selectsVisibleWindow: Bool = false,
        filter: HistoryFilter = .all
    ) {
        guard isSessionActive else { return }
        // Query restart synchronously clears `HistoryViewState.rows` before
        // the replacement observation publishes its first authoritative page.
        // That loading gap is not evidence that the selected item was removed:
        // preserve both an existing selection and the one-shot initial-open
        // intent until a replacement page (including an authoritative empty
        // page) actually arrives. Merely ending loading with a failure is not
        // authoritative removal evidence (review Card 8A/8C).
        guard hasAuthoritativeFirstPage else { return }
        let filterChanged = selectionFilter != filter
        selectionFilter = filter
        quickLookReference = resolvedQuickLookReference(in: rows)
        guard let selection else {
            guard isAwaitingInitialSelection || filterChanged else { return }
            self.selection = PanelSessionSelection.preparedSelection(in: rows)
            if self.selection != nil {
                isAwaitingInitialSelection = false
            }
            return
        }
        guard rows.contains(where: { $0.item.id == selection }) else {
            isAwaitingInitialSelection = false
            // Filter changes and page navigation keep a visible keyboard
            // target. A deletion within the same query still clears it.
            self.selection = selectsVisibleWindow || filterChanged
                ? PanelSessionSelection.preparedSelection(in: rows) : nil
            return
        }
        isAwaitingInitialSelection = false
    }

    func moveSelection(
        in rows: [HistoryRow],
        direction: PanelSelectionDirection
    ) {
        guard isSessionActive else { return }
        noteKeyboardNavigation()
        isAwaitingInitialSelection = false
        selection = PanelSessionSelection.movedSelection(
            selection,
            in: rows,
            direction: direction
        )
    }

    /// Arrow/shortcut selection movement is keyboard intent: hover stops
    /// selecting live and defers until the mouse next moves.
    func noteKeyboardNavigation() {
        inputMode = .keyboard
    }

    /// A real mouse-movement event over the list area restores mouse mode
    /// and applies any hover deferred during keyboard navigation. Hover
    /// selection never scrolls: this writes the ID-only selection directly
    /// and the list carries no scroll-to-selection path it could trigger.
    func notePointerMovement() {
        guard inputMode == .keyboard else { return }
        inputMode = .mouse
        guard let hovered = deferredHoverSelection else { return }
        deferredHoverSelection = nil
        selection = hovered
    }

    /// The pointer entered a row. Mouse mode selects it immediately —
    /// never scrolling — so selection dwell yields hover-preview. Keyboard
    /// mode only remembers the row, so arrows and the pointer never fight;
    /// the deferral applies on the next real mouse movement.
    func handleRowHover(_ id: HistoryItemID) {
        guard isSessionActive, selection != id else { return }
        switch inputMode {
        case .mouse:
            selection = id
        case .keyboard:
            deferredHoverSelection = id
        }
    }

    /// Retarget a selected row absent from the rendered lanes. The caller
    /// supplies an authoritative page; nil selections remain intentionally
    /// clear. Query replacement uses `reconcileSessionSelection` first so it
    /// can distinguish a changed filter from a same-query deletion.
    func retargetHiddenSelectionToDisplayedDefault(
        displayedRows: [HistoryRow]
    ) {
        guard isSessionActive else { return }
        quickLookReference = resolvedQuickLookReference(in: displayedRows)
        guard let selection else { return }
        guard !displayedRows.contains(where: { $0.item.id == selection })
        else { return }
        self.selection = PanelSessionSelection.preparedSelection(
            in: displayedRows
        )
    }

    /// Quick Look keeps its trigger-time target until that item is hidden,
    /// removed, or revised. Resolve directly for rendering as well as state
    /// reconciliation, so invalid content does not wait for an onChange
    /// callback to disappear. Older rows cannot retire a newer known target,
    /// and a query-loading gap is not authoritative absence.
    func resolvedQuickLookReference(
        in rows: [HistoryRow],
        hasAuthoritativeFirstPage: Bool = true
    ) -> HistoryItemReference? {
        guard let quickLookReference else { return nil }
        guard hasAuthoritativeFirstPage else { return quickLookReference }
        guard let row = rows.first(where: { $0.item.id == quickLookReference.id }),
              row.item.contentVersion <= quickLookReference.contentVersion
        else { return nil }
        return quickLookReference
    }

    /// Exact executable list-root selection for both the AppKit Return path
    /// and the search field's submit callback. A pushed Details/editor owns
    /// keyboard input; its retained background selection cannot be pasted.
    func selectedReference(
        in rows: [HistoryRow]
    ) -> HistoryItemReference? {
        guard isAtListRoot, let selection else { return nil }
        return rows.first(where: { $0.item.id == selection })?.item
    }
}

/// The composition point ClipyApp hosts inside its floating panel window.
/// Receives the one AppDelegate-owned `HistoryPanelSurfaceState` in production
/// (previews/tests may construct the same type locally). That state owns the
/// reference-exact `ThumbnailStore`, hoisted list selection, and panel details
/// navigation: the stack root is the list and
/// `HistoryItemReference` values push `HistoryDetailsView`.
///
/// The preview pane (`PreviewPaneState`) is INJECTED by the composition
/// root so the AppKit panel can drive its lifecycle hooks
/// (`panelBecameKey`/`panelResignedKey` — `panelClosed` is a module-internal
/// hook the panel surface itself calls). The floating preview window
/// subscribes to the state through `onFloatingPreviewTransition`, wired by
/// the AppDelegate — PresentationUI itself never touches AppKit (01 §8).
///
/// `appearance` is the loaded `PanelAppearanceSettings` snapshot (row
/// density and typography threaded to the list, preview auto-open pushed
/// into `PreviewPaneState`'s preference gate); the default keeps the shipped
/// look and behavior.
/// `keepPanelOpenIsActive`/`onToggleKeepPanelOpen` admit the composition
/// root's opt-in keep-open menu item. The app-facing icon seam is the
/// PUBLIC `SourceIconProvider` (`SourceIconStore` is package vocabulary the
/// public signature cannot name): the view builds and owns one per-surface
/// store from it, and only in-package callers inject a store directly.
struct HistoryPanelView: View {
    @Environment(\.locale) private var locale

    private let viewState: HistoryViewState
    private let previewState: PreviewPaneState
    private let appearance: PanelAppearanceSettings
    private let keepPanelOpenIsActive: Bool
    private let onToggleKeepPanelOpen: (() -> Void)?
    /// The per-surface icon store consulted by the rows. `@State` (the same
    /// idiom as `surfaceState` below) preserves the FIRST value across body
    /// re-evaluations: the public seam builds its store from the injected
    /// provider inside the initializer, and a plain `let` would rebuild —
    /// and empty — the cache on every evaluation.
    @State private var sourceIcons: SourceIconStore?
    private let onPauseCapture: (() -> Void)?
    private let onOpenSettings: () -> Void
    private let onQuit: () -> Void
    private let onRequestClose: () -> Void
    /// Reports the analytic content-fit snapshot (`PanelContentFit.Input`)
    /// whenever the displayed rows or chrome change; the composition root
    /// coalesces and applies it to the hosting window. Nil in previews and
    /// view-only tests leaves the view frameless as before.
    private let onContentFitChange: ((PanelContentFit.Input) -> Void)?

    @State private var surfaceState: HistoryPanelSurfaceState
    @State private var dismissedFailureEpisode: Int?
    @State private var pendingClear: ClearScope?
    @FocusState private var isSearchFieldFocused: Bool

    /// The app-facing entry point. Calls that do not name `sourceIcons:`
    /// resolve here because the designated initializer below requires that
    /// label (the app cannot name `SourceIconStore` anyway — that type is
    /// package vocabulary), so the public seam takes the PUBLIC
    /// `SourceIconProvider` instead and builds the store internally. The
    /// default `.none` provider resolves every bundle ID to nil, keeping
    /// the rows on today's fallback symbols.
    init(
        viewState: HistoryViewState,
        previewState: PreviewPaneState,
        surfaceState: HistoryPanelSurfaceState? = nil,
        onPauseCapture: (() -> Void)? = nil,
        onOpenSettings: @escaping () -> Void = {},
        onQuit: @escaping () -> Void = {},
        onRequestClose: @escaping () -> Void = {},
        appearance: PanelAppearanceSettings = PanelAppearanceSettings(),
        keepPanelOpenIsActive: Bool = false,
        onToggleKeepPanelOpen: (() -> Void)? = nil,
        sourceIconProvider: SourceIconProvider = .none,
        onContentFitChange: ((PanelContentFit.Input) -> Void)? = nil
    ) {
        self.init(
            viewState: viewState,
            previewState: previewState,
            surfaceState: surfaceState,
            onPauseCapture: onPauseCapture,
            onOpenSettings: onOpenSettings,
            onQuit: onQuit,
            onRequestClose: onRequestClose,
            appearance: appearance,
            keepPanelOpenIsActive: keepPanelOpenIsActive,
            onToggleKeepPanelOpen: onToggleKeepPanelOpen,
            sourceIcons: SourceIconStore(provider: sourceIconProvider),
            onContentFitChange: onContentFitChange
        )
    }

    /// The in-package designated initializer. `sourceIcons` is deliberately
    /// NOT defaulted: the public overload above differs only in its trailing
    /// parameter (`sourceIconProvider`), and a second defaulted tail would
    /// make every call naming neither trailing parameter ambiguous — the
    /// public init wins those calls precisely because this one requires
    /// `sourceIcons:` to be named.
    ///
    /// The inferred main-actor isolation of `View` (01 §6: main-actor UI)
    /// covers this initializer, which constructs the `@MainActor`
    /// `ThumbnailStore` for `viewState.history` (01 §5.7).
    init(
        viewState: HistoryViewState,
        previewState: PreviewPaneState,
        surfaceState: HistoryPanelSurfaceState? = nil,
        onPauseCapture: (() -> Void)? = nil,
        onOpenSettings: @escaping () -> Void = {},
        onQuit: @escaping () -> Void = {},
        onRequestClose: @escaping () -> Void = {},
        appearance: PanelAppearanceSettings = PanelAppearanceSettings(),
        keepPanelOpenIsActive: Bool = false,
        onToggleKeepPanelOpen: (() -> Void)? = nil,
        sourceIcons: SourceIconStore?,
        onContentFitChange: ((PanelContentFit.Input) -> Void)? = nil
    ) {
        self.viewState = viewState
        self.previewState = previewState
        self.appearance = appearance
        self.keepPanelOpenIsActive = keepPanelOpenIsActive
        self.onToggleKeepPanelOpen = onToggleKeepPanelOpen
        self.onPauseCapture = onPauseCapture
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        self.onRequestClose = onRequestClose
        self.onContentFitChange = onContentFitChange
        _sourceIcons = State(initialValue: sourceIcons)
        _surfaceState = State(
            initialValue: surfaceState ?? HistoryPanelSurfaceState(
                history: viewState.history,
                previewState: previewState,
                baselinePurgeGeneration: viewState.surfacePurge?.generation ?? 0
            )
        )
    }

    var body: some View {
        ZStack {
            mainColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.displayMemoryPressure, surfaceState.memoryPressure)
            .environment(\.displayMemoryPressureGeneration, surfaceState.memoryPressureGeneration)
            .onChange(of: surfaceState.memoryPressureGeneration, initial: true) { _, _ in
                sourceIcons?.respondToMemoryPressure(surfaceState.memoryPressure)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("clipy.panel.root")
            .background { hiddenShortcuts }
            .task(id: surfaceState.sessionGeneration) {
                guard surfaceState.isSessionActive else { return }
                reconcileSelectionWithDisplayedDefault()
                isSearchFieldFocused = true
            }
            // Pointer presence across BOTH windows owns the preview's
            // lightweight exit lifecycle (150 ms grace, no manual-close
            // suppression); FloatingPreviewRootView reports the pane half.
            .onHover { isInside in
                if isInside {
                    previewState.pointerEntered(.mainPanel)
                } else {
                    previewState.pointerExited(.mainPanel)
                }
            }
            // The injected appearance snapshot owns the preference half of
            // PreviewPaneState's auto-open gate; `initial: true` covers the
            // first appearance, later changes repush (a re-enabled preference
            // takes effect on the NEXT selection change by gate contract).
            .onChange(of: appearance, initial: true) { _, newAppearance in
                previewState.isAutoOpenPreferenceEnabled =
                    newAppearance.isPreviewAutoOpenEnabled
            }
            // The input-mode machine gates the preview's pointer
            // lifecycle: sessions begin in keyboard mode and only a REAL
            // mouse movement flips to pointer control, so a synthesized
            // `.onHover` exit during window/frame churn can never cancel
            // the selection dwell while no pointer is over the panel.
            .onChange(of: surfaceState.inputMode, initial: true) { _, mode in
                previewState.isPointerInteractionActive = mode == .mouse
            }
            // The content-fit oracle: any change to the displayed rows,
            // typography, or chrome republishes the analytic height demand;
            // the composition root coalesces and fits the hosting window.
            .onChange(of: contentFitInput, initial: true) { _, input in
                onContentFitChange?(input)
            }
            .onChange(of: surfaceState.isSessionActive, initial: true) { _, isActive in
                sourceIcons?.isSurfaceActive = isActive
                if !isActive { isSearchFieldFocused = false }
            }
            .onChange(of: surfaceState.isAtListRoot) { _, isAtRoot in
                if !isAtRoot { isSearchFieldFocused = false }
            }
            .onChange(of: surfaceState.selection) { _, newSelection in
                previewState.handleSelectionChange(
                    PreviewSelectionResolution.resolve(
                        selectedID: newSelection,
                        rows: viewState.rows
                    ).reference
                )
            }
            // An authoritative row replacement can change the exact reference
            // while the ID-only list selection stays fixed (Card 9A).
            .onChange(of: previewSelection.reference) { _, reference in
                guard let reference else {
                    // A query restart temporarily empties rows before its first
                    // replacement page. That loading placeholder cannot retire
                    // an otherwise valid selection; Return remains disabled by
                    // the exact-reference check until authoritative rows return.
                    guard viewState.hasAuthoritativeFirstPage else { return }
                    // The same reconciliation owns filter replacement,
                    // page navigation, and deletion; callback order must not
                    // clear a filter-hidden selection before it can retarget.
                    reconcileSelectionWithDisplayedDefault()
                    return
                }
                // Preserve cross-ID dwell and manual-close suppression. Only an
                // already-open preview of this same item needs state retargeting.
                if previewState.isOpen, previewState.previewedItem?.id == reference.id {
                    previewState.refreshOpenPreview(reference)
                }
            }
            // Pin-only membership can change without changing any item
            // reference or raw ordering. Reconcile the rows actually shown
            // so an observed Unpin also retires a now-hidden selection.
            .onChange(of: viewState.displayedRows.map(\.item)) { _, _ in
                reconcileSelectionWithDisplayedDefault()
            }
            // An authoritative empty replacement can leave `rows == []` across
            // the whole generation, so rows alone cannot trigger reconciliation.
            // The first authoritative page fact must be part of the owner signal.
            .onChange(of: viewState.hasAuthoritativeFirstPage) { _, _ in
                reconcileSelectionWithDisplayedDefault()
            }
            // A changed filter may settle before this render. Reconcile
            // with the complete query shape regardless of callback order;
            // loading placeholders preserve the previous selection.
            .onChange(of: viewState.typeFilter) { _, _ in
                reconcileSelectionWithDisplayedDefault()
            }
            .onChange(of: viewState.showsPinnedOnly) { _, _ in
                reconcileSelectionWithDisplayedDefault()
            }
            .onChange(of: resolvedPreviewTarget) { _, target in
                guard previewState.isOpen else { return }
                if let target {
                    // The visible item can change version while selection is
                    // on another row. Retain that new exact target so a later
                    // stale page cannot make the loader go backwards.
                    previewState.refreshOpenPreview(target)
                    return
                }
                // The selected row may still exist while the previously displayed
                // cross-item dwell target was removed. Close only the preview;
                // preserve the valid list selection and restart its dwell from
                // this authoritative transition.
                previewState.handleSelectionChange(nil)
                previewState.handleSelectionChange(previewSelection.reference)
            }
            .onChange(of: viewState.surfacePurge, initial: true) { _, purge in
                guard let purge else { return }
                surfaceState.apply(purge)
            }
            .confirmationDialog(
                clearConfirmationTitle,
                isPresented: clearConfirmationPresented,
                titleVisibility: .visible
            ) {
                clearConfirmationActions
            } message: {
                Text(clearConfirmationMessage)
            }
            .disabled(surfaceState.quickLookReference != nil)

            // The quick-look overlay layers above the whole browsing panel;
            // it renders only while the surface
            // state holds a trigger-time exact reference.
            if let quickLookItem = surfaceState.resolvedQuickLookReference(
                in: displayedSelectionRows,
                hasAuthoritativeFirstPage: viewState.hasAuthoritativeFirstPage
            ) {
                HistoryQuickLookOverlay(
                    viewState: viewState,
                    previewState: previewState,
                    item: quickLookItem,
                    sourceIcons: sourceIcons,
                    onDismiss: { surfaceState.quickLookReference = nil }
                )
                // Removed/revised content must not remain visible as a
                // retained fading-out view after its target is invalidated.
                .transition(.identity)
            }
        }
    }

    // MARK: Main column

    /// Search and secondary actions share the list's compact toolbar.
    /// Details and its editor own their navigation and window drag surface.
    private var browsingHeader: some View {
        HStack(alignment: .top, spacing: PanelTheme.spacingXSmall) {
            SearchHeaderView(
                viewState: viewState,
                searchFieldFocused: $isSearchFieldFocused,
                onMoveSelection: { offset in
                    surfaceState.moveSelection(
                        in: displayedSelectionRows,
                        direction: offset < 0 ? .previous : .next
                    )
                },
                onSubmitSelection: {
                    guard let selected = surfaceState.selectedReference(
                        in: viewState.displayedRows
                    )
                    else { return }
                    viewState.requestPasteFromDisplayedRow(selected)
                }
            )
            panelActions
        }
        .padding(.horizontal, PanelTheme.headerHorizontalPadding)
        .padding(.top, PanelTheme.headerTopPadding)
        .padding(.bottom, PanelTheme.headerBottomPadding)
        .task {
            // Returning from Details inserts a new field. Hand it focus only
            // once its focused binding is mounted, not during path removal.
            guard surfaceState.isAtListRoot, surfaceState.isSessionActive else { return }
            isSearchFieldFocused = true
        }
        .background {
            // Only the header's empty background drags the window;
            // foreground search controls keep their own interactions.
            // List drag-out remains independent.
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents()
        }
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            if surfaceState.isAtListRoot {
                browsingHeader
            }

            NavigationStack(path: $surfaceState.detailsPath) {
                HistoryListView(
                    viewState: viewState,
                    thumbnails: surfaceState.thumbnails,
                    density: appearance.rowDensity,
                    snippetLineCount: appearance.snippetLineCount,
                    fontSize: appearance.rowFontSize,
                    isSearchFieldFocused: isSearchFieldFocused,
                    selection: $surfaceState.selection,
                    onFocusHistory: {
                        isSearchFieldFocused = false
                        // An actual click is a choice, not pointer transit.
                        // Publish it before a subsequent preview-button click.
                        previewState.handleSelectionChange(
                            surfaceState.selectedReference(in: viewState.displayedRows),
                            isExplicit: true
                        )
                    },
                    onHoverRow: { id in surfaceState.handleRowHover(id) },
                    onKeyboardNavigation: { surfaceState.noteKeyboardNavigation() },
                    onPointerMovement: { surfaceState.notePointerMovement() },
                    onShowDetails: { item in surfaceState.detailsPath.append(item) }
                )
                .navigationDestination(for: HistoryItemReference.self) { item in
                    HistoryDetailsView(
                        viewState: viewState,
                        item: item,
                        onReferenceAdvance: { old, new in
                            surfaceState.advanceOpenDetailsReference(
                                from: old,
                                to: new
                            )
                        }
                    )
                }
            }
            .id(surfaceState.detailsPurgeGeneration)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            failureBanner
        }
        // Restrained motion, SwiftUI-local only: the failure banner's
        // appearance animates inside the browsing column.
        .animation(
            .easeInOut(duration: 0.18),
            value: isFailureBannerVisible
        )
    }

    /// One lookup supplies both list reconciliation and preview's exact
    /// reference, making authoritative row replacement part of the change key.
    private var previewSelection: PreviewSelectionResolution {
        PreviewSelectionResolution.resolve(
            selectedID: surfaceState.selection,
            rows: viewState.rows
        )
    }

    private var resolvedPreviewTarget: HistoryItemReference? {
        previewSelection.previewTarget(
            previewedItem: previewState.previewedItem
        )
    }

    /// The analytic height oracle's input: the displayed section rows
    /// mapped to height descriptors, the row typography, and the chrome
    /// flags — the exact conditions the search header, list, and failure
    /// banner render with, so the fit cannot drift from the layout. A
    /// pushed Details/editor destination or the quick-look overlay renders
    /// across the whole panel while the list rows stay behind it, so those
    /// states report the full-height demand instead of the row-derived one
    /// (the overlay condition is the same resolved reference the ZStack
    /// renders with, keeping demand and rendering in lockstep).
    private var contentFitInput: PanelContentFit.Input {
        let snippetLineLimit = appearance.snippetLineCount.baseLineLimit(
            density: appearance.rowDensity
        )
        return PanelContentFit.Input(
            pinnedRows: viewState.displayedPinnedRows.map {
                PanelContentFit.RowDescriptor(
                    row: $0, snippetLineLimit: snippetLineLimit
                )
            },
            unpinnedRows: viewState.displayedUnpinnedRows.map {
                PanelContentFit.RowDescriptor(
                    row: $0, snippetLineLimit: snippetLineLimit
                )
            },
            density: appearance.rowDensity,
            fontSize: appearance.rowFontSize,
            hasWindowedPages: viewState.hasWindowedPages,
            showsPaginationControl:
                viewState.hasNextPage || viewState.isLoadingPage,
            isFilterChipVisible:
                viewState.typeFilter != .all || viewState.showsPinnedOnly,
            isFailureBannerVisible: isFailureBannerVisible,
            prefersFullHeight:
                !surfaceState.detailsPath.isEmpty
                    || surfaceState.resolvedQuickLookReference(
                        in: displayedSelectionRows,
                        hasAuthoritativeFirstPage: viewState.hasAuthoritativeFirstPage
                    ) != nil
        )
    }

    /// Keyboard navigation follows the same authoritative filtered lanes
    /// as HistoryListView, with pinned rows first.
    private var displayedSelectionRows: [HistoryRow] {
        viewState.displayedRows
    }

    /// Reconcile the selected item against this authoritative filtered page,
    /// retaining the selection through loading and retargeting filter changes.
    private func reconcileSelectionWithDisplayedDefault() {
        surfaceState.reconcileSessionSelection(
            rows: viewState.rows,
            hasAuthoritativeFirstPage: viewState.hasAuthoritativeFirstPage,
            selectsVisibleWindow: viewState.hasWindowedPages,
            filter: HistoryFilter(
                type: viewState.typeFilter.contentType,
                pinnedOnly: viewState.showsPinnedOnly
            )
        )
        retargetHiddenSelectionToDisplayedDefault()
    }

    /// Retargets a filter-hidden selection to the newest displayed row once
    /// an authoritative page exists. The gate mirrors
    /// `reconcileSessionSelection`'s: while the replacement page is still in
    /// flight `rows == []` is a loading placeholder, not evidence the
    /// selection is hidden.
    private func retargetHiddenSelectionToDisplayedDefault() {
        guard viewState.hasAuthoritativeFirstPage else { return }
        surfaceState.retargetHiddenSelectionToDisplayedDefault(
            displayedRows: displayedSelectionRows
        )
    }

    // MARK: Failure banner

    /// The banner's published visibility — the animation key for its
    /// appearance. Keyed by the publication episode, not typed-value
    /// equality, so the same failure after recovery counts as a fresh
    /// appearance; must mirror `failureBanner`'s condition exactly.
    private var isFailureBannerVisible: Bool {
        viewState.failure != nil
            && viewState.failureEpisode != dismissedFailureEpisode
    }

    /// Icon + typed-failure message; Retry appears only for
    /// `.temporarilyUnavailable` (03b §10: the caller may retry later).
    /// Dismissal is local and keyed by the publication episode, not by typed
    /// value equality. The same failure after recovery therefore reappears.
    @ViewBuilder
    private var failureBanner: some View {
        if let failure = viewState.failure,
           viewState.failureEpisode != dismissedFailureEpisode {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(FailurePresentation.message(for: failure))
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                if case .temporarilyUnavailable = failure,
                   viewState.canRetryFailureByRefreshing {
                    Button(PanelActionsCopy.text("Retry")) {
                        viewState.refresh()
                    }
                }
                Spacer(minLength: 4)
                Button {
                    dismissedFailureEpisode = viewState.failureEpisode
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(PanelActionsCopy.text("Dismiss"))
            }
            .padding(.horizontal, PanelTheme.bannerHorizontalPadding)
            .padding(.vertical, PanelTheme.bannerVerticalPadding)
            .overlay(alignment: .top) { Divider() }
        }
    }

    // MARK: Panel actions

    /// Secondary actions share the search toolbar instead of consuming a
    /// second permanent strip below the content.
    private var panelActions: some View {
        HStack(spacing: PanelTheme.spacingXSmall) {
            Menu {
                Text(itemCountText)
                Divider()
                Picker(PanelChromeCopy.text("Row Density"), selection: Binding(
                    get: { appearance.rowDensity },
                    set: { UserDefaults.standard.set($0.rawValue, forKey: PanelAppearanceSettings.rowDensityDefaultsKey) }
                )) {
                    Text(PanelChromeCopy.text("Comfortable")).tag(HistoryRowDensity.comfortable)
                    Text(PanelChromeCopy.text("Compact")).tag(HistoryRowDensity.compact)
                }
                Menu(PanelChromeCopy.text("Keyboard Shortcuts")) {
                    Text(PanelFooterShortcutHints.text(isSearchActive: viewState.isSearchActive))
                }
                Divider()
                // Opt-in keep-open affordance: the composition root admits it
                // by providing the toggle callback; a nil callback keeps the
                // shipped item set below byte-identical.
                if let onToggleKeepPanelOpen {
                    Toggle(
                        PanelFooterCopy.text("Keep Panel Open"),
                        isOn: Binding(
                            get: { keepPanelOpenIsActive },
                            set: { _ in onToggleKeepPanelOpen() }
                        )
                    )
                    .accessibilityIdentifier("clipy.panel.keep-open")
                    Divider()
                }
                if let onPauseCapture {
                    Button {
                        onPauseCapture()
                    } label: {
                        Label(
                            PanelFooterCopy.text("Pause Clipboard Monitoring for 5 Minutes"),
                            systemImage: "pause.circle"
                        )
                    }
                    .accessibilityIdentifier("clipy.capture.pause")
                    Divider()
                }
                Button {
                    pendingClear = .unpinned
                } label: {
                    Label(PanelFooterCopy.text("Clear Unpinned Items…"), systemImage: "trash")
                }
                Button {
                    pendingClear = .all
                } label: {
                    Label(PanelFooterCopy.text("Clear All History…"), systemImage: "trash.fill")
                }
                Divider()
                Button {
                    onOpenSettings()
                } label: {
                    Label(PanelFooterCopy.text("Settings…"), systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
                Divider()
                Button {
                    onQuit()
                } label: {
                    Label(PanelFooterCopy.text("Quit Clipy"), systemImage: "power")
                }
                .keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .overlay(alignment: .bottomTrailing) {
                        if keepPanelOpenIsActive {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                        }
                    }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(keepPanelOpenIsActive
                ? PanelChromeCopy.text("Panel stays open. Open More Actions to turn this off.")
                : PanelFooterCopy.text("More Actions"))
            .accessibilityLabel(PanelFooterCopy.text("More Actions"))
            .accessibilityValue(PanelChromeCopy.text(
                keepPanelOpenIsActive ? "Keep Panel Open: On" : "Keep Panel Open: Off"
            ))
            .accessibilityIdentifier("clipy.panel.more-actions")
        }
        .controlSize(.small)
        .frame(height: PanelContentFit.searchFieldHeight)
    }

    private var itemCountText: String {
        Self.itemCountText(
            for: viewState,
            locale: locale
        )
    }

    /// Count the same filtered rows as the list and keep cursor uncertainty.
    internal static func itemCountText(
        for viewState: HistoryViewState,
        locale: Locale = .current,
        bundle: Bundle = .main
    ) -> String {
        HistoryCountCopy.items(
            count: viewState.displayedCount,
            hasNextPage: viewState.displayedCountIsLowerBound,
            locale: locale,
            bundle: bundle
        )
    }

    // MARK: Clear confirmation

    private var clearConfirmationTitle: String {
        switch pendingClear {
        case .all: return PanelFooterCopy.text("Clear All History?")
        case .unpinned: return PanelFooterCopy.text("Clear Unpinned Items?")
        case nil: return ""
        }
    }

    private var clearConfirmationMessage: String {
        switch pendingClear {
        case .all:
            return PanelFooterCopy.text("All clipboard history, including pinned items, will be removed.")
        case .unpinned:
            return PanelFooterCopy.text("All unpinned items will be removed. Pinned items are kept.")
        case nil:
            return ""
        }
    }

    @ViewBuilder
    private var clearConfirmationActions: some View {
        if let scope = pendingClear {
            Button(PanelFooterCopy.text("Clear"), role: .destructive) {
                pendingClear = nil
                Task {
                    _ = try? await viewState.clearAwaitingReceipt(scope)
                }
            }
        }
        Button(PanelFooterCopy.text("Cancel"), role: .cancel) {
            pendingClear = nil
        }
    }

    private var clearConfirmationPresented: Binding<Bool> {
        Binding<Bool>(
            get: { pendingClear != nil },
            set: { presented in
                if !presented { pendingClear = nil }
            }
        )
    }

    // MARK: Hidden shortcuts

    /// At the list root, Esc dismisses preview information, then Quick Look, then
    /// the floating preview pane (a manual close that suppresses auto-open until
    /// the selection changes), then clears the search term, and otherwise asks
    /// the hosting panel to close (Maccy's KeyChord `.escape` → `close`). A
    /// pushed Details/editor destination owns Esc itself; retaining this root
    /// shortcut there would bypass the editor's dirty-discard confirmation.
    /// Space toggles the quick-look overlay (Maccy's Quick Look chord): gated
    /// like the list's ⌫ shortcut
    /// — disabled while the search field has focus, so Space keeps editing
    /// the query — and admitted only at the list root with a resolvable
    /// selection; while the overlay is open Space stays enabled so the same
    /// chord closes it.
    private var hiddenShortcuts: some View {
        Group {
            if surfaceState.detailsPath.isEmpty {
                Button(PanelFooterCopy.text("Clear Search or Close")) {
                    if previewState.isInformationPresented {
                        previewState.isInformationPresented = false
                    } else if surfaceState.quickLookReference != nil {
                        surfaceState.quickLookReference = nil
                    } else if previewState.dismissPreview() {
                        // The floating preview took this Esc; the next one
                        // continues down the chain.
                    } else if viewState.isSearchActive {
                        viewState.clearSearch()
                    } else {
                        onRequestClose()
                    }
                }
                .keyboardShortcut(.cancelAction)
            }

            Button(PanelFooterCopy.text("Quick Look")) {
                if surfaceState.quickLookReference != nil {
                    surfaceState.quickLookReference = nil
                } else {
                    surfaceState.quickLookReference = previewSelection.reference
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(
                isSearchFieldFocused
                    || (surfaceState.quickLookReference == nil
                        && (!surfaceState.detailsPath.isEmpty
                            || previewSelection.reference == nil))
            )

            // The floating preview pane is never the key window, so its own
            // Retry button's chord cannot fire there; the panel (the key
            // window) captures ⌘R and republishes it through the pane state.
            // While the quick-look overlay is open its in-hierarchy preview
            // owns the same chord, so this root copy stays disabled.
            Button(PanelActionsCopy.text("Retry")) {
                previewState.requestPreviewRetry()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(
                !previewState.isOpen
                    || !surfaceState.detailsPath.isEmpty
                    || surfaceState.quickLookReference != nil
            )

            // The floating pane's PDF pager chords (⌥⌘←/→) get the same
            // republish, gated identically: while the quick-look overlay is
            // open its in-view pager buttons own the chords, so these stay
            // disabled and nothing double-handles.
            Button(PreviewCopy.text("Previous PDF Page")) {
                previewState.requestPreviewPage(.previous)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.option, .command])
            .disabled(
                !previewState.isOpen
                    || !surfaceState.detailsPath.isEmpty
                    || surfaceState.quickLookReference != nil
            )

            Button(PreviewCopy.text("Next PDF Page")) {
                previewState.requestPreviewPage(.next)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.option, .command])
            .disabled(
                !previewState.isOpen
                    || !surfaceState.detailsPath.isEmpty
                    || surfaceState.quickLookReference != nil
            )
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

#Preview {
    HistoryPanelPreview()
}

private struct HistoryPanelPreview: View {
    @State private var previewState = PreviewPaneState()

    var body: some View {
        HistoryPanelView(
            viewState: HistoryViewState(history: PreviewClipboardHistory.populated),
            previewState: previewState
        )
        // The view itself is frameless (the hosting window owns the live
        // size); the preview stands in for the default window frame.
        .frame(
            width: PanelGeometry.contentWidth,
            height: PanelGeometry.height
        )
    }
}
