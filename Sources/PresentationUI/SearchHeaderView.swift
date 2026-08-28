/// SearchHeaderView.swift — the panel's query surface: the rounded search
/// field, the three-mode search picker (⌘1/⌘2/⌘3), the client-side row
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

    // MARK: Search field

    private var searchField: some View {
        HStack(spacing: PanelTheme.spacingXSmall) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search clipboard…", text: searchTextBinding)
                .textFieldStyle(.plain)
                .focused(searchFieldFocused)
                .autocorrectionDisabled(true)
                .accessibilityIdentifier("clipy.search.field")
                .accessibilityLabel("Search clipboard history")
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
                    Text("Clear")
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityIdentifier("clipy.search.clear")
                .accessibilityLabel("Clear search")
                .accessibilityHint(
                    "Clears the query and keeps focus in search."
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
                count: viewState.rows.count,
                hasNextPage: viewState.hasNextPage,
                locale: locale
            )
        )
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// A page cursor makes `count` a lower bound, not a total (Card 8C).
    /// The exact-count key varies by plural in PresentationUI's resources;
    /// the cursor key stays explicitly plural because even `1+` is not one.
    package static func resultCountText(
        count: Int,
        hasNextPage: Bool,
        locale: Locale = .current
    ) -> String {
        if hasNextPage {
            return String(
                localized: "\(count)+ results",
                bundle: .module,
                locale: locale,
                comment: "A lower-bound search result count; more results are available."
            )
        }
        return String(
            localized: "\(count) results",
            bundle: .module,
            locale: locale,
            comment: "The exact number of search results."
        )
    }

    // MARK: Mode picker

    private var modeMenu: some View {
        Menu {
            Picker("Search Mode", selection: searchModeBinding) {
                Text("Exact").tag(SearchMode.exact)
                Text("Fuzzy").tag(SearchMode.fuzzy)
                Text("Regular Expression").tag(SearchMode.regexp)
            }
        } label: {
            Label(
                Self.modeName(viewState.searchMode),
                systemImage: "text.magnifyingglass"
            )
        }
        .fixedSize()
        .accessibilityLabel("Search Mode")
        .accessibilityValue(Self.modeName(viewState.searchMode))
    }

    private static func modeName(_ mode: SearchMode) -> String {
        switch mode {
        case .exact: return "Exact"
        case .fuzzy: return "Fuzzy"
        case .regexp: return "Regular Expression"
        }
    }

    // MARK: Row filter menu

    /// The client-side type/pinned filter over the already-loaded rows. It
    /// narrows what the list renders in memory only — a change never
    /// restarts the History query (see `HistoryViewState.typeFilter`).
    private var filterMenu: some View {
        Menu {
            Picker("Filter", selection: typeFilterBinding) {
                Text("All").tag(HistoryTypeFilter.all)
                Text("Text").tag(HistoryTypeFilter.text)
                Text("Images").tag(HistoryTypeFilter.images)
                Text("Links").tag(HistoryTypeFilter.links)
            }
            Divider()
            Toggle("Pinned Only", isOn: pinnedOnlyBinding)
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .fixedSize()
        .accessibilityIdentifier("clipy.search.filter")
        .accessibilityLabel("Filter results")
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
            Button("Exact") { viewState.searchMode = .exact }
                .keyboardShortcut("1", modifiers: .command)
            Button("Fuzzy") { viewState.searchMode = .fuzzy }
                .keyboardShortcut("2", modifiers: .command)
            Button("Regular Expression") { viewState.searchMode = .regexp }
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
