import Foundation
import HistoryCore
import Observation

struct SearchHistoryPreferences: Codable, Equatable, Sendable {
    static let recentCountRange = 1...100
    var isEnabled = false
    var recordsRecentSearches = false
    var maximumRecentSearches = 20
    var excludedKeywords: [String] = []

    fileprivate mutating func normalize() {
        maximumRecentSearches = min(Self.recentCountRange.upperBound,
                                    max(Self.recentCountRange.lowerBound, maximumRecentSearches))
        if !isEnabled { recordsRecentSearches = false }
        var seen: Set<String> = []
        excludedKeywords = excludedKeywords.compactMap { keyword in
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(Self.folded(trimmed)).inserted else { return nil }
            return trimmed
        }
    }

    /// Ignore Unicode case and canonical composition, using a fixed English
    /// locale so privacy rules do not change with the system language. This
    /// deliberately preserves accents and full/half-width distinctions.
    private static func folded(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    fileprivate func excludes(_ definition: HistorySearchDefinition, name: String) -> Bool {
        let values = [definition.query, definition.filters.sourceApplication, name].map(Self.folded)
        return excludedKeywords.contains { keyword in
            let needle = Self.folded(keyword)
            return !needle.isEmpty && values.contains { $0.range(of: needle, options: .literal) != nil }
        }
    }
}

struct SavedHistorySearch: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let definition: HistorySearchDefinition
    var savedAt: Date
}

enum SearchHistoryWriteResult: Equatable, Sendable {
    case saved, disabled, recentSearchesDisabled, excluded, empty
    case favoriteLimitReached, invalidDefinition, unavailable
}

enum SearchHistoryFailure: Error, Equatable, Sendable {
    case unreadableStore, writeFailed
}

/// Opt-in storage for submitted query definitions and explicit favorites.
/// It has no clipboard observer, no result payloads and no execution task.
/// One defaults value commits preferences and the pruned records together.
/// Owning product behavior: V2-11, 保存搜索条件.
@MainActor @Observable
final class SearchHistoryStore {
    static let defaultsKey = "clipy.searchHistory"
    static let maximumFavorites = 50
    private static let maximumDefinitionBytes = 16_384
    private static let maximumStoreBytes = 4 * 1_024 * 1_024

    private(set) var preferences = SearchHistoryPreferences()
    private(set) var favorites: [SavedHistorySearch] = []
    private(set) var recentSearches: [SavedHistorySearch] = []
    private(set) var lastWriteResult: SearchHistoryWriteResult?
    private(set) var failure: SearchHistoryFailure?
    @ObservationIgnored private let defaults: UserDefaults

    private struct StoredSearches: Codable, Equatable {
        var preferences = SearchHistoryPreferences()
        var favorites: [SavedHistorySearch] = []
        var recentSearches: [SavedHistorySearch] = []

        mutating func applyPreferences() {
            preferences.normalize()
            guard preferences.isEnabled else {
                favorites = []
                recentSearches = []
                return
            }
            let rules = preferences
            favorites.removeAll { rules.excludes($0.definition, name: $0.name) }
            recentSearches.removeAll { rules.excludes($0.definition, name: $0.name) }
            if !preferences.recordsRecentSearches { recentSearches = [] }
            recentSearches = Array(recentSearches.prefix(preferences.maximumRecentSearches))
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
    }

    func reload() {
        do { publish(try readCurrent()) }
        catch { reportReadFailure() }
    }

    func updatePreferences(_ edit: (inout SearchHistoryPreferences) -> Void) {
        do {
            var stored = try readCurrent()
            edit(&stored.preferences)
            stored.applyPreferences()
            try persist(stored)
            lastWriteResult = nil
        } catch {
            if failure == nil { failure = .writeFailed }
        }
    }

    /// The explicit disable action can remove unreadable saved queries.
    /// Ordinary preferences edits never infer that destructive intent from
    /// a default false value after a decoding failure.
    func setEnabled(_ enabled: Bool) {
        guard !enabled else {
            updatePreferences { $0.isEnabled = true }
            return
        }
        var stored = (try? readCurrent()) ?? StoredSearches(preferences: preferences)
        stored.preferences.isEnabled = false
        stored.applyPreferences()
        do { try persist(stored); lastWriteResult = nil }
        catch { failure = .writeFailed }
    }

    @discardableResult
    func saveFavorite(_ definition: HistorySearchDefinition, name: String = "") -> SearchHistoryWriteResult {
        write(definition, name: name, recent: false)
    }

    /// Call only after a deliberate query submission or result choice.
    /// Draft field edits must never call this method.
    @discardableResult
    func recordSubmittedSearch(_ definition: HistorySearchDefinition) -> SearchHistoryWriteResult {
        write(definition, name: "", recent: true)
    }

    @discardableResult
    func renameFavorite(_ id: UUID, name: String) -> SearchHistoryWriteResult {
        do {
            var stored = try readCurrent()
            publish(stored)
            guard stored.preferences.isEnabled else { return finish(.disabled) }
            guard let index = stored.favorites.firstIndex(where: { $0.id == id }) else {
                return finish(.unavailable)
            }
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let definition = stored.favorites[index].definition
            if let rejection = rejection(for: definition, name: name, preferences: stored.preferences) {
                return finish(rejection)
            }
            stored.favorites[index].name = name
            try persist(stored)
            return finish(.saved)
        } catch {
            if failure == nil { failure = .writeFailed }
            return finish(.unavailable)
        }
    }

    func removeFavorite(_ id: UUID) { editRecords { $0.favorites.removeAll { $0.id == id } } }
    func removeRecent(_ id: UUID) { editRecords { $0.recentSearches.removeAll { $0.id == id } } }
    func clearRecentSearches() { editRecords { $0.recentSearches = [] } }

    func clearAllSearches() {
        // This explicit destructive action also recovers an unreadable value.
        var stored = (try? readCurrent()) ?? StoredSearches(preferences: preferences)
        stored.favorites = []
        stored.recentSearches = []
        stored.applyPreferences()
        do { try persist(stored); lastWriteResult = nil }
        catch { failure = .writeFailed }
    }

    private func write(
        _ definition: HistorySearchDefinition, name: String, recent: Bool
    ) -> SearchHistoryWriteResult {
        do {
            var stored = try readCurrent()
            publish(stored)
            guard stored.preferences.isEnabled else { return finish(.disabled) }
            guard !recent || stored.preferences.recordsRecentSearches else { return finish(.recentSearchesDisabled) }
            // Normalize only unused draft dates. Query bytes remain unchanged.
            let definition = HistorySearchDefinition(
                query: definition.query, mode: definition.mode, typeFilter: definition.typeFilter,
                pinnedOnly: definition.pinnedOnly, filters: definition.filters, sortOrder: definition.sortOrder
            )
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let rejection = rejection(for: definition, name: name, preferences: stored.preferences) {
                return finish(rejection)
            }
            if recent {
                let existing = stored.recentSearches.first { $0.definition == definition }
                stored.recentSearches.removeAll { $0.definition == definition }
                stored.recentSearches.insert(SavedHistorySearch(
                    id: existing?.id ?? UUID(), name: "", definition: definition, savedAt: Date()
                ), at: 0)
                stored.recentSearches = Array(stored.recentSearches.prefix(stored.preferences.maximumRecentSearches))
            } else if let index = stored.favorites.firstIndex(where: { $0.definition == definition }) {
                if !name.isEmpty { stored.favorites[index].name = name }
            } else {
                guard stored.favorites.count < Self.maximumFavorites else { return finish(.favoriteLimitReached) }
                stored.favorites.insert(SavedHistorySearch(
                    id: UUID(), name: name, definition: definition, savedAt: Date()
                ), at: 0)
            }
            try persist(stored)
            return finish(.saved)
        } catch {
            if failure == nil { failure = .writeFailed }
            return finish(.unavailable)
        }
    }

    private func rejection(
        for definition: HistorySearchDefinition, name: String, preferences: SearchHistoryPreferences
    ) -> SearchHistoryWriteResult? {
        guard definition.hasCriteria else { return .empty }
        guard Self.isValid(definition, name: name) else { return .invalidDefinition }
        guard !preferences.excludes(definition, name: name) else { return .excluded }
        return nil
    }

    private static func isValid(_ definition: HistorySearchDefinition, name: String) -> Bool {
        guard name.utf8.count <= 200,
              definition.query.utf8.count + definition.filters.sourceApplication.utf8.count + name.utf8.count <= maximumDefinitionBytes,
              definition.filters.startDate.timeIntervalSince1970.isFinite,
              definition.filters.endDate.timeIntervalSince1970.isFinite,
              definition.filters.hasValidDates() else { return false }
        switch definition.mode {
        case .regexp:
            return definition.query.isEmpty || (try? NSRegularExpression(pattern: definition.query)) != nil
        case .expression:
            return definition.query.isEmpty || (try? HistorySearchExpression.parse(definition.query)) != nil
        case .exact, .fuzzy: return true
        }
    }

    private func editRecords(_ edit: (inout StoredSearches) -> Void) {
        do {
            var stored = try readCurrent()
            edit(&stored)
            try persist(stored)
            lastWriteResult = nil
        } catch {
            if failure == nil { failure = .writeFailed }
        }
    }

    /// Main-actor read-modify-write merges different windows' definitions and
    /// rechecks the latest privacy setting before any new query is persisted.
    private func readCurrent() throws -> StoredSearches {
        guard let raw = defaults.object(forKey: Self.defaultsKey) else { return StoredSearches() }
        do {
            guard let data = raw as? Data, data.count <= Self.maximumStoreBytes else {
                throw SearchHistoryFailure.unreadableStore
            }
            var stored = try JSONDecoder().decode(StoredSearches.self, from: data)
            guard stored.favorites.count <= Self.maximumFavorites,
                  stored.recentSearches.count <= SearchHistoryPreferences.recentCountRange.upperBound,
                  Set(stored.favorites.map(\.id)).count == stored.favorites.count,
                  Set(stored.recentSearches.map(\.id)).count == stored.recentSearches.count,
                  (stored.favorites + stored.recentSearches).allSatisfy({
                      $0.definition.hasCriteria && Self.isValid($0.definition, name: $0.name)
                          && $0.savedAt.timeIntervalSince1970.isFinite
                  }) else { throw SearchHistoryFailure.unreadableStore }
            let original = stored
            stored.applyPreferences()
            if stored != original { try persist(stored) }
            return stored
        } catch {
            reportReadFailure()
            throw SearchHistoryFailure.unreadableStore
        }
    }

    private func persist(_ stored: StoredSearches) throws {
        let data = try JSONEncoder().encode(stored)
        guard data.count <= Self.maximumStoreBytes else { throw SearchHistoryFailure.writeFailed }
        defaults.set(data, forKey: Self.defaultsKey)
        publish(stored)
    }

    private func publish(_ stored: StoredSearches) {
        preferences = stored.preferences
        favorites = stored.favorites
        recentSearches = stored.recentSearches
        failure = nil
    }

    private func reportReadFailure() {
        preferences = SearchHistoryPreferences()
        favorites = []
        recentSearches = []
        failure = .unreadableStore
    }

    private func finish(_ result: SearchHistoryWriteResult) -> SearchHistoryWriteResult {
        lastWriteResult = result
        return result
    }
}
