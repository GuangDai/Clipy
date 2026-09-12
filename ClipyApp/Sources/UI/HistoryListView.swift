/// HistoryListView.swift — the panel's two-section list (Pinned, Recent)
/// with single selection, last-row pagination prefetch, the panel keyboard
/// surface, and the empty states. Rows render the view state's DISPLAYED
/// lanes: History applies type/pinned filters before pagination. Row content
/// uses the available width without changing metadata formats on resize.
/// Owning spec: docs/01-architecture.md §5.2 (gesture → action), §5.4
/// (browse/observe), §6 (main-actor selection);
/// docs/03b-instruction-set.md §8 (default ordering: pinned rows by ordinal
/// ascending, then unpinned by lastCopiedAt descending);
/// docs/04-coherence.md §5 (snapshot-replacement pages — the list renders
/// `HistoryViewState.rows`, never deltas) and §6 (cursor expiry is handled by
/// `HistoryViewState.loadNextPage()`); accessibility per docs/v2/V2-07-ux.md §9.
import Foundation
import HistoryCore
import SwiftUI

/// Module-internal browsing list behind the caller-visible `HistoryPanelView`.
/// Rows are keyed by `HistoryItemID`; the selection
/// (hoisted to the panel so the preview pane can dwell on it) drives the
/// panel shortcuts (⏎ copy, ⌫ remove, ⌘P pin toggle, ⌥⌘↑/⌥⌘↓ pin to
/// top/bottom, ⌘I details push).
/// Additional pages are requested when the last row appears and shown with a
/// trailing spinner row while `isLoadingPage` (04 §6: observation covers only
/// the first page; continuations are one-shot browses owned by the view state).
/// `density` is the panel's row-density preference, threaded unchanged into
/// every row; `.comfortable` reproduces the shipped row metrics exactly.
/// `snippetLineCount`/`fontSize` are the row-typography preferences,
/// likewise threaded unchanged into each row.
struct HistoryListView: View {
    private let viewState: HistoryViewState
    private let thumbnails: ThumbnailStore
    private let density: HistoryRowDensity
    private let snippetLineCount: HistorySnippetLineCount
    private let fontSize: HistoryRowFontSize
    private let isSearchFieldFocused: Bool
    private let selection: Binding<HistoryItemID?>
    private let onFocusHistory: () -> Void
    private let onHoverRow: (HistoryItemID) -> Void
    private let onKeyboardNavigation: () -> Void
    private let onPointerMovement: () -> Void
    private let onShowDetails: (HistoryItemReference) -> Void

    init(
        viewState: HistoryViewState,
        thumbnails: ThumbnailStore,
        density: HistoryRowDensity = .compact,
        snippetLineCount: HistorySnippetLineCount = .automatic,
        fontSize: HistoryRowFontSize = .medium,
        isSearchFieldFocused: Bool,
        selection: Binding<HistoryItemID?>,
        onFocusHistory: @escaping () -> Void = {},
        onHoverRow: @escaping (HistoryItemID) -> Void = { _ in },
        onKeyboardNavigation: @escaping () -> Void = {},
        onPointerMovement: @escaping () -> Void = {},
        onShowDetails: @escaping (HistoryItemReference) -> Void
    ) {
        self.viewState = viewState
        self.thumbnails = thumbnails
        self.density = density
        self.snippetLineCount = snippetLineCount
        self.fontSize = fontSize
        self.isSearchFieldFocused = isSearchFieldFocused
        self.selection = selection
        self.onFocusHistory = onFocusHistory
        self.onHoverRow = onHoverRow
        self.onKeyboardNavigation = onKeyboardNavigation
        self.onPointerMovement = onPointerMovement
        self.onShowDetails = onShowDetails
    }

    @State private var dragSource = HistoryListDraggingView()

    var body: some View {
        // One list-owned timeline refreshes idle relative metadata each
        // minute. Its scheduled date may predate newly captured rows, so
        // sample the actual redraw time once for the whole list; otherwise
        // a copy made during this minute can read "in 23s" until the next
        // tick (01 §6). Individual rows still own no clocks or timers.
        TimelineView(.everyMinute) { _ in
            VStack(spacing: 0) {
                if viewState.hasWindowedPages {
                    HStack {
                        Button(HistoryListCopy.text("Newer")) { viewState.loadPreviousPage() }
                            .disabled(!viewState.hasPreviousPage || viewState.isLoadingPage)
                            .accessibilityIdentifier("clipy.history.newer")
                        Spacer()
                        Button(HistoryListCopy.text("Latest")) { viewState.returnToLatest() }
                            .accessibilityIdentifier("clipy.history.latest")
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }
                content(now: Date())
            }
            .background { selectionShortcuts }
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if viewState.rows.isEmpty {
            emptyState
        } else if viewState.displayedPinnedRows.isEmpty,
                  viewState.displayedUnpinnedRows.isEmpty {
            // Keep the displayed-row fallback consistent with the current
            // query while presentation reconciles its loaded lanes.
            filteredEmptyState
        } else {
            list(now: now)
        }
    }

    // MARK: List

    private func list(now: Date) -> some View {
        List(selection: selection) {
            if !viewState.displayedPinnedRows.isEmpty {
                Section {
                    ForEach(viewState.displayedPinnedRows, id: \.item.id) { row in
                        rowContent(
                            row,
                            now: now,
                            pinnedOrdinal: (row.pinnedPosition ?? 0) + 1
                        )
                    }
                } header: {
                    if showsSectionHeaders { Text(HistoryListCopy.text("Pinned")) }
                }
            }
            if !viewState.displayedUnpinnedRows.isEmpty || viewState.hasNextPage || viewState.isLoadingPage {
                Section {
                    ForEach(viewState.displayedUnpinnedRows, id: \.item.id) { row in
                        rowContent(row, now: now, pinnedOrdinal: nil)
                    }
                    paginationControl
                } header: {
                    if showsSectionHeaders { Text(HistoryListCopy.text("Recent")) }
                }
            }
        }
        // macOS inset lists retain extra internal margins even when scroll
        // content margins are zero. A plain list keeps the first and last
        // row inside the content-fitted viewport; horizontal inset is explicit.
        .listStyle(.plain)
        .contentMargins(.vertical, 0, for: .scrollContent)
        .padding(.horizontal, PanelContentFit.listRowHorizontalInset)
        .environment(\.defaultMinListRowHeight, 0)
        .environment(\.defaultMinListHeaderHeight, 0)
        .scrollContentBackground(.hidden)
        .background {
            HistoryListDragSource(view: dragSource) { reference in
                try await viewState.dragPayload(for: reference)
            }
        }
        // Real mouse movement (an NSTrackingArea, never SwiftUI hover —
        // which also fires when content scrolls beneath a STATIONARY
        // pointer) restores pointer control of the selection. Paging and
        // beginning/end keys also scroll rows beneath that pointer, so they
        // must establish keyboard intent before native scrolling (V2-07 §9).
        // This list-scoped handler leaves search/editor text input alone;
        // `.ignored` preserves native key bindings and scroll behavior.
        .onKeyPress(keys: [.upArrow, .downArrow, .pageUp, .pageDown, .home, .end]) { _ in
            onKeyboardNavigation()
            return .ignored
        }
        .onPanelMouseMovement(onPointerMovement)
    }

    private var showsSectionHeaders: Bool {
        !viewState.displayedPinnedRows.isEmpty
            && (!viewState.displayedUnpinnedRows.isEmpty || viewState.hasNextPage || viewState.isLoadingPage)
    }

    private func rowContent(
        _ row: HistoryRow,
        now: Date,
        pinnedOrdinal: Int?
    ) -> some View {
        HistoryRowView(
            row: row,
            now: now,
            pinnedOrdinal: pinnedOrdinal,
            density: density,
            snippetLineCount: snippetLineCount,
            fontSize: fontSize,
            isSelected: selection.wrappedValue == row.item.id,
            thumbnails: thumbnails,
            dragSource: dragSource,
            onCopy: { viewState.requestPasteFromDisplayedRow($0) },
            onPin: { id, placement in viewState.pin(id, at: placement) },
            onUnpin: { id in viewState.unpin(id) },
            onRemove: { id in viewState.remove(id) },
            onShowDetails: onShowDetails
        )
        .tag(row.item.id)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(
            top: PanelContentFit.listRowVerticalInset,
            leading: PanelContentFit.listRowHorizontalInset,
            bottom: PanelContentFit.listRowVerticalInset,
            trailing: PanelContentFit.listRowHorizontalInset
        ))
        // Clicking even the already-selected row transfers keyboard intent
        // out of search, so Space opens Quick Look instead of editing the
        // query. Keep this simultaneous with the row's double-click Copy;
        // a single click only selects and changes focus (Card 14A).
        .simultaneousGesture(
            TapGesture().onEnded {
                selection.wrappedValue = row.item.id
                onFocusHistory()
            }
        )
        // Hover selection (Maccy's HoverSelectionModifier): the surface
        // state arbitrates pointer-vs-keyboard mode, so hover selects
        // without scrolling only in mouse mode and otherwise defers until
        // the mouse next moves.
        .onHover { inside in
            if inside { onHoverRow(row.item.id) }
        }
        .onAppear {
            viewState.prefetchNextPageIfNeeded(appearingRowID: row.item.id)
        }
    }

    private var loadingRow: some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Spacer()
        }
        .padding(.vertical, 6)
        .accessibilityLabel(HistoryListCopy.text("Loading more items"))
    }

    /// A page can add only filtered-out rows, leaving the last rendered row
    /// unchanged and producing no new onAppear. Keep an explicit continuation
    /// reachable both there and when every loaded row is hidden (Card 8B).
    @ViewBuilder
    private var paginationControl: some View {
        if viewState.isLoadingPage {
            loadingRow
        } else if viewState.hasNextPage {
            Button(HistoryListCopy.text("Older")) {
                viewState.loadNextPage()
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("clipy.history.load-more")
        }
    }

    // MARK: Empty states

    @ViewBuilder
    private var emptyState: some View {
        if viewState.isLoadingFirstPage {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(HistoryListCopy.text("Loading clipboard history"))
        } else if viewState.typeFilter != .all || viewState.showsPinnedOnly {
            filteredEmptyState
        } else if viewState.isSearchActive {
            emptyMessage("No Results", symbol: "magnifyingglass",
                         description: HistoryListCopy.searchMiss(viewState.searchText))
        } else {
            emptyMessage("No Clipboard History", symbol: "doc.on.clipboard",
                         description: HistoryListCopy.text("Copy something and it will appear here."))
        }
    }

    /// Filtered-to-empty keeps the pinned "No Results" title so the
    /// running-app journey's headline assertion stays byte-identical, but
    /// the description must not render an empty search literal: a pure
    /// filter (no query) gets filter-specific copy, and a query plus filter
    /// still names the query.
    private var filteredEmptyState: some View {
        VStack {
            emptyMessage("No Results", symbol: "magnifyingglass", description: filteredEmptyDescription)
            paginationControl
                .padding(.bottom)
        }
    }

    private func emptyMessage(_ title: String, symbol: String, description: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(HistoryListCopy.text(title)).font(.callout.weight(.medium))
                Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var filteredEmptyDescription: String {
        viewState.searchText.isEmpty
            ? HistoryListCopy.text("No items match the current filter.")
            : HistoryListCopy.searchMiss(viewState.searchText)
    }

    // MARK: Selection + keyboard surface

    private var selectedRow: HistoryRow? {
        guard let id = selection.wrappedValue else { return nil }
        return viewState.displayedRows.first { $0.item.id == id }
    }

    /// Invisible buttons carrying the selection-keyed shortcuts. The ⌫
    /// shortcut is disabled while the search field has focus so Backspace
    /// keeps editing the query instead of removing the selected item.
    private var selectionShortcuts: some View {
        Group {
            Button(PanelActionsCopy.text("Copy to Clipboard")) {
                if let row = selectedRow {
                    viewState.requestPasteFromDisplayedRow(row.item)
                }
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(selectedRow == nil)

            Button(PanelActionsCopy.text("Remove")) {
                if let row = selectedRow {
                    viewState.remove(row.item.id)
                }
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(selectedRow == nil || isSearchFieldFocused)

            Button(HistoryListCopy.text("Toggle Pin")) {
                if let row = selectedRow {
                    if row.pinnedPosition != nil {
                        viewState.unpin(row.item.id)
                    } else {
                        viewState.pin(row.item.id, at: .first)
                    }
                }
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(selectedRow == nil)

            // Context-menu semantics: placePinned reorders an already-pinned item.
            Button(PanelActionsCopy.text("Pin to Top")) {
                if let row = selectedRow {
                    viewState.pin(row.item.id, at: .first)
                }
            }
            .keyboardShortcut(.upArrow, modifiers: [.option, .command])
            .disabled(selectedRow == nil)

            Button(PanelActionsCopy.text("Pin to Bottom")) {
                if let row = selectedRow {
                    viewState.pin(row.item.id, at: .last)
                }
            }
            .keyboardShortcut(.downArrow, modifiers: [.option, .command])
            .disabled(selectedRow == nil)

            Button(PanelActionsCopy.text("Show Details")) {
                if let row = selectedRow {
                    onShowDetails(row.item)
                }
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(selectedRow == nil)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

#Preview {
    HistoryListViewPreview()
}

private struct HistoryListViewPreview: View {
    @State private var viewState = HistoryViewState(
        history: PreviewClipboardHistory.populated
    )
    @State private var thumbnails = ThumbnailStore(
        history: PreviewClipboardHistory.populated
    )
    @State private var selection: HistoryItemID?

    var body: some View {
        HistoryListView(
            viewState: viewState,
            thumbnails: thumbnails,
            isSearchFieldFocused: false,
            selection: $selection,
            onShowDetails: { _ in }
        )
        .task { viewState.activate() }
        .frame(width: 400, height: 560)
    }
}
