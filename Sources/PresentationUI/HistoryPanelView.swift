/// HistoryPanelView.swift — the floating-panel browsing surface: search
/// header, history list inside the panel NavigationStack, failure banner,
/// footer bar, and the optional preview column (Maccy's two-pane slideout
/// replicated with `PanelGeometry`-shared sizing).
///
/// The panel is user-resizable (01 §8 keeps the AppKit window in ClipyApp):
/// the hosting window owns the live frame through `PanelGeometry`'s
/// persisted/clamped size, so this view carries NO fixed root frame — the
/// browsing column flexes with the window and the preview column keeps its
/// persisted free-drag width (an invisible divider handle resizes it inside
/// the fixed window) and fills the window's height. A Space-triggered
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

/// Which side of the stable history column displays the optional preview.
/// ClipyApp chooses this from screen geometry; PresentationUI uses the same
/// value to order the columns without depending on AppKit (01 §8).
public enum PreviewPlacement: Equatable, Sendable {
    case leading
    case trailing
}

/// Pure Card 14A ordering rule shared by panel-open preparation and arrow
/// commands. `HistoryViewState.rows` is already the authoritative displayed
/// order, so this value never re-sorts or invents a parallel cursor model.
package enum PanelSelectionDirection: Equatable {
    case previous
    case next
}

package enum PanelSessionSelection {
    package static func preparedSelection(
        in rows: [HistoryRow]
    ) -> HistoryItemID? {
        rows.first?.item.id
    }

    package static func movedSelection(
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

/// The list selection reconciled against the latest authoritative rows.
/// The ID remains the list-control identity, while `reference` is the exact
/// content target consumed by preview. A row removal clears both; a same-ID
/// ContentVersion advance changes this value (review Card 9A).
package struct PreviewSelectionResolution: Equatable {
    package let selectedID: HistoryItemID?
    package let reference: HistoryItemReference?
    private let availableItemIDs: Set<HistoryItemID>

    package static func resolve(
        selectedID: HistoryItemID?,
        rows: [HistoryRow]
    ) -> PreviewSelectionResolution {
        guard let selectedID,
              let reference = rows.first(where: { $0.item.id == selectedID })?.item
        else {
            return PreviewSelectionResolution(
                selectedID: nil,
                reference: nil,
                availableItemIDs: Set(rows.map(\.item.id))
            )
        }
        return PreviewSelectionResolution(
            selectedID: selectedID,
            reference: reference,
            availableItemIDs: Set(rows.map(\.item.id))
        )
    }

    /// Keeps PreviewPaneState's cross-item dwell target, but immediately
    /// advances the exact reference when observation revises that same item.
    /// A missing selected row invalidates preview immediately.
    package func previewTarget(
        previewedItem: HistoryItemReference?
    ) -> HistoryItemReference? {
        guard let reference,
              let previewedItem,
              availableItemIDs.contains(previewedItem.id)
        else { return nil }
        return reference.id == previewedItem.id ? reference : previewedItem
    }
}

/// State owned by one AppDelegate-hosted panel surface and purged only after
/// `HistoryViewState` publishes a receipt-confirmed destructive/effective
/// commit (review Card 9B). Keeping the coordination beside the panel avoids
/// a global cache bus: navigation, selection, preview, and thumbnail storage
/// all have the same lifetime and one monotonic applied generation.
@MainActor @Observable
public final class HistoryPanelSurfaceState {
    package var detailsPath: [HistoryItemReference] = []
    package var selection: HistoryItemID?
    /// The exact item the Space-triggered quick-look overlay renders.
    /// Reference-exact like the preview target and retired by the same
    /// purge/session transitions as the selection, so overlay content can
    /// never outlive its authoritative row (review Card 9B).
    package var quickLookReference: HistoryItemReference?
    package let thumbnails: ThumbnailStore
    public private(set) var appliedPurgeGeneration = 0
    public private(set) var sessionGeneration = 0
    public private(set) var isSessionActive = false
    public var isAtListRoot: Bool { detailsPath.isEmpty }
    package private(set) var detailsPurgeGeneration = 0

    private let previewState: PreviewPaneState
    /// A panel can open before its first authoritative page arrives because
    /// `HistoryViewState.activate()` clears the previous snapshot
    /// synchronously. This one-shot bit distinguishes that empty bootstrap
    /// from an intentional nil selection after a selected row is retired.
    private var isAwaitingInitialSelection = false

    package init(
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
    public convenience init(
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
    public func apply(_ purge: HistorySurfacePurge) {
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
        case .unpinned:
            detailsPurgeGeneration += 1
            detailsPath.removeAll()
            isAwaitingInitialSelection = false
            selection = nil
            quickLookReference = nil
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
    public func beginSession(rows: [HistoryRow]) {
        sessionGeneration += 1
        isSessionActive = true
        detailsPath.removeAll()
        quickLookReference = nil
        selection = PanelSessionSelection.preparedSelection(in: rows)
        isAwaitingInitialSelection = selection == nil
    }

    /// Ends one session and retires content-bearing transient UI state. The
    /// raw search draft intentionally survives reopen; selection/details/
    /// preview/quick look do not (approved Card 14A close policy).
    public func endSession() {
        guard isSessionActive else { return }
        isSessionActive = false
        detailsPath.removeAll()
        isAwaitingInitialSelection = false
        selection = nil
        quickLookReference = nil
        previewState.panelClosed()
    }

    /// Retargets only the currently open exact Details destination after that
    /// child has crossed an authoritative editor read/receipt boundary. This
    /// is not a purge: selection, preview, thumbnails, generations, and other
    /// path entries are untouched. A later revision purge naming `old` then
    /// cannot pop the already-retargeted `new` destination.
    @discardableResult
    package func advanceOpenDetailsReference(
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

    package func reconcileSessionSelection(
        rows: [HistoryRow],
        hasAuthoritativeFirstPage: Bool = true
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
        guard let selection else {
            guard isAwaitingInitialSelection else { return }
            self.selection = PanelSessionSelection.preparedSelection(in: rows)
            if self.selection != nil {
                isAwaitingInitialSelection = false
            }
            return
        }
        guard rows.contains(where: { $0.item.id == selection }) else {
            isAwaitingInitialSelection = false
            self.selection = nil
            return
        }
        isAwaitingInitialSelection = false
    }

    package func moveSelection(
        in rows: [HistoryRow],
        direction: PanelSelectionDirection
    ) {
        guard isSessionActive else { return }
        isAwaitingInitialSelection = false
        selection = PanelSessionSelection.movedSelection(
            selection,
            in: rows,
            direction: direction
        )
    }

    /// Wave-2 filter consistency: the client-side type/pinned filter narrows
    /// which loaded rows RENDER, and a selection naming an invisible row
    /// could be Return-pasted blindly. The panel applies this after every
    /// authoritative reconciliation and after every filter change: a
    /// rendered selection is kept untouched, while a filter-hidden selection
    /// retargets to the newest DISPLAYED row — the same newest-row default
    /// `beginSession` picks, so the open-session default can never land on a
    /// filtered-out row. A nil selection is never re-picked here (an
    /// intentional clear after authoritative removal stays clear;
    /// `reconcileSessionSelection` owns the initial pick), and the caller
    /// gates on `hasAuthoritativeFirstPage` so the query-restart loading gap
    /// (`rows == []` before the replacement page) cannot clear a selection
    /// either. With no filter active the displayed lanes ARE the
    /// authoritative rows, so this never fires.
    package func retargetHiddenSelectionToDisplayedDefault(
        displayedRows: [HistoryRow]
    ) {
        guard isSessionActive, let selection else { return }
        guard !displayedRows.contains(where: { $0.item.id == selection })
        else { return }
        self.selection = PanelSessionSelection.preparedSelection(
            in: displayedRows
        )
    }

    /// Exact executable selection for the AppKit window's IME-aware Return
    /// routing. The row must still exist in the authoritative display before
    /// the composition boundary publishes the product paste intent.
    public func selectedReference(
        in rows: [HistoryRow]
    ) -> HistoryItemReference? {
        guard let selection else { return nil }
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
/// hook the panel surface itself calls) and observe
/// `isOpen` through `onPreviewVisibilityChange` to resize the window —
/// PresentationUI itself never touches AppKit (01 §8).
///
/// `appearance` is the loaded `PanelAppearanceSettings` snapshot (row
/// density threaded to the list, preview auto-open pushed into
/// `PreviewPaneState`'s preference gate); the default keeps the shipped
/// look and behavior. The preview column's width is NOT part of that
/// snapshot: the divider handle owns it through `PanelGeometry`'s
/// persisted preview-width key.
/// `keepPanelOpenIsActive`/`onToggleKeepPanelOpen` admit the composition
/// root's opt-in keep-open menu item. The app-facing icon seam is the
/// PUBLIC `SourceIconProvider` (`SourceIconStore` is package vocabulary the
/// public signature cannot name): the view builds and owns one per-surface
/// store from it, and only in-package callers inject a store directly.
public struct HistoryPanelView: View {
    @Environment(\.locale) private var locale

    private let viewState: HistoryViewState
    private let previewState: PreviewPaneState
    private let previewPlacement: PreviewPlacement
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
    private let onPreviewVisibilityChange: ((Bool) -> Void)?

    @State private var surfaceState: HistoryPanelSurfaceState
    @State private var dismissedFailureEpisode: Int?
    @State private var pendingClear: ClearScope?
    @FocusState private var isSearchFieldFocused: Bool

    /// The live preview column width: the persisted free-drag value at
    /// first appearance, then the divider handle's live updates. The same
    /// first-value `@State` idiom as `sourceIcons` — the defaults read
    /// happens once, never per body evaluation.
    @State private var previewColumnWidth =
        PanelGeometry.persistedPreviewColumnWidth(from: .standard)
    /// The column width captured when a divider drag begins; the gesture's
    /// translation is cumulative, so every live update derives from it.
    @State private var previewDragStartWidth: CGFloat?
    /// The root HStack's measured total width (preview included), tracked
    /// so a drag can never squeeze the browsing column below its minimum.
    /// `nil` only before the first layout pass.
    @State private var panelTotalWidth: CGFloat?

    /// The app-facing entry point. Calls that do not name `sourceIcons:`
    /// resolve here because the designated initializer below requires that
    /// label (the app cannot name `SourceIconStore` anyway — that type is
    /// package vocabulary), so the public seam takes the PUBLIC
    /// `SourceIconProvider` instead and builds the store internally. The
    /// default `.none` provider resolves every bundle ID to nil, keeping
    /// the rows on today's fallback symbols.
    public init(
        viewState: HistoryViewState,
        previewState: PreviewPaneState,
        surfaceState: HistoryPanelSurfaceState? = nil,
        previewPlacement: PreviewPlacement = .trailing,
        onPauseCapture: (() -> Void)? = nil,
        onOpenSettings: @escaping () -> Void = {},
        onQuit: @escaping () -> Void = {},
        onRequestClose: @escaping () -> Void = {},
        onPreviewVisibilityChange: ((Bool) -> Void)? = nil,
        appearance: PanelAppearanceSettings = PanelAppearanceSettings(),
        keepPanelOpenIsActive: Bool = false,
        onToggleKeepPanelOpen: (() -> Void)? = nil,
        sourceIconProvider: SourceIconProvider = .none
    ) {
        self.init(
            viewState: viewState,
            previewState: previewState,
            surfaceState: surfaceState,
            previewPlacement: previewPlacement,
            onPauseCapture: onPauseCapture,
            onOpenSettings: onOpenSettings,
            onQuit: onQuit,
            onRequestClose: onRequestClose,
            onPreviewVisibilityChange: onPreviewVisibilityChange,
            appearance: appearance,
            keepPanelOpenIsActive: keepPanelOpenIsActive,
            onToggleKeepPanelOpen: onToggleKeepPanelOpen,
            sourceIcons: SourceIconStore(provider: sourceIconProvider)
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
    package init(
        viewState: HistoryViewState,
        previewState: PreviewPaneState,
        surfaceState: HistoryPanelSurfaceState? = nil,
        previewPlacement: PreviewPlacement = .trailing,
        onPauseCapture: (() -> Void)? = nil,
        onOpenSettings: @escaping () -> Void = {},
        onQuit: @escaping () -> Void = {},
        onRequestClose: @escaping () -> Void = {},
        onPreviewVisibilityChange: ((Bool) -> Void)? = nil,
        appearance: PanelAppearanceSettings = PanelAppearanceSettings(),
        keepPanelOpenIsActive: Bool = false,
        onToggleKeepPanelOpen: (() -> Void)? = nil,
        sourceIcons: SourceIconStore?
    ) {
        self.viewState = viewState
        self.previewState = previewState
        self.previewPlacement = previewPlacement
        self.appearance = appearance
        self.keepPanelOpenIsActive = keepPanelOpenIsActive
        self.onToggleKeepPanelOpen = onToggleKeepPanelOpen
        self.onPauseCapture = onPauseCapture
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        self.onRequestClose = onRequestClose
        self.onPreviewVisibilityChange = onPreviewVisibilityChange
        _sourceIcons = State(initialValue: sourceIcons)
        _surfaceState = State(
            initialValue: surfaceState ?? HistoryPanelSurfaceState(
                history: viewState.history,
                previewState: previewState,
                baselinePurgeGeneration: viewState.surfacePurge?.generation ?? 0
            )
        )
    }

    public var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if previewState.isOpen, previewPlacement == .leading {
                    previewColumn
                    previewDivider
                }
                mainColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if previewState.isOpen, previewPlacement == .trailing {
                    previewDivider
                    previewColumn
                }
            }
            // The divider drag's main-column guard needs the live total
            // width; the HStack IS the window's content, so its size is the
            // value the AppKit frame math already agrees on.
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { newSize in
                panelTotalWidth = newSize.width
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("clipy.panel.root")
            .background { hiddenShortcuts }
            .task(id: surfaceState.sessionGeneration) {
                guard surfaceState.isSessionActive else { return }
                reconcileSelectionWithDisplayedDefault()
                isSearchFieldFocused = true
            }
            // The injected appearance snapshot owns the preference half of
            // PreviewPaneState's auto-open gate; `initial: true` covers the
            // first appearance, later changes repush (a re-enabled preference
            // takes effect on the NEXT selection change by gate contract).
            .onChange(of: appearance, initial: true) { _, newAppearance in
                previewState.isAutoOpenPreferenceEnabled =
                    newAppearance.isPreviewAutoOpenEnabled
            }
            .onChange(of: surfaceState.isSessionActive) { _, isActive in
                if !isActive { isSearchFieldFocused = false }
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
                    surfaceState.selection = nil
                    previewState.handleSelectionChange(nil)
                    return
                }
                // Preserve cross-ID dwell and manual-close suppression. Only an
                // already-open preview of this same item needs state retargeting.
                if previewState.isOpen, previewState.previewedItem?.id == reference.id {
                    previewState.refreshOpenPreview(reference)
                }
            }
            .onChange(of: viewState.rows.map(\.item)) { _, _ in
                reconcileSelectionWithDisplayedDefault()
            }
            // An authoritative empty replacement can leave `rows == []` across
            // the whole generation, so rows alone cannot trigger reconciliation.
            // The first authoritative page fact must be part of the owner signal.
            .onChange(of: viewState.hasAuthoritativeFirstPage) { _, _ in
                reconcileSelectionWithDisplayedDefault()
            }
            // The client-side filters never restart the query, so no rows
            // signal fires for them; a filter change that hides the current
            // selection retargets it to the newest displayed row directly.
            .onChange(of: viewState.typeFilter) { _, _ in
                retargetHiddenSelectionToDisplayedDefault()
            }
            .onChange(of: viewState.showsPinnedOnly) { _, _ in
                retargetHiddenSelectionToDisplayedDefault()
            }
            .onChange(of: resolvedPreviewTarget) { _, target in
                guard previewState.isOpen, target == nil else { return }
                // The selected row may still exist while the previously displayed
                // cross-item dwell target was removed. Close only the preview;
                // preserve the valid list selection and restart its dwell from
                // this authoritative transition.
                previewState.handleSelectionChange(nil)
                previewState.handleSelectionChange(previewSelection.reference)
            }
            .onChange(of: previewState.isOpen) { _, isOpen in
                onPreviewVisibilityChange?(isOpen)
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

            // The quick-look overlay layers above the whole panel (browsing
            // and preview columns alike); it renders only while the surface
            // state holds a trigger-time exact reference.
            if let quickLookItem = surfaceState.quickLookReference {
                HistoryQuickLookOverlay(
                    viewState: viewState,
                    previewState: previewState,
                    item: quickLookItem,
                    onDismiss: { surfaceState.quickLookReference = nil }
                )
                .transition(.opacity)
            }
        }
        // Restrained motion, SwiftUI-local only: the overlay fades in/out.
        // The preview column's WIDTH is never animated — FloatingPanel
        // documents the NSHostingView re-layout storm a width animation
        // forces per frame; compositing an opacity fade does not.
        .animation(
            .easeInOut(duration: 0.18),
            value: surfaceState.quickLookReference != nil
        )
    }

    // MARK: Main column

    private var previewColumn: some View {
        HistoryPreviewView(
            viewState: viewState,
            previewState: previewState,
            selection: previewSelection
        )
        .id(previewState.purgeGeneration)
        // The divider handle's live width, full window height: the browsing
        // column alone absorbs both the drag and the user's window resize —
        // a divider drag never moves the AppKit frame.
        .frame(width: previewColumnWidth)
        .frame(maxHeight: .infinity)
        // Opacity-only fade (Maccy's lesson: animating the WIDTH forces an
        // NSHostingView re-layout per frame; compositing a fade does not).
        .transition(.opacity)
    }

    /// The 1 pt column separator plus the invisible 9 pt drag hit-strip
    /// centered on it (the divider itself stays visually 1 pt; the overlay
    /// widens only the hit area). `zIndex` keeps the strip ahead of both
    /// columns' own hit regions in the few points where they overlap.
    private var previewDivider: some View {
        Divider()
            .overlay { previewDividerHitStrip }
            .zIndex(1)
    }

    /// The free-drag preview-width handle (V2-07 §3/§9: the strip keeps an
    /// AX identity for the running-app journey). A zero-distance DragGesture
    /// resizes the column LIVE — clamped to PanelGeometry's preview bounds
    /// AND to the width that keeps the browsing column at its minimum
    /// inside the measured root — and persists the settled width on drag
    /// end; a simultaneous double click restores and persists the default
    /// `PanelGeometry.previewWidth`. The trade happens entirely inside the
    /// window (the browsing column flexes), so no AppKit `setFrame` runs;
    /// the next preview open/close re-syncs the window's extension to the
    /// persisted width (FloatingPanel reads it fresh per computation).
    private var previewDividerHitStrip: some View {
        Color.clear
            .frame(width: 9)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let startWidth = previewDragStartWidth
                            ?? previewColumnWidth
                        previewDragStartWidth = startWidth
                        previewColumnWidth = draggedPreviewColumnWidth(
                            from: startWidth,
                            translation: value.translation.width
                        )
                    }
                    .onEnded { _ in
                        previewDragStartWidth = nil
                        PanelGeometry.persistPreviewColumnWidth(
                            previewColumnWidth,
                            to: .standard
                        )
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded { _ in
                        previewColumnWidth = PanelGeometry.previewWidth
                        PanelGeometry.persistPreviewColumnWidth(
                            PanelGeometry.previewWidth,
                            to: .standard
                        )
                    }
            )
            .accessibilityLabel("Resize preview")
            .accessibilityIdentifier("clipy.panel.previewDivider")
    }

    /// The width a divider drag lands on: `translation` is the gesture's
    /// cumulative horizontal delta, signed so the column follows the
    /// pointer (a trailing preview NARROWS as the pointer moves right, a
    /// leading preview widens). Beyond the fixed 240…480 bounds, the drag
    /// must leave the browsing column at least `minimumContentWidth` inside
    /// the measured root width; before the first layout pass (unknown
    /// total) the fixed bounds alone apply.
    private func draggedPreviewColumnWidth(
        from startWidth: CGFloat,
        translation: CGFloat
    ) -> CGFloat {
        let signed = previewPlacement == .trailing ? -translation : translation
        let proposed = PanelGeometry.clampedPreviewColumnWidth(
            startWidth + signed
        )
        guard let panelTotalWidth else { return proposed }
        let widthKeepingMainMinimum = panelTotalWidth
            - PanelGeometry.dividerWidth
            - PanelGeometry.minimumContentWidth
        return min(
            proposed,
            max(
                widthKeepingMainMinimum,
                PanelGeometry.minimumPreviewColumnWidth
            )
        )
    }

    /// The browsing column: search header, the list in its details
    /// NavigationStack, failure banner, footer. Width and height are
    /// flexible — the hosting window's (resizable, persisted) frame sizes
    /// this column; header and footer keep their intrinsic heights and the
    /// list absorbs the rest.
    private var mainColumn: some View {
        VStack(spacing: 0) {
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
                    guard let selectedID = surfaceState.selection,
                          let selected = viewState.rows.first(where: {
                              $0.item.id == selectedID
                          })
                    else { return }
                    viewState.requestPasteFromDisplayedRow(selected.item)
                }
            )
            .padding(.horizontal, PanelTheme.headerHorizontalPadding)
            .padding(.top, PanelTheme.headerTopPadding)
            .padding(.bottom, PanelTheme.headerBottomPadding)

            NavigationStack(path: $surfaceState.detailsPath) {
                HistoryListView(
                    viewState: viewState,
                    thumbnails: surfaceState.thumbnails,
                    density: appearance.rowDensity,
                    isSearchFieldFocused: isSearchFieldFocused,
                    selection: $surfaceState.selection,
                    sourceIcons: sourceIcons,
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
            footer
                .overlay(alignment: .top) { Divider() }
        }
        // Restrained motion, SwiftUI-local only: the failure banner's
        // appearance animates inside the browsing column. The preview
        // column's width never animates (FloatingPanel's layout-storm
        // lesson, documented at `previewColumn`).
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

    /// The ordering keyboard selection walks: the pinned displayed lane
    /// then the unpinned displayed lane — the same arrays HistoryListView
    /// renders (docs/03b-instruction-set.md §8). Observation already merges
    /// the lanes pinned-first, so with no client-side filter active this is
    /// exactly `viewState.rows` and the pre-filter walk is byte-identical;
    /// with an active filter, arrows can never land on an invisible row and
    /// Return can never paste one blindly.
    private var displayedSelectionRows: [HistoryRow] {
        viewState.displayedPinnedRows + viewState.displayedUnpinnedRows
    }

    /// Authoritative reconciliation plus the wave-2 displayed-default
    /// retarget in one place: membership evidence stays authoritative (the
    /// query-restart loading gap never clears a selection), then a
    /// filter-hidden selection retargets to the newest displayed row.
    private func reconcileSelectionWithDisplayedDefault() {
        surfaceState.reconcileSessionSelection(
            rows: viewState.rows,
            hasAuthoritativeFirstPage: viewState.hasAuthoritativeFirstPage
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
                    Button("Retry") {
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
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, PanelTheme.bannerHorizontalPadding)
            .padding(.vertical, PanelTheme.bannerVerticalPadding)
            .overlay(alignment: .top) { Divider() }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: PanelTheme.footerSpacing) {
            Text(itemCountText)
                .font(.caption)
                .foregroundStyle(.secondary)
                // A page cursor makes the count a lower bound, not a total
                // (Card 8C); the tooltip discloses that without touching the
                // pinned count formats.
                .help(
                    "Shows the loaded portion of your history. Search to narrow results."
                )
            Spacer()
            // Visible twin of the hidden ⌃Space shortcut button: same
            // manual-toggle semantics on the same selection target.
            Button {
                previewState.togglePreview(for: previewSelection.reference)
            } label: {
                Image(systemName: "sidebar.trailing")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Toggle Preview (⌃Space)")
            .accessibilityLabel("Toggle Preview")
            .accessibilityIdentifier("clipy.panel.preview-toggle")
            Menu {
                // Opt-in keep-open affordance: the composition root admits it
                // by providing the toggle callback; a nil callback keeps the
                // shipped item set below byte-identical.
                if let onToggleKeepPanelOpen {
                    Toggle(
                        "Keep Panel Open",
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
                            "Pause Clipboard Monitoring for 5 Minutes",
                            systemImage: "pause.circle"
                        )
                    }
                    .accessibilityIdentifier("clipy.capture.pause")
                    Divider()
                }
                Button {
                    pendingClear = .unpinned
                } label: {
                    Label("Clear Unpinned Items…", systemImage: "trash")
                }
                Button {
                    pendingClear = .all
                } label: {
                    Label("Clear All History…", systemImage: "trash.fill")
                }
                Divider()
                Button {
                    onOpenSettings()
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
                Divider()
                Button {
                    onQuit()
                } label: {
                    Label("Quit Clipy", systemImage: "power")
                }
                .keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More Actions")
            .accessibilityIdentifier("clipy.panel.more-actions")
        }
        .padding(.horizontal, PanelTheme.footerHorizontalPadding)
        .padding(.vertical, PanelTheme.footerVerticalPadding)
    }

    private var itemCountText: String {
        Self.itemCountText(
            count: viewState.rows.count,
            hasNextPage: viewState.hasNextPage,
            locale: locale
        )
    }

    /// A page cursor makes `count` a lower bound, not a total (Card 8C).
    package static func itemCountText(
        count: Int,
        hasNextPage: Bool,
        locale: Locale = .current
    ) -> String {
        let number = LocalizedCountPresentation.number(count, locale: locale)
        let displayedCount = hasNextPage ? "\(number)+" : number
        let noun = count == 1 && !hasNextPage ? "item" : "items"
        return "\(displayedCount) \(noun)"
    }

    // MARK: Clear confirmation

    private var clearConfirmationTitle: String {
        switch pendingClear {
        case .all: return "Clear All History?"
        case .unpinned: return "Clear Unpinned Items?"
        case nil: return ""
        }
    }

    private var clearConfirmationMessage: String {
        switch pendingClear {
        case .all:
            return "All clipboard history, including pinned items, will be removed."
        case .unpinned:
            return "All unpinned items will be removed. Pinned items are kept."
        case nil:
            return ""
        }
    }

    @ViewBuilder
    private var clearConfirmationActions: some View {
        if let scope = pendingClear {
            Button("Clear", role: .destructive) {
                pendingClear = nil
                Task {
                    _ = try? await viewState.clearAwaitingReceipt(scope)
                }
            }
        }
        Button("Cancel", role: .cancel) {
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

    /// At the list root, Esc dismisses the quick-look overlay first, then
    /// clears the search term, and otherwise asks the hosting panel to close
    /// (Maccy's KeyChord `.escape` → `close`). A pushed Details/editor
    /// destination owns Esc itself; retaining this root shortcut there would
    /// bypass the editor's dirty-discard confirmation.
    /// ⌃Space toggles the preview pane for the current selection (Maccy's
    /// `togglePreview` default chord). Space toggles the quick-look overlay
    /// (Maccy's Quick Look chord): gated exactly like the list's ⌫ shortcut
    /// — disabled while the search field has focus, so Space keeps editing
    /// the query — and admitted only at the list root with a resolvable
    /// selection; while the overlay is open Space stays enabled so the same
    /// chord closes it.
    private var hiddenShortcuts: some View {
        Group {
            if surfaceState.detailsPath.isEmpty {
                Button("Clear Search or Close") {
                    if surfaceState.quickLookReference != nil {
                        surfaceState.quickLookReference = nil
                    } else if viewState.isSearchActive {
                        viewState.clearSearch()
                    } else {
                        onRequestClose()
                    }
                }
                .keyboardShortcut(.cancelAction)
            }

            Button("Toggle Preview") {
                previewState.togglePreview(for: previewSelection.reference)
            }
            .keyboardShortcut(.space, modifiers: .control)

            Button("Quick Look") {
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
            width: PanelGeometry.totalWidth(previewOpen: previewState.isOpen),
            height: PanelGeometry.height
        )
    }
}
