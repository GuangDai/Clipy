import Foundation
import HistoryCore
import Testing
@testable import HistoryPerfRunner

extension HistoryPerfRunnerHelperTests {
    @Test func searchSamplesRecordActualWorkAndRejectUnvalidatedResults() async throws {
        let history = try await openMemoryStore()
        let expected = try await captureItem(history, index: 0)
        _ = try await captureItem(history, index: 1)
        let measured = try await measurePerfSearchSamples(
            history: history,
            request: HistoryBrowseRequest(kind: .search(text: "perf-item-0-", mode: .exact), limit: 50),
            retainedRows: 2, expectedItem: expected, requiresUniqueResult: true,
            warmups: 1, iterations: 3
        )
        #expect(measured.retainedRows == 2)
        #expect(measured.warmupCount == 1)
        #expect(measured.rawSamplesMs.count == 3)
        #expect(measured.searchWork.count == measured.rawSamplesMs.count)
        #expect(measured.rawSamplesMs.allSatisfy { $0.isFinite && $0 > 0 })
        #expect(measured.searchWork.allSatisfy {
            $0.rowsDecoded >= 1 && $0.rowsEvaluated >= 1 && $0.matchesFound == 1 && $0.batchCount >= 1
        })

        // A quick empty request or a request that returns additional exact
        // matches must not become a successful small timing sample.
        for term in ["absent-token", "perf-item-"] {
            await #expect(throws: PerfError.self) {
                try await measurePerfSearchSamples(
                    history: history,
                    request: HistoryBrowseRequest(kind: .search(text: term, mode: .exact), limit: 50),
                    retainedRows: 2, expectedItem: expected, requiresUniqueResult: true,
                    warmups: 0, iterations: 1
                )
            }
        }
    }
}
