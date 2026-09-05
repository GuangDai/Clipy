/// HistoryListView.swift — the panel's two-section list (Pinned, Recent)
/// with single selection, last-row pagination prefetch, the panel keyboard
/// surface, and the empty states. Rows render the view state's DISPLAYED
/// lanes: the client-side type/pinned filter narrows them in memory while
/// pagination keeps walking the unfiltered stream. One list-level width
/// measurement (`onGeometryChange`, the `HistoryPanelView` body's idiom)
/// drives every row's wide-presentation decision — rows carry no geometry
/// observers of their own.
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
/// likewise threaded unchanged; the wide-presentation boolean is derived
/// here from the one list-level width measurement
/// (`HistoryRowLayout.usesWidePresentation`), never measured per row.
struct HistoryListView: View {
    private let viewState: HistoryViewState
    private let thumbnails: ThumbnailStore
    private let density: HistoryRowDensity
    private let snippetLineCount: HistorySnippetLineCount
    private let fontSize: HistoryRowFontSize
    private let isSearchFieldFocused: Bool
    private let selection: Binding<HistoryItemID?>
    private let sourceIcons: SourceIconStore?
    private let onShowDetails: (HistoryItemReference) -> Void

    /// The browsing column's live width — the single wide/narrow signal
    /// every row's presentation derives from. Zero before the first layout
    /// pass, which reads narrow (the shipped default look).
    @State private var listWidth: CGFloat = 0

    init(
        viewState: HistoryViewState,
        thumbnails: ThumbnailStore,
        density: HistoryRowDensity = .comfortable,
        snippetLineCount: HistorySnippetLineCount = .automatic,
        fontSize: HistoryRowFontSize = .medium,
        isSearchFieldFocused: Bool,
        selection: Binding<HistoryItemID?>,
        sourceIcons: SourceIconStore? = nil,
        onShowDetails: @escaping (HistoryItemReference) -> Void
    ) {
        self.viewState = viewState
        self.thumbnails = thumbnails
        self.density = density
        self.snippetLineCount = snippetLineCount
        self.fontSize = fontSize
        self.isSearchFieldFocused = isSearchFieldFocused
        self.selection = selection
        self.sourceIcons = sourceIcons
        self.onShowDetails = onShowDetails
    }

    var body: some View {
        // One list-owned timeline refreshes idle relative metadata each
        // minute. Its scheduled date may predate newly captured rows, so
        // sample the actual redraw time once for the whole list; otherwise
        // a copy made during this minute can read "in 23s" until the next
        // tick (01 §6). Individual rows still own no clocks or timers.
        TimelineView(.everyMinute) { _ in
            content(now: Date())
                .background { selectionShortcuts }
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if viewState.rows.isEmpty {
            emptyState
        } else if viewState.displayedPinnedRows.isEmpty,
                  viewState.displayedUnpinnedRows.isEmpty {
            // Rows exist but the client-side filter hides every one of them:
            // reuse the search miss state byte-identically rather than
            // gaining filter-specific copy.
            filteredEmptyState
        } else {
            list(now: now)
        }
    }

    // MARK: List

    private func list(now: Date) -> some View {
        List(selection: selection) {
            if !viewState.displayedPinnedRows.isEmpty {
                Section(HistoryListCopy.text("Pinned")) {
                    ForEach(viewState.displayedPinnedRows, id: \.item.id) { row in
                        rowContent(
                            row,
                            now: now,
                            pinnedOrdinal: (row.pinnedPosition ?? 0) + 1
                        )
                    }
                }
            }
            Section(HistoryListCopy.text("Recent")) {
                ForEach(viewState.displayedUnpinnedRows, id: \.item.id) { row in
                    rowContent(row, now: now, pinnedOrdinal: nil)
                }
                paginationControl
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        // One list-level width signal drives every row's wide/narrow
        // presentation (`HistoryRowLayout.usesWidePresentation`) — no
        // per-row geometry observers. The modifier only reports; it
        // imposes no layout of its own (the `HistoryPanelView` body's
        // idiom), and nothing animates off `listWidth`.
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            listWidth = newSize.width
        }
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
            isWidePresentation: HistoryRowLayout.usesWidePresentation(
                width: listWidth
            ),
            thumbnails: thumbnails,
            sourceIcons: sourceIcons,
            onCopy: { viewState.requestPasteFromDisplayedRow($0) },
            onPin: { id, placement in viewState.pin(id, at: placement) },
            onUnpin: { id in viewState.unpin(id) },
            onRemove: { id in viewState.remove(id) },
            onShowDetails: onShowDetails
        )
        .tag(row.item.id)
        // Drag-out loads its bytes lazily from the History paste read
        // (`HistoryViewState.dragItemProvider`), never from row state.
        // `onDrag(_:)` is the NSItemProvider-based drag API on macOS (the
        // `draggable(_:)` NSItemProvider overload is iOS/Catalyst-only);
        // the modifier attaches no AX surface, so the row's combined-element
        // contract is unchanged.
        .onDrag { viewState.dragItemProvider(for: row.item) }
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
            Button(HistoryListCopy.text("Load More")) {
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
        } else if viewState.isSearchActive {
            ContentUnavailableView(
                HistoryListCopy.text("No Results"),
                systemImage: "magnifyingglass",
                description: Text(HistoryListCopy.searchMiss(viewState.searchText))
            )
        } else {
            ContentUnavailableView(
                HistoryListCopy.text("No Clipboard History"),
                systemImage: "doc.on.clipboard",
                description: Text(HistoryListCopy.text("Copy something and it will appear here."))
            )
        }
    }

    /// Filtered-to-empty keeps the pinned "No Results" title so the
    /// running-app journey's headline assertion stays byte-identical, but
    /// the description must not render an empty search literal: a pure
    /// filter (no query) gets filter-specific copy, and a query plus filter
    /// still names the query.
    private var filteredEmptyState: some View {
        VStack {
            ContentUnavailableView(
                HistoryListCopy.text("No Results"),
                systemImage: "magnifyingglass",
                description: Text(filteredEmptyDescription)
            )
            paginationControl
                .padding(.bottom)
        }
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
