/// HistoryListView.swift — the panel's two-section list (Pinned, Recent)
/// with single selection, last-row pagination prefetch, the panel keyboard
/// surface, and the empty states. Rows render the view state's DISPLAYED
/// lanes: the client-side type/pinned filter narrows them in memory while
/// pagination keeps walking the unfiltered stream.
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

/// Pure Card 8B decision seam: pagination belongs to the complete displayed
/// ordering, not specifically to the Recent section that happens to own most
/// continuation rows.
package enum HistoryListPaginationTrigger {
    package static func shouldLoadNextPage(
        appearingRowID: HistoryItemID,
        lastDisplayedRowID: HistoryItemID?,
        hasNextPage: Bool,
        isLoadingPage: Bool
    ) -> Bool {
        hasNextPage
            && !isLoadingPage
            && lastDisplayedRowID == appearingRowID
    }
}

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
struct HistoryListView: View {
    private let viewState: HistoryViewState
    private let thumbnails: ThumbnailStore
    private let density: HistoryRowDensity
    private let isSearchFieldFocused: Bool
    private let selection: Binding<HistoryItemID?>
    private let sourceIcons: SourceIconStore?
    private let onShowDetails: (HistoryItemReference) -> Void

    init(
        viewState: HistoryViewState,
        thumbnails: ThumbnailStore,
        density: HistoryRowDensity = .comfortable,
        isSearchFieldFocused: Bool,
        selection: Binding<HistoryItemID?>,
        sourceIcons: SourceIconStore? = nil,
        onShowDetails: @escaping (HistoryItemReference) -> Void
    ) {
        self.viewState = viewState
        self.thumbnails = thumbnails
        self.density = density
        self.isSearchFieldFocused = isSearchFieldFocused
        self.selection = selection
        self.sourceIcons = sourceIcons
        self.onShowDetails = onShowDetails
    }

    var body: some View {
        // Minute precision is the owning UX decision for relative metadata.
        // One list-owned timeline supplies the same minute-boundary instant
        // to every visible row. `.everyMinute` performs an immediate render
        // and then advances at wall-clock minute boundaries; rows do not own
        // timers, and no process-global clock service is introduced.
        TimelineView(.everyMinute) { timeline in
            content(now: timeline.date)
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
                Section("Pinned") {
                    ForEach(viewState.displayedPinnedRows, id: \.item.id) { row in
                        rowContent(
                            row,
                            now: now,
                            pinnedOrdinal: (row.pinnedPosition ?? 0) + 1
                        )
                    }
                }
            }
            Section("Recent") {
                ForEach(viewState.displayedUnpinnedRows, id: \.item.id) { row in
                    rowContent(row, now: now, pinnedOrdinal: nil)
                }
                if viewState.isLoadingPage {
                    loadingRow
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
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
        // (`HistoryViewState.dragItemProvider`), never from row state. The
        // modifier attaches no AX surface, so the row's combined-element
        // contract is unchanged.
        .draggable(viewState.dragItemProvider(for: row.item))
        .onAppear {
            prefetchNextPageIfNeeded(appearingRowID: row.item.id)
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
        .accessibilityLabel("Loading more items")
    }

    private func prefetchNextPageIfNeeded(appearingRowID: HistoryItemID) {
        guard HistoryListPaginationTrigger.shouldLoadNextPage(
            appearingRowID: appearingRowID,
            lastDisplayedRowID: viewState.rows.last?.item.id,
            hasNextPage: viewState.hasNextPage,
            isLoadingPage: viewState.isLoadingPage
        ) else { return }
        viewState.loadNextPage()
    }

    // MARK: Empty states

    @ViewBuilder
    private var emptyState: some View {
        if viewState.isLoadingFirstPage {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading clipboard history")
        } else if viewState.isSearchActive {
            ContentUnavailableView(
                "No Results",
                systemImage: "magnifyingglass",
                description: Text("No items match “\(viewState.searchText)”.")
            )
        } else {
            ContentUnavailableView(
                "No Clipboard History",
                systemImage: "doc.on.clipboard",
                description: Text("Copy something and it will appear here.")
            )
        }
    }

    /// Filtered-to-empty reuses the search miss state (the pinned "No
    /// Results" strings stay byte-identical); only the "no items at all"
    /// copy above stays distinct.
    private var filteredEmptyState: some View {
        ContentUnavailableView(
            "No Results",
            systemImage: "magnifyingglass",
            description: Text("No items match “\(viewState.searchText)”.")
        )
    }

    // MARK: Selection + keyboard surface

    private var selectedRow: HistoryRow? {
        guard let id = selection.wrappedValue else { return nil }
        return viewState.rows.first { $0.item.id == id }
    }

    /// Invisible buttons carrying the selection-keyed shortcuts. The ⌫
    /// shortcut is disabled while the search field has focus so Backspace
    /// keeps editing the query instead of removing the selected item.
    private var selectionShortcuts: some View {
        Group {
            Button("Copy to Clipboard") {
                if let row = selectedRow {
                    viewState.requestPasteFromDisplayedRow(row.item)
                }
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(selectedRow == nil)

            Button("Remove") {
                if let row = selectedRow {
                    viewState.remove(row.item.id)
                }
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(selectedRow == nil || isSearchFieldFocused)

            Button("Toggle Pin") {
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
            Button("Pin to Top") {
                if let row = selectedRow {
                    viewState.pin(row.item.id, at: .first)
                }
            }
            .keyboardShortcut(.upArrow, modifiers: [.option, .command])
            .disabled(selectedRow == nil)

            Button("Pin to Bottom") {
                if let row = selectedRow {
                    viewState.pin(row.item.id, at: .last)
                }
            }
            .keyboardShortcut(.downArrow, modifiers: [.option, .command])
            .disabled(selectedRow == nil)

            Button("Show Details") {
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
