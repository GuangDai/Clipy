/// Representative V2-09 search measurements with independently read expected
/// identities. Fixture values are fixed, so no million-row oracle is needed.
import Foundation
import HistoryCore
import HistoryStorage

struct SQLiteScaleBrowseEvidence: Sendable {
    let count: Int
    let leadingRows: [HistoryRow]
    let oldestRow: HistoryRow?
}

struct SQLiteScaleQuery: Codable, Sendable {
    let text: String
    let mode: String
    let pageIndex: Int
    let requestedLimit: Int
    let expectedTotalMatches: Int
}

struct SQLiteScaleSearchCase: Sendable {
    let name: String
    let text: String
    let mode: SearchMode
    let expectedRows: [HistoryRow]
    let expectedTotalMatches: Int

    var modeName: String {
        switch mode {
        case .exact: "exact"
        case .fuzzy: "fuzzy"
        case .regexp: "regexp"
        }
    }
}

func sqliteScaleSearchCases(corpus: SQLiteScaleBrowseEvidence) -> [SQLiteScaleSearchCase] {
    let oldest = corpus.oldestRow.map { [$0] } ?? []
    return [
        SQLiteScaleSearchCase(name: "exact-no-hit", text: "ZZZZZZZZ", mode: .exact,
                              expectedRows: [], expectedTotalMatches: 0),
        // At the one-million-row scale, indices are 0...999999. Every
        // trigram exists, but no at-most-six-digit index contains all five
        // trigrams of this seven-digit query.
        SQLiteScaleSearchCase(name: "exact-common-grams-no-intersection", text: "1234567", mode: .exact,
                              expectedRows: [], expectedTotalMatches: 0),
        // Repeating a gram cannot prove the full needle occurs. Rows such as
        // 111 remain candidates and must fail the exact byte/string check.
        SQLiteScaleSearchCase(name: "exact-repeated-gram-no-hit", text: "1111111", mode: .exact,
                              expectedRows: [], expectedTotalMatches: 0),
        SQLiteScaleSearchCase(name: "exact-oldest", text: "perf-item-0-", mode: .exact,
                              expectedRows: oldest, expectedTotalMatches: oldest.count),
        SQLiteScaleSearchCase(name: "exact-dense", text: "perf-item-", mode: .exact,
                              expectedRows: corpus.leadingRows, expectedTotalMatches: corpus.count),
        SQLiteScaleSearchCase(name: "regexp-no-hit", text: "ZZZZZZZZ", mode: .regexp,
                              expectedRows: [], expectedTotalMatches: 0),
        SQLiteScaleSearchCase(name: "regexp-common-grams-no-intersection", text: "1234567", mode: .regexp,
                              expectedRows: [], expectedTotalMatches: 0),
        // Structural regexp misses cannot rely on dense first-page success:
        // every real index has fewer than seven digits.
        SQLiteScaleSearchCase(name: "regexp-structural-no-hit", text: "^perf-item-[0-9]{7}-", mode: .regexp,
                              expectedRows: [], expectedTotalMatches: 0),
        SQLiteScaleSearchCase(name: "regexp-oldest", text: "^perf-item-0-", mode: .regexp,
                              expectedRows: oldest, expectedTotalMatches: oldest.count),
        SQLiteScaleSearchCase(name: "regexp-structural-dense", text: "^perf-item-[0-9]+-", mode: .regexp,
                              expectedRows: corpus.leadingRows, expectedTotalMatches: corpus.count),
        SQLiteScaleSearchCase(name: "fuzzy-no-hit", text: "ZZZZZZZZ", mode: .fuzzy,
                              expectedRows: [], expectedTotalMatches: 0),
        // The corpus contains 'a'; seven missing 'z' characters still require
        // more edits than Fuse's threshold. An any-character-presence filter
        // alone cannot reject this query.
        SQLiteScaleSearchCase(name: "fuzzy-mixed-presence-no-hit", text: "aZZZZZZZ", mode: .fuzzy,
                              expectedRows: [], expectedTotalMatches: 0),
        SQLiteScaleSearchCase(name: "fuzzy-dense", text: "perf-item-", mode: .fuzzy,
                              expectedRows: corpus.leadingRows, expectedTotalMatches: corpus.count),
        // Every row starts with the same prefix, giving equal Fuse score for
        // one substitution at the same location; recency breaks every tie.
        SQLiteScaleSearchCase(name: "fuzzy-typo", text: "perg-item-", mode: .fuzzy,
                              expectedRows: corpus.leadingRows, expectedTotalMatches: corpus.count),
    ]
}

func validateSQLiteScaleSearchPage(
    _ page: HistoryPage,
    expectedRows: [HistoryRow],
    expectedPosition: ChangePosition,
    expectedTotalMatches: Int,
    pageIndex: Int,
    limit: Int
) throws {
    let offset = pageIndex * limit
    let wanted = Array(expectedRows.dropFirst(offset).prefix(limit))
    guard page.position == expectedPosition,
          page.rows.count == wanted.count,
          (page.previous != nil) == (pageIndex > 0),
          (page.next != nil) == (expectedTotalMatches > offset + wanted.count) else {
        throw SQLiteScaleError.unexpectedResult
    }
    for (actual, expected) in zip(page.rows, wanted) {
        guard actual.item == expected.item,
              actual.title == expected.title,
              actual.lastCopiedAt == expected.lastCopiedAt,
              actual.copyCount == expected.copyCount,
              actual.typeIdentifiers == expected.typeIdentifiers,
              actual.pinnedPosition == expected.pinnedPosition,
              let presentation = actual.search,
              presentation.snippet == nil,
              !presentation.matchedRanges.isEmpty else {
            throw SQLiteScaleError.unexpectedResult
        }
    }
}

func exerciseSQLiteScaleSearches(
    history: SQLiteHistory,
    corpus: SQLiteScaleBrowseEvidence,
    position: ChangePosition,
    samples: inout [SQLiteScaleSample]
) async throws {
    let limit = 50
    for fixture in sqliteScaleSearchCases(corpus: corpus) {
        var cursor: HistoryPageCursor?
        let pageCount = fixture.expectedTotalMatches > limit ? 2 : 1
        for pageIndex in 0..<pageCount {
            let query = SQLiteScaleQuery(
                text: fixture.text, mode: fixture.modeName, pageIndex: pageIndex,
                requestedLimit: limit, expectedTotalMatches: fixture.expectedTotalMatches
            )
            do {
                let page = try await measureSQLiteScale(
                    phase: "search-\(fixture.name)-page\(pageIndex + 1)", samples: &samples, query: query
                ) {
                    let result = try await history.browse(HistoryBrowseRequest(
                        kind: .search(text: fixture.text, mode: fixture.mode), limit: limit, cursor: cursor
                    ))
                    try validateSQLiteScaleSearchPage(
                        result, expectedRows: fixture.expectedRows, expectedPosition: position,
                        expectedTotalMatches: fixture.expectedTotalMatches, pageIndex: pageIndex, limit: limit
                    )
                    return result
                } facts: { ($0.rows.count, 0) }
                cursor = page.next
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Do not use a nonexistent/failed cursor. The sample keeps the
                // error and final exit is nonzero; independent cases continue.
                break
            }
        }
    }
}
