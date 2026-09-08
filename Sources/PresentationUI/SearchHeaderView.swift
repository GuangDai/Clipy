/// SearchHeaderView.swift — the panel's query surface: the rounded search
/// field, the three-mode search picker (⌘1/⌘2/⌘3), the history-wide row
/// filter menu, and the active-search result-count caption.
/// Owning spec: docs/01-architecture.md §5.4 (browse/search flow);
/// docs/03a-instruction-set.md §7 (search modes);
/// docs/06-cross-cutting.md §2 (fuzzy 64-Character query bound);
/// accessibility per docs/v2/V2-07-ux.md §9.
import Foundation
import HistoryCore
import SwiftUI

/// The header above the history list. Edits funnel through
/// `HistoryViewState.searchText`, which restarts observation; the header adds
/// no state of its own beyond the focus binding the panel uses to keep the
/// bare-key shortcuts away from the text field (01 §6: selection and keyboard
/// behavior are main-actor UI concerns).
///
/// The field always preserves the user's raw draft. `HistoryViewState` owns
/// mode-specific admission, including fuzzy's 64-character execution view,
/// so switching modes never truncates clipboard syntax typed by the user.
package struct SearchHeaderView: View {
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

    package var body: some View {
        HStack(spacing: PanelTheme.spacingSmall) {
            searchField
            if viewState.isSearchActive {
                resultCountCaption
            }
            modeMenu
            filterMenu
        }
        .background { modeShortcuts }
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
            if !viewState.searchText.isEmpty {
                Button {
                    viewState.clearSearch()
                    searchFieldFocused.wrappedValue = true
                } label: {
                    Text(PanelActionsCopy.text("Clear", bundle: copyBundle))
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityIdentifier("clipy.search.clear")
                .accessibilityLabel(PanelActionsCopy.text("Clear search", bundle: copyBundle))
                .accessibilityHint(
                    PanelActionsCopy.text("Clears the query and keeps focus in search.", bundle: copyBundle)
                )
            }
        }
        .padding(.horizontal, PanelTheme.spacingSmall)
        .padding(.vertical, PanelTheme.spacingXSmall)
        .background(
            .quaternary,
            in: RoundedRectangle(cornerRadius: PanelTheme.cornerRadiusMedium)
        )
    }

    /// The count caption shown while a search term is present (03b §8: an
    /// empty term is equivalent to `.recent` and carries no search results).
    private var resultCountCaption: some View {
        Text(
            Self.resultCountText(
                for: viewState,
                locale: locale,
                bundle: copyBundle
            )
        )
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// Counts include traversed rows in the complete filtered query. A
    /// remaining cursor means older matching rows have not yet been counted.
    internal static func resultCountText(
        for viewState: HistoryViewState,
        locale: Locale = .current,
        bundle: Bundle = .module
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
        } label: {
            Label(
                modeName(viewState.searchMode),
                systemImage: "text.magnifyingglass"
            )
        }
        .fixedSize()
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
            Divider()
            Toggle(PanelActionsCopy.text("Pinned Only", bundle: copyBundle), isOn: pinnedOnlyBinding)
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .fixedSize()
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
