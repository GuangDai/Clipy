#if DEBUG
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

/// The immutable matcher fixture remains a useful independent comparison for
/// SQLite when explicit order and fresh reading-position requests are used.
struct SearchSortOracleTests {
    @Test(arguments: [SearchMode.exact, .regexp, .fuzzy, .expression], HistorySortOrder.allCases)
    func seekingAcrossBatchesMatchesTheCompleteOracleOrder(mode: SearchMode, sortOrder: HistorySortOrder) async throws {
        let rows = (0..<70).map { index in
            let text = "alpha row \(index)"
            return SearchCorpusRow(
                id: HistoryItemID(rawValue: UUID()), contentVersion: .initial,
                title: text, searchBody: text,
                debugTitleUTF8Bytes: text.utf8.count, debugSearchBodyUTF8Bytes: text.utf8.count,
                typeIdentifiers: ["public.utf8-plain-text"],
                lastCopiedAt: Date(timeIntervalSinceReferenceDate: Double(1_000 - index)),
                copyCount: UInt64(index % 5 + 1), lastSource: nil,
                pinOrdinal: index < 2 ? PinOrdinal(rawValue: index) : nil
            )
        }
        let corpus = SearchCorpusSnapshot(position: ChangePosition(rawValue: 1), rows: rows,
                                          debugTrace: SearchDebugTrace(id: UUID(), startedAt: ContinuousClock.now))
        let worker = SearchWorker()
        let marker = UUID()
        let kind = HistoryBrowseKind.search(text: "alpha", mode: mode)
        let baseline = try await worker.page(
            HistoryBrowseRequest(kind: kind, limit: 100, sortOrder: sortOrder),
            corpus: corpus, continuationAnchor: nil, processMarker: marker
        )
        #expect(baseline.rows.count == 70)
        for targetIndex in [0, 33, 69] {
            for limit in [1, 3] {
                let target = baseline.rows[targetIndex].item.id
                let located = try await worker.page(
                    HistoryBrowseRequest(kind: kind, limit: limit, sortOrder: sortOrder, startAround: target),
                    corpus: corpus, continuationAnchor: nil, processMarker: marker
                )
                #expect(located.rows == Array(baseline.rows.dropFirst(targetIndex).prefix(limit)))
                #expect((located.previous != nil) == (targetIndex > 0))
                #expect((located.next != nil) == (targetIndex + limit < baseline.rows.count))
                if let cursor = located.next {
                    let next = try await worker.page(
                        HistoryBrowseRequest(kind: kind, limit: limit, cursor: cursor, sortOrder: sortOrder),
                        corpus: corpus,
                        continuationAnchor: PageCursorCodec.decode(cursor, processMarker: marker).anchor,
                        processMarker: marker
                    )
                    #expect(next.rows == Array(baseline.rows.dropFirst(targetIndex + limit).prefix(limit)))
                }
                if let cursor = located.previous {
                    let previous = try await worker.page(
                        HistoryBrowseRequest(kind: kind, limit: limit, cursor: cursor, sortOrder: sortOrder),
                        corpus: corpus,
                        continuationAnchor: PageCursorCodec.decode(cursor, processMarker: marker).anchor,
                        processMarker: marker
                    )
                    #expect(previous.rows == Array(baseline.rows.prefix(targetIndex).suffix(limit)))
                }
            }
        }
    }
}
#endif
