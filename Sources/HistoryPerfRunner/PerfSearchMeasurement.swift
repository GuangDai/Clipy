/// Same-request measurements for the small search timing comparisons.
import Foundation
import HistoryCore
import HistoryStorage

func measurePerfSearchSamples(
    history: SQLiteHistory,
    request: HistoryBrowseRequest,
    retainedRows: Int,
    expectedItem: HistoryItemReference,
    requiresUniqueResult: Bool,
    warmups: Int = 1,
    iterations: Int = 5
) async throws -> WorkloadSearchMeasurements {
    precondition(warmups >= 0 && iterations > 0)
    let expectedPosition = try await history.usage().position
    let clock = ContinuousClock()
    var samples: [Double] = []
    var work: [SQLiteScaleSearchWork] = []
    samples.reserveCapacity(iterations)
    work.reserveCapacity(iterations)
    for index in 0..<(warmups + iterations) {
        try Task.checkCancellation()
        let start = clock.now
        let measured = await history.measureSearch(request)
        let elapsed = durationToMs(start.duration(to: clock.now))
        let page = try measured.result.get()
        guard elapsed.isFinite, elapsed > 0,
              page.position == expectedPosition,
              page.previous == nil,
              page.rows.contains(where: { $0.item == expectedItem }),
              !requiresUniqueResult || (page.rows.count == 1 && page.next == nil) else {
            throw PerfError.searchUnexpectedResult
        }
        if index >= warmups {
            samples.append(elapsed)
            work.append(SQLiteScaleSearchWork(measured.metrics))
        }
    }
    return WorkloadSearchMeasurements(
        retainedRows: retainedRows, warmupCount: warmups, rawSamplesMs: samples, searchWork: work
    )
}
