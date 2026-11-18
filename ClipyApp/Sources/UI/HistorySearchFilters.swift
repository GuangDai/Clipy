/// Search controls remain independent of the query's matching mode. Dates
/// describe the most recent copy, in the user's calendar (03a §7; V2-07 §3).
import Foundation
import HistoryCore

enum HistorySearchDateRange: String, CaseIterable, Codable, Sendable {
    case anyTime, today, yesterday, lastSevenDays, lastThirtyDays, custom

    var title: String {
        switch self {
        case .anyTime: "Any time"
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .lastSevenDays: "Last 7 days"
        case .lastThirtyDays: "Last 30 days"
        case .custom: "Custom dates"
        }
    }
}

enum HistorySearchSourceMatch: String, CaseIterable, Codable, Sendable {
    case applicationName, bundleIdentifier
}

struct HistorySearchFilters: Codable, Equatable, Sendable {
    var sourceApplication = ""
    var sourceMatch: HistorySearchSourceMatch = .applicationName
    var dateRange: HistorySearchDateRange = .anyTime
    var startDate = Date()
    var endDate = Date()

    var source: String? {
        let value = sourceApplication.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var isActive: Bool { source != nil || dateRange != .anyTime }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sourceApplication.utf8.elementsEqual(rhs.sourceApplication.utf8)
            && lhs.sourceMatch == rhs.sourceMatch && lhs.dateRange == rhs.dateRange
            && lhs.startDate == rhs.startDate && lhs.endDate == rhs.endDate
    }

    func hasValidDates(calendar: Calendar = .current) -> Bool {
        dateRange != .custom || calendar.startOfDay(for: startDate) <= calendar.startOfDay(for: endDate)
    }

    /// Calendar arithmetic keeps local days correct across daylight-saving
    /// transitions. End dates include the chosen day, excluding the next day.
    func dateBounds(now: Date, calendar: Calendar) -> (after: Date?, before: Date?) {
        let today = calendar.startOfDay(for: now)
        let endOfToday = calendar.dateInterval(of: .day, for: now)?.end
        func priorDay(_ offset: Int) -> Date? {
            calendar.date(byAdding: .day, value: offset, to: today).map { calendar.startOfDay(for: $0) }
        }
        switch dateRange {
        case .anyTime: return (nil, nil)
        case .today: return (today, endOfToday)
        case .yesterday: return (priorDay(-1), today)
        case .lastSevenDays: return (priorDay(-6), endOfToday)
        case .lastThirtyDays: return (priorDay(-29), endOfToday)
        case .custom:
            return (calendar.startOfDay(for: startDate), calendar.dateInterval(of: .day, for: endDate)?.end)
        }
    }
}

enum HistorySearchCopy {
    static func text(_ english: String, bundle: Bundle = AppLocalization.bundle) -> String {
        bundle.localizedString(forKey: english, value: english, table: "HistorySearch")
    }

    static func format(_ english: String, _ value: String, bundle: Bundle = AppLocalization.bundle) -> String {
        String(format: text(english, bundle: bundle), value)
    }

    static func expressionError(_ error: HistorySearchExpressionError, bundle: Bundle = AppLocalization.bundle) -> String {
        String(format: text("Character %d: %@", bundle: bundle), error.offset + 1,
               text(error.message, bundle: bundle))
    }

    static func sortTitle(_ order: HistorySortOrder, bundle: Bundle = AppLocalization.bundle) -> String {
        switch order {
        case .automatic: text("Pinned first", bundle: bundle)
        case .newestFirst: text("Newest first", bundle: bundle)
        case .oldestFirst: text("Oldest first", bundle: bundle)
        case .mostCopied: text("Most copied", bundle: bundle)
        }
    }

    @MainActor
    static func issue(for state: HistoryViewState, bundle: Bundle = AppLocalization.bundle) -> String? {
        if let error = state.expressionValidationError { return expressionError(error, bundle: bundle) }
        if state.fuzzyQueryExceedsLimit {
            return String(format: text(
                "Fuzzy search supports up to %d characters. Use Exact to search the entire text.", bundle: bundle
            ), HistoryLimits.standard.maximumFuzzyQueryCharacters)
        }
        if !state.unresolvedSearchSources.isEmpty {
            return format("No installed application matches %@. Choose an application or use an exact bundle ID.",
                          state.unresolvedSearchSources.joined(separator: ", "), bundle: bundle)
        }
        if state.isSourceSearchTooBroad {
            return text("Too many applications match. Choose an application or use an exact bundle ID.", bundle: bundle)
        }
        if let error = state.sourceResolutionError {
            return format("After resolving application names: %@ Shorten the expression or use exact source IDs.",
                          text(error.message, bundle: bundle), bundle: bundle)
        }
        return nil
    }

    @MainActor
    static func resultsFailure(for state: HistoryViewState) -> HistoryFailure? {
        guard !state.isLoadingFirstPage, state.canRetryFailureByRefreshing,
              state.displayedRows.isEmpty else { return nil }
        return state.failure
    }

    static func resultsFailureTitle(_ failure: HistoryFailure, bundle: Bundle = AppLocalization.bundle) -> String {
        text(canRetryResults(failure) ? "Couldn't load results" : "Check search conditions", bundle: bundle)
    }

    static func canRetryResults(_ failure: HistoryFailure) -> Bool {
        if case .invalidInput = failure { return false }
        return true
    }
}
