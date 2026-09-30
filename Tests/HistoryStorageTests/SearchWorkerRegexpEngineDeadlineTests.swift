#if DEBUG
/// Regexp cancellation through the real `SearchWorker.page` boundary (03b §8).
/// The long ambiguous-quantifier chain under a 60-second budget exercises
/// cooperative cancellation in `enumerateMatches` progress callbacks.
/// Expired-budget admission is covered by RegexpDeadlineAdmissionTests.
/// First-match ranges and ordering remain covered by WS17 and SearchModeGapTests.
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

@Suite("SearchWorker regexp engine cancellation")
struct SearchWorkerRegexpEngineDeadlineTests {
    /// Spelled independently from the probe executable by design: the test
    /// binds the exact admitted pattern to the exact fixed input, as the
    /// characterization suite does for the child experiment.
    private static let chainPattern = "a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*b"

    /// The product's own regexp scan bound: the 1,000-Character title prefix
    /// the characterization probe also uses, all `a` so the chain (which
    /// requires a trailing `b`) can never match and only the engine's
    /// progress callbacks can end the scan.
    private static func chainCorpus() -> SearchCorpusSnapshot {
        let title = String(repeating: "a", count: 1_000)
        let body = "no b in this body"
        let row = SearchCorpusRow(
            id: HistoryItemID(rawValue: UUID()),
            contentVersion: .initial,
            title: title,
            searchBody: body,
            debugTitleUTF8Bytes: title.utf8.count,
            debugSearchBodyUTF8Bytes: body.utf8.count,
            typeIdentifiers: ["public.utf8-plain-text"],
            lastCopiedAt: Date(timeIntervalSinceReferenceDate: 730_400_000),
            copyCount: 1,
            lastSource: nil,
            pinOrdinal: nil
        )
        return SearchCorpusSnapshot(
            position: ChangePosition(rawValue: 11),
            rows: [row],
            debugTrace: SearchDebugTrace(
                id: UUID(),
                startedAt: ContinuousClock().now
            )
        )
    }

    @Test(
        "cancellation observed inside the engine scan fails the request cooperatively"
    )
    func cancellationInsideTheEngineScanFailsCooperatively() async throws {
        let worker = SearchWorker()
        // Distant deadline: only cooperative cancellation may stop this scan.
        await worker.setRegexpEngineDeadline(.seconds(60))
        let clock = ContinuousClock()

        let scan = Task {
            try await worker.page(
                HistoryBrowseRequest(
                    kind: .search(text: Self.chainPattern, mode: .regexp),
                    limit: 10
                ),
                in: Self.chainCorpus(),
                continuationAnchor: nil,
                processMarker: UUID()
            )
        }

        // The row-0 chain scan is CI-proven to still be inside its single
        // engine call 100 ms in (two master watchdog runs never saw the
        // former operation return within 2 s), so the cancellation lands
        // inside the interruptible iterator and is observed at its next
        // progress callback. Platform dependency: if a future engine
        // finishes this request inside the 100 ms window, the typed
        // cancellation assertion fails informatively (the scan returns a
        // page before the cancel lands) — visible, never silent.
        try await Task.sleep(for: .milliseconds(100))
        scan.cancel()
        let cancelledAt = clock.now

        await #expect(throws: CancellationError.self) {
            _ = try await scan.value
        }
        #expect(
            clock.now - cancelledAt < .seconds(5),
            "a cancelled scan must release the actor at the next progress callback"
        )
    }
}
#endif
