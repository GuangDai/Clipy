/// SearchHeaderView.swift — the panel's query surface: the rounded search
/// field, ordinary search modes (⌘1/⌘2/⌘3), explicit advanced expressions,
/// history-wide metadata filters, and directly removable active conditions.
/// Owning spec: docs/architecture.md (browse/search flow);
/// docs/architecture.md (search modes);
/// docs/testing.md (fuzzy 64-Character query bound);
/// accessibility per docs/interface.md
import Foundation
import HistoryCore
import SwiftUI

/// The header above the history list. Edits funnel through
/// `HistoryViewState.searchText`, which restarts observation. The stable search row
/// keeps secondary options in compact menus; the panel's focus binding keeps bare-key
/// shortcuts away from the text field (01 §6: selection and keyboard behavior
/// are main-actor UI concerns).
///
/// The field preserves the raw draft. `HistoryViewState` owns mode-specific
/// input limits, so the user can switch modes without re-entering their query.
struct SearchHeaderView: View {
    @Environment(\.locale) private var locale
    @Environment(\.searchHistoryStore) private var searchHistoryStore
    @State private var showsSearchOptions = false
    @State private var showsExpressionGuide = false
    @State private var showsSearchLibrary = false
    @State private var completion: HistorySearchCompletionState

    private let viewState: HistoryViewState
    private let searchFieldFocused: Binding<Bool>
    private let onMoveSelection: (Int) -> Void
    private let onSubmitSelection: () -> Void
    private let shortcuts: PanelShortcutSettings
    private let areShortcutsEnabled: Bool

    init(
        viewState: HistoryViewState,
        searchFieldFocused: Binding<Bool>,
        shortcuts: PanelShortcutSettings = PanelShortcutSettings(),
        areShortcutsEnabled: Bool = true,
        onMoveSelection: @escaping (Int) -> Void = { _ in },
        onSubmitSelection: @escaping () -> Void = {},
        completion: HistorySearchCompletionState? = nil
    ) {
        self.viewState = viewState
        self.searchFieldFocused = searchFieldFocused
        self.shortcuts = shortcuts
        self.areShortcutsEnabled = areShortcutsEnabled
        self.onMoveSelection = onMoveSelection
        self.onSubmitSelection = onSubmitSelection
        _completion = State(initialValue: completion ?? HistorySearchCompletionState())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.spacingXSmall) {
            HStack(spacing: PanelTheme.spacingXSmall) {
                searchField
                    .frame(maxWidth: .infinity)
                filterMenu
                    .frame(width: 24, height: 24)
            }
            // Candidates extend below this row over the status controls.
            // The outer header's ordering does not order these siblings.
            .zIndex(completion.isPresented ? 1 : 0)
            queryControls
            if viewState.isSearchStatusVisible {
                searchStatusRow.frame(height: 15)
            }
        }
        .zIndex(completion.isPresented ? 20 : 0)
        .background { modeShortcuts }
        .popover(isPresented: $showsSearchOptions, arrowEdge: .bottom) {
            HistorySearchOptionsView(
                viewState: viewState, completion: completion,
                showsExpressionGuide: showsExpressionGuide
            )
        }
        .onChange(of: showsSearchOptions) { _, isPresented in
            if !isPresented { searchFieldFocused.wrappedValue = true }
        }
        .popover(isPresented: $showsSearchLibrary, arrowEdge: .bottom) {
            if let store = searchHistoryStore {
                SearchLibraryView(viewState: viewState, store: store) {
                    searchFieldFocused.wrappedValue = true
                }
            }
        }
        .onChange(of: showsSearchLibrary) { _, isPresented in
            if !isPresented { searchFieldFocused.wrappedValue = true }
        }
        .onAppear { configureCompletion() }
        .onDisappear { completion.close() }
        .onChange(of: searchFieldFocused.wrappedValue) { _, focused in
            if focused { configureCompletion() }
            else { completion.setFocused(false) }
        }
        .onChange(of: areShortcutsEnabled) { _, enabled in
            if !enabled { completion.close() }
            else { configureCompletion() }
        }
        .onChange(of: viewState.sourceCompletionPosition) { _, position in
            completion.updateHistoryPosition(position)
        }
        .onChange(of: viewState.searchMode) { _, _ in configureCompletion() }
    }

    private func configureCompletion() {
        completion.configure(history: viewState.history, mode: viewState.searchMode) { await viewState.sourceApplicationsForCompletion() }
        completion.updateHistoryPosition(viewState.sourceCompletionPosition)
    }

    private var hasActiveFilters: Bool {
        viewState.hasActiveFilters
    }

    private func openOptions(expressionGuide: Bool = false) {
        showsExpressionGuide = expressionGuide
        searchFieldFocused.wrappedValue = false
        showsSearchOptions = true
    }

    @ViewBuilder
    private var searchStatusRow: some View {
        if let issue = HistorySearchCopy.issue(for: viewState, bundle: copyBundle) {
            HStack(spacing: 5) {
                if viewState.fuzzyQueryExceedsLimit {
                    searchIssueLabel(issue)
                        .accessibilityIdentifier("clipy.search.fuzzy.limit")
                    Button(HistorySearchCopy.text("Use Exact", bundle: copyBundle)) {
                        viewState.searchMode = .exact
                        searchFieldFocused.wrappedValue = true
                    }
                    .buttonStyle(.link)
                    .fixedSize()
                    .accessibilityIdentifier("clipy.search.fuzzy.use-exact")
                } else {
                    Button { openOptions(expressionGuide: true) } label: { searchIssueLabel(issue) }
                        .buttonStyle(AppMotionPressStyle())
                        .accessibilityIdentifier("clipy.search.expression.error")
                }
                if hasActiveFilters { clearFiltersButton }
            }
            .font(.caption)
        } else {
            HStack(spacing: 5) {
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        if viewState.hasWrappedSearchConditions {
                            Button { openOptions(expressionGuide: true) } label: {
                                Label(HistorySearchCopy.text("Expression", bundle: copyBundle), systemImage: "chevron.left.forwardslash.chevron.right")
                            }
                            .buttonStyle(AppMotionPressStyle()).foregroundStyle(.secondary)
                            .accessibilityIdentifier("clipy.search.expression.help")
                        }
                        if viewState.typeFilter != .all {
                            filterChip(typeFilterTitle, symbol: "line.3.horizontal.decrease", id: "type") {
                                viewState.typeFilter = .all
                            }
                        }
                        if viewState.showsPinnedOnly {
                            filterChip(PanelActionsCopy.text("Pinned Only", bundle: copyBundle), symbol: "pin.fill", id: "pinned") {
                                viewState.showsPinnedOnly = false
                            }
                        }
                        if let source = viewState.searchFilters.source {
                            filterChip(source, symbol: "app.badge", id: "source") {
                                viewState.searchFilters.sourceApplication = ""
                            }
                        }
                        if viewState.searchFilters.dateRange != .anyTime {
                            filterChip(dateFilterTitle, symbol: "calendar", id: "date") {
                                viewState.searchFilters.dateRange = .anyTime
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                if hasActiveFilters { clearFiltersButton }
            }
            .font(.caption)
        }
    }

    private func searchIssueLabel(_ issue: String) -> some View {
        let isWarning = viewState.isLoadingFirstPage || viewState.hasAuthoritativeFirstPage
        return Label(issue, systemImage: isWarning ? "exclamationmark.triangle" : "exclamationmark.circle")
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.caption)
            .foregroundStyle(isWarning ? Color.secondary : .red)
            .help(issue)
    }

    private var clearFiltersButton: some View {
        Button {
            viewState.clearFilters()
            searchFieldFocused.wrappedValue = true
        } label: { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(AppMotionPressStyle())
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("clipy.search.clear-filters")
            .accessibilityLabel(PanelChromeCopy.text("Clear filters", bundle: copyBundle))
            .accessibilityValue(filterSummary)
            .help(PanelChromeCopy.text("Clear filters", bundle: copyBundle))
    }

    private func filterChip(_ title: String, symbol: String, id: String, clear: @escaping () -> Void) -> some View {
        Button {
            clear()
            searchFieldFocused.wrappedValue = true
        } label: {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                Text(title).lineLimit(1)
                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
            }
            .padding(.horizontal, 5)
            .background(Color.accentColor.opacity(0.1), in: Capsule())
        }
        .buttonStyle(AppMotionPressStyle()).foregroundStyle(Color.accentColor)
        .accessibilityIdentifier("clipy.search.clear-filter.\(id)")
        .accessibilityLabel(HistorySearchCopy.format("Remove filter: %@", title, bundle: copyBundle))
        .help(title)
    }

    private var typeFilterTitle: String {
        switch viewState.typeFilter {
        case .all: PanelActionsCopy.text("All", bundle: copyBundle)
        case .text: PanelActionsCopy.text("Text", bundle: copyBundle)
        case .images: PanelActionsCopy.text("Images", bundle: copyBundle)
        case .links: PanelActionsCopy.text("Links", bundle: copyBundle)
        }
    }

    private var dateFilterTitle: String {
        let filters = viewState.searchFilters
        if filters.dateRange == .custom {
            let style = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)
            return filters.startDate.formatted(style) + " – " + filters.endDate.formatted(style)
        }
        return HistorySearchCopy.text(filters.dateRange.title, bundle: copyBundle)
    }

    private var filterSummary: String {
        var parts: [String] = []
        switch viewState.typeFilter {
        case .all: break
        case .text: parts.append(PanelActionsCopy.text("Text", bundle: copyBundle))
        case .images: parts.append(PanelActionsCopy.text("Images", bundle: copyBundle))
        case .links: parts.append(PanelActionsCopy.text("Links", bundle: copyBundle))
        }
        if viewState.showsPinnedOnly {
            parts.append(PanelActionsCopy.text("Pinned Only", bundle: copyBundle))
        }
        if let source = viewState.searchFilters.source { parts.append(source) }
        if viewState.searchFilters.dateRange != .anyTime { parts.append(dateFilterTitle) }
        return parts.joined(separator: " · ")
    }

    private var copyBundle: Bundle { PanelActionsCopy.bundle(for: locale) }

    // MARK: Search field

    private var searchField: some View {
        HStack(spacing: PanelTheme.spacingXSmall) {
            ZStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .opacity(viewState.isLoadingFirstPage ? 0 : 1)
                    .accessibilityHidden(true)
                if viewState.isLoadingFirstPage {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(HistorySearchCopy.text("Updating results…", bundle: copyBundle))
                        .accessibilityIdentifier("clipy.search.updating")
                        .allowsHitTesting(false)
                }
            }
            .frame(width: 16)
            HistorySearchField(
                text: searchTextBinding,
                isFocused: searchFieldFocused,
                placeholder: PanelActionsCopy.text("Search clipboard…", bundle: copyBundle),
                accessibilityLabel: PanelActionsCopy.text("Search clipboard history", bundle: copyBundle),
                onMoveSelection: onMoveSelection,
                onSubmit: {
                    if HistorySearchCopy.issue(for: viewState) == nil, viewState.searchFilters.hasValidDates() {
                        searchHistoryStore?.recordSubmittedSearch(HistorySearchDefinition(viewState: viewState))
                    }
                    onSubmitSelection()
                },
                completion: completion
            )
            .frame(minWidth: 0, maxWidth: .infinity)
            // Keep the editor's width and text position stable as the user
            // enters the first character or clears the query (V2-07 §3).
            // The empty slot has no control or accessibility element.
            ZStack {
                if !viewState.searchText.isEmpty {
                    Button {
                        viewState.clearSearch()
                        searchFieldFocused.wrappedValue = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: PanelContentFit.searchFieldHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(AppMotionPressStyle())
                    .help(PanelActionsCopy.text("Clear search", bundle: copyBundle))
                    .accessibilityIdentifier("clipy.search.clear")
                    .accessibilityLabel(PanelActionsCopy.text("Clear search", bundle: copyBundle))
                    .accessibilityHint(
                        PanelActionsCopy.text("Clears the query and keeps focus in search.", bundle: copyBundle)
                    )
                }
            }
            .frame(width: 24, height: PanelContentFit.searchFieldHeight)
        }
        .padding(.horizontal, PanelTheme.spacingSmall)
        .frame(height: PanelContentFit.searchFieldHeight)
        .background(
            .quaternary,
            in: RoundedRectangle(cornerRadius: PanelTheme.cornerRadiusMedium)
        )
        .overlay {
            RoundedRectangle(cornerRadius: PanelTheme.cornerRadiusMedium)
                .strokeBorder(searchFieldFocused.wrappedValue
                    ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            if completion.isPresented {
                HistorySearchCompletionView(completion: completion)
                    .offset(y: PanelContentFit.searchFieldHeight + 4)
            }
        }
    }

    /// Counts include traversed rows in the complete filtered query. A
    /// remaining cursor means more matching rows have not yet been counted.
    internal static func resultCountText(
        for viewState: HistoryViewState,
        locale: Locale = .current,
        bundle: Bundle = AppLocalization.bundle
    ) -> String {
        if viewState.isLoadingFirstPage {
            return HistorySearchCopy.text("Updating results…", bundle: bundle)
        }
        if !viewState.hasAuthoritativeFirstPage, HistorySearchCopy.issue(for: viewState, bundle: bundle) != nil {
            return HistorySearchCopy.text("Check search conditions", bundle: bundle)
        }
        if let failure = HistorySearchCopy.resultsFailure(for: viewState) {
            return HistorySearchCopy.resultsFailureTitle(failure, bundle: bundle)
        }
        guard viewState.hasAuthoritativeFirstPage else { return "" }
        return HistoryCountCopy.results(
            count: viewState.displayedCount,
            hasNextPage: viewState.displayedCountIsLowerBound,
            locale: locale,
            bundle: bundle
        )
    }

    // MARK: Query controls

    private var queryControls: some View {
        ScrollView(.horizontal) {
            HStack(spacing: PanelTheme.spacingXSmall) {
                modeMenu
                sortMenu
                Button { openOptions() } label: {
                    Label(HistorySearchCopy.text("Date", bundle: copyBundle), systemImage: "calendar")
                        .fixedSize()
                        .padding(.horizontal, 4)
                        .frame(height: PanelContentFit.searchControlsHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(AppMotionPressStyle())
                .foregroundStyle(viewState.searchFilters.dateRange == .anyTime ? Color.primary : .accentColor)
                .help(HistorySearchCopy.text("Date and application…", bundle: copyBundle))
                .accessibilityLabel(HistorySearchCopy.text("Date and application filters", bundle: copyBundle))
                .accessibilityValue(dateFilterTitle)
                .accessibilityIdentifier("clipy.search.date-options")
            }
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .font(.caption)
        .frame(height: PanelContentFit.searchControlsHeight)
    }

    private var modeMenu: some View {
        Menu {
            Picker(PanelActionsCopy.text("Search Mode", bundle: copyBundle), selection: searchModeBinding) {
                Text(PanelActionsCopy.text("Exact", bundle: copyBundle)).tag(SearchMode.exact)
                Text(PanelActionsCopy.text("Fuzzy", bundle: copyBundle)).tag(SearchMode.fuzzy)
                Text(PanelActionsCopy.text("Regular Expression", bundle: copyBundle)).tag(SearchMode.regexp)
            }
            .pickerStyle(.inline)
            Divider()
            Button(HistorySearchCopy.text("Insert condition / show suggestions", bundle: copyBundle)) {
                configureCompletion()
                completion.requestFromMenu()
                searchFieldFocused.wrappedValue = true
            }
            .accessibilityIdentifier("clipy.search.completion.request")
            Button(HistorySearchCopy.text("Expression guide…", bundle: copyBundle)) {
                openOptions(expressionGuide: true)
            }
        } label: {
            queryMenuLabel("Match", value: viewState.searchMode == .regexp
                ? HistorySearchCopy.text("Regex", bundle: copyBundle) : modeName(viewState.searchMode))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(PanelActionsCopy.text("Search Mode", bundle: copyBundle) + ": " + modeName(viewState.searchMode))
        .accessibilityIdentifier("clipy.search.mode")
        .accessibilityLabel(PanelActionsCopy.text("Search Mode", bundle: copyBundle))
        .accessibilityValue(modeName(viewState.searchMode))
    }

    private var sortMenu: some View {
        Menu {
            Picker(HistorySearchCopy.text("Sort results", bundle: copyBundle), selection: sortBinding) {
                ForEach([HistorySortOrder.newestFirst, .oldestFirst, .mostCopied, .automatic], id: \.self) { order in
                    Text(HistorySearchCopy.sortTitle(order, bundle: copyBundle)).tag(order)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Text(HistorySearchCopy.text("Pinned first preserves your pin order.", bundle: copyBundle))
            Text(HistorySearchCopy.text(
                viewState.searchMode == .fuzzy || viewState.searchMode == .expression
                    ? "With Pinned first, unpinned fuzzy matches are ranked by relevance."
                    : "With Pinned first, unpinned results are sorted by latest copy.",
                bundle: copyBundle
            ))
        } label: {
            queryMenuLabel("Sort", value: compactSortName)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(HistorySearchCopy.text("Sort results", bundle: copyBundle))
        .accessibilityLabel(HistorySearchCopy.text("Sort results", bundle: copyBundle))
        .accessibilityValue(HistorySearchCopy.sortTitle(viewState.sortOrder, bundle: copyBundle))
        .accessibilityIdentifier("clipy.search.sort")
    }

    private func queryMenuLabel(_ key: String, value: String) -> some View {
        HStack(spacing: 3) {
            Text(HistorySearchCopy.text(key, bundle: copyBundle)).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium)
            Image(systemName: "chevron.down").font(.caption2).accessibilityHidden(true)
        }
        .padding(.horizontal, 4)
        .frame(height: PanelContentFit.searchControlsHeight)
        .contentShape(Rectangle())
    }

    private var compactSortName: String {
        switch viewState.sortOrder {
        case .newestFirst: HistorySearchCopy.text("Newest", bundle: copyBundle)
        case .oldestFirst: HistorySearchCopy.text("Oldest", bundle: copyBundle)
        case .automatic, .mostCopied: HistorySearchCopy.sortTitle(viewState.sortOrder, bundle: copyBundle)
        }
    }

    private func modeName(_ mode: SearchMode) -> String {
        switch mode {
        case .exact: return PanelActionsCopy.text("Exact", bundle: copyBundle)
        case .fuzzy: return PanelActionsCopy.text("Fuzzy", bundle: copyBundle)
        case .regexp: return PanelActionsCopy.text("Regular Expression", bundle: copyBundle)
        case .expression: return PanelActionsCopy.text("Fuzzy", bundle: copyBundle)
        }
    }

    // MARK: Row filter menu

    /// Each type/pinned change starts a new History query so older matches
    /// remain reachable even when no current window row belongs to the family.
    private var filterMenu: some View {
        Menu {
            Picker(PanelActionsCopy.text("Filter", bundle: copyBundle), selection: typeFilterBinding) {
                Text(PanelActionsCopy.text("All", bundle: copyBundle)).tag(HistoryTypeFilter.all)
                Text(PanelActionsCopy.text("Text", bundle: copyBundle)).tag(HistoryTypeFilter.text)
                Text(PanelActionsCopy.text("Images", bundle: copyBundle)).tag(HistoryTypeFilter.images)
                Text(PanelActionsCopy.text("Links", bundle: copyBundle)).tag(HistoryTypeFilter.links)
            }
            // Four choices belong in this menu. An explicit inline style
            // avoids a second native menu-tracking handoff for each filter.
            .pickerStyle(.inline)
            Divider()
            Toggle(PanelActionsCopy.text("Pinned Only", bundle: copyBundle), isOn: pinnedOnlyBinding)
            Divider()
            Button(HistorySearchCopy.text("Date and application…", bundle: copyBundle)) { openOptions() }
            if searchHistoryStore != nil {
                Button(SearchLibraryCopy.text("Saved searches and history…", bundle: copyBundle)) {
                    searchFieldFocused.wrappedValue = false
                    showsSearchLibrary = true
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hasActiveFilters ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 24)
                .background(hasActiveFilters ? Color.accentColor.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: PanelTheme.cornerRadiusSmall))
        }
        .fixedSize()
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(hasActiveFilters ? filterSummary : PanelActionsCopy.text("Filter results", bundle: copyBundle))
        .accessibilityValue(hasActiveFilters ? filterSummary : PanelActionsCopy.text("All", bundle: copyBundle))
        .accessibilityIdentifier("clipy.search.filter")
        .accessibilityLabel(PanelActionsCopy.text("Filter results", bundle: copyBundle))
    }

    // MARK: Bindings

    private var searchTextBinding: Binding<String> {
        Binding<String>(
            get: { viewState.searchText },
            set: { viewState.searchText = $0 }
        )
    }

    private var searchModeBinding: Binding<SearchMode> {
        Binding<SearchMode>(
            get: { viewState.searchMode == .expression ? .fuzzy : viewState.searchMode },
            set: { viewState.searchMode = $0 }
        )
    }

    private var sortBinding: Binding<HistorySortOrder> {
        Binding(get: { viewState.sortOrder }, set: { viewState.sortOrder = $0 })
    }

    private var typeFilterBinding: Binding<HistoryTypeFilter> {
        Binding<HistoryTypeFilter>(
            get: { viewState.typeFilter },
            set: { viewState.typeFilter = $0 }
        )
    }

    private var pinnedOnlyBinding: Binding<Bool> {
        Binding<Bool>(
            get: { viewState.showsPinnedOnly },
            set: { viewState.showsPinnedOnly = $0 }
        )
    }

    // MARK: Hidden mode shortcuts

    /// Invisible ⌘1/⌘2/⌘3 buttons driving the mode picker (panel-level
    /// keyboard surface; the contract's sanctioned hidden-shortcut pattern).
    private var modeShortcuts: some View {
        Group {
            Button(PanelActionsCopy.text("Exact", bundle: copyBundle)) { viewState.searchMode = .exact }
                .keyboardShortcut(shortcuts.keyboardShortcut(for: .exactSearch, whileEditingText: searchFieldFocused.wrappedValue))
            Button(PanelActionsCopy.text("Fuzzy", bundle: copyBundle)) { viewState.searchMode = .fuzzy }
                .keyboardShortcut(shortcuts.keyboardShortcut(for: .fuzzySearch, whileEditingText: searchFieldFocused.wrappedValue))
            Button(PanelActionsCopy.text("Regular Expression", bundle: copyBundle)) { viewState.searchMode = .regexp }
                .keyboardShortcut(shortcuts.keyboardShortcut(for: .regexpSearch, whileEditingText: searchFieldFocused.wrappedValue))
        }
        .disabled(!areShortcutsEnabled)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

#Preview {
    SearchHeaderViewPreview()
}

private struct SearchHeaderViewPreview: View {
    @State private var viewState = HistoryViewState(
        history: PreviewClipboardHistory.populated
    )
    @State private var searchFieldFocused = false

    var body: some View {
        SearchHeaderView(
            viewState: viewState,
            searchFieldFocused: $searchFieldFocused
        )
        .padding()
        .frame(width: 400)
    }
}
