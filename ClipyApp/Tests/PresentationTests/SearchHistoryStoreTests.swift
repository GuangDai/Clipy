import Foundation
import HistoryCore
@testable import ClipyApp
import Testing

/// Search saving is opt-in and persists complete search intent. Tests use
/// isolated real UserDefaults suites, including competing settings instances.
@MainActor
struct SearchHistoryStoreTests {
    @Test func newStoreDoesNotRecordQueriesUntilExplicitlyEnabled() throws {
        try withStore { store, defaults in
            #expect(!store.preferences.isEnabled)
            #expect(!store.preferences.recordsRecentSearches)
            #expect(store.preferences.maximumRecentSearches == 20)
            #expect(store.preferences.excludedKeywords.isEmpty)
            #expect(store.saveFavorite(.init(query: "private query")) == .disabled)
            #expect(store.recordSubmittedSearch(.init(query: "private query")) == .disabled)
            #expect(store.lastWriteResult == .disabled)
            #expect(store.favorites.isEmpty)
            #expect(store.recentSearches.isEmpty)

            let reopened = SearchHistoryStore(defaults: defaults)
            #expect(!reopened.preferences.isEnabled)
            #expect(reopened.favorites.isEmpty)
            #expect(reopened.recentSearches.isEmpty)
            #expect(reopened.failure == nil)
        }
    }

    @Test func favoritesAndRecentRecordingHaveSeparateOptIns() throws {
        try withStore { store, defaults in
            store.updatePreferences { $0.isEnabled = true }
            let definition = HistorySearchDefinition(query: "quarterly report", mode: .exact)
            #expect(store.saveFavorite(definition, name: "Reports") == .saved)
            #expect(store.recordSubmittedSearch(definition) == .recentSearchesDisabled)
            #expect(store.recentSearches.isEmpty)

            store.updatePreferences { $0.recordsRecentSearches = true }
            #expect(store.recordSubmittedSearch(definition) == .saved)
            #expect(store.lastWriteResult == .saved)
            #expect(store.failure == nil)
            let reopened = SearchHistoryStore(defaults: defaults)
            #expect(reopened.preferences.isEnabled)
            #expect(reopened.preferences.recordsRecentSearches)
            #expect(reopened.favorites.map(\.definition) == [definition])
            #expect(reopened.recentSearches.map(\.definition) == [definition])
        }
    }

    @Test func disablingAllSavingDeletesBothListsAndStaleInstancesCannotRestoreThem() throws {
        try withStore { store, defaults in
            enableAll(store)
            #expect(store.saveFavorite(.init(query: "saved before disabling")) == .saved)
            #expect(store.recordSubmittedSearch(.init(query: "recent before disabling")) == .saved)
            let stale = SearchHistoryStore(defaults: defaults)

            store.setEnabled(false)
            #expect(store.favorites.isEmpty)
            #expect(store.recentSearches.isEmpty)
            #expect(!store.preferences.recordsRecentSearches)
            #expect(stale.saveFavorite(.init(query: "stale favorite")) == .disabled)
            #expect(stale.recordSubmittedSearch(.init(query: "stale recent")) == .disabled)
            // A separate preference edit must not write the stale enabled
            // snapshot or its old searches back into the shared defaults.
            stale.updatePreferences { $0.maximumRecentSearches = 7 }

            let reopened = SearchHistoryStore(defaults: defaults)
            #expect(!reopened.preferences.isEnabled)
            #expect(!reopened.preferences.recordsRecentSearches)
            #expect(reopened.preferences.maximumRecentSearches == 7)
            #expect(reopened.favorites.isEmpty)
            #expect(reopened.recentSearches.isEmpty)
        }
    }

    @Test func disablingRecentSearchesKeepsFavoritesAndRejectsStaleRecording() throws {
        try withStore { store, defaults in
            enableAll(store)
            let favorite = HistorySearchDefinition(query: "deliberate favorite")
            #expect(store.saveFavorite(favorite) == .saved)
            #expect(store.recordSubmittedSearch(.init(query: "old recent")) == .saved)
            let stale = SearchHistoryStore(defaults: defaults)

            store.updatePreferences { $0.recordsRecentSearches = false }
            #expect(store.preferences.isEnabled)
            #expect(store.favorites.map(\.definition) == [favorite])
            #expect(store.recentSearches.isEmpty)
            #expect(stale.recordSubmittedSearch(.init(query: "late submission")) == .recentSearchesDisabled)
            #expect(stale.saveFavorite(.init(query: "another favorite")) == .saved)

            let reopened = SearchHistoryStore(defaults: defaults)
            #expect(reopened.favorites.count == 2)
            #expect(!reopened.preferences.recordsRecentSearches)
            #expect(reopened.recentSearches.isEmpty)
        }
    }

    @Test func reopeningRestoresEveryConditionAndItsExactUTF8Spelling() throws {
        try withStore { store, defaults in
            enableAll(store)
            var filters = HistorySearchFilters()
            filters.sourceApplication = "com.example.e\u{301}ditor"
            filters.sourceMatch = .bundleIdentifier
            filters.dateRange = .custom
            filters.startDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
            filters.endDate = Date(timeIntervalSinceReferenceDate: 800_259_200)
            let definition = HistorySearchDefinition(
                query: "^工程-[0-9]+ e\u{301}$", mode: .regexp,
                typeFilter: .text, pinnedOnly: true, filters: filters, sortOrder: .mostCopied
            )
            #expect(store.saveFavorite(definition, name: "报告") == .saved)
            #expect(store.recordSubmittedSearch(definition) == .saved)
            let saved = try #require(store.favorites.first)
            let recent = try #require(store.recentSearches.first)

            let reopened = SearchHistoryStore(defaults: defaults)
            let restored = try #require(reopened.favorites.first)
            #expect(restored.id == saved.id)
            #expect(restored.name == "报告")
            #expect(restored.savedAt == saved.savedAt)
            #expect(restored.definition == definition)
            #expect(Data(restored.definition.query.utf8) == Data(definition.query.utf8))
            #expect(Data(restored.definition.filters.sourceApplication.utf8)
                    == Data(filters.sourceApplication.utf8))
            #expect(reopened.recentSearches.first?.id == recent.id)
            #expect(reopened.recentSearches.first?.savedAt == recent.savedAt)
            #expect(reopened.recentSearches.first?.definition == definition)
            #expect(reopened.failure == nil)
        }
    }

    @Test(arguments: [SearchMode.fuzzy, .exact, .regexp, .expression])
    func everyMatchingModeSurvivesReopening(mode: SearchMode) throws {
        try withStore { store, defaults in
            store.updatePreferences { $0.isEnabled = true }
            #expect(store.saveFavorite(.init(query: "report", mode: mode)) == .saved)
            #expect(SearchHistoryStore(defaults: defaults).favorites.first?.definition.mode == mode)
        }
    }

    @Test func relativeDatesStayRelativeAndIgnoreUnusedCustomDateValues() throws {
        try withStore { store, defaults in
            enableAll(store)
            var firstFilters = HistorySearchFilters()
            firstFilters.dateRange = .lastSevenDays
            firstFilters.startDate = Date(timeIntervalSinceReferenceDate: 10)
            firstFilters.endDate = Date(timeIntervalSinceReferenceDate: 20)
            var secondFilters = firstFilters
            secondFilters.startDate = Date(timeIntervalSinceReferenceDate: 100)
            secondFilters.endDate = Date(timeIntervalSinceReferenceDate: 200)
            let first = HistorySearchDefinition(filters: firstFilters)
            let second = HistorySearchDefinition(filters: secondFilters)
            #expect(first == second)
            #expect(store.recordSubmittedSearch(first) == .saved)
            #expect(store.recordSubmittedSearch(second) == .saved)
            #expect(store.recentSearches.count == 1)

            let restored = try #require(SearchHistoryStore(defaults: defaults).recentSearches.first?.definition)
            #expect(restored.filters.dateRange == .lastSevenDays)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
            let now = Date(timeIntervalSinceReferenceDate: 900_000_000)
            let nextWeek = now.addingTimeInterval(7 * 86_400)
            let currentBounds = restored.filters.dateBounds(now: now, calendar: calendar)
            let laterBounds = restored.filters.dateBounds(now: nextWeek, calendar: calendar)
            #expect(laterBounds.after == currentBounds.after?.addingTimeInterval(7 * 86_400))
            #expect(laterBounds.before == currentBounds.before?.addingTimeInterval(7 * 86_400))
        }
    }

    @Test func emptySearchIsRejectedButWhitespaceAndMetadataOnlySearchesAreUseful() throws {
        try withStore { store, _ in
            enableAll(store)
            #expect(store.saveFavorite(.init()) == .empty)
            #expect(store.recordSubmittedSearch(.init()) == .empty)
            var source = HistorySearchFilters()
            source.sourceApplication = "Notes"
            var dates = HistorySearchFilters()
            dates.dateRange = .today
            let definitions: [HistorySearchDefinition] = [
                .init(query: " \n", mode: .exact), .init(typeFilter: .images),
                .init(pinnedOnly: true), .init(filters: source), .init(filters: dates),
                .init(sortOrder: .oldestFirst),
            ]
            for definition in definitions {
                #expect(store.saveFavorite(definition) == .saved)
                #expect(store.recordSubmittedSearch(definition) == .saved)
            }
            #expect(store.favorites.count == definitions.count)
            #expect(store.recentSearches.count == definitions.count)
            #expect(store.favorites.contains { Data($0.definition.query.utf8) == Data(" \n".utf8) })
        }
    }

    @Test func invalidDefinitionsNeverReplacePreviouslySavedSearches() throws {
        try withStore { store, _ in
            enableAll(store)
            let valid = HistorySearchDefinition(query: "valid")
            #expect(store.saveFavorite(valid) == .saved)
            #expect(store.recordSubmittedSearch(valid) == .saved)
            var reversed = HistorySearchFilters()
            reversed.dateRange = .custom
            reversed.startDate = Date(timeIntervalSinceReferenceDate: 800_259_200)
            reversed.endDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
            var nonfinite = reversed
            nonfinite.startDate = Date(timeIntervalSinceReferenceDate: .infinity)
            let invalid: [HistorySearchDefinition] = [
                .init(query: "[", mode: .regexp), .init(query: "(report OR", mode: .expression),
                .init(filters: reversed), .init(filters: nonfinite),
                .init(query: String(repeating: "x", count: 16_385), mode: .exact),
            ]
            for definition in invalid {
                #expect(store.saveFavorite(definition) == .invalidDefinition)
                #expect(store.recordSubmittedSearch(definition) == .invalidDefinition)
            }
            #expect(store.favorites.map(\.definition) == [valid])
            #expect(store.recentSearches.map(\.definition) == [valid])
        }
    }

    @Test func favoriteNamesUseAUTF8ByteLimitWithoutDamagingExistingNames() throws {
        try withStore { store, _ in
            store.updatePreferences { $0.isEnabled = true }
            let accepted = String(repeating: "é", count: 100)
            #expect(accepted.utf8.count == 200)
            #expect(store.saveFavorite(.init(query: "report"), name: accepted) == .saved)
            let item = try #require(store.favorites.first)
            #expect(store.renameFavorite(item.id, name: accepted + "x") == .invalidDefinition)
            #expect(store.favorites.first?.name == accepted)
            #expect(store.saveFavorite(.init(query: "other"), name: accepted + "x") == .invalidDefinition)
            #expect(store.favorites.count == 1)
        }
    }

    @Test func definitionByteLimitCountsQuerySourceAndNameTogether() throws {
        try withStore { store, _ in
            enableAll(store)
            #expect(store.recordSubmittedSearch(.init(
                query: String(repeating: "x", count: 16_384), mode: .exact
            )) == .saved)
            var filters = HistorySearchFilters()
            filters.sourceApplication = "com.example.Editor"
            filters.sourceMatch = .bundleIdentifier
            let name = "Saved"
            let query = String(repeating: "x", count: 16_384 - name.utf8.count - filters.sourceApplication.utf8.count)
            let accepted = HistorySearchDefinition(query: query, mode: .exact, filters: filters)
            #expect(store.saveFavorite(accepted, name: name) == .saved)
            #expect(store.saveFavorite(accepted, name: name + "x") == .invalidDefinition)
            #expect(store.favorites.count == 1)
            #expect(store.favorites.first?.name == name)
        }
    }

    @Test(arguments: [
        ("secret", "prefix SeCrEt suffix"),
        ("CAFÉ", "prefix cafe\u{301} suffix"),
        ("strasse", "prefix Straße suffix"),
        ("密钥", "含有密钥的查询"),
        ("a.b", "prefix A.B suffix"),
    ])
    func excludedWordsMatchCaseFoldedCanonicalLiteralSubstrings(rule: String, query: String) throws {
        try withStore { store, _ in
            enableAll(store)
            store.updatePreferences { $0.excludedKeywords = [rule] }
            let definition = HistorySearchDefinition(query: query, mode: .exact)
            #expect(store.saveFavorite(definition) == .excluded)
            #expect(store.recordSubmittedSearch(definition) == .excluded)
            #expect(store.lastWriteResult == .excluded)
            #expect(store.favorites.isEmpty)
            #expect(store.recentSearches.isEmpty)
        }
    }

    @Test(arguments: [("cafe", "café"), ("abc", "ＡＢＣ"), ("a.b", "axb")])
    func exclusionPreservesAccentsWidthAndLiteralPunctuation(rule: String, query: String) throws {
        try withStore { store, _ in
            enableAll(store)
            store.updatePreferences { $0.excludedKeywords = [rule] }
            #expect(store.saveFavorite(.init(query: query)) == .saved)
            #expect(store.recordSubmittedSearch(.init(query: query)) == .saved)
            let savedQuery = try #require(store.favorites.first?.definition.query)
            #expect(Data(savedQuery.utf8) == Data(query.utf8))
        }
    }

    @Test func sourceAndFavoriteNameExclusionsRejectTheWholeEntry() throws {
        try withStore { store, _ in
            enableAll(store)
            store.updatePreferences { $0.excludedKeywords = ["secret"] }
            let publicDefinition = HistorySearchDefinition(query: "public notes")
            #expect(store.saveFavorite(publicDefinition, name: "Public") == .saved)
            let original = try #require(store.favorites.first)
            var source = HistorySearchFilters()
            source.sourceApplication = "com.example.SECRETeditor"
            source.sourceMatch = .bundleIdentifier
            let sourceExcluded = HistorySearchDefinition(query: "public notes", filters: source)

            #expect(store.saveFavorite(sourceExcluded) == .excluded)
            #expect(store.recordSubmittedSearch(sourceExcluded) == .excluded)
            #expect(store.saveFavorite(publicDefinition, name: "Secret collection") == .excluded)
            #expect(store.renameFavorite(original.id, name: "Secret collection") == .excluded)
            #expect(store.favorites.count == 1)
            #expect(store.favorites.first?.id == original.id)
            #expect(store.favorites.first?.name == "Public")
            #expect(store.favorites.first?.definition == publicDefinition)
            #expect(store.recentSearches.isEmpty)
        }
    }

    @Test func newExclusionRulesImmediatelyRemoveMatchingOldEntries() throws {
        try withStore { store, defaults in
            enableAll(store)
            var source = HistorySearchFilters()
            source.sourceApplication = "com.example.cafe\u{301}"
            source.sourceMatch = .bundleIdentifier
            let queryMatch = HistorySearchDefinition(query: "cafe\u{301} report")
            let sourceMatch = HistorySearchDefinition(query: "source report", filters: source)
            let nameMatch = HistorySearchDefinition(query: "named report")
            let retained = HistorySearchDefinition(query: "ordinary report")
            #expect(store.saveFavorite(queryMatch) == .saved)
            #expect(store.saveFavorite(sourceMatch) == .saved)
            #expect(store.saveFavorite(nameMatch, name: "Café") == .saved)
            #expect(store.saveFavorite(retained) == .saved)
            for definition in [queryMatch, sourceMatch, retained] {
                #expect(store.recordSubmittedSearch(definition) == .saved)
            }

            store.updatePreferences { $0.excludedKeywords = ["CAFÉ"] }
            #expect(store.favorites.map(\.definition) == [retained])
            #expect(store.recentSearches.map(\.definition) == [retained])
            let reopened = SearchHistoryStore(defaults: defaults)
            #expect(reopened.favorites.map(\.definition) == [retained])
            #expect(reopened.recentSearches.map(\.definition) == [retained])
        }
    }

    @Test func favoriteLimitRejectsTheNewEntryWithoutDiscardingAnExistingFavorite() throws {
        try withStore { store, defaults in
            store.updatePreferences { $0.isEnabled = true }
            for index in 0..<50 {
                #expect(store.saveFavorite(.init(query: "favorite \(index)")) == .saved)
            }
            let retainedIDs = store.favorites.map(\.id)
            #expect(store.saveFavorite(.init(query: "favorite 51")) == .favoriteLimitReached)
            #expect(store.favorites.map(\.id) == retainedIDs)
            #expect(SearchHistoryStore(defaults: defaults).favorites.map(\.id) == retainedIDs)
            let renamedID = try #require(retainedIDs.first)
            #expect(store.renameFavorite(renamedID, name: "Renamed at capacity") == .saved)
            #expect(store.favorites.count == 50)
            #expect(store.favorites.first(where: { $0.id == renamedID })?.name == "Renamed at capacity")
        }
    }

    @Test func recentCapacityDiscardsOldestEntriesAndRepeatedSearchMovesToFront() throws {
        try withStore { store, defaults in
            enableAll(store)
            store.updatePreferences { $0.maximumRecentSearches = 3 }
            #expect(store.saveFavorite(.init(query: "retained favorite")) == .saved)
            for index in 0..<5 {
                #expect(store.recordSubmittedSearch(.init(query: "query \(index)")) == .saved)
            }
            #expect(store.recentSearches.map(\.definition.query) == ["query 4", "query 3", "query 2"])
            let repeatedID = try #require(store.recentSearches.first(where: { $0.definition.query == "query 3" })?.id)
            #expect(store.recordSubmittedSearch(.init(query: "query 3")) == .saved)
            #expect(store.recentSearches.map(\.definition.query) == ["query 3", "query 4", "query 2"])
            #expect(store.recentSearches.first?.id == repeatedID)
            store.updatePreferences { $0.maximumRecentSearches = 2 }
            #expect(store.recentSearches.map(\.definition.query) == ["query 3", "query 4"])
            #expect(store.favorites.count == 1)
            #expect(SearchHistoryStore(defaults: defaults).recentSearches.map(\.definition.query)
                    == ["query 3", "query 4"])
        }
    }

    @Test(arguments: [(0, 1), (-100, 1), (101, 100), (Int.max, 100)])
    func recentCapacityIsClampedToTheSupportedRange(proposed: Int, expected: Int) throws {
        try withStore { store, defaults in
            store.updatePreferences { $0.maximumRecentSearches = proposed }
            #expect(store.preferences.maximumRecentSearches == expected)
            #expect(SearchHistoryStore(defaults: defaults).preferences.maximumRecentSearches == expected)
        }
    }

    @Test func recentIdentityPreservesCaseAndExactUnicodeBytes() throws {
        try withStore { store, defaults in
            enableAll(store)
            let queries = ["Case", "case", "é", "e\u{301}", "Ａ", "A"]
            for query in queries {
                #expect(store.recordSubmittedSearch(.init(query: query, mode: .exact)) == .saved)
            }
            #expect(store.recentSearches.count == queries.count)
            #expect(Set(store.recentSearches.map { Data($0.definition.query.utf8) })
                    == Set(queries.map { Data($0.utf8) }))
            #expect(store.recordSubmittedSearch(.init(query: "é", mode: .exact)) == .saved)
            #expect(store.recentSearches.count == queries.count)
            let firstQuery = try #require(store.recentSearches.first?.definition.query)
            #expect(Data(firstQuery.utf8) == Data("é".utf8))
            #expect(Set(SearchHistoryStore(defaults: defaults).recentSearches.map { Data($0.definition.query.utf8) })
                    == Set(queries.map { Data($0.utf8) }))
        }
    }

    @Test func recentIdentityIncludesModeTypePinSourceDateAndSort() throws {
        try withStore { store, _ in
            enableAll(store)
            var source = HistorySearchFilters()
            source.sourceApplication = "com.example.é"
            source.sourceMatch = .bundleIdentifier
            var alternateSource = source
            alternateSource.sourceApplication = "com.example.e\u{301}"
            var dates = HistorySearchFilters()
            dates.dateRange = .today
            let definitions: [HistorySearchDefinition] = [
                .init(query: "same"), .init(query: "same", mode: .exact),
                .init(query: "same", typeFilter: .text), .init(query: "same", pinnedOnly: true),
                .init(query: "same", filters: source), .init(query: "same", filters: alternateSource),
                .init(query: "same", filters: dates), .init(query: "same", sortOrder: .oldestFirst),
            ]
            for definition in definitions { #expect(store.recordSubmittedSearch(definition) == .saved) }
            #expect(store.recentSearches.count == definitions.count)
            let original = try #require(definitions.first)
            #expect(store.recordSubmittedSearch(original) == .saved)
            #expect(store.recentSearches.count == definitions.count)
            #expect(store.recentSearches.first?.definition == original)
        }
    }

    @Test func removingAndClearingSearchesOnlyAffectsTheRequestedEntries() throws {
        try withStore { store, defaults in
            enableAll(store)
            #expect(store.saveFavorite(.init(query: "favorite one")) == .saved)
            #expect(store.saveFavorite(.init(query: "favorite two")) == .saved)
            #expect(store.recordSubmittedSearch(.init(query: "recent one")) == .saved)
            #expect(store.recordSubmittedSearch(.init(query: "recent two")) == .saved)
            let removedFavorite = try #require(store.favorites.first?.id)
            let removedRecent = try #require(store.recentSearches.first?.id)
            store.removeFavorite(removedFavorite)
            store.removeRecent(removedRecent)
            #expect(store.favorites.count == 1)
            #expect(store.recentSearches.count == 1)
            #expect(!store.favorites.contains { $0.id == removedFavorite })
            #expect(!store.recentSearches.contains { $0.id == removedRecent })
            store.clearRecentSearches()
            #expect(store.recentSearches.isEmpty)
            #expect(store.favorites.count == 1)
            store.clearAllSearches()
            #expect(store.favorites.isEmpty)
            let reopened = SearchHistoryStore(defaults: defaults)
            #expect(reopened.favorites.isEmpty)
            #expect(reopened.recentSearches.isEmpty)
            #expect(reopened.preferences.isEnabled)
        }
    }

    @Test func separateStoreInstancesMergeFavoritesAndReloadExternalChanges() throws {
        try withStore { first, defaults in
            first.updatePreferences { $0.isEnabled = true }
            let second = SearchHistoryStore(defaults: defaults)
            #expect(first.saveFavorite(.init(query: "first window")) == .saved)
            #expect(second.saveFavorite(.init(query: "second window")) == .saved)
            #expect(second.favorites.count == 2)
            first.reload()
            #expect(Set(first.favorites.map(\.definition.query)) == ["first window", "second window"])
            let removed = try #require(first.favorites.first(where: { $0.definition.query == "first window" }))
            first.removeFavorite(removed.id)
            #expect(second.saveFavorite(.init(query: "second window addition")) == .saved)
            let reopened = SearchHistoryStore(defaults: defaults)
            #expect(Set(reopened.favorites.map(\.definition.query))
                    == ["second window", "second window addition"])
        }
    }

    @Test func unreadableStoreIsPreservedUntilTheUserExplicitlyClearsIt() throws {
        try withStore { store, defaults in
            let corrupted = Data([0xFF, 0x00, 0x7B, 0x22])
            defaults.set(corrupted, forKey: SearchHistoryStore.defaultsKey)
            store.reload()
            #expect(store.failure == .unreadableStore)
            #expect(store.favorites.isEmpty)
            #expect(store.recentSearches.isEmpty)
            #expect(defaults.data(forKey: SearchHistoryStore.defaultsKey) == corrupted)
            #expect(store.saveFavorite(.init(query: "must not overwrite unreadable data")) == .unavailable)
            #expect(store.recordSubmittedSearch(.init(query: "must not overwrite unreadable data")) == .unavailable)
            store.updatePreferences { $0.isEnabled = true }
            #expect(store.failure == .unreadableStore)
            #expect(defaults.data(forKey: SearchHistoryStore.defaultsKey) == corrupted)

            store.clearAllSearches()
            #expect(store.failure == nil)
            let reopened = SearchHistoryStore(defaults: defaults)
            #expect(reopened.failure == nil)
            #expect(reopened.favorites.isEmpty)
            #expect(reopened.recentSearches.isEmpty)
            reopened.updatePreferences { $0.isEnabled = true }
            #expect(reopened.saveFavorite(.init(query: "after explicit clearing")) == .saved)
        }
    }

    @Test func unrelatedPreferenceEditsDoNotImplicitlyDiscardAnUnreadableStore() throws {
        try withStore { store, defaults in
            let corrupted = Data("not a saved-search document".utf8)
            defaults.set(corrupted, forKey: SearchHistoryStore.defaultsKey)
            store.reload()
            store.updatePreferences { $0.maximumRecentSearches = 5 }
            #expect(store.failure == .unreadableStore)
            #expect(defaults.data(forKey: SearchHistoryStore.defaultsKey) == corrupted)
            store.updatePreferences { $0.excludedKeywords = ["secret"] }
            #expect(store.failure == .unreadableStore)
            #expect(defaults.data(forKey: SearchHistoryStore.defaultsKey) == corrupted)
        }
    }

    @Test func explicitlyDisablingRecoversAnUnreadableStoreWithoutRetainingQueries() throws {
        try withStore { store, defaults in
            enableAll(store)
            #expect(store.saveFavorite(.init(query: "old favorite")) == .saved)
            #expect(store.recordSubmittedSearch(.init(query: "old recent")) == .saved)
            defaults.set(Data("corrupted after loading".utf8), forKey: SearchHistoryStore.defaultsKey)
            store.setEnabled(false)
            #expect(store.failure == nil)
            #expect(!store.preferences.isEnabled)
            #expect(!store.preferences.recordsRecentSearches)
            #expect(store.favorites.isEmpty)
            #expect(store.recentSearches.isEmpty)
            let reopened = SearchHistoryStore(defaults: defaults)
            #expect(reopened.failure == nil)
            #expect(!reopened.preferences.isEnabled)
            #expect(reopened.favorites.isEmpty)
            #expect(reopened.recentSearches.isEmpty)
        }
    }

    @Test func capturingSavingAndApplyingSearchRestoresOneCompleteObservationRequest() async throws {
        let suite = "SearchHistoryReplayTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = HistoryViewState(history: ScriptedHistory())
        source.searchText = "^report-[0-9]+$"
        source.searchMode = .regexp
        source.typeFilter = .text
        source.showsPinnedOnly = true
        source.sortOrder = .oldestFirst
        var filters = HistorySearchFilters()
        filters.sourceApplication = "com.example.Editor"
        filters.sourceMatch = .bundleIdentifier
        filters.dateRange = .custom
        filters.startDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
        filters.endDate = Date(timeIntervalSinceReferenceDate: 800_259_200)
        source.searchFilters = filters
        let captured = HistorySearchDefinition(viewState: source)
        source.deactivate()
        let store = SearchHistoryStore(defaults: defaults)
        store.updatePreferences { $0.isEnabled = true }
        #expect(store.saveFavorite(captured, name: "Report search") == .saved)
        let saved = try #require(SearchHistoryStore(defaults: defaults).favorites.first?.definition)

        let history = ScriptedHistory(observedFirstPage: fixturePage(rows: [], next: nil))
        let destination = HistoryViewState(history: history)
        destination.activate()
        defer { destination.deactivate() }
        try #require(await pollUntil {
            let count = await history.observeRequests.count
            return destination.hasAuthoritativeFirstPage && count == 1
        })
        saved.apply(to: destination)
        #expect(destination.searchText == "^report-[0-9]+$")
        #expect(destination.searchMode == .regexp)
        #expect(destination.typeFilter == .text)
        #expect(destination.showsPinnedOnly)
        #expect(destination.searchFilters == filters)
        #expect(destination.sortOrder == .oldestFirst)
        try #require(await pollUntil {
            let count = await history.observeRequests.count
            return destination.hasAuthoritativeFirstPage && count == 2
        })
        let requests = await history.observeRequests
        #expect(requests.count == 2, "Applying one saved search must not observe intermediate field combinations")
        let request = try #require(requests.last)
        guard case .search(let query, let mode) = request.kind else {
            Issue.record("Restoring a saved query must create a search observation")
            return
        }
        #expect(query == "^report-[0-9]+$")
        #expect(mode == .regexp)
        #expect(request.sortOrder == .oldestFirst)
        #expect(request.filter.type == .text)
        #expect(request.filter.pinnedOnly)
        #expect(request.filter.sourceApplicationIDs == ["com.example.Editor"])
        let bounds = filters.dateBounds(now: filters.endDate, calendar: .current)
        #expect(request.filter.copiedAfter == bounds.after)
        #expect(request.filter.copiedBefore == bounds.before)
    }

    private func enableAll(_ store: SearchHistoryStore) {
        store.updatePreferences {
            $0.isEnabled = true
            $0.recordsRecentSearches = true
        }
    }

    private func withStore(
        _ body: (SearchHistoryStore, UserDefaults) throws -> Void
    ) throws {
        let suite = "SearchHistoryStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(SearchHistoryStore(defaults: defaults), defaults)
    }
}
