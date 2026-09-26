import Foundation
import SwiftUI

/// Favorites are explicit reusable conditions. Recent searches are a separate,
/// opt-in record of submissions. Neither collection contains result content.
struct SearchLibraryView: View {
    private enum Group: String, CaseIterable { case favorites, recent }

    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openSearchSavingSettings) private var openSearchSavingSettings
    @AppStorage("clipy.settings.selectedCategory") private var settingsCategory = "general"
    @State private var group: Group = .favorites
    @State private var favoriteName = ""
    @State private var renaming: SavedHistorySearch?
    @State private var renameText = ""
    @State private var showsRename = false
    @State private var confirmsClearRecent = false

    let viewState: HistoryViewState
    let store: SearchHistoryStore
    var onApply: () -> Void = {}

    private var copyBundle: Bundle { PanelActionsCopy.bundle(for: locale) }
    private func text(_ key: String) -> String { SearchLibraryCopy.text(key, bundle: copyBundle) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(text("Saved searches and history")).font(.headline)
                Spacer()
                Button(text("Done")) { dismiss() }
                    .accessibilityIdentifier("clipy.search.library.done")
            }
            Text(text("Only search conditions are saved, never matching clipboard content."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !store.preferences.isEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text(text("Search saving is off by default."))
                        .font(.callout).foregroundStyle(.secondary)
                    Button(text("Enable search saving")) {
                        store.setEnabled(true)
                    }
                    .accessibilityIdentifier("clipy.search.library.enable")
                }
            } else {
                saveCurrentSearch
            }
            Picker(text("Saved search category"), selection: $group) {
                Text(text("Favorites")).tag(Group.favorites)
                Text(text("Recent searches")).tag(Group.recent)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("clipy.search.library.category")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if group == .favorites { favorites } else { recentSearches }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            if let failure = store.failure {
                SettingStatusView(status: .failure(SearchLibraryCopy.failure(failure, bundle: copyBundle)))
                    .accessibilityIdentifier("clipy.search.library.feedback")
            } else if let result = store.lastWriteResult {
                SettingStatusView(status: SearchLibraryCopy.feedback(result, bundle: copyBundle))
                    .accessibilityIdentifier("clipy.search.library.feedback")
            }
            Divider()
            Button {
                settingsCategory = "interaction"
                dismiss()
                if let openSearchSavingSettings { openSearchSavingSettings() }
                else { openSettings() }
            } label: {
                Label(text("Search-saving settings…"), systemImage: "gearshape")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityIdentifier("clipy.search.library.settings")
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { store.reload() }
        .alert(text("Rename favorite"), isPresented: $showsRename) {
            TextField(text("Favorite name"), text: $renameText)
            Button(text("Cancel"), role: .cancel) { renaming = nil }
            Button(text("Save")) {
                if let renaming { store.renameFavorite(renaming.id, name: renameText) }
                renaming = nil
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog(text("Clear recent searches?"), isPresented: $confirmsClearRecent) {
            Button(text("Clear recent searches"), role: .destructive) { store.clearRecentSearches() }
            Button(text("Cancel"), role: .cancel) {}
        } message: {
            Text(text("Favorites and clipboard history will remain unchanged."))
        }
        .accessibilityIdentifier("clipy.search.library")
    }

    private var saveCurrentSearch: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text("Save current conditions")).font(.subheadline.weight(.semibold))
            Text(viewState.searchText.isEmpty ? text("Filters only") : viewState.searchText)
                .lineLimit(2).font(.callout).textSelection(.enabled)
            if let issue = HistorySearchCopy.issue(for: viewState, bundle: copyBundle) {
                SettingStatusView(status: .failure(issue))
            }
            HStack {
                TextField(text("Favorite name (optional)"), text: $favoriteName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("clipy.search.library.favorite-name")
                Button {
                    let result = store.saveFavorite(HistorySearchDefinition(viewState: viewState), name: favoriteName)
                    if result == .saved {
                        favoriteName = ""
                        group = .favorites
                    }
                } label: {
                    Label(text("Save favorite"), systemImage: "star")
                }
                .disabled(HistorySearchCopy.issue(for: viewState) != nil || viewState.sourceResolutionError != nil)
                .accessibilityIdentifier("clipy.search.library.save-favorite")
            }
        }
    }

    private var favorites: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(SearchLibraryCopy.count("%lld favorites", store.favorites.count, bundle: copyBundle))
                .font(.caption).foregroundStyle(.secondary)
            if store.favorites.isEmpty {
                emptyState("No favorites yet", detail: "Save a useful query and its filters to run it again.")
            }
            ForEach(store.favorites) { item in savedRow(item, isFavorite: true) }
        }
    }

    private var recentSearches: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(text("Keep recent submitted searches"), isOn: Binding(
                get: { store.preferences.recordsRecentSearches },
                set: { value in store.updatePreferences { $0.recordsRecentSearches = value } }
            ))
            .disabled(!store.preferences.isEnabled)
            .accessibilityIdentifier("clipy.search.library.record-recent")
            Text(text("Only submitted searches are kept. Typing alone is never saved."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(text("Turning off automatic history clears recent searches and keeps favorites."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if store.recentSearches.isEmpty {
                emptyState("No recent searches", detail: "Enable automatic history, then submit a query to keep it here.")
            } else {
                HStack {
                    Text(SearchLibraryCopy.count("%lld recent searches", store.recentSearches.count, bundle: copyBundle))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(text("Clear"), role: .destructive) { confirmsClearRecent = true }
                        .accessibilityIdentifier("clipy.search.library.clear-recent")
                }
            }
            ForEach(store.recentSearches) { item in savedRow(item, isFavorite: false) }
        }
    }

    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text(title)).font(.subheadline.weight(.medium))
            Text(text(detail)).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
    }

    private func savedRow(_ item: SavedHistorySearch, isFavorite: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                item.definition.apply(to: viewState)
                store.recordSubmittedSearch(item.definition)
                onApply()
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name.isEmpty
                        ? (item.definition.query.isEmpty ? text("Filters only") : item.definition.query)
                        : item.name)
                        .font(.body.weight(isFavorite ? .medium : .regular)).lineLimit(2)
                    if !item.name.isEmpty, !item.definition.query.isEmpty, item.name != item.definition.query {
                        Text(item.definition.query).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                    }
                    Text(SearchLibraryCopy.summary(item.definition, locale: locale, bundle: copyBundle))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .help(SearchLibraryCopy.summary(item.definition, locale: locale, bundle: copyBundle))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("clipy.search.library.apply.\(item.id.uuidString)")
            .accessibilityHint(text("Applies the saved query, filters and sort order."))
            Menu {
                if isFavorite {
                    Button(text("Rename…")) {
                        renaming = item
                        renameText = item.name
                        showsRename = true
                    }
                    Button(text("Remove favorite"), role: .destructive) { store.removeFavorite(item.id) }
                } else {
                    Button(text("Save as favorite")) { store.saveFavorite(item.definition, name: item.name) }
                    Button(text("Remove from recent searches"), role: .destructive) { store.removeRecent(item.id) }
                }
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(text(isFavorite ? "Manage favorite" : "Manage recent search"))
                .accessibilityIdentifier("clipy.search.library.manage.\(item.id.uuidString)")
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
