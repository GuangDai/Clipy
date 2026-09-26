#if DEBUG
/// V2-09 §4: expression predicates must preserve bounded SQLite projection,
/// adjacent-page resumption and cooperative cancellation.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct SearchExpressionBoundedExecutionTests {
    private actor FirstBatchLatch {
        private var available = true

        func take() -> Bool {
            defer { available = false }
            return available
        }
    }

    @Test func denseExpressionPagesKeepProjectionAndEvaluationBounded() async throws {
        let history = try await fixture(count: 128)
        let query = "(app:notes OR app:safari) AND NOT absent"
        var cursor: HistoryPageCursor?
        var collected: [HistoryItemID] = []
        for _ in 0..<8 {
            let measured = await history.measureSearch(HistoryBrowseRequest(
                kind: .search(text: query, mode: .expression), limit: 7, cursor: cursor
            ))
            let page = try measured.result.get()
            #expect(page.rows.count == 7)
            #expect(measured.metrics.rowsDecoded <= SearchWorker.maximumBatchRows)
            #expect(measured.metrics.rowsEvaluated <= 9)
            #expect(measured.metrics.batchCount == 1)
            #expect(measured.metrics.stopReason == .pageBudget)
            collected += page.rows.map(\.item.id)
            cursor = try #require(page.next)
        }
        let recent = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 128))
        #expect(collected == Array(recent.rows.prefix(56).map(\.item.id)))
        #expect(Set(collected).count == 56)
    }

    @Test(arguments: [
        "alpha OR", "(app:notes", "NOT", "date:2026-02-30", "date:2026-09-27..2026-09-26",
        String(repeating: "(", count: 17) + "needle" + String(repeating: ")", count: 17),
        String(repeating: "a", count: 4_097),
    ])
    func invalidExpressionFailsBeforeReadingStoredRows(query: String) async throws {
        let history = try await fixture(count: 1)
        let request = HistoryBrowseRequest(kind: .search(text: query, mode: .expression), limit: 10)
        let measured = await history.measureSearch(request)
        #expect(throws: HistoryFailure.invalidInput(.invalidSearchTerm)) {
            _ = try measured.result.get()
        }
        #expect(measured.metrics.rowsDecoded == 0)
        #expect(measured.metrics.rowsEvaluated == 0)
        #expect(measured.metrics.batchCount == 0)
        await #expect(throws: HistoryFailure.invalidInput(.invalidSearchTerm)) {
            _ = try await history.browse(request)
        }
    }

    @Test func cancellationReleasesExpressionScanForAReplacementBeforeFinishing() async throws {
        let history = try await fixture(count: 70)
        let gate = SuspensionGate()
        let latch = FirstBatchLatch()
        let pointName = SearchWorkerSuspensionPoint.sqliteBatchComplete.rawValue
        await history.searchWorker.setSuspensionHandler { point in
            guard point == .sqliteBatchComplete, await latch.take() else { return }
            await gate.park(at: point.rawValue)
        }
        let running = Task {
            await history.measureSearch(HistoryBrowseRequest(
                kind: .search(text: "NOT absent AND (app:notes OR app:safari)", mode: .expression),
                limit: 70
            ))
        }
        await gate.waitForPark(pointName)
        running.cancel()
        do {
            // A remains parked after one real SQL batch. B must be able to
            // enter the worker and finish before A resumes and reports cancel.
            let replacement = try await history.browse(HistoryBrowseRequest(
                kind: .search(text: #""entry 69" AND app:safari"#, mode: .expression), limit: 1
            ))
            #expect(replacement.rows.map(\.title) == ["entry 69"])
            await gate.resume(pointName)
            let cancelled = await running.value
            #expect(throws: CancellationError.self) { _ = try cancelled.result.get() }
            #expect(cancelled.metrics.rowsDecoded == SearchWorker.maximumBatchRows)
            #expect(cancelled.metrics.rowsEvaluated == SearchWorker.maximumBatchRows)
            #expect(cancelled.metrics.batchCount == 1)
            #expect(cancelled.metrics.stopReason == .cancelled)
            await history.searchWorker.setSuspensionHandler(nil)
        } catch {
            await gate.resume(pointName)
            _ = await running.value
            await history.searchWorker.setSuspensionHandler(nil)
            throw error
        }
    }

    @Test func commitInvalidatesAnExpressionContinuationEvenWhenMatchesAreUnchanged() async throws {
        let history = try await fixture(count: 5)
        let kind = HistoryBrowseKind.search(text: "app:notes OR app:safari", mode: .expression)
        let first = try await history.browse(HistoryBrowseRequest(kind: kind, limit: 2))
        let cursor = try #require(first.next)
        let receipt = try await history.perform(.capture(WSSupport.textCapture(
            "excluded new row", observedAt: Date(timeIntervalSinceReferenceDate: 10), source: "com.example.other"
        )))
        guard case .committed(let commit) = receipt else {
            Issue.record("Expected the out-of-query copy to advance the snapshot")
            return
        }
        await #expect(throws: HistoryFailure.snapshotExpired(current: commit.position)) {
            _ = try await history.browse(HistoryBrowseRequest(kind: kind, limit: 2, cursor: cursor))
        }
    }

    private func fixture(count: Int) async throws -> SQLiteHistory {
        let history = try await WSSupport.makeHistory()
        _ = try await history.seedPerformanceFixture(rowCount: count) { index in
            WSSupport.textCapture(
                "entry \(index)", observedAt: Date(timeIntervalSinceReferenceDate: Double(index)),
                source: index.isMultiple(of: 2) ? "com.apple.Notes" : "com.apple.Safari"
            )
        }
        return history
    }
}
#endif
