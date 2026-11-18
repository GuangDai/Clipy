import Foundation
@testable import HistoryCore
@testable import HistoryStorage
@testable import ClipyApp
import Testing

/// Metadata controls compose with the real matcher and its observation;
/// calendar assertions cover local days whose lengths are not 24 hours.
@MainActor
struct HistorySearchFilterTests {
    @Test(arguments: [
        (SearchMode.fuzzy, "meting", "meeting final"),
        (.exact, "meeting", "meeting final"),
        (.regexp, "^meeting final$", "meeting final"),
        (.regexp, #"\$\d+$"#, "meeting $20"),
        (.regexp, "^report[ $]$", "report$")
    ])
    func outsideTextKeepsItsModeWhileConditionsMatchAnOlderCopySource(
        mode: SearchMode, literal: String, content: String
    ) async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let target = try await capture(content, source: "org.example.old", at: date, in: history)
        _ = try await history.perform(.capture(ClipboardCapture(
            representations: [.init(typeIdentifier: "public.utf8-plain-text", bytes: Data(content.utf8))],
            origin: .init(sourceApplication: "org.example.new", lineageHint: nil), observedAt: date.addingTimeInterval(1)
        )))
        _ = try await capture("meeting elsewhere", source: "org.example.other", at: date, in: history)
        _ = try await capture("unrelated", source: "org.example.old", at: date, in: history)
        let state = HistoryViewState(history: history)
        state.searchMode = mode
        state.searchText = literal + " $source-id:org.example.old$"
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil {
            state.hasAuthoritativeFirstPage && state.rows.map(\.item) == [target]
        })
        #expect(state.rows.first?.lastSource == "org.example.new")
        #expect(state.rows.first?.search != nil)
        #expect(state.searchMode == mode)
        #expect(state.failure == nil)
    }

    @Test func regexpCharacterClassAndExplicitConditionFindTheCorrectRows() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let dollar = try await capture("report$", source: "org.example.editor", at: date, in: history)
        let bracket = try await capture("report]", source: "org.example.browser", at: date, in: history)
        _ = try await capture("reporta", source: "org.example.editor", at: date, in: history)

        let state = HistoryViewState(history: history)
        let pattern = #"^report[\] $]$"#
        state.searchMode = .regexp
        state.searchText = pattern
        state.activate()
        defer { state.deactivate() }

        try #require(await pollUntil { state.hasAuthoritativeFirstPage })
        #expect(Set(state.rows.map(\.item)) == Set([dollar, bracket]))

        let source = "source-id:org.example.editor"
        let input = HistorySearchCompletionInput(text: pattern, selection: NSRange(location: 2, length: 0), isComposing: false)
        let context = try #require(HistorySearchCompletionEngine.context(for: input, explicit: true, mode: .regexp))
        let candidate = HistorySearchCompletionEngine.candidate(id: "editor", title: "Editor", term: source, context: context)
        state.searchText = (pattern as NSString).replacingCharacters(in: candidate.replacementRange, with: candidate.insertion)

        try #require(await pollUntil { state.hasAuthoritativeFirstPage })
        #expect(state.rows.map(\.item) == [dollar])
        #expect(state.rows.first?.search?.matchedRanges == [.init(location: 0, length: 7)])
        #expect(state.failure == nil)
    }

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

    @Test func filteredObservationUsesMostRecentDateAndEveryRetainedSource() async throws {
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
        try #require(await pollUntil {
            state.hasAuthoritativeFirstPage && state.rows.map(\.item) == [item]
                && state.rows.first?.copyCount == 2 && state.rows.first?.lastSource == "com.example.Browser"
        })
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
        state.searchText = "$alpha$"
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil {
            state.hasAuthoritativeFirstPage && Set(state.rows.map(\.item)) == Set([alpha, draft])
        })

        state.searchText = "$(alpha OR$"
        #expect(state.expressionValidationError != nil)
        #expect(state.rows.isEmpty)
        #expect(!state.isLoadingFirstPage)
        #expect(!state.hasAuthoritativeFirstPage)
        #expect(!state.hasNextPage)
        #expect(state.failure == nil)
        let newer = try await capture("beta current", source: nil, at: date.addingTimeInterval(1), in: history)

        state.searchText = "$(alpha OR beta) AND NOT draft$"
        #expect(state.expressionValidationError == nil)
        #expect(state.isLoadingFirstPage)
        try #require(await pollUntil {
            state.hasAuthoritativeFirstPage && Set(state.rows.map(\.item)) == Set([alpha, beta, newer])
        })
        #expect(state.failure == nil)

        // Closed conditions report syntax errors in every matching mode.
        // Bare syntax remains ordinary text, and Clear returns to recent history.
        state.searchText = "$(alpha OR$"
        #expect(state.expressionValidationError != nil)
        state.searchMode = .exact
        #expect(state.expressionValidationError != nil)
        state.searchText = "(alpha OR"
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
        let query = "$(source:Telegram OR source:Brave) AND NOT draft$"
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
        state.searchText = "$source:NoSuchApplication$"
        try #require(await pollUntil {
            state.hasAuthoritativeFirstPage && state.unresolvedSearchSources == ["NoSuchApplication"]
        })
        #expect(state.rows.isEmpty)
        #expect(state.expressionValidationError == nil)
        #expect(state.failure == nil)
        #expect(state.searchText == "$source:NoSuchApplication$")
    }

    @Test func unknownApplicationNameOnlyMakesItsOwnExpressionBranchFalse() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let report = try await capture("available report", source: "org.example.retired", at: date, in: history)
        let note = try await capture("notebook", source: "org.example.notes", at: date.addingTimeInterval(1), in: history)
        let resolver = SourceApplicationSearchResolver(applications: [
            .init(bundleID: "org.example.notes", displayName: "Example Notes")
        ])
        let state = HistoryViewState(history: history, searchSourceResolver: resolver)
        state.activate()
        defer { state.deactivate() }

        let cases: [(condition: String, expected: Set<HistoryItemReference>)] = [
            ("source:Missing AND report", []),
            ("source:Missing OR report", [report]),
            ("NOT source:Missing", [note, report]),
            ("source:Missing OR source-id:org.example.retired OR source:Notes", [note, report]),
        ]
        for (condition, expected) in cases {
            state.searchText = "$" + condition + "$"
            try #require(await pollUntil { state.hasAuthoritativeFirstPage })
            #expect(Set(state.rows.map(\.item)) == expected)
            #expect(state.unresolvedSearchSources == ["Missing"])
            #expect(HistorySearchCopy.issue(for: state) != nil)
            #expect(state.failure == nil)
        }
    }

    @Test func activeDateFilterReplacesItsPageAtALocalDayBoundaryAfterAMidnightShift() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Sao_Paulo"))
        let noon = try #require(calendar.date(from: DateComponents(year: 2018, month: 11, day: 4, hour: 12)))
        let firstValidTime = calendar.startOfDay(for: noon)
        #expect(calendar.component(.hour, from: firstValidTime) == 1)
        let midnight = try #require(calendar.date(from: DateComponents(year: 2018, month: 11, day: 5, hour: 0)))
        _ = try await capture("previous day starts", source: nil, at: firstValidTime, in: history)
        let beforeMidnight = try await capture("previous day ends", source: nil, at: midnight.addingTimeInterval(-1), in: history)
        let atMidnight = try await capture("new day begins", source: nil, at: midnight, in: history)

        let state = HistoryViewState(history: history, pageLimit: 1)
        state.searchFilters.dateRange = .today
        state.activate()
        defer { state.deactivate() }

        state.refreshDateFiltersIfNeeded(now: noon, calendar: calendar)
        try #require(await pollUntil { state.hasAuthoritativeFirstPage })
        #expect(state.rows.map(\.item) == [beforeMidnight])
        #expect(state.hasNextPage)

        state.refreshDateFiltersIfNeeded(now: midnight, calendar: calendar)
        try #require(await pollUntil { state.hasAuthoritativeFirstPage })
        #expect(state.rows.map(\.item) == [atMidnight])
        #expect(!state.hasNextPage)
        #expect(state.failure == nil)
        #expect(!state.didLoseReadingPosition)
        #expect(state.restoredReadingItemID == nil)
    }

    @Test func passiveDateRefreshKeepsAMatchingReadingRowWithoutRestoringAStoredBookmark() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let calendar = HistorySearchFilters.gregorianCalendar(in: try #require(TimeZone(secondsFromGMT: 0)))
        let nextDay = try #require(calendar.date(from: DateComponents(year: 2025, month: 6, day: 2)))
        let justBefore = nextDay.addingTimeInterval(-1)
        let readingRow = try await capture("before midnight", source: nil, at: justBefore, in: history)
        _ = try await capture("after midnight", source: nil, at: nextDay, in: history)

        let state = HistoryViewState(history: history, pageLimit: 1)
        state.searchFilters.dateRange = .lastSevenDays
        defer { state.deactivate() }
        state.refreshDateFiltersIfNeeded(now: justBefore, calendar: calendar)
        try #require(await pollUntil { state.hasAuthoritativeFirstPage && state.rows.map(\.item) == [readingRow] })
        state.recordReadingPosition(visibleRowIDs: [readingRow.id])

        state.refreshDateFiltersIfNeeded(now: nextDay, calendar: calendar)
        #expect(state.isPreservingReadingPosition)
        try #require(await pollUntil { state.hasAuthoritativeFirstPage })
        #expect(state.rows.map(\.item) == [readingRow])
        #expect(state.hasPreviousPage)
        #expect(state.restoredReadingItemID == nil)
        #expect(!state.didLoseReadingPosition)
    }

    @Test func liveCustomDayDoesNotMatchAnotherDayWhenTheTimeZoneSkippedIt() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let utc = HistorySearchFilters.gregorianCalendar(in: try #require(TimeZone(secondsFromGMT: 0)))
        let apia = HistorySearchFilters.gregorianCalendar(in: try #require(TimeZone(identifier: "Pacific/Apia")))
        let selected = try #require(utc.date(from: DateComponents(year: 2011, month: 12, day: 30)))
        let item = try await capture("December 30 in UTC", source: nil, at: selected, in: history)

        let state = HistoryViewState(history: history)
        var filters = HistorySearchFilters()
        filters.dateRange = .custom
        filters.startDate = selected
        filters.endDate = selected
        filters.dateSelectionTimeZone = utc.timeZone
        state.searchFilters = filters
        defer { state.deactivate() }
        state.refreshDateFiltersIfNeeded(now: selected, calendar: utc)
        try #require(await pollUntil { state.hasAuthoritativeFirstPage && state.rows.map(\.item) == [item] })

        state.refreshDateFiltersIfNeeded(now: selected, calendar: apia)
        #expect(state.hasInvalidDateFilter)
        #expect(HistorySearchCopy.issue(for: state) != nil)
        #expect(state.rowsForPresentation.isEmpty)
        #expect(!state.isLoadingFirstPage)
        #expect(state.displayedRow(for: item.id) == nil)

        state.refreshDateFiltersIfNeeded(now: selected, calendar: utc)
        try #require(await pollUntil { state.hasAuthoritativeFirstPage })
        #expect(state.rows.map(\.item) == [item])
        #expect(!state.hasInvalidDateFilter)
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
