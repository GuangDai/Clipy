/// SearchHeaderView.swift — the panel's query surface: the rounded search
/// field, the three-mode search picker (⌘1/⌘2/⌘3), and the active-search
/// result-count caption.
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
/// The fuzzy-mode clamp (06 §2 `maximumFuzzyQueryCharacters`) is enforced in
/// the field's binding — and again on a mode switch — because Fuse 1.4.0's
/// bitap cannot represent a longer pattern: storage rejects an over-bound
/// query as `invalidInput(.invalidSearchTerm)` (03b §8), so the field never
/// lets one be typed in fuzzy mode.
public struct SearchHeaderView: View {
    private let viewState: HistoryViewState
    private let searchFieldFocused: FocusState<Bool>.Binding

    public init(
        viewState: HistoryViewState,
        searchFieldFocused: FocusState<Bool>.Binding
    ) {
        self.viewState = viewState
        self.searchFieldFocused = searchFieldFocused
    }

    public var body: some View {
        HStack(spacing: 8) {
            searchField
            if viewState.isSearchActive {
                resultCountCaption
            }
            modeMenu
        }
        .background { modeShortcuts }
        .onChange(of: viewState.searchMode) { _, _ in
            clampForFuzzyMode()
        }
    }

    // MARK: Search field

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search clipboard…", text: clampedSearchText)
                .textFieldStyle(.plain)
                .focused(searchFieldFocused)
                .accessibilityLabel("Search clipboard history")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    /// The count caption shown while a search term is present (03b §8: an
    /// empty term is equivalent to `.recent` and carries no search results).
    private var resultCountCaption: some View {
        let count = viewState.rows.count
        return Text(count == 1 ? "1 result" : "\(count) results")
            .font(.caption)
            .foregroundStyle(.secondary)
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

    // MARK: Bindings

    private var clampedSearchText: Binding<String> {
        let fuzzyLimit = HistoryLimits.standard.maximumFuzzyQueryCharacters
        return Binding<String>(
            get: { viewState.searchText },
            set: { newValue in
                if viewState.searchMode == .fuzzy, newValue.count > fuzzyLimit {
                    viewState.searchText = String(newValue.prefix(fuzzyLimit))
                } else {
                    viewState.searchText = newValue
                }
            }
        )
    }

    private var searchModeBinding: Binding<SearchMode> {
        Binding<SearchMode>(
            get: { viewState.searchMode },
            set: { viewState.searchMode = $0 }
        )
    }

    /// Re-clamps already-typed text when the mode switches to fuzzy, so a
    /// long exact/regexp term cannot survive into a mode that cannot
    /// represent it (06 §2; 03b §8).
    private func clampForFuzzyMode() {
        let fuzzyLimit = HistoryLimits.standard.maximumFuzzyQueryCharacters
        guard viewState.searchMode == .fuzzy,
              viewState.searchText.count > fuzzyLimit
        else { return }
        viewState.searchText = String(viewState.searchText.prefix(fuzzyLimit))
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
