/// Expression search evaluates the retained history before pagination, using
/// the same SQLite snapshots and default ordering as ordinary browsing.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct SearchExpressionStorageTests {
    @Test func booleanPrecedenceGroupingAndImplicitAndUseWholeRowContent() async throws {
        let history = try await WSSupport.makeHistory()
        let alpha = try await capture("alpha alone", in: history, at: 1)
        let betaGamma = try await capture("beta gamma", in: history, at: 2)
        let beta = try await capture("beta alone", in: history, at: 3)
        let alphaGamma = try await capture("alpha gamma", in: history, at: 4)
        let bodyMatch = try await capture("unrelated title\nbeta and gamma detail", in: history, at: 5)

        #expect(try await ids("alpha OR beta AND gamma", in: history) == [bodyMatch, alphaGamma, betaGamma, alpha])
        #expect(try await ids("(alpha OR beta) AND gamma", in: history) == [bodyMatch, alphaGamma, betaGamma])
        #expect(try await ids("alpha OR beta AND NOT gamma", in: history) == [alphaGamma, beta, alpha])
        #expect(try await ids("(alpha OR beta) gamma", in: history) == [bodyMatch, alphaGamma, betaGamma])
        #expect(try await ids("not (alpha or beta)", in: history).isEmpty)

        let page = try await search("beta AND gamma", in: history)
        let bodyRow = try #require(page.rows.first { $0.item.id == bodyMatch })
        let presentation = try #require(bodyRow.search)
        let snippet = try #require(presentation.snippet)
        #expect(!presentation.matchedRanges.isEmpty)
        for range in presentation.matchedRanges {
            let match = WS17SearchModesTests.substring(snippet, utf16Range: range).lowercased()
            #expect(match == "beta" || match == "gamma")
        }
    }

    @Test func quotedPhrasesAndReservedWordsStayLiteralWhileExactModeIsUnchanged() async throws {
        let history = try await WSSupport.makeHistory()
        let phrase = try await capture("alpha AND beta", in: history, at: 1)
        _ = try await capture("alpha separated beta", in: history, at: 2)
        let punctuation = try await capture(#"open (draft) at C:\notes"#, in: history, at: 3)

        #expect(try await ids(#""alpha AND beta""#, in: history) == [phrase])
        #expect(try await ids(#""AND""#, in: history) == [phrase])
        #expect(try await ids(HistorySearchExpression.quoted(#"open (draft) at C:\notes"#), in: history) == [punctuation])
        let exact = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: "alpha AND beta", mode: .exact), limit: 10
        ))
        #expect(exact.rows.map(\.item.id) == [phrase])
        let expression = try await ids("alpha AND beta", in: history)
        #expect(expression.count == 2)
    }

    @Test func dateFieldsUseUTCDayBoundariesAndInclusiveDateRange() async throws {
        let history = try await WSSupport.makeHistory()
        let start = try utcDate(2026, 9, 26)
        let before = try await capture("before start", in: history, date: start.addingTimeInterval(-0.001))
        let first = try await capture("at start", in: history, date: start)
        let last = try await capture("last instant", in: history, date: start.addingTimeInterval(86_400 - 0.001))
        let nextDay = try await capture("next midnight", in: history, date: start.addingTimeInterval(86_400))
        let afterRange = try await capture("after range", in: history, date: start.addingTimeInterval(172_800))

        #expect(try await ids("date:2026-09-26", in: history) == [last, first])
        #expect(try await ids("after:2026-09-26 before:2026-09-27", in: history) == [last, first])
        #expect(try await ids("date:2026-09-26..2026-09-27", in: history) == [nextDay, last, first])
        #expect(try await ids("before:2026-09-26 OR after:2026-09-28", in: history) == [afterRange, before])
    }

    @Test func applicationAndDateReferToMostRecentCopyAfterCoalescing() async throws {
        let history = try await WSSupport.makeHistory()
        let firstDay = try utcDate(2026, 9, 25)
        let item = try await capture("copied twice", in: history, date: firstDay, source: "com.apple.Safari")
        _ = try await history.perform(.capture(WSSupport.textCapture(
            "copied twice", observedAt: firstDay.addingTimeInterval(86_400), source: "com.apple.Notes"
        )))

        #expect(try await ids("app:safari", in: history).isEmpty)
        #expect(try await ids("date:2026-09-25", in: history).isEmpty)
        #expect(try await ids("app:NOTES AND date:2026-09-26", in: history) == [item])
        #expect(try await ids(#"app:"com.apple.Notes" NOT app:safari"#, in: history) == [item])
        let page = try await search("app:notes", in: history)
        #expect(page.rows.first?.search == nil)
    }

    @Test func resolvedApplicationNamesMatchExactSourceIDsInsideBooleanExpressions() async throws {
        let history = try await WSSupport.makeHistory()
        let application = try await capture("primary application", in: history, at: 1, source: "com.example.notes")
        let companion = try await capture("companion application", in: history, at: 2, source: "com.example.notes.helper")
        let otherApplication = try await capture("other application", in: history, at: 3, source: "com.example.journal")
        let resolved = try HistorySearchExpression.parse("app:notebooks").replacingApplicationTerms { term in
            term == "notebooks" ? ["com.example.notes", "com.example.journal"] : nil
        }
        #expect(try await ids(resolved.serialized, in: history) == [otherApplication, application])
        #expect(try await ids("source-id:COM.EXAMPLE.NOTES", in: history).isEmpty)
        #expect(try await ids("NOT (\(resolved.serialized))", in: history) == [companion])

        let unavailable = try HistorySearchExpression.parse("app:uninstalled").replacingApplicationTerms { _ in [] }
        #expect(try await ids(unavailable.serialized, in: history).isEmpty)
        #expect(try await ids("NOT (\(unavailable.serialized))", in: history).count == 3)
    }

    @Test func metadataOnlyExpressionsIncludeImagesAndUnknownApplications() async throws {
        let history = try await WSSupport.makeHistory()
        let text = try await capture("a plain text note", in: history, at: 1, source: "com.apple.Notes")
        let image = try await capture(ClipboardCapture(
            representations: [CapturedRepresentation(typeIdentifier: "public.png", bytes: Data([0x89, 0x50, 0x4e, 0x47]))],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 2)
        ), in: history)
        let link = try await capture(ClipboardCapture(
            representations: [CapturedRepresentation(typeIdentifier: "public.url", bytes: Data("https://example.test".utf8))],
            origin: CopyOriginObservation(sourceApplication: "com.apple.Safari", lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 3)
        ), in: history)
        _ = try await history.perform(.placePinned(image, at: .last))

        #expect(try await ids("type:images AND is:pinned", in: history) == [image])
        #expect(try await ids("NOT app:safari", in: history) == [image, text])
        #expect(try await ids("NOT source-id:com.apple.Safari", in: history) == [image, text])
        #expect(try await ids("type:links OR type:images", in: history) == [image, link])
        let page = try await search("type:all", in: history)
        #expect(page.rows.map(\.item.id) == [image, link, text])
        #expect(page.rows.allSatisfy { $0.search == nil })
    }

    @Test func metadataOrBranchesDoNotRequireTheTextBranchesCandidatePostings() async throws {
        let history = try await WSSupport.makeHistory()
        let text = try await capture("needle appears here", in: history, at: 1, source: "com.apple.Safari")
        let metadata = try await capture("unrelated content", in: history, at: 2, source: "com.apple.Notes")
        _ = try await capture("unrelated exclusion", in: history, at: 3, source: "com.apple.Safari")
        #expect(try await ids("needle OR app:notes", in: history) == [metadata, text])
        #expect(try await ids("app:notes OR needle", in: history) == [metadata, text])
        #expect(try await ids("needle AND app:safari", in: history) == [text])
        #expect(try await ids("NOT (needle OR app:safari)", in: history) == [metadata])
    }

    @Test func expressionAndVisibleFiltersIntersectBeforePagination() async throws {
        let history = try await WSSupport.makeHistory()
        let start = try utcDate(2026, 9, 26)
        let expected = try await capture("target note", in: history, date: start, source: "com.apple.Notes")
        _ = try await history.perform(.placePinned(expected, at: .last))
        _ = try await capture("newer note", in: history, date: start.addingTimeInterval(1), source: "com.apple.Notes")
        _ = try await capture("newer browser", in: history, date: start.addingTimeInterval(2), source: "com.apple.Safari")
        _ = try await capture("outside dates", in: history, date: start.addingTimeInterval(86_400), source: "com.apple.Notes")
        let filter = HistoryFilter(
            type: .text, pinnedOnly: true, sourceApplication: "NOTES",
            copiedAfter: start, copiedBefore: start.addingTimeInterval(86_400)
        )
        let page = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: "app:notes OR app:safari", mode: .expression), limit: 1, filter: filter
        ))
        #expect(page.rows.map(\.item.id) == [expected])
        #expect(page.next == nil)
    }

    @Test func expressionPagesTraverseBothDirectionsAndBindTheWholeQuery() async throws {
        let history = try await WSSupport.makeHistory()
        var matches: [HistoryItemID] = []
        for index in 0..<10 {
            let id = try await capture(
                "page item \(index)", in: history, at: Double(index),
                source: index.isMultiple(of: 2) ? "com.example.keep" : "com.example.skip"
            )
            if index.isMultiple(of: 2) { matches.append(id) }
        }
        let pinned = try #require(matches.first)
        _ = try await history.perform(.placePinned(pinned, at: .last))
        let query = "app:keep AND NOT discarded"
        let first = try await search(query, in: history, limit: 2)
        let next = try #require(first.next)
        let second = try await search(query, in: history, limit: 2, cursor: next)
        let third = try await search(query, in: history, limit: 2, cursor: #require(second.next))
        let actual = (first.rows + second.rows + third.rows).map(\.item.id)
        #expect(actual == [pinned] + Array(matches.dropFirst().reversed()))
        #expect(Set(actual).count == 5)
        #expect(third.next == nil)
        #expect(first.previous == nil)
        #expect(first.position == second.position && second.position == third.position)
        let backward = try await search(query, in: history, limit: 2, cursor: #require(third.previous))
        #expect(backward.rows == second.rows)

        await #expect(throws: HistoryFailure.snapshotExpired(current: first.position)) {
            _ = try await self.search("app:keep OR discarded", in: history, limit: 2, cursor: next)
        }
        await #expect(throws: HistoryFailure.snapshotExpired(current: first.position)) {
            _ = try await history.browse(HistoryBrowseRequest(
                kind: .search(text: query, mode: .exact), limit: 2, cursor: next
            ))
        }
    }

    @Test func sourceAndDateFiltersAgreeAcrossRecentAndEverySearchMode() async throws {
        let history = try await WSSupport.makeHistory()
        let first = try await capture("note first", in: history, at: 10, source: "com.apple.Notes")
        let last = try await capture("note last", in: history, at: 19, source: "com.apple.Notes")
        _ = try await capture("note too early", in: history, at: 9, source: "com.apple.Notes")
        _ = try await capture("note boundary", in: history, at: 20, source: "com.apple.Notes")
        _ = try await capture("note browser", in: history, at: 15, source: "com.apple.Safari")
        _ = try await capture("note unknown", in: history, at: 16)
        let filter = HistoryFilter(
            sourceApplication: "NoTeS", copiedAfter: Date(timeIntervalSinceReferenceDate: 10),
            copiedBefore: Date(timeIntervalSinceReferenceDate: 20)
        )
        let kinds: [HistoryBrowseKind] = [
            .recent, .search(text: "note", mode: .exact), .search(text: "note", mode: .regexp),
            .search(text: "note", mode: .fuzzy), .search(text: "note", mode: .expression),
        ]
        for kind in kinds {
            let page = try await history.browse(HistoryBrowseRequest(kind: kind, limit: 10, filter: filter))
            #expect(page.rows.map(\.item.id) == [last, first])
            #expect(page.next == nil)
        }
    }

    @Test func expressionCursorBindsSourceAndBothDateBoundaries() async throws {
        let history = try await WSSupport.makeHistory()
        for index in 1...4 {
            _ = try await capture("note \(index)", in: history, at: Double(index), source: "com.example.notes")
        }
        let lower = Date(timeIntervalSinceReferenceDate: 0)
        let upper = Date(timeIntervalSinceReferenceDate: 10)
        let kind = HistoryBrowseKind.search(text: "note", mode: .expression)
        let filter = HistoryFilter(sourceApplication: "notes", copiedAfter: lower, copiedBefore: upper)
        let first = try await history.browse(HistoryBrowseRequest(kind: kind, limit: 2, filter: filter))
        let cursor = try #require(first.next)
        // These changes happen to retain the same fixture rows. The cursor
        // must still expire because its complete query shape has changed.
        let changedFilters = [
            HistoryFilter(sourceApplication: "example", copiedAfter: lower, copiedBefore: upper),
            HistoryFilter(sourceApplication: "notes", copiedAfter: lower.addingTimeInterval(-1), copiedBefore: upper),
            HistoryFilter(sourceApplication: "notes", copiedAfter: lower, copiedBefore: upper.addingTimeInterval(1)),
        ]
        for changed in changedFilters {
            await #expect(throws: HistoryFailure.snapshotExpired(current: first.position)) {
                _ = try await history.browse(HistoryBrowseRequest(kind: kind, limit: 2, cursor: cursor, filter: changed))
            }
        }
    }

    @Test(arguments: ["", " \t\n "])
    func emptyExpressionKeepsRecentOrderAndHasNoHighlights(query: String) async throws {
        let history = try await WSSupport.makeHistory()
        _ = try await capture("ordinary note", in: history, at: 1)
        _ = try await capture("newer note", in: history, at: 2)
        let recent = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 1))
        let expression = try await search(query, in: history, limit: 1)
        #expect(expression.rows == recent.rows)
        #expect(expression.position == recent.position)
        let second = try await search(query, in: history, limit: 1, cursor: #require(expression.next))
        #expect(second.rows.map(\.title) == ["ordinary note"])
        #expect(second.rows.allSatisfy { $0.search == nil })
        #expect(second.next == nil)
    }

    private func search(
        _ query: String, in history: SQLiteHistory, limit: Int = 50, cursor: HistoryPageCursor? = nil
    ) async throws -> HistoryPage {
        try await history.browse(HistoryBrowseRequest(
            kind: .search(text: query, mode: .expression), limit: limit, cursor: cursor
        ))
    }

    private func ids(_ query: String, in history: SQLiteHistory) async throws -> [HistoryItemID] {
        try await search(query, in: history).rows.map(\.item.id)
    }

    private func capture(
        _ text: String, in history: SQLiteHistory, at seconds: Double, source: String? = nil
    ) async throws -> HistoryItemID {
        try await capture(text, in: history, date: Date(timeIntervalSinceReferenceDate: seconds), source: source)
    }

    private func capture(
        _ text: String, in history: SQLiteHistory, date: Date, source: String? = nil
    ) async throws -> HistoryItemID {
        try await capture(WSSupport.textCapture(text, observedAt: date, source: source), in: history)
    }

    private func capture(_ value: ClipboardCapture, in history: SQLiteHistory) async throws -> HistoryItemID {
        let receipt = try await history.perform(.capture(value))
        guard case .committed(let commit) = receipt, case .inserted(let reference) = commit.outcome else {
            Issue.record("Expected a distinct inserted search fixture")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return reference.id
    }

    private func utcDate(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        return try #require(calendar.date(from: DateComponents(year: year, month: month, day: day)))
    }
}
