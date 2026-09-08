import Foundation
import HistoryCore

package enum SearchStopReason: String, Sendable {
    case exhausted, pageBudget, provenBestScore, provenNoMatch
    case cancelled, deadline, failed
}

/// Work performed by the same request that produced `result`. These are
/// History projection/matcher counts, not FTS postings or SQL-filtered rows.
package struct SearchWorkMetrics: Sendable {
    /// Complete candidate projections decoded into Swift; includes lookahead
    /// rows even when page selection stops before evaluating the entire batch.
    package let rowsDecoded: Int
    /// Rows whose matcher evaluation started; an interrupted row counts once.
    package let rowsEvaluated: Int
    /// Matched rows, including anchors/lookahead and discarded ranked hits.
    package let matchesFound: Int
    /// Nonempty decode batches, including a batch interrupted after some rows.
    package let batchCount: Int
    package let stopReason: SearchStopReason
}

package struct MeasuredSearchPage: Sendable {
    package let result: Result<HistoryPage, any Error>
    package let metrics: SearchWorkMetrics
}

extension SQLiteHistory {
    /// A package measurement of the actual SQLite search path, including
    /// partial work on failure. No last-query state is retained by the facade.
    /// Callers measure nonempty `.search` requests; ordinary browse continues
    /// to use its existing recent/empty-search Authority path.
    package func measureSearch(_ request: HistoryBrowseRequest) async -> MeasuredSearchPage {
        await searchWorker.measurePage(
            request, store: authority.storeLocation, processMarker: authority.cursorProcessMarker
        )
    }
}

/// A single SearchWorker request owns this counter throughout its read and
/// matcher calls. Only the immutable snapshot leaves that actor. In
/// particular, a throwing matcher does not lose its partially evaluated batch.
internal final class SearchWorkCounter {
    var rowsDecoded = 0
    var rowsEvaluated = 0
    var matchesFound = 0
    var batchCount = 0
    var stopReason: SearchStopReason = .exhausted

    func snapshot() -> SearchWorkMetrics {
        SearchWorkMetrics(rowsDecoded: rowsDecoded, rowsEvaluated: rowsEvaluated,
                          matchesFound: matchesFound, batchCount: batchCount, stopReason: stopReason)
    }
}
