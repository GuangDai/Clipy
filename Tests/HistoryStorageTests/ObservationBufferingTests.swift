/// Regression coverage for the public observation storage boundary: it is a
/// latest-state stream, not an event log (DATA-6 / STORAGE-6).
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct ObservationBufferingTests {
#if DEBUG
    /// DATA-6 / STORAGE-6: a consumer that pauses after its initial page must
    /// resume at the newest authoritative snapshot. Intermediate replacement
    /// pages are state already superseded by the final page, not events that
    /// need replaying.
    @Test func pausedObserverResumesAtNewestAuthoritativeSnapshot() async throws {
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(
                persistence: .memory,
                initialMaximumUnpinnedItems: 200
            )
        )
        let yieldGate = SuspensionGate()
        let didYield: @Sendable (HistoryPage) async -> Void = { page in
            await yieldGate.park(at: "outer-page-\(page.position.rawValue)")
        }
        let stream = await ObservationDebugInstrumentation.$pageDidYield.withValue(didYield) {
            await history.observe(
                HistoryObservationRequest(kind: .recent, limit: 10)
            )
        }
        var iterator = stream.makeAsyncIterator()

        await yieldGate.waitForPark("outer-page-0")
        let initialResult = try await iterator.next()
        let initial = try #require(initialResult)
        #expect(initial.position.rawValue == 0)
        #expect(initial.rows.isEmpty)
        await yieldGate.resume("outer-page-0")

        for (offset, title) in ["outer one", "outer two", "outer three"].enumerated() {
            _ = try await history.perform(.capture(
                ClipboardCapture(
                    representations: [CapturedRepresentation(
                        typeIdentifier: "public.utf8-plain-text",
                        bytes: Data(title.utf8)
                    )],
                    origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
                    observedAt: Date(timeIntervalSinceReferenceDate: 720_000_000 + Double(offset))
                )
            ))
            let point = "outer-page-\(offset + 1)"
            await yieldGate.waitForPark(point)
            await yieldGate.resume(point)
        }

        let resumedResult = try await iterator.next()
        let resumed = try #require(resumedResult)
        #expect(resumed.position.rawValue == 3)
        #expect(resumed.rows.map(\.title) == ["outer three", "outer two", "outer one"])
    }
#endif
}
