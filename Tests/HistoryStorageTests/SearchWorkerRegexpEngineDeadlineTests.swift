#if DEBUG
/// REVIEW Card 11C engine-deadline proofs for the 03b §8 adjudicated scan
/// operation (Apple's interruptible `enumerateMatches` iterator under a fixed
/// per-request typed deadline). The seam is the real `SearchWorker.page` value
/// boundary plus the `setRegexpEngineDeadline` injection point: the fixed
/// top-level ambiguous-quantifier chain — admitted by the frozen grammar and
/// proven by two master CI watchdog runs to run the former `firstMatch`
/// operation uninterruptibly past 2 s over this exact 1,000-Character input —
/// must now fail typed at an injected zero deadline and release the actor
/// cooperatively when cancelled mid-scan. Platform dependency (same class
/// as the characterization suite's): if a future engine resolves this exact
/// chain-and-input quickly without entering a progress callback, the
/// deadline test fails informatively (a returned no-match page instead of
/// the typed throw) — a visible signal, never a silent degradation.
/// The first-match semantics
/// anti-regression (title/body UTF-16 `matchedRanges`, snippets, pinned-first
/// order) stays pinned by the existing WS17 title-lane and SearchModeGapTests
/// body-lane fixtures, which are deliberately left untouched.
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

@Suite("SearchWorker regexp engine deadline (REVIEW Card 11C)")
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
        "admitted chain fails typed at the injected engine deadline without wedging"
    )
    func admittedChainFailsTypedAtEngineDeadline() async throws {
        let worker = SearchWorker()
        await worker.setRegexpEngineDeadline(.zero)
        let clock = ContinuousClock()
        let start = clock.now

        await #expect(
            throws: HistoryFailure.temporarilyUnavailable(.searchEngineDeadline)
        ) {
            _ = try await worker.page(
                HistoryBrowseRequest(
                    kind: .search(text: Self.chainPattern, mode: .regexp),
                    limit: 10
                ),
                in: Self.chainCorpus(),
                continuationAnchor: nil,
                processMarker: UUID()
            )
        }

        // The deadline stop must return through the progress callback in
        // milliseconds; an unbounded or watchdog-only regression to a
        // non-interruptible operation fails this wall-clock bound.
        #expect(clock.now - start < .seconds(5))
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
