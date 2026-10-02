#if DEBUG
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct FuzzySeekReadBoundsTests {
    @Test func restoringTheFirstFloorScoreDoesNotReadTheUnrelatedTail() async throws {
        let history = try await WSSupport.makeHistory()
        _ = try await history.seedPerformanceFixture(rowCount: 128) { index in
            WSSupport.textCapture("needle\n\(index)", observedAt: Date(timeIntervalSinceReferenceDate: Double(index)))
        }
        let first = try await history.browse(.init(kind: .search(text: "needle", mode: .fuzzy), limit: 7))
        let target = try #require(first.rows.first).item.id
        let request = HistoryBrowseRequest(kind: .search(text: "needle", mode: .fuzzy), limit: 7, startAround: target)
        let measured = await history.measureSearch(request)
        #expect(try measured.result.get() == first)
        // One target, at most one candidate batch for predecessors, and one
        // ordinary page batch. The old predecessor probe decoded all 128 rows.
        #expect(measured.metrics.rowsDecoded <= 1 + 2 * SearchWorker.maximumBatchRows)

        try await history.authority.withTestDatabase { authority in
            try authority.database.execute("""
                UPDATE history_items SET searchBodyUTF8 = ? WHERE id = (
                    SELECT id FROM history_items ORDER BY lastCopiedAt ASC, id ASC LIMIT 1
                )
                """, bindings: [.blob(Data([0xFF]))])
        }
        #expect(try await history.browse(request) == first)
    }

    @Test func aWorseScoreStillFindsAnOlderBetterPredecessor() async throws {
        let history = try await WSSupport.makeHistory()
        _ = try await history.perform(.capture(WSSupport.textCapture(
            "needle\nolder exact hit", observedAt: Date(timeIntervalSinceReferenceDate: 1)
        )))
        _ = try await history.perform(.capture(WSSupport.textCapture(
            "xneedle\nnewer worse hit", observedAt: Date(timeIntervalSinceReferenceDate: 2)
        )))
        let baseline = try await history.browse(.init(kind: .search(text: "needle", mode: .fuzzy), limit: 2))
        let target = try #require(baseline.rows.last).item.id
        #expect(baseline.rows.map(\.title) == ["needle", "xneedle"])
        let located = try await history.browse(.init(
            kind: .search(text: "needle", mode: .fuzzy), limit: 1, startAround: target
        ))
        #expect(located.rows == Array(baseline.rows.suffix(1)))
        #expect(located.next == nil)
        let previous = try #require(located.previous)
        let preceding = try await history.browse(.init(
            kind: .search(text: "needle", mode: .fuzzy), limit: 1, cursor: previous
        ))
        #expect(preceding.rows == Array(baseline.rows.prefix(1)))
    }
}
#endif
