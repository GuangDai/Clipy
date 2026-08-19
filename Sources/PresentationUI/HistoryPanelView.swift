/// HistoryPanelView.swift — the menu-bar browsing surface (400×560): search
/// header, history list inside the panel NavigationStack, failure banner, and
/// footer bar.
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

/// The composition point ClipyApp hosts inside its `MenuBarExtra` window.
/// Owns the reference-exact `ThumbnailStore` (created from
/// `viewState.history`; 01 §5.7) and the panel's details navigation: the
/// stack root is the list and `HistoryItemReference` values push
/// `HistoryDetailsView`.
public struct HistoryPanelView: View {
    private let viewState: HistoryViewState
    private let onOpenSettings: () -> Void
    private let onQuit: () -> Void

    @State private var thumbnails: ThumbnailStore
    @State private var detailsPath: [HistoryItemReference] = []
    @State private var dismissedFailure: HistoryFailure?
    @State private var pendingClear: ClearScope?
    @FocusState private var isSearchFieldFocused: Bool

    /// The inferred main-actor isolation of `View` (01 §6: main-actor UI)
    /// covers this initializer, which constructs the `@MainActor`
    /// `ThumbnailStore` for `viewState.history` (01 §5.7).
    public init(
        viewState: HistoryViewState,
        onOpenSettings: @escaping () -> Void = {},
        onQuit: @escaping () -> Void = {}
    ) {
        self.viewState = viewState
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        _thumbnails = State(initialValue: ThumbnailStore(history: viewState.history))
    }

    public var body: some View {
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
        .frame(width: 400, height: 560)
        .background { escapeShortcut }
        .task { viewState.activate() }
        .onDisappear { viewState.deactivate() }
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

    /// Esc clears the search term first; with no search text the key falls
    /// through to the menu-bar window's own dismissal.
    private var escapeShortcut: some View {
        Button("Clear Search") {
            if viewState.isSearchActive {
                viewState.searchText = ""
            }
        }
        .keyboardShortcut(.cancelAction)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

#Preview {
    HistoryPanelView(
        viewState: HistoryViewState(history: PreviewClipboardHistory.populated)
    )
}
