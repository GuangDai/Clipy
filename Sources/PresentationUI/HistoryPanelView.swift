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

/// The composition point ClipyApp hosts inside its floating panel window.
/// Owns the reference-exact `ThumbnailStore` (created from
/// `viewState.history`; 01 §5.7), the hoisted list selection, and the
/// panel's details navigation: the stack root is the list and
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
    private let onOpenSettings: () -> Void
    private let onQuit: () -> Void
    private let onRequestClose: () -> Void
    private let onPreviewVisibilityChange: ((Bool) -> Void)?

    @State private var thumbnails: ThumbnailStore
    @State private var detailsPath: [HistoryItemReference] = []
    @State private var selection: HistoryItemID?
    @State private var dismissedFailure: HistoryFailure?
    @State private var pendingClear: ClearScope?
    @FocusState private var isSearchFieldFocused: Bool

    /// The inferred main-actor isolation of `View` (01 §6: main-actor UI)
    /// covers this initializer, which constructs the `@MainActor`
    /// `ThumbnailStore` for `viewState.history` (01 §5.7).
    public init(
        viewState: HistoryViewState,
        previewState: PreviewPaneState,
        onOpenSettings: @escaping () -> Void = {},
        onQuit: @escaping () -> Void = {},
        onRequestClose: @escaping () -> Void = {},
        onPreviewVisibilityChange: ((Bool) -> Void)? = nil
    ) {
        self.viewState = viewState
        self.previewState = previewState
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        self.onRequestClose = onRequestClose
        self.onPreviewVisibilityChange = onPreviewVisibilityChange
        _thumbnails = State(initialValue: ThumbnailStore(history: viewState.history))
    }

    public var body: some View {
        HStack(spacing: 0) {
            mainColumn
                .frame(width: PanelGeometry.contentWidth)
            if previewState.isOpen {
                Divider()
                HistoryPreviewView(viewState: viewState, previewState: previewState)
                    .frame(width: PanelGeometry.previewWidth)
                    // Opacity-only fade (Maccy's lesson: animating the WIDTH
                    // forces an NSHostingView re-layout per frame — a layout
                    // storm; compositing a fade does not).
                    .transition(.opacity)
            }
        }
        .frame(
            width: PanelGeometry.totalWidth(previewOpen: previewState.isOpen),
            height: PanelGeometry.height
        )
        .background { hiddenShortcuts }
        .task { viewState.activate() }
        .onDisappear { viewState.deactivate() }
        .onChange(of: selection) { _, newSelection in
            previewState.handleSelectionChange(reference(for: newSelection))
        }
        .onChange(of: previewState.isOpen) { _, isOpen in
            onPreviewVisibilityChange?(isOpen)
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

    /// The pre-preview 400pt column, unchanged: search header, the list in
    /// its details NavigationStack, failure banner, footer.
    private var mainColumn: some View {
        VStack(spacing: 0) {
            SearchHeaderView(
                viewState: viewState,
                searchFieldFocused: $isSearchFieldFocused
            )
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            NavigationStack(path: $detailsPath) {
                HistoryListView(
                    viewState: viewState,
                    thumbnails: thumbnails,
                    isSearchFieldFocused: isSearchFieldFocused,
                    selection: $selection,
                    onShowDetails: { item in detailsPath.append(item) }
                )
                .navigationDestination(for: HistoryItemReference.self) { item in
                    HistoryDetailsView(viewState: viewState, item: item)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            failureBanner
            footer
                .overlay(alignment: .top) { Divider() }
        }
    }

    /// The selected row's exact reference (item ID + Content Version) — the
    /// preview pane's dwell target; `nil` when the selection no longer
    /// resolves (e.g. the row was removed).
    private func reference(for selection: HistoryItemID?) -> HistoryItemReference? {
        guard let selection else { return nil }
        return viewState.rows.first { $0.item.id == selection }?.item
    }

    // MARK: Failure banner

    /// Icon + typed-failure message; Retry appears only for
    /// `.temporarilyUnavailable` (03b §10: the caller may retry later).
    /// Dismissal is local: `HistoryViewState` owns the authoritative
    /// `failure` value, so the panel remembers which failure instance it
    /// dismissed and a new, different failure re-shows the banner.
    @ViewBuilder
    private var failureBanner: some View {
        if let failure = viewState.failure, failure != dismissedFailure {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(FailurePresentation.message(for: failure))
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                if case .temporarilyUnavailable = failure {
                    Button("Retry") {
                        dismissedFailure = nil
                        viewState.refresh()
                    }
                }
                Spacer(minLength: 4)
                Button {
                    dismissedFailure = failure
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
                viewState.clear(scope)
                pendingClear = nil
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
                    viewState.searchText = ""
                } else {
                    onRequestClose()
                }
            }
            .keyboardShortcut(.cancelAction)

            Button("Toggle Preview") {
                previewState.togglePreview(for: reference(for: selection))
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
