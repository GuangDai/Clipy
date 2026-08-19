/// HistoryListView.swift — the panel's two-section list (Pinned, Recent)
/// with single selection, last-row pagination prefetch, the panel keyboard
/// surface, and both empty states.
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

/// The browsing list. Rows are keyed by `HistoryItemID`; the selection drives
/// the panel shortcuts (⏎ copy, ⌫ remove, ⌘P pin toggle, ⌘I details push).
/// Additional pages are requested when the last row appears and shown with a
/// trailing spinner row while `isLoadingPage` (04 §6: observation covers only
/// the first page; continuations are one-shot browses owned by the view state).
public struct HistoryListView: View {
    private let viewState: HistoryViewState
    private let thumbnails: ThumbnailStore
    private let isSearchFieldFocused: Bool
    private let onShowDetails: (HistoryItemReference) -> Void
    @State private var selection: HistoryItemID?

    public init(
        viewState: HistoryViewState,
        thumbnails: ThumbnailStore,
        isSearchFieldFocused: Bool,
        onShowDetails: @escaping (HistoryItemReference) -> Void
    ) {
        self.viewState = viewState
        self.thumbnails = thumbnails
        self.isSearchFieldFocused = isSearchFieldFocused
        self.onShowDetails = onShowDetails
    }

    public var body: some View {
        content
            .background { selectionShortcuts }
    }

    @ViewBuilder
    private var content: some View {
        if viewState.rows.isEmpty {
            emptyState
        } else {
            list
        }
    }

    // MARK: List

    private var list: some View {
        List(selection: $selection) {
            if !viewState.pinnedRows.isEmpty {
                Section("Pinned") {
                    ForEach(viewState.pinnedRows, id: \.item.id) { row in
                        rowContent(row, pinnedOrdinal: (row.pinnedPosition ?? 0) + 1)
                    }
                }
            }
            Section("Recent") {
                ForEach(viewState.unpinnedRows, id: \.item.id) { row in
                    rowContent(row, pinnedOrdinal: nil)
                        .onAppear {
                            prefetchNextPageIfNeeded(lastRowID: row.item.id)
                        }
                }
                if viewState.isLoadingPage {
                    loadingRow
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private func rowContent(_ row: HistoryRow, pinnedOrdinal: Int?) -> some View {
        HistoryRowView(
            row: row,
            pinnedOrdinal: pinnedOrdinal,
            thumbnails: thumbnails,
            onCopy: { viewState.requestPaste($0) },
            onPin: { id, placement in viewState.pin(id, at: placement) },
            onUnpin: { id in viewState.unpin(id) },
            onRemove: { id in viewState.remove(id) },
            onShowDetails: onShowDetails
        )
        .tag(row.item.id)
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

    private func prefetchNextPageIfNeeded(lastRowID: HistoryItemID) {
        guard viewState.hasNextPage,
              !viewState.isLoadingPage,
              viewState.rows.last?.item.id == lastRowID
        else { return }
        viewState.loadNextPage()
    }

    // MARK: Empty states

    @ViewBuilder
    private var emptyState: some View {
        if viewState.isLoadingPage {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading clipboard history")
        } else if viewState.isSearchActive {
            ContentUnavailableView(
                "No Results",
                systemImage: "magnifyingglass",
                description: "No items match “\(viewState.searchText)”."
            )
        } else {
            ContentUnavailableView(
                "No Clipboard History",
                systemImage: "doc.on.clipboard",
                description: "Copy something and it will appear here."
            )
        }
    }

    // MARK: Selection + keyboard surface

    private var selectedRow: HistoryRow? {
        guard let selection else { return nil }
        return viewState.rows.first { $0.item.id == selection }
    }

    /// Invisible buttons carrying the selection-keyed shortcuts. The ⌫
    /// shortcut is disabled while the search field has focus so Backspace
    /// keeps editing the query instead of removing the selected item.
    private var selectionShortcuts: some View {
        Group {
            Button("Copy to Clipboard") {
                if let row = selectedRow {
                    viewState.requestPaste(row.item)
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

    var body: some View {
        HistoryListView(
            viewState: viewState,
            thumbnails: thumbnails,
            isSearchFieldFocused: false,
            onShowDetails: { _ in }
        )
        .task { viewState.activate() }
        .frame(width: 400, height: 560)
    }
}
