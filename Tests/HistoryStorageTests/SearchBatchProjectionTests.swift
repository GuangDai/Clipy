#if DEBUG
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct SearchBatchProjectionTests {
    private actor BatchLatch {
        private var count = 0
        func isSecond() -> Bool { count += 1; return count == 2 }
    }

    @Test(arguments: [SearchMode.exact, .regexp, .expression], HistorySortOrder.allCases)
    func aDenseSingleRowPageReadsOnlyItsLookaheadAndContinuationAnchor(
        mode: SearchMode, sortOrder: HistorySortOrder
    ) async throws {
        let history = try await fixture()
        let kind = HistoryBrowseKind.search(text: "needle", mode: mode)
        let recent = try await history.browse(.init(kind: .recent, limit: 3, sortOrder: sortOrder))
        let first = await history.measureSearch(.init(kind: kind, limit: 1, sortOrder: sortOrder))
        let page = try first.result.get()
        #expect(page.rows.map(\.item) == recent.rows.prefix(1).map(\.item))
        #expect(page.previous == nil)
        #expect(first.metrics.rowsDecoded == 2)
        let next = try #require(page.next)
        let second = await history.measureSearch(.init(kind: kind, limit: 1, cursor: next, sortOrder: sortOrder))
        let continuation = try second.result.get()
        #expect(continuation.rows.map(\.item) == recent.rows.dropFirst().prefix(1).map(\.item))
        #expect(second.metrics.rowsDecoded == 3)
        let previous = try #require(continuation.previous)
        let restored = try await history.browse(.init(kind: kind, limit: 1, cursor: previous, sortOrder: sortOrder))
        #expect(restored.rows == page.rows)
    }

    @Test func missesRestoreTheNormalCancellationBatchAndReleaseTheReadSnapshot() async throws {
        let history = try await fixture()
        let gate = SuspensionGate()
        let latch = BatchLatch()
        let point = SearchWorkerSuspensionPoint.sqliteBatchComplete.rawValue
        await history.searchWorker.setSuspensionHandler { suspension in
            guard suspension == .sqliteBatchComplete, await latch.isSecond() else { return }
            await gate.park(at: suspension.rawValue)
        }
        let task = Task {
            await history.measureSearch(.init(kind: .search(text: "(?:absent)", mode: .regexp), limit: 1))
        }
        await gate.waitForPark(point)
        task.cancel()
        await gate.resume(point)
        let stopped = await task.value
        #expect(throws: CancellationError.self) { _ = try stopped.result.get() }
        // Two first-page candidates miss. The next batch then uses the full
        // cancellation cadence, rather than yielding every two absent rows.
        #expect(stopped.metrics.rowsDecoded == 2 + SearchWorker.maximumBatchRows)
        #expect(stopped.metrics.rowsEvaluated == stopped.metrics.rowsDecoded)
        #expect(stopped.metrics.stopReason == .cancelled)
        await history.searchWorker.setSuspensionHandler(nil)
        try await history.authority.withTestDatabase { authority in
            let checkpoint = try authority.database.prepare("PRAGMA wal_checkpoint(TRUNCATE)")
            defer { checkpoint.finalize() }
            try #require(try checkpoint.step())
            #expect(try checkpoint.integer(at: 0) == 0)
        }
        let replacement = await history.measureSearch(.init(kind: .search(text: "needle", mode: .exact), limit: 1))
        #expect(try replacement.result.get().rows.count == 1)
        #expect(replacement.metrics.rowsDecoded == 2)
    }

    private func fixture() async throws -> SQLiteHistory {
        let history = try await WSSupport.makeHistory()
        _ = try await history.seedPerformanceFixture(rowCount: 70) { index in
            WSSupport.textCapture("needle\n\(index)", observedAt: Date(timeIntervalSinceReferenceDate: Double(index)))
        }
        return history
    }
}
#endif
