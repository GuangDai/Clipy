import Foundation
import SwiftUI

/// The master opt-in, recent-submission policy and exclusions use the same
/// preference owner as both search surfaces. Rules apply before any write.
struct SearchHistorySettingsSection: View {
    @Environment(\.locale) private var locale
    let store: SearchHistoryStore
    @State private var excludedKeyword = ""
    @State private var showsExclusions = false
    @State private var confirmsDisable = false
    @State private var confirmsClearAll = false
    @State private var confirmsClearRecent = false
    @State private var feedback: SettingStatus?

    private var copyBundle: Bundle { PanelActionsCopy.bundle(for: locale) }
    private func text(_ key: String) -> String { SearchLibraryCopy.text(key, bundle: copyBundle) }
    private var hasSavedSearches: Bool { !store.favorites.isEmpty || !store.recentSearches.isEmpty }

    var body: some View {
        Group {
            Section {
                Toggle(text("Enable search saving"), isOn: Binding(
                    get: { store.preferences.isEnabled },
                    set: { isEnabled in
                        if !isEnabled, hasSavedSearches {
                            confirmsDisable = true
                        } else {
                            store.setEnabled(isEnabled)
                            feedback = nil
                        }
                    }
                ))
                .accessibilityIdentifier("clipy.settings.search-saving.enabled")
                if store.preferences.isEnabled {
                    Label(SearchLibraryCopy.count("%lld favorites", store.favorites.count, bundle: copyBundle),
                          systemImage: "star")
                    Text(text("Favorites are saved only when you choose Save favorite in the search menu."))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup(text("Excluded keywords"), isExpanded: $showsExclusions) {
                    excludedKeywordControls.padding(.top, 6)
                }
                .accessibilityIdentifier("clipy.settings.search-saving.exclusions")
                if let failure = store.failure {
                    SettingStatusView(status: .failure(SearchLibraryCopy.failure(failure, bundle: copyBundle)))
                        .accessibilityIdentifier("clipy.settings.search-saving.feedback")
                } else if let feedback {
                    SettingStatusView(status: feedback)
                        .accessibilityIdentifier("clipy.settings.search-saving.feedback")
                }
                Button(text("Clear all saved searches…"), role: .destructive) { confirmsClearAll = true }
                    .disabled(!hasSavedSearches && store.failure == nil)
                    .accessibilityIdentifier("clipy.settings.search-saving.clear-all")
            } header: {
                Text(text("Saved searches"))
            } footer: {
                Text(text("Off by default. Saves query text, filters and sort order in preferences; search results are never saved. Turning this off removes all favorites and recent searches."))
            }

            if store.preferences.isEnabled {
                Section {
                    Toggle(text("Keep recent submitted searches"), isOn: Binding(
                        get: { store.preferences.recordsRecentSearches },
                        set: { enabled in
                            store.updatePreferences { $0.recordsRecentSearches = enabled }
                            feedback = nil
                        }
                    ))
                    .accessibilityIdentifier("clipy.settings.search-saving.record-recent")
                    if store.preferences.recordsRecentSearches {
                        Stepper(value: Binding(
                            get: { store.preferences.maximumRecentSearches },
                            set: { value in store.updatePreferences { $0.maximumRecentSearches = value } }
                        ), in: SearchHistoryPreferences.recentCountRange) {
                            Text(SearchLibraryCopy.count("Keep up to %lld searches", store.preferences.maximumRecentSearches, bundle: copyBundle))
                        }
                        .accessibilityIdentifier("clipy.settings.search-saving.limit")
                    }
                    Button(text("Clear recent searches…"), role: .destructive) { confirmsClearRecent = true }
                        .disabled(store.recentSearches.isEmpty)
                        .accessibilityIdentifier("clipy.settings.search-saving.clear-recent")
                } header: {
                    Text(text("Automatic search history"))
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(text("This is separate from favorites. Only submitted searches are kept; unfinished typing is not saved. Lowering the limit removes the oldest recent entries."))
                        Text(text("Turning off automatic history clears recent searches and keeps favorites."))
                    }
                }
            }
        }
        .onAppear { store.reload() }
        .confirmationDialog(text("Turn off search saving?"), isPresented: $confirmsDisable) {
            Button(text("Turn off and clear saved searches"), role: .destructive) {
                store.setEnabled(false)
                feedback = store.failure == nil ? .success(text("Search saving is off. Saved searches have been cleared.")) : nil
            }
            Button(text("Cancel"), role: .cancel) {}
        } message: {
            Text(text("This removes favorites and recent search conditions. Clipboard history is unchanged."))
        }
        .confirmationDialog(text("Clear all saved searches?"), isPresented: $confirmsClearAll) {
            Button(text("Clear all saved searches"), role: .destructive) {
                store.clearAllSearches()
                feedback = store.failure == nil ? .success(text("Saved searches cleared.")) : nil
            }
            Button(text("Cancel"), role: .cancel) {}
        } message: {
            Text(text("This removes favorites and recent search conditions. Clipboard history is unchanged."))
        }
        .confirmationDialog(text("Clear recent searches?"), isPresented: $confirmsClearRecent) {
            Button(text("Clear recent searches"), role: .destructive) {
                store.clearRecentSearches()
                feedback = store.failure == nil ? .success(text("Recent searches cleared.")) : nil
            }
            Button(text("Cancel"), role: .cancel) {}
        } message: {
            Text(text("Favorites and clipboard history will remain unchanged."))
        }
    }

    private var excludedKeywordControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text("A matching query, source or favorite name is not saved. Matching ignores letter case. New rules also remove matching favorites and recent searches already saved."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField(text("Keyword to exclude"), text: $excludedKeyword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addExcludedKeyword)
                    .accessibilityIdentifier("clipy.settings.search-saving.keyword")
                Button(text("Add"), action: addExcludedKeyword)
                    .disabled(excludedKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("clipy.settings.search-saving.add-keyword")
            }
            ForEach(store.preferences.excludedKeywords, id: \.self) { keyword in
                HStack {
                    Text(keyword).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        store.updatePreferences { $0.excludedKeywords.removeAll { $0 == keyword } }
                        feedback = nil
                    } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(text("Remove exclusion"))
                }
            }
            if store.preferences.excludedKeywords.isEmpty {
                Text(text("No exclusion rules.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func addExcludedKeyword() {
        let keyword = excludedKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        store.updatePreferences { $0.excludedKeywords.append(keyword) }
        guard store.failure == nil else { return }
        excludedKeyword = ""
        feedback = .success(text("Exclusion rules applied. Matching saved searches have been removed."))
    }
}
