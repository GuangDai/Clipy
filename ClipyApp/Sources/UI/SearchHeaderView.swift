/// SearchHeaderView.swift — the panel's query surface: the rounded search
/// field, the three-mode search picker (⌘1/⌘2/⌘3), the history-wide row
/// filter menu, and directly removable active filters.
/// Owning spec: docs/01-architecture.md §5.4 (browse/search flow);
/// docs/03a-instruction-set.md §7 (search modes);
/// docs/06-cross-cutting.md §2 (fuzzy 64-Character query bound);
/// accessibility per docs/v2/V2-07-ux.md §9.
import Foundation
import HistoryCore
import SwiftUI

/// The header above the history list. Edits funnel through
/// `HistoryViewState.searchText`, which restarts observation. The stable search row
/// keeps secondary options in compact menus; the panel's focus binding keeps bare-key
/// shortcuts away from the text field (01 §6: selection and keyboard behavior
/// are main-actor UI concerns).
///
/// The field always preserves the user's raw draft. `HistoryViewState` owns
/// mode-specific admission, including fuzzy's 64-character execution view,
/// so switching modes never truncates clipboard syntax typed by the user.
struct SearchHeaderView: View {
    @Environment(\.locale) private var locale

    private let viewState: HistoryViewState
    private let searchFieldFocused: FocusState<Bool>.Binding
    private let onMoveSelection: (Int) -> Void
    private let onSubmitSelection: () -> Void

    init(
        viewState: HistoryViewState,
        searchFieldFocused: FocusState<Bool>.Binding,
        onMoveSelection: @escaping (Int) -> Void = { _ in },
        onSubmitSelection: @escaping () -> Void = {}
    ) {
        self.viewState = viewState
        self.searchFieldFocused = searchFieldFocused
        self.onMoveSelection = onMoveSelection
        self.onSubmitSelection = onSubmitSelection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.spacingXSmall) {
            HStack(spacing: PanelTheme.spacingXSmall) {
                searchField
                    .frame(maxWidth: .infinity)
                modeMenu
                    .frame(width: 24, height: 24)
                filterMenu
                    .frame(width: 24, height: 24)
            }
            if hasActiveFilters {
                Button {
                    viewState.typeFilter = .all
                    viewState.showsPinnedOnly = false
                    searchFieldFocused.wrappedValue = true
                } label: {
                    HStack(spacing: 5) {
                        switch viewState.typeFilter {
                        case .all: EmptyView()
                        case .text: Image(systemName: "text.alignleft")
                        case .images: Image(systemName: "photo")
                        case .links: Image(systemName: "link")
                        }
                        if viewState.showsPinnedOnly {
                            Image(systemName: "pin.fill")
                        }
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                    }
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .background(Color.accentColor.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.borderless)
                .tint(.accentColor)
                .accessibilityIdentifier("clipy.search.clear-filters")
                .accessibilityLabel(PanelChromeCopy.text("Clear filters", bundle: copyBundle))
                .accessibilityValue(filterSummary)
                .help(filterSummary + " · " + PanelChromeCopy.text("Clear filters", bundle: copyBundle))
            }
        }
        .background { modeShortcuts }
    }

    private var hasActiveFilters: Bool {
        viewState.typeFilter != .all || viewState.showsPinnedOnly
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
        return parts.joined(separator: " · ")
    }

    private var copyBundle: Bundle { PanelActionsCopy.bundle(for: locale) }

    // MARK: Search field

    private var searchField: some View {
        HStack(spacing: PanelTheme.spacingXSmall) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(PanelActionsCopy.text("Search clipboard…", bundle: copyBundle), text: searchTextBinding)
                .textFieldStyle(.plain)
                .focused(searchFieldFocused)
                .autocorrectionDisabled(true)
                .accessibilityIdentifier("clipy.search.field")
                .accessibilityLabel(PanelActionsCopy.text("Search clipboard history", bundle: copyBundle))
                .onSubmit(onSubmitSelection)
                .onKeyPress(.downArrow) {
                    onMoveSelection(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    onMoveSelection(-1)
                    return .handled
                }
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
                    .buttonStyle(.plain)
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
    }

    /// Counts include traversed rows in the complete filtered query. A
    /// remaining cursor means older matching rows have not yet been counted.
    internal static func resultCountText(
        for viewState: HistoryViewState,
        locale: Locale = .current,
        bundle: Bundle = .main
    ) -> String {
        HistoryCountCopy.results(
            count: viewState.displayedCount,
            hasNextPage: viewState.displayedCountIsLowerBound,
            locale: locale,
            bundle: bundle
        )
    }

    // MARK: Mode picker

    private var modeMenu: some View {
        Menu {
            Picker(PanelActionsCopy.text("Search Mode", bundle: copyBundle), selection: searchModeBinding) {
                Text(PanelActionsCopy.text("Exact", bundle: copyBundle)).tag(SearchMode.exact)
                Text(PanelActionsCopy.text("Fuzzy", bundle: copyBundle)).tag(SearchMode.fuzzy)
                Text(PanelActionsCopy.text("Regular Expression", bundle: copyBundle)).tag(SearchMode.regexp)
            }
            .pickerStyle(.inline)
        } label: {
            Group {
                switch viewState.searchMode {
                case .exact: Image(systemName: "equal")
                case .fuzzy: Image(systemName: "text.magnifyingglass")
                case .regexp: Text(".*").font(.system(.body, design: .monospaced).weight(.semibold))
                }
            }
            .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .foregroundStyle(viewState.searchMode == .fuzzy ? Color.secondary : Color.accentColor)
        .fixedSize()
        .help(PanelActionsCopy.text("Search Mode", bundle: copyBundle) + ": " + modeName(viewState.searchMode))
        .accessibilityIdentifier("clipy.search.mode")
        .accessibilityLabel(PanelActionsCopy.text("Search Mode", bundle: copyBundle))
        .accessibilityValue(modeName(viewState.searchMode))
    }

    private func modeName(_ mode: SearchMode) -> String {
        switch mode {
        case .exact: return PanelActionsCopy.text("Exact", bundle: copyBundle)
        case .fuzzy: return PanelActionsCopy.text("Fuzzy", bundle: copyBundle)
        case .regexp: return PanelActionsCopy.text("Regular Expression", bundle: copyBundle)
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
            get: { viewState.searchMode },
            set: { viewState.searchMode = $0 }
        )
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
                .keyboardShortcut("1", modifiers: .command)
            Button(PanelActionsCopy.text("Fuzzy", bundle: copyBundle)) { viewState.searchMode = .fuzzy }
                .keyboardShortcut("2", modifiers: .command)
            Button(PanelActionsCopy.text("Regular Expression", bundle: copyBundle)) { viewState.searchMode = .regexp }
                .keyboardShortcut("3", modifiers: .command)
        }
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
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        SearchHeaderView(
            viewState: viewState,
            searchFieldFocused: $searchFieldFocused
        )
        .padding()
        .frame(width: 400)
    }
}
