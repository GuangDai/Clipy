import Foundation
import HistoryCore
import SwiftUI

/// Settings keeps its own browse/selection lifecycle over the same History
/// facade. The native split view has no floating-window or hover ownership;
/// only one page from HistoryViewState's bounded window is visible at a time.
struct HistoryWorkspaceView: View {
    private let viewState: HistoryViewState
    private let copyState: HistoryWorkspaceCopyState
    @Environment(\.locale) private var locale
    @Environment(\.displayMemoryPressure) private var memoryPressure
    @Environment(\.displayMemoryPressureGeneration) private var memoryPressureGeneration
    @Environment(\.historyBrowsingPreferences) private var browsingPreferences
    @State private var thumbnails: ThumbnailStore
    @State private var sourceIcons: SourceIconStore
    @State private var batchModel: HistoryBatchActionModel
    @State private var batchTask: Task<Void, Never>?
    @State private var batchRemoval: [HistoryItemReference] = []
    @State private var showsBatchResult = false
    @State private var batchTitles: [HistoryItemID: String] = [:]
    @State private var previewState = PreviewPaneState()
    @State private var paging: HistoryWorkspacePaging
    @State private var selectedIDs: Set<HistoryItemID> = []
    @State private var isSearchFocused = false
    @State private var detailsItem: HistoryItemReference?
    @State private var removalItem: HistoryItemReference?
    @State private var clearScope: ClearScope?
    @State private var action: ItemAction?
    @State private var mutationStatus: SettingStatus?
    @State private var compactRows = false
    @State private var listWidth = 350.0
    @State private var visibleIDs: Set<HistoryItemID> = []
    @State private var listViewportHeight: CGFloat = 0
    @State private var isActive = false

    private enum ItemAction: Equatable {
        case pin(HistoryItemID), unpin(HistoryItemID), remove(HistoryItemID), clear(ClearScope)
    }

    init(viewState: HistoryViewState, copyState: HistoryWorkspaceCopyState,
         sourceIconProvider: SourceIconProvider = .none) {
        self.viewState = viewState
        self.copyState = copyState
        _thumbnails = State(initialValue: ThumbnailStore(history: viewState.history))
        _sourceIcons = State(initialValue: SourceIconStore(provider: sourceIconProvider))
        _batchModel = State(initialValue: HistoryBatchActionModel(viewState: viewState))
        _paging = State(initialValue: HistoryWorkspacePaging(pageLimit: viewState.pageLimit))
    }

    private var copyBundle: Bundle { PanelActionsCopy.bundle(for: locale) }
    private func text(_ key: String) -> String { HistoryWorkspaceCopy.text(key, bundle: copyBundle) }
    private var pageRows: [HistoryRow] {
        let offsets = paging.rowOffsets(in: viewState.loadedRowRange)
        guard offsets.upperBound <= viewState.rows.count else { return [] }
        return Array(viewState.rows[offsets])
    }
    private var selectedRow: HistoryRow? {
        guard selectedIDs.count == 1, let id = selectedIDs.first else { return nil }
        return pageRows.first { $0.item.id == id }
    }
    private var isLoading: Bool { viewState.isLoadingFirstPage || viewState.isLoadingPage }
    private var isMutating: Bool { action != nil || batchTask != nil || batchModel.isRunning }
    private var selectedReferences: [HistoryItemReference] {
        let visible = pageRows.filter { selectedIDs.contains($0.item.id) }.map(\.item)
        let visibleIDs = Set(visible.map(\.id))
        return visible + batchModel.retryReferences.filter { selectedIDs.contains($0.id) && !visibleIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(16)
            Divider()
            HistoryWorkspaceSplitView(listWidth: $listWidth) {
                historyColumn
            } preview: {
                previewColumn
            }
            statusFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("clipy.history.workspace")
        .onAppear {
            isActive = true
            if let preferences = browsingPreferences {
                let layout = preferences.remembersWorkspaceLayout ? preferences.workspaceLayout : HistoryWorkspaceLayout()
                listWidth = layout.listWidth
                compactRows = layout.compactRows
                viewState.sortOrder = layout.sortOrder
            }
            paging.reset()
            thumbnails.isSurfaceActive = true
            sourceIcons.isSurfaceActive = true
            applyMemoryPressure()
            viewState.activate(restoring: browsingPreferences?.readingItemID(for: .workspace))
        }
        .onDisappear {
            isActive = false
            browsingPreferences?.rememberReadingPosition(viewState.readingItemID, for: .workspace)
            batchModel.stop()
            batchTask?.cancel()
            batchTask = nil
            copyState.cancel()
            viewState.deactivate()
            previewState.panelClosed()
            thumbnails.isSurfaceActive = false
            thumbnails.reset()
            sourceIcons.isSurfaceActive = false
            sourceIcons.respondToMemoryPressure(.critical)
            selectedIDs = []
            detailsItem = nil
            removalItem = nil
            clearScope = nil
            action = nil
            mutationStatus = nil
            batchTitles = [:]
            showsBatchResult = false
        }
        .onChange(of: viewState.rows) { _, _ in reconcilePage() }
        .onChange(of: viewState.isLoadingPage) { _, _ in reconcilePage() }
        .onChange(of: viewState.isLoadingFirstPage) { _, loading in
            if loading {
                paging.reset()
                if !isMutating { selectedIDs = [] }
            }
        }
        .onChange(of: paging.startOrdinal) { _, _ in if !isMutating { selectedIDs = [] } }
        .onChange(of: listWidth) { _, _ in saveLayout() }
        .onChange(of: compactRows) { _, _ in saveLayout() }
        .onChange(of: viewState.sortOrder) { _, _ in saveLayout() }
        .onChange(of: viewState.restoredReadingItemID) { _, item in
            if let item { selectedIDs = [item] }
        }
        .onChange(of: viewState.didLoseReadingPosition) { _, lost in
            if lost { browsingPreferences?.clearReadingPosition(for: .workspace) }
        }
        .onChange(of: viewState.hasKnownRowOffset) { old, new in
            // A keyset restore can leave a short first cache page when it
            // reaches the start. Reopen the same query with its standard page
            // boundaries before presenting fixed-size numbered pages.
            if isActive, viewState.hasAuthoritativeFirstPage,
               HistoryWorkspacePaging.shouldRestartAtKnownBoundary(wasKnown: old, isKnown: new,
                                                                   isLoadingFirstPage: viewState.isLoadingFirstPage) {
                refresh()
            }
        }
        .onChange(of: viewState.surfacePurge) { _, purge in
            guard let purge else { return }
            thumbnails.purge(purge.scope)
            previewState.purge(purge.scope)
        }
        .onChange(of: memoryPressureGeneration) { _, _ in applyMemoryPressure() }
        .task(id: action) { await performAction() }
        .sheet(isPresented: Binding(get: { detailsItem != nil }, set: { if !$0 { detailsItem = nil } })) {
            if let detailsItem {
                NavigationStack {
                    HistoryDetailsView(viewState: viewState, item: detailsItem)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(text("Done")) { self.detailsItem = nil }
                            }
                        }
                }
                .frame(minWidth: 580, idealWidth: 740, minHeight: 500, idealHeight: 650)
            }
        }
        .confirmationDialog(text("Remove this item from history?"), isPresented: Binding(
            get: { removalItem != nil }, set: { if !$0 { removalItem = nil } }
        ), titleVisibility: .visible) {
            Button(text("Remove"), role: .destructive) {
                if let removalItem { submit(.remove(removalItem.id)) }
                removalItem = nil
            }
            Button(text("Cancel"), role: .cancel) { removalItem = nil }
        } message: {
            Text(text("This removes the item and all its revisions. It cannot be undone."))
        }
        .confirmationDialog(text(clearScope == .all ? "Clear all history?" : "Clear unpinned history?"), isPresented: Binding(
            get: { clearScope != nil }, set: { if !$0 { clearScope = nil } }
        ), titleVisibility: .visible) {
            Button(text("Clear history"), role: .destructive) {
                if let clearScope { submit(.clear(clearScope)) }
                clearScope = nil
            }
            Button(text("Cancel"), role: .cancel) { clearScope = nil }
        } message: {
            Text(text(clearScope == .all
                      ? "Removes every item, including pinned items, regardless of the current filters. This cannot be undone."
                      : "Removes all unpinned items, regardless of the current filters. Pinned items remain. This cannot be undone."))
        }
        .confirmationDialog(String(format: text("Remove %lld selected items?"), Int64(batchRemoval.count)), isPresented: Binding(
            get: { !batchRemoval.isEmpty }, set: { if !$0 { batchRemoval = [] } }
        ), titleVisibility: .visible) {
            Button(text("Remove selected items"), role: .destructive) {
                executeBatch(.remove, references: batchRemoval)
                batchRemoval = []
            }
            Button(text("Cancel"), role: .cancel) { batchRemoval = [] }
        } message: {
            Text(text("Each selected item and its revisions will be removed. This cannot be undone."))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(text("Clipboard history")).font(.title2.weight(.semibold))
                Spacer()
                Button { refresh() } label: { Label(text("Refresh"), systemImage: "arrow.clockwise") }
                    .disabled(isLoading || isMutating)
                    .accessibilityIdentifier("clipy.history.workspace.refresh")
                Menu {
                    Toggle(text("Compact rows"), isOn: $compactRows)
                    Divider()
                    Button(text("Clear unpinned history…"), role: .destructive) { clearScope = .unpinned }
                    Button(text("Clear all history…"), role: .destructive) { clearScope = .all }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuIndicator(.hidden)
                .disabled(isMutating)
                .accessibilityLabel(text("History actions"))
                .accessibilityIdentifier("clipy.history.workspace.actions")
            }
            SearchHeaderView(viewState: viewState, searchFieldFocused: $isSearchFocused,
                             areShortcutsEnabled: detailsItem == nil,
                             onMoveSelection: moveSelection, onSubmitSelection: copySelection)
            HStack(spacing: 12) {
                Picker(text("Sort"), selection: Binding(get: { viewState.sortOrder }, set: { viewState.sortOrder = $0 })) {
                    ForEach(HistorySortOrder.allCases, id: \.self) { order in
                        Text(text(sortTitle(order))).tag(order)
                    }
                }
                .fixedSize()
                .accessibilityIdentifier("clipy.history.workspace.sort")
                Spacer(minLength: 0)
                Text(SearchHeaderView.resultCountText(for: viewState, locale: locale, bundle: copyBundle))
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("clipy.history.workspace.count")
            }
        }
    }

    private var historyColumn: some View {
        VStack(spacing: 0) {
            selectionToolbar.padding(10)
            Divider()
            if viewState.isLoadingFirstPage {
                ProgressView(text("Loading history…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if pageRows.isEmpty {
                ContentUnavailableView {
                    Label(text(viewState.isSearchActive || viewState.hasActiveFilters ? "No matching items" : "History is empty"),
                          systemImage: "clipboard")
                } description: {
                    Text(text("Copied items appear here. Change the search or filters to see other items."))
                }
            } else {
                List(selection: $selectedIDs) {
                    ForEach(pageRows, id: \.item.id) { row in
                        HistoryWorkspaceRow(row: row, thumbnails: thumbnails, sourceIcons: sourceIcons,
                                            compact: compactRows)
                            .tag(row.item.id)
                            .contextMenu {
                                Button(text("Copy to Clipboard")) { viewState.requestPasteFromDisplayedRow(row.item) }
                                    .disabled(copyState.isCopying)
                                Button(text(row.pinnedPosition == nil ? "Pin" : "Unpin")) {
                                    submit(row.pinnedPosition == nil ? .pin(row.item.id) : .unpin(row.item.id))
                                }
                                Button(text("Details and editing…")) { detailsItem = row.item }
                                Divider()
                                Button(text("Remove…"), role: .destructive) { removalItem = row.item }
                            }
                            .disabled(isMutating)
                            .onGeometryChange(for: Bool.self) { proxy in
                                let frame = proxy.frame(in: .named("history-workspace-list"))
                                return frame.height > 0 && frame.maxY > 0 && frame.minY < listViewportHeight
                            } action: { visible in
                                if visible { visibleIDs.insert(row.item.id) }
                                else { visibleIDs.remove(row.item.id) }
                                recordReadingPosition()
                            }
                            .onDisappear { visibleIDs.remove(row.item.id) }
                            .accessibilityIdentifier("clipy.history.workspace.row." + row.item.id.description)
                    }
                }
                .listStyle(.inset)
                .coordinateSpace(name: "history-workspace-list")
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listViewportHeight = $0 }
                .id(paging.startOrdinal)
                .accessibilityIdentifier("clipy.history.workspace.list")
                .onKeyPress(.return) {
                    guard !isSearchFocused else { return .ignored }
                    copySelection()
                    return .handled
                }
            }
            Divider()
            pageNavigation.padding(10)
        }
    }

    private var selectionToolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(text("Select page")) { selectedIDs = Set(pageRows.map(\.item.id)) }
                    .disabled(pageRows.isEmpty || isMutating)
                    .accessibilityIdentifier("clipy.history.workspace.select-page")
                Button(text("Clear selection")) { selectedIDs = [] }
                    .disabled(selectedIDs.isEmpty || isMutating)
                    .accessibilityIdentifier("clipy.history.workspace.clear-selection")
                Spacer(minLength: 0)
                Text(String(format: text("%lld selected"), Int64(selectedIDs.count)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .controlSize(.small)
            if !selectedIDs.isEmpty {
                HStack {
                    Button(text("Pin")) { executeBatch(.pin, references: selectedReferences) }
                        .accessibilityIdentifier("clipy.history.workspace.batch.pin")
                    Button(text("Unpin")) { executeBatch(.unpin, references: selectedReferences) }
                        .accessibilityIdentifier("clipy.history.workspace.batch.unpin")
                    Spacer(minLength: 0)
                    Button(text("Remove…"), role: .destructive) { batchRemoval = selectedReferences }
                        .accessibilityIdentifier("clipy.history.workspace.batch.remove")
                }
                .controlSize(.small)
                .disabled(isMutating || selectedReferences.isEmpty)
            }
        }
    }

    private var previewColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(text("Preview")).font(.headline)
                Spacer()
                Button(action: copySelection) { Image(systemName: "doc.on.doc") }
                    .disabled(selectedRow == nil || copyState.isCopying || isMutating)
                    .help(text("Copy to Clipboard"))
                    .accessibilityLabel(text("Copy to Clipboard"))
                    .accessibilityIdentifier("clipy.history.workspace.copy")
                Button {
                    guard let row = selectedRow else { return }
                    submit(row.pinnedPosition == nil ? .pin(row.item.id) : .unpin(row.item.id))
                } label: { Image(systemName: selectedRow?.pinnedPosition == nil ? "pin" : "pin.fill") }
                .disabled(selectedRow == nil || isMutating)
                .help(text(selectedRow?.pinnedPosition == nil ? "Pin" : "Unpin"))
                .accessibilityLabel(text(selectedRow?.pinnedPosition == nil ? "Pin" : "Unpin"))
                .accessibilityIdentifier("clipy.history.workspace.pin")
                Button { detailsItem = selectedRow?.item } label: { Image(systemName: "info.circle") }
                    .disabled(selectedRow == nil || isMutating)
                    .help(text("Details and editing…"))
                    .accessibilityLabel(text("Details and editing…"))
                    .accessibilityIdentifier("clipy.history.workspace.details")
                Button { removalItem = selectedRow?.item } label: { Image(systemName: "trash") }
                    .disabled(selectedRow == nil || isMutating)
                    .help(text("Remove…"))
                    .accessibilityLabel(text("Remove…"))
                    .accessibilityIdentifier("clipy.history.workspace.remove")
            }
            .buttonStyle(.borderless)
            .padding(12)
            Divider()
            if let row = selectedRow {
                HistoryPreviewView(viewState: viewState, previewState: previewState, item: row.item,
                                   sourceIcons: sourceIcons)
                    .id(row.item.id)
                    .disabled(isMutating)
            } else {
                ContentUnavailableView {
                    Label(text(selectedIDs.count > 1 ? "Multiple items selected" : "Select an item"),
                          systemImage: selectedIDs.count > 1 ? "checkmark.circle" : "sidebar.right")
                } description: {
                    Text(text("Select one item to read its content, copy it, or open details and editing."))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityIdentifier("clipy.history.workspace.preview")
    }

    private var pageNavigation: some View {
        HStack(spacing: 8) {
            Button { changePage(.previous) } label: { Label(text("Previous page"), systemImage: "chevron.left") }
                .labelStyle(.iconOnly)
                .help(text("Previous page"))
                .disabled(isLoading || isMutating || !canMove(.previous))
                .accessibilityIdentifier("clipy.history.workspace.previous")
            VStack(spacing: 2) {
                Text(viewState.hasKnownRowOffset
                     ? String(format: text("Page %lld"), Int64(paging.pageNumber))
                     : text("Near your reading position"))
                    .font(.caption.weight(.medium))
                if viewState.hasKnownRowOffset, let range = paging.visibleRange(in: viewState.loadedRowRange) {
                    Text(String(format: text("Items %lld–%lld"), Int64(range.lowerBound), Int64(range.upperBound)))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .monospacedDigit().frame(maxWidth: .infinity)
            if viewState.isLoadingPage { ProgressView().controlSize(.small).accessibilityLabel(text("Loading page…")) }
            Button { changePage(.next) } label: { Label(text("Next page"), systemImage: "chevron.right") }
                .labelStyle(.iconOnly)
                .help(text("Next page"))
                .disabled(isLoading || isMutating || !canMove(.next))
                .accessibilityIdentifier("clipy.history.workspace.next")
        }
    }

    @ViewBuilder private var statusFooter: some View {
        if viewState.failure != nil || copyState.isCopying || copyState.status != nil || mutationStatus != nil || isMutating || showsBatchResult || viewState.didLoseReadingPosition {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if viewState.didLoseReadingPosition {
                    Label(HistoryBrowsingCopy.text("Saved reading position is unavailable in these results. Showing the start of the list.",
                                                   bundle: copyBundle), systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let failure = viewState.failure {
                    HStack {
                        SettingStatusView(status: .failure(FailurePresentation.message(for: failure, bundle: copyBundle)))
                        Spacer()
                        if viewState.canRetryFailureByRefreshing {
                            Button(text("Retry")) { refresh() }.disabled(isLoading)
                        }
                    }
                }
                if copyState.isCopying { ProgressView(text("Copying…")).controlSize(.small) }
                if let status = copyState.status { SettingStatusView(status: status) }
                if action != nil { ProgressView(text("Updating history…")).controlSize(.small) }
                if let mutationStatus { SettingStatusView(status: mutationStatus) }
                if batchModel.isRunning {
                    HStack {
                        ProgressView(value: Double(batchModel.completedCount), total: Double(max(1, batchModel.requested.count)))
                        Text(String(format: text("Processed %lld of %lld"),
                                    Int64(batchModel.completedCount), Int64(batchModel.requested.count)))
                            .font(.caption).monospacedDigit()
                        Button(text(batchModel.isStopping ? "Stopping…" : "Stop")) { batchModel.stop() }
                            .disabled(batchModel.isStopping)
                    }
                } else if batchTask != nil {
                    ProgressView(text("Updating history…")).controlSize(.small)
                } else if showsBatchResult {
                    batchResult
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .accessibilityIdentifier("clipy.history.workspace.status")
        }
    }

    private var batchResult: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(String(format: text("Completed: %lld · Failed: %lld · Not processed: %lld"),
                             Int64(batchModel.succeeded.count), Int64(batchModel.failures.count), Int64(batchModel.remaining.count)),
                      systemImage: batchModel.retryReferences.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption)
                Spacer()
                if !batchModel.retryReferences.isEmpty, let operation = batchModel.operation {
                    Button(text("Retry remaining items")) {
                        if operation == .remove { batchRemoval = batchModel.retryReferences }
                        else { executeBatch(operation, references: batchModel.retryReferences) }
                    }
                    .accessibilityIdentifier("clipy.history.workspace.batch.retry")
                }
                Button { showsBatchResult = false } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain).accessibilityLabel(text("Dismiss"))
            }
            if let first = batchModel.failures.first {
                Text(first.reason.map { FailurePresentation.message(for: $0, bundle: copyBundle) }
                     ?? text("Some items could not be updated. Retry the remaining items."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !batchModel.retryReferences.isEmpty {
                Text(text("Unfinished items remain selected for retry, even if they are no longer on this page."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup(text("Item results")) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(batchModel.succeeded, id: \.id) { item in
                            Label(batchTitles[item.id] ?? text("History item"), systemImage: "checkmark.circle")
                                .lineLimit(2)
                        }
                        ForEach(batchModel.failures, id: \.item.id) { failure in
                            VStack(alignment: .leading, spacing: 3) {
                                Label(batchTitles[failure.item.id] ?? text("History item"), systemImage: "exclamationmark.triangle")
                                    .lineLimit(2)
                                Text(failure.reason.map { FailurePresentation.message(for: $0, bundle: copyBundle) }
                                     ?? text("This item could not be updated."))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ForEach(batchModel.remaining, id: \.id) { item in
                            Label(batchTitles[item.id] ?? text("History item"), systemImage: "clock")
                                .lineLimit(2)
                                .accessibilityValue(text("Not processed"))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
            }
            .font(.caption)
        }
        .accessibilityIdentifier("clipy.history.workspace.batch.result")
    }

    private func sortTitle(_ order: HistorySortOrder) -> String {
        switch order {
        case .automatic: "Default order"
        case .newestFirst: "Newest copied first"
        case .oldestFirst: "Oldest copied first"
        case .mostCopied: "Most copied first"
        }
    }

    private func canMove(_ direction: HistoryWorkspacePaging.Direction) -> Bool {
        paging.canMove(direction, loadedRange: viewState.loadedRowRange,
                       hasPreviousPage: viewState.hasPreviousPage, hasNextPage: viewState.hasNextPage,
                       hasKnownRowOffset: viewState.hasKnownRowOffset)
    }

    private func changePage(_ direction: HistoryWorkspacePaging.Direction) {
        guard !isLoading, !isMutating, canMove(direction) else { return }
        selectedIDs = []
        visibleIDs = []
        if let request = paging.move(direction, loadedRange: viewState.loadedRowRange,
                                      hasPreviousPage: viewState.hasPreviousPage, hasNextPage: viewState.hasNextPage,
                                      hasKnownRowOffset: viewState.hasKnownRowOffset) {
            switch request {
            case .previous: viewState.loadPreviousPage()
                case .next: viewState.loadNextPage()
            }
        }
        recordReadingPosition()
    }

    private func reconcilePage() {
        paging.reconcile(loadedRange: viewState.loadedRowRange, isLoadingPage: viewState.isLoadingPage)
        guard !isMutating else { return }
        var allowed = Set(pageRows.map(\.item.id))
        if showsBatchResult { allowed.formUnion(batchModel.retryReferences.map(\.id)) }
        selectedIDs.formIntersection(allowed)
    }

    private func refresh() {
        paging.reset()
        selectedIDs = []
        viewState.refresh()
    }

    private func copySelection() {
        guard let row = selectedRow, !copyState.isCopying, !isMutating else { return }
        viewState.requestPasteFromDisplayedRow(row.item)
    }

    private func moveSelection(_ offset: Int) {
        guard !isMutating else { return }
        let current = selectedIDs.count == 1 ? selectedIDs.first : nil
        let next = PanelSessionSelection.movedSelection(current, in: pageRows,
                                                        direction: offset < 0 ? .previous : .next)
        selectedIDs = next.map { Set([$0]) } ?? []
    }

    private func submit(_ intent: ItemAction) {
        guard !isMutating else { return }
        mutationStatus = nil
        action = intent
    }

    private func executeBatch(_ operation: HistoryBatchActionModel.Operation, references: [HistoryItemReference]) {
        guard !isMutating, !references.isEmpty else { return }
        batchTitles = Dictionary(uniqueKeysWithValues: references.map { reference in
            (reference.id, pageRows.first(where: { $0.item.id == reference.id })?.title
                ?? batchTitles[reference.id] ?? text("History item"))
        })
        mutationStatus = nil
        showsBatchResult = true
        batchTask = Task {
            await batchModel.execute(operation, references: references)
            guard !Task.isCancelled else { return }
            selectedIDs = Set(batchModel.retryReferences.map(\.id))
            batchTask = nil
        }
    }

    private func performAction() async {
        guard let action else { return }
        do {
            switch action {
            case .pin(let id): _ = try await viewState.pinAwaitingReceipt(id)
            case .unpin(let id): _ = try await viewState.unpinAwaitingReceipt(id)
            case .remove(let id): _ = try await viewState.removeAwaitingReceipt(id)
            case .clear(let scope):
                let receipt = try await viewState.clearAwaitingReceipt(scope)
                guard !Task.isCancelled else { return }
                mutationStatus = clearStatusFeedback(receipt)
            }
            guard !Task.isCancelled else { return }
            if mutationStatus == nil { mutationStatus = .success(text("History updated.")) }
        } catch is CancellationError {
            return
        } catch let failure as HistoryFailure {
            guard !Task.isCancelled else { return }
            mutationStatus = .failure(FailurePresentation.message(for: failure, bundle: copyBundle))
        } catch {
            guard !Task.isCancelled else { return }
            mutationStatus = .failure(text("History could not be updated. Try again."))
        }
        self.action = nil
    }

    private func applyMemoryPressure() {
        thumbnails.respondToMemoryPressure(memoryPressure)
        sourceIcons.respondToMemoryPressure(memoryPressure)
        previewState.respondToMemoryPressure(memoryPressure)
    }

    private func saveLayout() {
        guard let preferences = browsingPreferences else { return }
        preferences.workspaceLayout = .init(listWidth: listWidth, sortOrder: viewState.sortOrder, compactRows: compactRows)
    }

    private func recordReadingPosition() {
        guard isActive else { return }
        let visible = pageRows.filter { visibleIDs.contains($0.item.id) }.map(\.item.id)
        viewState.recordReadingPosition(visibleRowIDs: visible.isEmpty ? Array(pageRows.prefix(1).map(\.item.id)) : visible)
    }
}

/// List selection uses native Command/Shift behavior. Row activation selects;
/// the workspace's explicit Copy command owns the clipboard handoff.
private struct HistoryWorkspaceRow: View {
    @Environment(\.locale) private var locale
    let row: HistoryRow
    let thumbnails: ThumbnailStore
    let sourceIcons: SourceIconStore
    let compact: Bool

    private var kind: HistoryRowKind { HistoryRowKind.classify(effectiveTypeIdentifiers: row.typeIdentifiers) }
    private var symbol: String {
        switch kind { case .text: "doc.text"; case .image: "photo"; case .link: "link"; case .other: "doc" }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                if let raster = thumbnails.raster(for: row.item),
                   let image = PreviewRasterDisplay.image(raster, scale: 2, label: Text(row.title)) {
                    image.resizable().scaledToFit()
                } else {
                    Image(systemName: symbol).font(.title3).foregroundStyle(.secondary)
                }
            }
            .frame(width: compact ? 24 : 36, height: compact ? 24 : 36)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 6) {
                    Text(row.title).lineLimit(compact ? 1 : 2).frame(maxWidth: .infinity, alignment: .leading)
                    if row.pinnedPosition != nil { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
                }
                if !compact, let snippet = row.search?.snippet {
                    Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack {
                    if let source = row.lastSource {
                        Text(sourceIcons.cachedName(forBundleID: source) ?? source)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if row.copyCount > 1 {
                        Text("×\(row.copyCount)")
                            .help(String(format: HistoryWorkspaceCopy.text("Copied %llu times", bundle: PanelActionsCopy.bundle(for: locale)),
                                         row.copyCount))
                    }
                    Spacer(minLength: 4)
                    Text(row.lastCopiedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .lineLimit(1)
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, compact ? 2 : 6)
        .contentShape(Rectangle())
        .onAppear {
            thumbnails.setDisplayed(row.item, true)
            if let source = row.lastSource { sourceIcons.setDisplayed(source, true) }
        }
        .onDisappear {
            thumbnails.setDisplayed(row.item, false)
            if let source = row.lastSource { sourceIcons.setDisplayed(source, false) }
        }
        .onChange(of: row.item) { old, new in
            thumbnails.setDisplayed(old, false)
            thumbnails.setDisplayed(new, true)
        }
        .onChange(of: row.lastSource) { old, new in
            if let old { sourceIcons.setDisplayed(old, false) }
            if let new { sourceIcons.setDisplayed(new, true) }
        }
        .task(id: row.item) {
            if ThumbnailStore.likelyThumbnailable(row.typeIdentifiers) { thumbnails.prefetch(row.item) }
        }
        .onChange(of: thumbnails.isPrefetchSuspended) { _, suspended in
            if !suspended, ThumbnailStore.likelyThumbnailable(row.typeIdentifiers) { thumbnails.prefetch(row.item) }
        }
        .onChange(of: sourceIcons.isPrefetchSuspended) { _, suspended in
            if !suspended, let source = row.lastSource { sourceIcons.icon(forBundleID: source) }
        }
        .accessibilityElement(children: .combine)
    }
}

enum HistoryWorkspaceCopy {
    static func text(_ key: String, bundle: Bundle = AppLocalization.bundle) -> String {
        bundle.localizedString(forKey: key, value: key, table: "HistoryWorkspace")
    }
}
