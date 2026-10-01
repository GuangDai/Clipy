/// Same-request native work and per-page observations for recent traversal.
import Foundation
import HistoryCore
import HistoryStorage

struct SQLiteScaleRecentWork: Codable, Sendable {
    let pageRequests: Int
    let statementCount: Int
    let rowsDecoded: Int
    let virtualMachineSteps: Int
    let fullScanSteps: Int
    let sortOperations: Int
    let cacheHits: Int
    let cacheMisses: Int

    static let zero = Self(
        pageRequests: 0, statementCount: 0, rowsDecoded: 0, virtualMachineSteps: 0,
        fullScanSteps: 0, sortOperations: 0, cacheHits: 0, cacheMisses: 0
    )
}

extension SQLiteScaleRecentWork {
    init(_ metrics: RecentReadWorkMetrics) {
        self.init(
            pageRequests: 1, statementCount: metrics.statementCount, rowsDecoded: metrics.rowsDecoded,
            virtualMachineSteps: metrics.virtualMachineSteps, fullScanSteps: metrics.fullScanSteps,
            sortOperations: metrics.sortOperations, cacheHits: metrics.cacheHits, cacheMisses: metrics.cacheMisses
        )
    }

    func adding(_ metrics: RecentReadWorkMetrics) -> Self {
        Self(
            pageRequests: pageRequests + 1,
            statementCount: statementCount + metrics.statementCount,
            rowsDecoded: rowsDecoded + metrics.rowsDecoded,
            virtualMachineSteps: virtualMachineSteps + metrics.virtualMachineSteps,
            fullScanSteps: fullScanSteps + metrics.fullScanSteps,
            sortOperations: sortOperations + metrics.sortOperations,
            cacheHits: cacheHits + metrics.cacheHits,
            cacheMisses: cacheMisses + metrics.cacheMisses
        )
    }
}

struct SQLiteScaleRecentPageSample: Codable, Sendable {
    let pageIndex: Int
    /// The page request only; subsequent fixture validation is excluded.
    let elapsedMilliseconds: Double
    let returnedRows: Int?
    let failure: String?
    let work: SQLiteScaleRecentWork
}

struct MeasuredSQLiteScaleRecentTraversal: Sendable {
    let result: Result<SQLiteScaleBrowseEvidence, any Error>
    let work: SQLiteScaleRecentWork
    let pages: [SQLiteScaleRecentPageSample]
}

func measureSQLiteScaleRecentTraversal(
    history: SQLiteHistory,
    expectedCount: Int,
    largeBodyIndex: Int? = nil
) async -> MeasuredSQLiteScaleRecentTraversal {
    var cursor: HistoryPageCursor?
    var position: ChangePosition?
    var count = 0
    var leadingRows: [HistoryRow] = []
    var oldestRow: HistoryRow?
    var largeBodyRow: HistoryRow?
    var work = SQLiteScaleRecentWork.zero
    var pages: [SQLiteScaleRecentPageSample] = []
    let clock = ContinuousClock()
    repeat {
        let start = clock.now
        let measured = await history.measureRecentPage(
            HistoryBrowseRequest(kind: .recent, limit: 50, cursor: cursor)
        )
        let elapsed = durationToMs(start.duration(to: clock.now))
        work = work.adding(measured.metrics)
        do {
            let page = try measured.result.get()
            guard count < expectedCount,
                  page.rows.count == min(50, expectedCount - count),
                  (page.previous != nil) == (count > 0),
                  (page.next != nil) == (count + page.rows.count < expectedCount),
                  position.map({ page.position == $0 }) ?? true else {
                throw SQLiteScaleError.unexpectedResult
            }
            position = page.position
            for row in page.rows {
                let expectedIndex = expectedCount - count - 1
                guard expectedIndex >= 0,
                      row.lastCopiedAt == Date(timeIntervalSinceReferenceDate: 600_000_000 + Double(expectedIndex)),
                      row.title.hasPrefix("perf-item-\(expectedIndex)-") else {
                    throw SQLiteScaleError.unexpectedResult
                }
                if leadingRows.count < 100 { leadingRows.append(row) }
                if expectedIndex == largeBodyIndex { largeBodyRow = row }
                oldestRow = row
                count += 1
            }
            pages.append(SQLiteScaleRecentPageSample(
                pageIndex: pages.count, elapsedMilliseconds: elapsed, returnedRows: page.rows.count,
                failure: nil, work: SQLiteScaleRecentWork(measured.metrics)
            ))
            cursor = page.next
        } catch {
            pages.append(SQLiteScaleRecentPageSample(
                pageIndex: pages.count, elapsedMilliseconds: elapsed, returnedRows: nil,
                failure: String(describing: error), work: SQLiteScaleRecentWork(measured.metrics)
            ))
            return MeasuredSQLiteScaleRecentTraversal(result: .failure(error), work: work, pages: pages)
        }
    } while cursor != nil
    guard count == expectedCount, largeBodyIndex == nil || largeBodyRow != nil else {
        return MeasuredSQLiteScaleRecentTraversal(
            result: .failure(SQLiteScaleError.unexpectedResult), work: work, pages: pages
        )
    }
    return MeasuredSQLiteScaleRecentTraversal(
        result: .success(SQLiteScaleBrowseEvidence(
            count: count, leadingRows: leadingRows, oldestRow: oldestRow, largeBodyRow: largeBodyRow
        )), work: work, pages: pages
    )
}
