#if DEBUG
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct RegexpDeadlineAdmissionTests {
    @Test(arguments: ["a", "[a]", "(?:a)", "[z]", "a$"])
    func expiredEngineBudgetRejectsFastHitsAndMisses(pattern: String) async throws {
        let history = try await WSSupport.makeHistory()
        _ = try await history.perform(.capture(WSSupport.textCapture(
            "a", observedAt: Date(timeIntervalSinceReferenceDate: 1)
        )))
        await history.searchWorker.setRegexpEngineDeadline(.zero)
        let request = HistoryBrowseRequest(kind: .search(text: pattern, mode: .regexp), limit: 7)
        await #expect(throws: HistoryFailure.temporarilyUnavailable(.searchEngineDeadline)) {
            try await history.browse(request)
        }
        // Deadline failure unwinds the same request-owned snapshot. A fresh
        // request with its ordinary budget must still match on the worker.
        await history.searchWorker.setRegexpEngineDeadline(SearchWorker.defaultRegexpEngineDeadline)
        let replacement = try await history.browse(.init(kind: .search(text: "[a]", mode: .regexp), limit: 7))
        #expect(replacement.rows.map(\.title) == ["a"])
    }
}
#endif
