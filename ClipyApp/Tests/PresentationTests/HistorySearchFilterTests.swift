import Foundation
@testable import HistoryCore
@testable import HistoryStorage
@testable import ClipyApp
import Testing

/// Metadata controls compose with the real matcher and its observation;
/// calendar assertions cover local days whose lengths are not 24 hours.
@MainActor
struct HistorySearchFilterTests {
    @Test func metadataFiltersPreserveRegexpAndClearRestoresItsResults() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 800_000_000))
        let nextDay = try #require(calendar.date(byAdding: .day, value: 1, to: start))
        let previousDay = try #require(calendar.date(byAdding: .day, value: -1, to: start))
        let first = try await capture("report-101", source: "com.example.Editor", at: start, in: history)
        let last = try await capture("report-102", source: "com.example.Editor",
                                     at: nextDay.addingTimeInterval(-1), in: history)
        let old = try await capture("report-103", source: "com.example.Editor", at: previousDay, in: history)
        let next = try await capture("report-104", source: "com.example.Editor", at: nextDay, in: history)
        let other = try await capture("report-105", source: "com.example.Browser", at: start, in: history)
        let unknown = try await capture("report-106", source: nil, at: start, in: history)
        _ = try await capture("ordinary note", source: "com.example.Editor", at: start, in: history)
        _ = try await history.perform(.placePinned(first.id, at: .last))

        let state = HistoryViewState(history: history)
        state.searchMode = .regexp
        state.searchText = "^report-[0-9]+$"
        state.activate()
        defer { state.deactivate() }
        let allMatches = Set([first, last, old, next, other, unknown])
        try #require(await pollUntil {
            state.hasAuthoritativeFirstPage && Set(state.rows.map(\.item)) == allMatches
        })

        var filters = HistorySearchFilters()
        filters.sourceApplication = "  com.example.Editor\n"
        filters.sourceMatch = .bundleIdentifier
        state.searchFilters = filters
        #expect(state.rows.isEmpty)
        #expect(state.hasActiveFilters)
        try #require(await pollUntil {
            state.hasAuthoritativeFirstPage && Set(state.rows.map(\.item)) == Set([first, last, old, next])
        })

        filters.dateRange = .custom
        filters.startDate = start.addingTimeInterval(3600)
        filters.endDate = start.addingTimeInterval(7200)
        state.searchFilters = filters
        #expect(state.rows.isEmpty)
        try #require(await pollUntil {
            state.hasAuthoritativeFirstPage && Set(state.rows.map(\.item)) == Set([first, last])
        })
        #expect(state.searchText == "^report-[0-9]+$")
        #expect(state.searchMode == .regexp)

        state.typeFilter = .text
        state.showsPinnedOnly = true
        try #require(await pollUntil {
            state.hasAuthoritativeFirstPage && state.rows.map(\.item) == [first]
        })
        state.clearFilters()
        #expect(!state.hasActiveFilters)
        #expect(state.typeFilter == .all)
        #expect(!state.showsPinnedOnly)
        #expect(state.searchText == "^report-[0-9]+$")
        #expect(state.searchMode == .regexp)
        try #require(await pollUntil {
            state.hasAuthoritativeFirstPage && Set(state.rows.map(\.item)) == allMatches
        })
        #expect(state.failure == nil)
    }

    @Test func metadataFiltersFindItemsOutsideTheLoadedPage() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 800_000_000))
        let nextDay = try #require(calendar.date(byAdding: .day, value: 1, to: start))
        let older = try await capture("older report", source: "com.example.Editor", at: start, in: history)
        for index in 0..<4 {
            _ = try await capture("recent report \(index)", source: "com.example.Browser",
                                  at: nextDay.addingTimeInterval(Double(index)), in: history)
        }
        let state = HistoryViewState(history: history, pageLimit: 2)
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.hasAuthoritativeFirstPage && state.rows.count == 2 })
        #expect(!state.rows.contains { $0.item == older })
        #expect(state.hasNextPage)

        var filters = HistorySearchFilters()
        filters.sourceApplication = "com.example.Editor"
        filters.sourceMatch = .bundleIdentifier
        filters.dateRange = .custom
        filters.startDate = start
        filters.endDate = start
        state.searchFilters = filters
        #expect(state.rows.isEmpty)
        try #require(await pollUntil {
            state.hasAuthoritativeFirstPage && state.rows.map(\.item) == [older]
        })
        #expect(!state.hasNextPage)
        #expect(state.displayedCount == 1)
        #expect(state.failure == nil)
    }

    @Test func filteredObservationUsesMostRecentCopyDateAndSource() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 800_000_000))
        let nextDay = try #require(calendar.date(byAdding: .day, value: 1, to: start))
        let item = try await capture("repeated report", source: "com.example.Editor", at: start, in: history)
        var filters = HistorySearchFilters()
        filters.sourceApplication = "com.example.Editor"
        filters.sourceMatch = .bundleIdentifier
        filters.dateRange = .custom
        filters.startDate = start
        filters.endDate = start
        let state = HistoryViewState(history: history)
        state.searchFilters = filters
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil {
            state.hasAuthoritativeFirstPage && state.rows.map(\.item) == [item]
        })

        _ = try await history.perform(.capture(ClipboardCapture(
            representations: [CapturedRepresentation(
                typeIdentifier: "public.utf8-plain-text", bytes: Data("repeated report".utf8)
            )],
            origin: .init(sourceApplication: "com.example.Browser", lineageHint: nil),
            observedAt: start.addingTimeInterval(1)
        )))
        try #require(await pollUntil { state.hasAuthoritativeFirstPage && state.rows.isEmpty })
        filters.sourceApplication = "com.example.Browser"
        state.searchFilters = filters
        try #require(await pollUntil {
            state.hasAuthoritativeFirstPage && state.rows.map(\.item) == [item]
        })

        _ = try await history.perform(.capture(ClipboardCapture(
            representations: [CapturedRepresentation(
                typeIdentifier: "public.utf8-plain-text", bytes: Data("repeated report".utf8)
            )],
            origin: .init(sourceApplication: "com.example.Browser", lineageHint: nil),
            observedAt: nextDay
        )))
        try #require(await pollUntil { state.hasAuthoritativeFirstPage && state.rows.isEmpty })
        #expect(!state.isLoadingFirstPage)
        state.clearFilters()
        try #require(await pollUntil {
            state.hasAuthoritativeFirstPage && state.rows.map(\.item) == [item]
        })
        #expect(state.rows.first?.lastCopiedAt == nextDay)
        #expect(state.rows.first?.lastSource == "com.example.Browser")
        #expect(state.rows.first?.copyCount == 3)
        #expect(state.failure == nil)
    }

    @Test func canonicallyEquivalentSourceDraftsReplaceLiteralSourceResults() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let composed = "com.example.é"
        let decomposed = "com.example.e\u{301}"
        let first = try await capture("composed source", source: composed, at: date, in: history)
        let second = try await capture("decomposed source", source: decomposed, at: date, in: history)
        let state = HistoryViewState(history: history)
        var filters = HistorySearchFilters()
        filters.sourceMatch = .bundleIdentifier
        filters.sourceApplication = composed
        state.searchFilters = filters
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil {
            state.hasAuthoritativeFirstPage && state.rows.map(\.item) == [first]
        })

        state.searchFilters.sourceApplication = decomposed
        #expect(state.rows.isEmpty)
        try #require(await pollUntil {
            state.hasAuthoritativeFirstPage && state.rows.map(\.item) == [second]
        })
        #expect(state.failure == nil)
    }

    @Test func invalidExpressionRetiresResultsImmediatelyAndRepairRestartsSearch() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let alpha = try await capture("alpha final", source: nil, at: date, in: history)
        let draft = try await capture("alpha draft", source: nil, at: date, in: history)
        let beta = try await capture("beta final", source: nil, at: date, in: history)
        let state = HistoryViewState(history: history)
        state.searchMode = .expression
        state.searchText = "alpha"
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil {
            state.hasAuthoritativeFirstPage && Set(state.rows.map(\.item)) == Set([alpha, draft])
        })

        state.searchText = "(alpha OR"
        #expect(state.expressionValidationError != nil)
        #expect(state.rows.isEmpty)
        #expect(!state.isLoadingFirstPage)
        #expect(!state.hasAuthoritativeFirstPage)
        #expect(!state.hasNextPage)
        #expect(state.failure == nil)
        let newer = try await capture("beta current", source: nil, at: date.addingTimeInterval(1), in: history)

        state.searchText = "(alpha OR beta) AND NOT draft"
        #expect(state.expressionValidationError == nil)
        #expect(state.isLoadingFirstPage)
        try #require(await pollUntil {
            state.hasAuthoritativeFirstPage && Set(state.rows.map(\.item)) == Set([alpha, beta, newer])
        })
        #expect(state.failure == nil)

        // Syntax belongs to expression mode. Literal search accepts the same
        // unfinished text, and Clear returns to unfiltered recent history.
        state.searchText = "(alpha OR"
        #expect(state.expressionValidationError != nil)
        state.searchMode = .exact
        #expect(state.expressionValidationError == nil)
        try #require(await pollUntil { state.hasAuthoritativeFirstPage && state.rows.isEmpty })
        state.clearSearch()
        try #require(await pollUntil { state.hasAuthoritativeFirstPage && state.rows.count == 4 })
        #expect(state.searchMode == .exact)
    }

    @Test func applicationNamesResolveAcrossExpressionPagesAndOrdinarySourceControls() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let resolver = SourceApplicationSearchResolver(applications: [
            .init(bundleID: "org.example.a", displayName: "Telegram Desktop"),
            .init(bundleID: "org.example.b", displayName: "Brave Browser"),
            .init(bundleID: "org.example.c", displayName: "Notes")
        ])
        var matching: [HistoryItemReference] = []
        for index in 0..<4 {
            matching.append(try await capture("ready report \(index)",
                source: index.isMultiple(of: 2) ? "org.example.a" : "org.example.b",
                at: date.addingTimeInterval(Double(index)), in: history))
        }
        _ = try await capture("draft report", source: "org.example.a", at: date.addingTimeInterval(4), in: history)
        _ = try await capture("unrelated source", source: "org.example.c", at: date.addingTimeInterval(5), in: history)
        let state = HistoryViewState(history: history, pageLimit: 2, searchSourceResolver: resolver)
        let query = "(source:Telegram OR source:Brave) AND NOT draft"
        state.searchMode = .expression
        state.searchText = query
        state.activate()
        defer { state.deactivate() }

        try #require(await pollUntil {
            state.hasAuthoritativeFirstPage && state.rows.map(\.item) == [matching[3], matching[2]]
        })
        #expect(state.searchText == query, "Resolving names preserves the editable expression")
        #expect(state.unresolvedSearchSources.isEmpty)
        #expect(state.hasNextPage)
        state.loadNextPage()
        try #require(await pollUntil { !state.isLoadingPage && state.rows.count == 4 })
        #expect(state.rows.map(\.item) == Array(matching.reversed()))
        #expect(!state.hasNextPage)
        #expect(state.failure == nil, "Pagination must reuse the resolved expression's cursor query")
        #expect(state.searchText == query)

        var filters = HistorySearchFilters()
        filters.sourceApplication = "TELEGRAM"
        filters.sourceMatch = .applicationName
        state.searchFilters = filters
        try #require(await pollUntil {
            state.hasAuthoritativeFirstPage && state.rows.map(\.item) == [matching[2], matching[0]]
        })
        #expect(state.searchText == query)
        #expect(state.unresolvedSearchSources.isEmpty)
        #expect(state.failure == nil)
    }

    @Test func unknownApplicationNameExplainsTheConditionAndCanBeCorrected() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let item = try await capture("available report", source: "org.example.a",
                                     at: Date(timeIntervalSinceReferenceDate: 800_000_000), in: history)
        let resolver = SourceApplicationSearchResolver(applications: [
            .init(bundleID: "org.example.a", displayName: "Telegram")
        ])
        let state = HistoryViewState(history: history, searchSourceResolver: resolver)
        state.searchFilters.sourceApplication = "Missing Messenger"
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil {
            state.unresolvedSearchSources == ["Missing Messenger"] && !state.isLoadingFirstPage
        })
        #expect(state.rows.isEmpty)
        #expect(!state.hasAuthoritativeFirstPage)
        #expect(state.expressionValidationError == nil)
        #expect(state.failure == nil)
        #expect(HistorySearchCopy.issue(for: state) != nil)

        state.searchFilters.sourceApplication = "Telegram"
        try #require(await pollUntil {
            state.hasAuthoritativeFirstPage && state.rows.map(\.item) == [item]
        })
        #expect(state.unresolvedSearchSources.isEmpty)
        #expect(HistorySearchCopy.issue(for: state) == nil)

        state.clearFilters()
        state.searchMode = .expression
        state.searchText = "source:NoSuchApplication"
        try #require(await pollUntil {
            state.unresolvedSearchSources == ["NoSuchApplication"] && !state.isLoadingFirstPage
        })
        #expect(state.rows.isEmpty)
        #expect(state.expressionValidationError == nil)
        #expect(state.failure == nil)
        #expect(state.searchText == "source:NoSuchApplication")
    }

    @Test(arguments: [(3, 8, 23), (11, 1, 25)])
    func todayAndYesterdayUseCalendarBoundariesAcrossDaylightSaving(
        month: Int, day: Int, hours: Int
    ) throws {
        let calendar = try calendarInLosAngeles()
        let start = try localDate(month: month, day: day, hour: 0, calendar: calendar)
        let noon = try localDate(month: month, day: day, hour: 12, calendar: calendar)
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: start))
        var filters = HistorySearchFilters()
        filters.dateRange = .today
        let today = filters.dateBounds(now: noon, calendar: calendar)
        #expect(today.after == start)
        #expect(today.before == tomorrow)
        #expect(tomorrow.timeIntervalSince(start) == Double(hours * 3600))

        filters.dateRange = .yesterday
        let yesterday = filters.dateBounds(now: tomorrow.addingTimeInterval(3600), calendar: calendar)
        #expect(yesterday.after == start)
        #expect(yesterday.before == tomorrow)
    }

    @Test func customDatesIncludeBothSelectedDaysAndRejectReversedDays() throws {
        let calendar = try calendarInLosAngeles()
        var filters = HistorySearchFilters()
        filters.dateRange = .custom
        filters.startDate = try localDate(month: 3, day: 7, hour: 18, calendar: calendar)
        filters.endDate = try localDate(month: 3, day: 8, hour: 9, calendar: calendar)
        let bounds = filters.dateBounds(now: filters.endDate, calendar: calendar)
        #expect(bounds.after == (try localDate(month: 3, day: 7, hour: 0, calendar: calendar)))
        #expect(bounds.before == (try localDate(month: 3, day: 9, hour: 0, calendar: calendar)))
        #expect(filters.hasValidDates(calendar: calendar))

        filters.startDate = try localDate(month: 3, day: 8, hour: 18, calendar: calendar)
        #expect(filters.hasValidDates(calendar: calendar), "Times within one selected date do not reverse the date range")
        filters.startDate = try localDate(month: 3, day: 9, hour: 0, calendar: calendar)
        #expect(!filters.hasValidDates(calendar: calendar))
    }

    @Test func rollingRangesIncludeTodayAndWhitespaceSourceDoesNotActivateFiltering() throws {
        let calendar = try calendarInLosAngeles()
        let now = try localDate(month: 3, day: 10, hour: 12, calendar: calendar)
        var filters = HistorySearchFilters()
        filters.sourceApplication = " \n\t"
        #expect(filters.source == nil)
        #expect(!filters.isActive)
        let unrestricted = filters.dateBounds(now: now, calendar: calendar)
        #expect(unrestricted.after == nil)
        #expect(unrestricted.before == nil)

        filters.dateRange = .lastSevenDays
        let week = filters.dateBounds(now: now, calendar: calendar)
        #expect(week.after == (try localDate(month: 3, day: 4, hour: 0, calendar: calendar)))
        #expect(week.before == (try localDate(month: 3, day: 11, hour: 0, calendar: calendar)))
        filters.dateRange = .lastThirtyDays
        let month = filters.dateBounds(now: now, calendar: calendar)
        #expect(month.after == (try localDate(month: 2, day: 9, hour: 0, calendar: calendar)))
        #expect(month.before == week.before)
    }

    private func capture(
        _ text: String, source: String?, at date: Date, in history: SQLiteHistory
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: [CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(text.utf8))],
            origin: .init(sourceApplication: source, lineageHint: nil), observedAt: date
        )))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw FixtureFailure.expectedInsertion
        }
        return item
    }

    private func calendarInLosAngeles() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        return calendar
    }

    private func localDate(month: Int, day: Int, hour: Int, calendar: Calendar) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour)))
    }

    private enum FixtureFailure: Error { case expectedInsertion }
}
