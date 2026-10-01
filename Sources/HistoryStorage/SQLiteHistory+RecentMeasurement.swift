import Foundation
import HistoryCore

/// Native work from the same recent-page scalar SELECTs that produced the
/// result. Counters include anchors, ties, lookahead and partially failed
/// reads; no database-wide last-query state is retained by the facade. VM,
/// full-scan and sort counts omit position reads, transaction statements,
/// separate source-validation queries and Swift page/cursor construction.
package struct RecentReadWorkMetrics: Sendable {
    package let statementCount: Int
    /// Complete bounded scalar projections, including anchors/lookahead.
    /// A later DTO projection failure does not erase the completed SQL work.
    package let rowsDecoded: Int
    package let virtualMachineSteps: Int
    package let fullScanSteps: Int
    package let sortOperations: Int
    /// Pager hit/miss differences cover each synchronous scalar SELECT's
    /// prepare, stepping, decoding and source validation. Other requests
    /// cannot interleave there. These are cache events, not physical bytes.
    package let cacheHits: Int
    package let cacheMisses: Int
}

package struct MeasuredRecentPage: Sendable {
    package let result: Result<HistoryPage, any Error>
    package let metrics: RecentReadWorkMetrics
}

extension SQLiteHistory {
    /// Recent and empty-search requests use the ordinary Authority page
    /// implementation. Nonempty search has its separate measureSearch entry.
    package func measureRecentPage(_ request: HistoryBrowseRequest) async -> MeasuredRecentPage {
        await authority.measureRecentPage(request)
    }
}

extension HistoryAuthority {
    internal func measureRecentPage(_ request: HistoryBrowseRequest) async -> MeasuredRecentPage {
        let work = RecentReadWorkCounter()
        do {
            guard request.conditionExpression == nil else {
                throw HistoryFailure.invalidInput(.invalidSearchTerm)
            }
            if case .search(let text, _) = request.kind, !text.isEmpty {
                throw HistoryFailure.invalidInput(.invalidSearchTerm)
            }
            let page = try await recentPage(
                limit: request.limit, cursor: request.cursor, filter: request.filter,
                sortOrder: request.sortOrder, startAround: request.startAround, measurement: work
            )
            return MeasuredRecentPage(result: .success(page), metrics: work.snapshot())
        } catch {
            return MeasuredRecentPage(result: .failure(error), metrics: work.snapshot())
        }
    }
}

/// Owned and mutated only by the Authority interval for one request. The
/// immutable snapshot is the only value returned across the actor boundary.
internal final class RecentReadWorkCounter {
    private var statementCount = 0
    private var rowsDecoded = 0
    private var virtualMachineSteps = 0
    private var fullScanSteps = 0
    private var sortOperations = 0
    private var cacheHits = 0
    private var cacheMisses = 0

    internal func record(
        rows: Int, statement: SQLiteStatementReadWork,
        cacheBefore: SQLiteCacheReadWork, cacheAfter: SQLiteCacheReadWork
    ) {
        statementCount += 1
        rowsDecoded += rows
        virtualMachineSteps += statement.virtualMachineSteps
        fullScanSteps += statement.fullScanSteps
        sortOperations += statement.sortOperations
        // SQLite's cumulative cache counters are unsigned-width snapshots;
        // modular subtraction also handles a wrap during this one statement.
        cacheHits += Int(cacheAfter.hits &- cacheBefore.hits)
        cacheMisses += Int(cacheAfter.misses &- cacheBefore.misses)
    }

    internal func snapshot() -> RecentReadWorkMetrics {
        RecentReadWorkMetrics(
            statementCount: statementCount, rowsDecoded: rowsDecoded,
            virtualMachineSteps: virtualMachineSteps, fullScanSteps: fullScanSteps,
            sortOperations: sortOperations, cacheHits: cacheHits, cacheMisses: cacheMisses
        )
    }
}
