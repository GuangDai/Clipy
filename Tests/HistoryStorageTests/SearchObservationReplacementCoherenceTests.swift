#if DEBUG
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct SearchObservationReplacementCoherenceTests {
    /// A removal during replacement evaluation must not briefly republish
    /// the removed row. Holding the first replacement yield prevents the
    /// public newest-page buffer from hiding a stale intermediate result.
    @Test(arguments: [SearchMode.exact, .fuzzy, .regexp])
    func removalDuringReplacementEvaluationDiscardsSupersededPage(mode: SearchMode) async throws {
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )
        let initialReceipt = try await history.perform(.capture(WSSupport.textCapture(
            "needle original", observedAt: Date(timeIntervalSinceReferenceDate: 820_000_000)
        )))
        guard case .committed(let initialCommit) = initialReceipt,
              case .inserted(let original) = initialCommit.outcome else {
            Issue.record("Expected the initial search fixture")
            return
        }

        let yieldGate = SuspensionGate()
        let didYield: @Sendable (HistoryPage) async -> Void = { page in
            if page.position > initialCommit.position {
                await yieldGate.park(at: "replacement-yield")
            }
        }
        let stream = await ObservationDebugInstrumentation.$pageDidYield.withValue(didYield) {
            await history.observe(HistoryObservationRequest(
                kind: .search(text: "needle", mode: mode), limit: 10
            ))
        }
        var iterator = stream.makeAsyncIterator()
        let initial = try #require(try await iterator.next())
        #expect(initial.rows.map(\.item.id) == [original.id])

        let evaluationGate = SuspensionGate()
        let latch = ReplacementEvaluationLatch()
        await history.searchWorker.setSuspensionHandler { point in
            guard point == .evaluationEntry, await latch.consume() else { return }
            await evaluationGate.park(at: "replacement-evaluation")
        }
        let replacementReceipt = try await history.perform(.capture(WSSupport.textCapture(
            "needle replacement", observedAt: Date(timeIntervalSinceReferenceDate: 820_000_001)
        )))
        guard case .committed(let replacementCommit) = replacementReceipt,
              case .inserted(let replacement) = replacementCommit.outcome else {
            Issue.record("Expected a second search fixture")
            return
        }
        await evaluationGate.waitForPark("replacement-evaluation")
        let removalReceipt = try await history.perform(.remove(original.id))
        guard case .committed(let removalCommit) = removalReceipt else {
            Issue.record("Expected the removal to commit")
            await evaluationGate.resume("replacement-evaluation")
            return
        }
        await evaluationGate.resume("replacement-evaluation")
        await yieldGate.waitForPark("replacement-yield")
        let replacementPage = try #require(try await iterator.next())
        #expect(replacementPage.position == removalCommit.position)
        #expect(replacementPage.rows.map(\.item.id) == [replacement.id])

        await history.searchWorker.setSuspensionHandler(nil)
        await yieldGate.resume("replacement-yield")
    }
}

private actor ReplacementEvaluationLatch {
    private var armed = true

    func consume() -> Bool {
        let result = armed
        armed = false
        return result
    }
}
#endif
