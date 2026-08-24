/// HistoryPanelView.swift — the floating-panel browsing surface: search
/// header, history list inside the panel NavigationStack, failure banner,
/// footer bar, and the optional preview column (Maccy's two-pane slideout
/// replicated with `PanelGeometry`-shared fixed widths).
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
    package let thumbnails: ThumbnailStore
    public private(set) var appliedPurgeGeneration = 0
    public private(set) var sessionGeneration = 0
    public private(set) var isSessionActive = false
    package private(set) var detailsPurgeGeneration = 0

    private let previewState: PreviewPaneState

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
    /// one item; Revise scopes to the old exact reference.
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
            selection = nil
        case .unpinned:
            detailsPurgeGeneration += 1
            detailsPath.removeAll()
            selection = nil
        case .item(let id):
            if detailsPath.contains(where: { $0.id == id }) {
                detailsPurgeGeneration += 1
            }
            detailsPath.removeAll { $0.id == id }
            if selection == id {
                selection = nil
            }
        case .revision(let old, _):
            if detailsPath.contains(old) {
                detailsPurgeGeneration += 1
            }
            detailsPath.removeAll { $0 == old }
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
        selection = PanelSessionSelection.preparedSelection(in: rows)
    }

    /// Ends one session and retires content-bearing transient UI state. The
    /// raw search draft intentionally survives reopen; selection/details/
    /// preview do not (approved Card 14A close policy).
    public func endSession() {
        guard isSessionActive else { return }
        isSessionActive = false
        detailsPath.removeAll()
        selection = nil
        previewState.panelClosed()
    }

    package func reconcileSessionSelection(rows: [HistoryRow]) {
        guard isSessionActive else { return }
        if let selection,
           rows.contains(where: { $0.item.id == selection }) {
            return
        }
        selection = PanelSessionSelection.preparedSelection(in: rows)
    }

    package func moveSelection(
        in rows: [HistoryRow],
        direction: PanelSelectionDirection
    ) {
        guard isSessionActive else { return }
        selection = PanelSessionSelection.movedSelection(
            selection,
            in: rows,
            direction: direction
        )
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
/// (`panelBecameKey`/`panelResignedKey`/`panelClosed`) and observe
/// `isOpen` through `onPreviewVisibilityChange` to resize the window —
/// PresentationUI itself never touches AppKit (01 §8).
public struct HistoryPanelView: View {
    private let viewState: HistoryViewState
    private let previewState: PreviewPaneState
    private let previewPlacement: PreviewPlacement
    private let onOpenSettings: () -> Void
    private let onQuit: () -> Void
    private let onRequestClose: () -> Void
    private let onPreviewVisibilityChange: ((Bool) -> Void)?

    @State private var surfaceState: HistoryPanelSurfaceState
    @State private var dismissedFailureEpisode: Int?
    @State private var pendingClear: ClearScope?
    @FocusState private var isSearchFieldFocused: Bool

    /// The inferred main-actor isolation of `View` (01 §6: main-actor UI)
    /// covers this initializer, which constructs the `@MainActor`
    /// `ThumbnailStore` for `viewState.history` (01 §5.7).
    public init(
        viewState: HistoryViewState,
        previewState: PreviewPaneState,
        surfaceState: HistoryPanelSurfaceState? = nil,
        previewPlacement: PreviewPlacement = .trailing,
        onOpenSettings: @escaping () -> Void = {},
        onQuit: @escaping () -> Void = {},
        onRequestClose: @escaping () -> Void = {},
        onPreviewVisibilityChange: ((Bool) -> Void)? = nil
    ) {
        self.viewState = viewState
        self.previewState = previewState
        self.previewPlacement = previewPlacement
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        self.onRequestClose = onRequestClose
        self.onPreviewVisibilityChange = onPreviewVisibilityChange
        _surfaceState = State(
            initialValue: surfaceState ?? HistoryPanelSurfaceState(
                history: viewState.history,
                previewState: previewState,
                baselinePurgeGeneration: viewState.surfacePurge?.generation ?? 0
            )
        )
    }

    public var body: some View {
        HStack(spacing: 0) {
            if previewState.isOpen, previewPlacement == .leading {
                previewColumn
                Divider()
            }
            mainColumn
                .frame(width: PanelGeometry.contentWidth)
            if previewState.isOpen, previewPlacement == .trailing {
                Divider()
                previewColumn
            }
        }
        .frame(
            width: PanelGeometry.totalWidth(previewOpen: previewState.isOpen),
            height: PanelGeometry.height
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipy.panel.root")
        .background { hiddenShortcuts }
        .task(id: surfaceState.sessionGeneration) {
            guard surfaceState.isSessionActive else { return }
            surfaceState.reconcileSessionSelection(rows: viewState.rows)
            isSearchFieldFocused = true
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
            surfaceState.reconcileSessionSelection(rows: viewState.rows)
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
    }

    // MARK: Main column

    private var previewColumn: some View {
        HistoryPreviewView(
            viewState: viewState,
            previewState: previewState,
            selection: previewSelection
        )
        .id(previewState.purgeGeneration)
        .frame(width: PanelGeometry.previewWidth)
        // Opacity-only fade (Maccy's lesson: animating the WIDTH forces an
        // NSHostingView re-layout per frame; compositing a fade does not).
        .transition(.opacity)
    }

    /// The pre-preview 400pt column, unchanged: search header, the list in
    /// its details NavigationStack, failure banner, footer.
    private var mainColumn: some View {
        VStack(spacing: 0) {
            SearchHeaderView(
                viewState: viewState,
                searchFieldFocused: $isSearchFieldFocused,
                onMoveSelection: { offset in
                    surfaceState.moveSelection(
                        in: viewState.rows,
                        direction: offset < 0 ? .previous : .next
                    )
                }
            )
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            NavigationStack(path: $surfaceState.detailsPath) {
                HistoryListView(
                    viewState: viewState,
                    thumbnails: surfaceState.thumbnails,
                    isSearchFieldFocused: isSearchFieldFocused,
                    selection: $surfaceState.selection,
                    onShowDetails: { item in surfaceState.detailsPath.append(item) }
                )
                .navigationDestination(for: HistoryItemReference.self) { item in
                    HistoryDetailsView(viewState: viewState, item: item)
                }
            }
            .id(surfaceState.detailsPurgeGeneration)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            failureBanner
            footer
                .overlay(alignment: .top) { Divider() }
        }
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

    // MARK: Failure banner

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
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .overlay(alignment: .top) { Divider() }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text(itemCountText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var itemCountText: String {
        let count = viewState.rows.count
        let noun = count == 1 ? "item" : "items"
        return viewState.hasNextPage ? "\(count)+ \(noun)" : "\(count) \(noun)"
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

    /// Esc clears the search term first; with no search text it asks the
    /// hosting panel to close (Maccy's KeyChord `.escape` → `close`,
    /// adapted: a non-empty query keeps its clear-first behavior).
    /// ⌃Space toggles the preview pane for the current selection (Maccy's
    /// `togglePreview` default chord).
    private var hiddenShortcuts: some View {
        Group {
            Button("Clear Search or Close") {
                if viewState.isSearchActive {
                    viewState.clearSearch()
                } else {
                    onRequestClose()
                }
            }
            .keyboardShortcut(.cancelAction)

            Button("Toggle Preview") {
                previewState.togglePreview(for: previewSelection.reference)
            }
            .keyboardShortcut(.space, modifiers: .control)
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
    }
}
