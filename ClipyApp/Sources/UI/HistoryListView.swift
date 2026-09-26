/// HistoryListView.swift — pinned items followed by recent history, separated
/// by one unobtrusive rule when both groups are present.
/// with single selection, viewport-driven pagination, the panel keyboard
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
/// Additional pages are requested near the visible edges and shown with a
/// trailing spinner row while `isLoadingPage` (04 §6: observation covers only
/// the first page; continuations are one-shot browses owned by the view state).
/// `density` is the panel's row-density preference, threaded unchanged into
/// every row; `.comfortable` reproduces the shipped row metrics exactly.
/// `snippetLineCount`/`fontSize` are the row-typography preferences,
/// likewise threaded unchanged into each row.
struct HistoryListView: View {
    @Environment(\.locale) private var locale
    private let viewState: HistoryViewState
    private let thumbnails: ThumbnailStore
    private let density: HistoryRowDensity
    private let snippetLineCount: HistorySnippetLineCount
    private let fontSize: HistoryRowFontSize
    private let isSearchFieldFocused: Bool
    private let shortcuts: PanelShortcutSettings
    private let areShortcutsEnabled: Bool
    private let selection: Binding<HistoryItemID?>
    private let inputMode: PanelInputMode
    private let keyboardNavigationGeneration: Int
    private let onFocusHistory: () -> Void
    private let onHoverRow: (HistoryItemID) -> Void
    private let onKeyboardSelection: (HistoryItemID?) -> Void
    private let onPointerMovement: () -> Void
    private let onShowDetails: (HistoryItemReference) -> Void

    init(
        viewState: HistoryViewState,
        thumbnails: ThumbnailStore,
        density: HistoryRowDensity = .compact,
        snippetLineCount: HistorySnippetLineCount = .automatic,
        fontSize: HistoryRowFontSize = .medium,
        isSearchFieldFocused: Bool,
        shortcuts: PanelShortcutSettings = PanelShortcutSettings(),
        areShortcutsEnabled: Bool = true,
        selection: Binding<HistoryItemID?>,
        inputMode: PanelInputMode = .keyboard,
        keyboardNavigationGeneration: Int = 0,
        onFocusHistory: @escaping () -> Void = {},
        onHoverRow: @escaping (HistoryItemID) -> Void = { _ in },
        onKeyboardSelection: @escaping (HistoryItemID?) -> Void,
        onPointerMovement: @escaping () -> Void = {},
        onShowDetails: @escaping (HistoryItemReference) -> Void
    ) {
        self.viewState = viewState
        self.thumbnails = thumbnails
        self.density = density
        self.snippetLineCount = snippetLineCount
        self.fontSize = fontSize
        self.isSearchFieldFocused = isSearchFieldFocused
        self.shortcuts = shortcuts
        self.areShortcutsEnabled = areShortcutsEnabled
        self.selection = selection
        self.inputMode = inputMode
        self.keyboardNavigationGeneration = keyboardNavigationGeneration
        self.onFocusHistory = onFocusHistory
        self.onHoverRow = onHoverRow
        self.onKeyboardSelection = onKeyboardSelection
        self.onPointerMovement = onPointerMovement
        self.onShowDetails = onShowDetails
    }

    @State private var dragSource = HistoryListDraggingView()
    @State private var viewportHeight: CGFloat = 0
    @State private var firstVisibleRowID: HistoryItemID?

    var body: some View {
        let _ = locale
        // Observe row facts directly. A periodic TimelineView must not own
        // publication of captures, pin changes or updated accessibility labels.
        VStack(spacing: 0) {
            content(now: Date())
        }
        .background { selectionShortcuts }
        .onChange(of: viewState.hasAuthoritativeFirstPage) { _, hasPage in
            // A new query or return-to-latest request starts at its first
            // result even if that query happens to include the old anchor.
            if !hasPage { firstVisibleRowID = nil }
        }
        .onChange(of: viewState.restoredReadingItemID, initial: true) { _, id in
            guard let id else { return }
            firstVisibleRowID = id
            selection.wrappedValue = id
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let rows = viewState.displayedRows
        if viewState.rows.isEmpty {
            emptyState
        } else if rows.isEmpty {
            // Keep the displayed-row fallback consistent with the current
            // query while presentation reconciles its loaded lanes.
            filteredEmptyState
        } else {
            list(rows: rows, now: now)
        }
    }

    // MARK: List

    private func list(rows: [HistoryRow], now: Date) -> some View {
        // Reuse this render's displayed rows for the lane boundary instead
        // of materializing both filtered lanes several times (03b §8).
        let firstUnpinnedID = rows.first { $0.pinnedPosition == nil }?.item.id
        let showsGroupSeparator = viewState.sortOrder == .automatic && rows.first?.pinnedPosition != nil
            && (firstUnpinnedID != nil || viewState.hasNextPage || viewState.isLoadingPage)
        let separatorID = showsGroupSeparator ? firstUnpinnedID : nil
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    // One identity stream lets a pin move the existing item
                    // while updating its facts. Separate pinned/recent ForEach
                    // branches can reuse the old unpinned lazy row for that ID.
                    ForEach(rows, id: \.item.id) { row in
                        VStack(spacing: 0) {
                            if row.item.id == separatorID {
                                Divider()
                                    .frame(height: PanelContentFit.groupSeparatorHeight)
                                    .accessibilityHidden(true)
                            }
                            rowContent(row, now: now, pinnedOrdinal: row.pinnedPosition.map { $0 + 1 })
                        }
                        .id(row.item.id)
                    }
                    if showsGroupSeparator, separatorID == nil {
                        Divider()
                            .frame(height: PanelContentFit.groupSeparatorHeight)
                            .accessibilityHidden(true)
                    }
                    paginationControl
                }
                .scrollTargetLayout()
                .padding(.horizontal, PanelContentFit.listRowHorizontalInset)
            }
            // Preserve the actual reading position when bounded pagination
            // removes a page above it or inserts newer rows before it.
            .scrollPosition(id: $firstVisibleRowID, anchor: .top)
            .onScrollTargetVisibilityChange(idType: HistoryItemID.self, threshold: 0.01) { ids in
                viewState.prefetchPagesIfNeeded(visibleRowIDs: ids)
            }
            .background { NativePanelBackground() }
            .focusable()
            .focusEffectDisabled()
            // Search owns explicit focus requests on open, Back and Clear.
            // The scroll view receives focus through actual keyboard/mouse
            // navigation, never by mirroring an earlier search-focus value.
            .accessibilityIdentifier("clipy.history.scroll")
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
            .onChange(of: keyboardNavigationGeneration) { _, _ in
                // Pointer hover must never scroll rows out from under the mouse.
                // Keyboard selection, including arrows received by Search,
                // reveals its current target without choosing an initial row.
                if inputMode == .keyboard, let selected = selection.wrappedValue {
                    proxy.scrollTo(selected)
                }
            }
            .onKeyPress(keys: [.upArrow, .downArrow, .pageUp, .pageDown, .home, .end]) { press in
                guard !isSearchFieldFocused, areShortcutsEnabled else { return .ignored }
                onKeyboardSelection(selectionTarget(for: press.key))
                return .handled
            }
            .background {
                HistoryListDragSource(view: dragSource) { reference in
                    try await viewState.dragPayload(for: reference)
                }
            }
            .onPanelMouseMovement(onPointerMovement)
        }
    }

    /// SwiftUI owns one selection highlight and the scroll viewport. Keyboard
    /// paging uses the same row heights as content fitting, including images.
    private func selectionTarget(for key: KeyEquivalent) -> HistoryItemID? {
        let rows = viewState.displayedRows
        guard !rows.isEmpty else { return nil }
        if key == .home { return rows.first?.item.id }
        if key == .end { return rows.last?.item.id }
        let direction: PanelSelectionDirection = key == .upArrow || key == .pageUp ? .previous : .next
        guard key == .pageUp || key == .pageDown,
              let index = rows.firstIndex(where: { $0.item.id == selection.wrappedValue }) else {
            return PanelSessionSelection.movedSelection(selection.wrappedValue, in: rows, direction: direction)
        }
        let offset = direction == .previous ? -1 : 1
        var target = index
        var distance: CGFloat = 0
        repeat {
            let next = target + offset
            guard rows.indices.contains(next) else { break }
            target = next
            let descriptor = PanelContentFit.RowDescriptor(row: rows[target],
                snippetLineLimit: snippetLineCount.baseLineLimit(density: density))
            distance += PanelContentFit.rowHeight(descriptor, density: density, fontSize: fontSize)
        } while distance < viewportHeight
        return rows[target].item.id
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
            shortcuts: shortcuts,
            areShortcutsEnabled: areShortcutsEnabled,
            thumbnails: thumbnails,
            dragSource: dragSource,
            externalOpener: viewState.externalOpener,
            onCopy: { reference in
                selection.wrappedValue = reference.id
                onFocusHistory()
                viewState.requestPasteFromDisplayedRow(reference)
            },
            onPin: { id, placement in viewState.pin(id, at: placement) },
            onUnpin: { id in viewState.unpin(id) },
            onRemove: { id in viewState.remove(id) },
            onShowDetails: onShowDetails
        )
        .padding(EdgeInsets(
            top: PanelContentFit.listRowVerticalInset,
            leading: PanelContentFit.listRowHorizontalInset,
            bottom: PanelContentFit.listRowVerticalInset,
            trailing: PanelContentFit.listRowHorizontalInset
        ))
        // Hover selection (Maccy's HoverSelectionModifier): the surface
        // state arbitrates pointer-vs-keyboard mode, so hover selects
        // without scrolling only in mouse mode and otherwise defers until
        // the mouse next moves.
        .onHover { inside in
            if inside { onHoverRow(row.item.id) }
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
        } else if let issue = HistorySearchCopy.issue(for: viewState) {
            emptyMessage(HistorySearchCopy.text("Check search conditions"), symbol: "exclamationmark.magnifyingglass",
                         description: issue)
        } else if viewState.hasActiveFilters {
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
        return viewState.displayedRow(for: id)
    }

    /// Invisible buttons carrying the selection-keyed shortcuts. The ⌫
    /// shortcut is disabled while the search field has focus so Backspace
    /// keeps editing the query instead of removing the selected item.
    private var selectionShortcuts: some View {
        let hasSelection = selectedRow != nil
        return Group {
            Button(PanelActionsCopy.text("Copy to Clipboard")) {
                if let row = selectedRow {
                    viewState.requestPasteFromDisplayedRow(row.item)
                }
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(!hasSelection)

            Button(PanelActionsCopy.text("Remove")) {
                if let row = selectedRow {
                    viewState.remove(row.item.id)
                }
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .remove, whileEditingText: isSearchFieldFocused))
            .disabled(!hasSelection)

            Button(HistoryListCopy.text("Toggle Pin")) {
                if let row = selectedRow {
                    if row.pinnedPosition != nil {
                        viewState.unpin(row.item.id)
                    } else {
                        viewState.pin(row.item.id, at: .first)
                    }
                }
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .togglePin, whileEditingText: isSearchFieldFocused))
            .disabled(!hasSelection)

            // Context-menu semantics: placePinned reorders an already-pinned item.
            Button(PanelActionsCopy.text("Pin to Top")) {
                if let row = selectedRow {
                    viewState.pin(row.item.id, at: .first)
                }
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .pinToTop, whileEditingText: isSearchFieldFocused))
            .disabled(!hasSelection)

            Button(PanelActionsCopy.text("Pin to Bottom")) {
                if let row = selectedRow {
                    viewState.pin(row.item.id, at: .last)
                }
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .pinToBottom, whileEditingText: isSearchFieldFocused))
            .disabled(!hasSelection)

            Button(PanelActionsCopy.text("Show Details")) {
                if let row = selectedRow {
                    onShowDetails(row.item)
                }
            }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: .showDetails, whileEditingText: isSearchFieldFocused))
            .disabled(!hasSelection)
        }
        .disabled(!areShortcutsEnabled)
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
    @State private var keyboardNavigationGeneration = 0

    var body: some View {
        HistoryListView(
            viewState: viewState,
            thumbnails: thumbnails,
            isSearchFieldFocused: false,
            selection: $selection,
            keyboardNavigationGeneration: keyboardNavigationGeneration,
            onKeyboardSelection: {
                selection = $0
                keyboardNavigationGeneration += 1
            },
            onShowDetails: { _ in }
        )
        .task { viewState.activate() }
        .frame(width: 400, height: 560)
    }
}
