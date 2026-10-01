import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct ConditionalSearchTests {
    @Test(arguments: [("alpHx", SearchMode.fuzzy), ("alpha", .exact), ("^alpha", .regexp)], HistorySortOrder.allCases)
    func independentConditionsPreserveLiteralModeHighlightsAndAdjacentPages(
        query: (String, SearchMode), sortOrder: HistorySortOrder
    ) async throws {
        let history = try await WSSupport.makeHistory()
        for index in 0..<8 {
            let text = index == 0 ? "alphx best fuzzy score" : "alpha \(index)"
            _ = try await copy(text, source: "app.old", at: index * 2, in: history)
            _ = try await copy(text, source: "app.new", at: index * 2 + 1, in: history)
        }
        _ = try await copy("alpha excluded", source: "app.new", at: 100, in: history)
        let condition = try HistorySearchExpression.parse("source-id:app.old AND NOT source-id:app.missing")
        let kind = HistoryBrowseKind.search(text: query.0, mode: query.1)
        let baseline = try await history.browse(.init(kind: kind, limit: 100,
            filter: .init(sourceApplicationIDs: ["app.old"]), sortOrder: sortOrder))
        try #require(baseline.rows.count >= 7)
        if query.1 == .fuzzy, sortOrder == .automatic {
            #expect(baseline.rows.first?.title == "alphx best fuzzy score")
        }
        #expect(baseline.rows.allSatisfy { $0.search?.matchedRanges.isEmpty == false })
        let first = try await history.browse(.init(kind: kind, limit: 3, sortOrder: sortOrder, conditionExpression: condition))
        #expect(first.rows == Array(baseline.rows.prefix(3)))
        let forward = try #require(first.next)
        let second = try await history.browse(.init(kind: kind, limit: 3, cursor: forward,
                                                   sortOrder: sortOrder, conditionExpression: condition))
        #expect(second.rows == Array(baseline.rows.dropFirst(3).prefix(3)))
        let backward = try #require(second.previous)
        let restored = try await history.browse(.init(kind: kind, limit: 3, cursor: backward,
                                                     sortOrder: sortOrder, conditionExpression: condition))
        #expect(restored.rows == first.rows)
        let target = baseline.rows[4].item.id
        let located = try await history.browse(.init(kind: kind, limit: 3, sortOrder: sortOrder,
                                                    startAround: target, conditionExpression: condition))
        #expect(located.rows == Array(baseline.rows.dropFirst(4).prefix(3)))
        await #expect(throws: HistoryFailure.snapshotExpired(current: first.position)) {
            try await history.browse(.init(kind: kind, limit: 3, cursor: forward, sortOrder: sortOrder,
                                          conditionExpression: HistorySearchExpression.parse("source-id:app.new")))
        }
    }

    @Test func aPureConditionUsesTheOriginalRequestShapeAndDoesNotReadBodies() async throws {
        let history = try await WSSupport.makeHistory()
        var retained: [HistoryItemReference] = []
        for index in 0..<4 {
            retained.append(try await copy("note \(index)", source: "app.old", at: index, in: history))
        }
        let condition = try HistorySearchExpression.parse("source-id:app.old")
        try await history.authority.withTestDatabase { authority in
            try authority.database.execute("UPDATE history_items SET searchBodyUTF8=X'FF'")
        }
        let first = try await history.browse(.init(kind: .recent, limit: 2, conditionExpression: condition))
        #expect(first.rows.map(\.item) == Array(retained.reversed().prefix(2)))
        #expect(first.rows.allSatisfy { $0.search == nil })
        let next = try #require(first.next)
        let second = try await history.browse(.init(kind: .recent, limit: 2, cursor: next, conditionExpression: condition))
        #expect(second.rows.map(\.item) == Array(retained.prefix(2).reversed()))
        #expect(second.next == nil)
        let back = try #require(second.previous)
        #expect(try await history.browse(.init(kind: .recent, limit: 2, cursor: back, conditionExpression: condition)).rows == first.rows)
        // Empty outer text can use the same condition while preserving its
        // original empty-search cursor shape rather than bypassing the DSL.
        let emptySearch = try await history.browse(.init(kind: .search(text: "", mode: .fuzzy), limit: 10,
                                                        conditionExpression: condition))
        #expect(emptySearch.rows == first.rows + second.rows)
        let stream = await history.observe(.init(kind: .recent, limit: 2, conditionExpression: condition))
        var iterator = stream.makeAsyncIterator()
        let observed = try #require(try await iterator.next())
        #expect(observed.rows == first.rows)
    }

    @Test func textInsideTheIndependentConditionStillUsesItsBooleanMatcher() async throws {
        let history = try await WSSupport.makeHistory()
        let kept = try await copy("alpha one", source: "app.old", at: 1, in: history)
        _ = try await copy("alpha two", source: "app.old", at: 2, in: history)
        let condition = try HistorySearchExpression.parse("one AND NOT two")
        let page = try await history.browse(.init(kind: .search(text: "alpHx", mode: .fuzzy), limit: 10,
                                                 conditionExpression: condition))
        #expect(page.rows.map(\.item) == [kept])
        #expect(page.rows.first?.search?.matchedRanges.isEmpty == false)
        let conditionOnly = try await history.browse(.init(kind: .recent, limit: 10, conditionExpression: condition))
        #expect(conditionOnly.rows.map(\.item) == [kept])
    }

    @Test func anOversizeCanonicalConditionIsRejectedBeforeItCanMintAnInvalidCursor() throws {
        let prefix = Array(repeating: "type:image", count: 127).joined(separator: " ") + " "
        let raw = prefix + String(repeating: "a", count: HistoryLimits.standard.maximumSearchTermUTF8Bytes - prefix.utf8.count)
        let condition = try HistorySearchExpression.parse(raw)
        #expect(condition.serialized.utf8.count > HistoryLimits.standard.maximumSearchTermUTF8Bytes)
        for kind in [HistoryBrowseKind.recent, .search(text: "needle", mode: .fuzzy)] {
            #expect(throws: HistoryFailure.invalidInput(.invalidSearchTerm)) {
                try AdmittedSearchRequest(.init(kind: kind, limit: 10, conditionExpression: condition), limits: .standard)
            }
        }
    }

#if DEBUG
    @Test func eitherRequiredTextConditionCanBoundAnIndependentSearch() async throws {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(
            persistence: .temporary, initialMaximumUnpinnedItems: 5_000
        ))
        _ = try await history.seedPerformanceFixture(rowCount: 4_105) { index in
            WSSupport.textCapture(
                "all record \(index)\n" + (index < 6 ? "quartz" : "ordinary"),
                observedAt: Date(timeIntervalSinceReferenceDate: Double(index))
            )
        }
        // Candidate planning may inspect either required operand, but the
        // original Boolean order continues to select the returned highlight.
        for (query, hasBodySnippet) in [
            ("all AND quartz", false), ("quartz AND all", true),
            ("(all AND quartz) OR (all AND absent)", false),
            (Array(repeating: "all", count: 127).joined(separator: " ") + " quartz", false),
        ] {
            let measured = await history.measureSearch(.init(
                kind: .search(text: query, mode: .expression), limit: 2
            ))
            let page = try measured.result.get()
            #expect(page.rows.map(\.title) == ["all record 5", "all record 4"])
            #expect(measured.metrics.rowsDecoded <= 6)
            #expect(page.rows.allSatisfy { ($0.search?.snippet != nil) == hasBodySnippet })
        }
        for mode in [SearchMode.exact, .regexp] {
            for (literal, conditionText) in [("quartz", "all"), ("all", "quartz")] {
                let kind = HistoryBrowseKind.search(text: literal, mode: mode)
                let condition = try HistorySearchExpression.parse(conditionText)
                let request = HistoryBrowseRequest(kind: kind, limit: 2, conditionExpression: condition)
                let first = await history.measureSearch(request)
                let firstPage = try first.result.get()
                #expect(firstPage.rows.map(\.title) == ["all record 5", "all record 4"])
                #expect(first.metrics.rowsDecoded <= 6)
                #expect(firstPage.rows.allSatisfy { row in
                    literal == "quartz" ? row.search?.snippet?.contains("quartz") == true
                        : row.search?.snippet == nil && row.search?.matchedRanges == [UTF16TextRange(location: 0, length: 3)]
                })

                let forward = try #require(firstPage.next)
                let second = await history.measureSearch(.init(
                    kind: kind, limit: 2, cursor: forward, conditionExpression: condition
                ))
                let secondPage = try second.result.get()
                #expect(secondPage.rows.map(\.title) == ["all record 3", "all record 2"])
                #expect(second.metrics.rowsDecoded <= 6)
                let backward = try #require(secondPage.previous)
                let restored = await history.measureSearch(.init(
                    kind: kind, limit: 2, cursor: backward, conditionExpression: condition
                ))
                #expect(try restored.result.get().rows == firstPage.rows)
                #expect(restored.metrics.rowsDecoded <= 6)
                let target = try #require(secondPage.rows.first?.item.id)
                let located = await history.measureSearch(.init(
                    kind: kind, limit: 2, startAround: target, conditionExpression: condition
                ))
                let locatedPage = try located.result.get()
                #expect(locatedPage.rows == secondPage.rows)
                #expect(locatedPage.previous != nil && locatedPage.next != nil)
                #expect(located.metrics.rowsDecoded <= 12)
            }
        }
    }
#endif

    private func copy(_ text: String, source: String?, at time: Int, in history: SQLiteHistory) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(WSSupport.textCapture(
            text, observedAt: Date(timeIntervalSinceReferenceDate: Double(time)), source: source
        )))
        guard case .committed(let commit) = receipt else { throw HistoryFailure.persistence(.invariantViolation) }
        switch commit.outcome {
        case .inserted(let item), .coalesced(let item): return item
        default: throw HistoryFailure.persistence(.invariantViolation)
        }
    }
}
