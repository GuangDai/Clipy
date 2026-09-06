#if DEBUG
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

/// Bounded selection must reproduce the frozen complete ordering, including
/// late better scores, date/UUID ties, pinned transitions and cursor tails
/// (03b §8 / 04 §6). No timing or memory-pressure thresholds are involved.
struct SearchWorkerBoundedResultsTests {
    private static func row(_ index: Int) -> SearchCorpusRow {
        let title = index.isMultiple(of: 5)
            ? "zzzzzzzzzzzz"
            : String(repeating: "x ", count: index % 8) + "alpha \(index)"
        let body = "alpha body \(index)"
        return SearchCorpusRow(
            id: HistoryItemID(rawValue: UUID(uuidString:
                "00000000-0000-0000-0000-" + String(format: "%012d", index)
            )!),
            contentVersion: .initial,
            title: title,
            searchBody: body,
            debugTitleUTF8Bytes: title.utf8.count,
            debugSearchBodyUTF8Bytes: body.utf8.count,
            typeIdentifiers: ["public.utf8-plain-text"],
            lastCopiedAt: Date(timeIntervalSinceReferenceDate: Double(1_000 - index / 3)),
            copyCount: 1,
            lastSource: nil,
            pinOrdinal: index < 4 ? PinOrdinal(rawValue: index) : nil
        )
    }

    private static func anchor(_ hit: SearchWorker.FuzzyHit) -> StoredOrderingAnchor {
        if hit.corpusRow.pinOrdinal != nil {
            return SearchWorker.defaultOrderAnchor(for: hit.corpusRow)
        }
        return .fuzzyUnpinned(
            score: hit.score,
            lastCopiedAt: hit.corpusRow.lastCopiedAt,
            id: hit.corpusRow.id
        )
    }

    @Test func boundedHeapMatchesIndependentFullSortForEveryCursorPosition() {
        let hits = (0..<60).map { index in
            SearchWorker.FuzzyHit(
                corpusRow: Self.row(index),
                // Adjacent equal-score pairs overlap three-row date groups,
                // so UUID ties are exercised independently of date ties.
                score: Double(((59 - index) / 2) % 7) / 10,
                search: .titleRanges([0..<1])
            )
        }
        // Deliberately retain the old full-sort algorithm only as the
        // independent test oracle, including its pinned-first partition.
        let pinned = hits.filter { $0.corpusRow.pinOrdinal != nil }
        let unpinned = hits.filter { $0.corpusRow.pinOrdinal == nil }.sorted {
            if $0.score != $1.score { return $0.score < $1.score }
            if $0.corpusRow.lastCopiedAt != $1.corpusRow.lastCopiedAt {
                return $0.corpusRow.lastCopiedAt > $1.corpusRow.lastCopiedAt
            }
            return $0.corpusRow.id < $1.corpusRow.id
        }
        let ordered = pinned + unpinned
        for capacity in [1, 3, 7] {
            for anchorIndex in -1..<ordered.count {
                let anchor = anchorIndex < 0 ? nil : Self.anchor(ordered[anchorIndex])
                var selection = SearchWorker.FuzzyPageSelection(directive: .init(
                    continuationAnchor: anchor,
                    maximumSurvivors: capacity
                ))
                for hit in hits.reversed() {
                    selection.insert(hit)
                    #expect(selection.hits.count <= capacity)
                }
                let start = max(0, anchorIndex)
                let count = capacity + (anchor == nil ? 0 : 1)
                let expected = ordered.dropFirst(start).prefix(count).map { $0.corpusRow.id }
                #expect(selection.evaluatedRows().map { $0.corpusRow.id } == expected)
            }
        }
    }

    @Test func changedFuzzyScoreDoesNotValidateAnExistingItemAsTheAnchor() {
        let hit = SearchWorker.FuzzyHit(
            corpusRow: Self.row(10), score: 0.1, search: .titleRanges([0..<1])
        )
        var selection = SearchWorker.FuzzyPageSelection(directive: .init(
            continuationAnchor: .fuzzyUnpinned(
                score: 0.2,
                lastCopiedAt: hit.corpusRow.lastCopiedAt,
                id: hit.corpusRow.id
            ),
            maximumSurvivors: 3
        ))
        selection.insert(hit)
        #expect(selection.evaluatedRows().isEmpty)
    }

    @Test func recentEquivalentCountsAnchorLookupAndTheBoundedWindow() async {
        let corpus = SearchCorpusSnapshot(
            position: ChangePosition(rawValue: 1),
            rows: (0..<5).map(Self.row),
            debugTrace: SearchDebugTrace(id: UUID(), startedAt: ContinuousClock().now)
        )
        let worker = SearchWorker()
        let cases: [(StoredOrderingAnchor?, Int, Int)] = [
            (nil, 3, 3),
            (SearchWorker.defaultOrderAnchor(for: Self.row(2)), 3, 5),
            (SearchWorker.defaultOrderAnchor(for: Self.row(9)), 0, 5),
        ]
        for (anchor, retained, examined) in cases {
            let result = await worker.evaluateRecentEquivalent(
                in: corpus,
                directive: .init(continuationAnchor: anchor, maximumSurvivors: 3)
            )
            #expect(result.rows.count == retained)
            #expect(result.debugRowsProcessed == examined)
            #expect(result.debugMatchedRows == examined)
        }
    }

    @Test(arguments: [SearchMode.exact, .regexp, .fuzzy])
    func smallPagesPreserveFullPageOrderAndPresentations(mode: SearchMode) async throws {
        let worker = SearchWorker()
        let corpus = SearchCorpusSnapshot(
            position: ChangePosition(rawValue: 1),
            rows: (0..<60).map(Self.row),
            debugTrace: SearchDebugTrace(id: UUID(), startedAt: ContinuousClock().now)
        )
        let marker = UUID()
        let kind = HistoryBrowseKind.search(text: "alpha", mode: mode)
        let full = try await worker.page(
            HistoryBrowseRequest(kind: kind, limit: 100),
            in: corpus, continuationAnchor: nil, processMarker: marker
        )
        #expect(full.rows.count == 60)
        var anchor: StoredOrderingAnchor?
        var collected: [HistoryRow] = []
        var reachedEnd = false
        for _ in 0..<20 {
            let page = try await worker.page(
                HistoryBrowseRequest(kind: kind, limit: 3),
                in: corpus, continuationAnchor: anchor, processMarker: marker
            )
            collected.append(contentsOf: page.rows)
            #expect(page.rows.count == 3)
            if let next = page.next {
                anchor = try PageCursorCodec.decode(next, processMarker: marker).anchor
            } else {
                reachedEnd = true
                break
            }
        }
        #expect(collected == full.rows)
        #expect(reachedEnd, "the last full page must not mint a continuation")

        // Deep continuation retains only the exact anchor plus lookahead,
        // even for the order-preserving scans that still validate old hits.
        let deepAnchor = try #require(anchor)
        let directive = SearchWorker.ScanDirective(
            continuationAnchor: deepAnchor, maximumSurvivors: 4
        )
        let evaluation: SearchWorker.EvaluationResult
        switch mode {
        case .exact:
            evaluation = try await worker.evaluateExact(term: "alpha", in: corpus, directive: directive)
        case .regexp:
            evaluation = try await worker.evaluateRegexp(term: "alpha", in: corpus, directive: directive)
        case .fuzzy:
            evaluation = try await worker.evaluateFuzzy(term: "alpha", in: corpus, directive: directive)
        }
        let retained = evaluation.rows
        #expect(retained.count <= 5)
        #expect(retained.first?.anchor == deepAnchor)
        #expect(evaluation.debugRowsProcessed == 60)
        #expect(evaluation.debugMatchedRows == 60)
    }
}
#endif
