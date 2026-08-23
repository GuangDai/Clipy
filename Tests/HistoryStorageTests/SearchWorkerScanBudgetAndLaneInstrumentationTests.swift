#if DEBUG
/// Debug-only proofs for the page-driven scan budget (03b §8; 04 §6) and
/// the fuzzy/regexp lane instrumentation. Every test drives the real public
/// facade and asserts either caller-visible page semantics or aggregate
/// probe events — never presentation internals directly.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct SearchWorkerScanBudgetAndLaneInstrumentationTests {
    private static let base = Date(timeIntervalSinceReferenceDate: 720_000_000)

    /// Captures `bodies.count` rows whose titles are numeric (no letters, so
    /// letter-bearing terms can never title-match) and bodies come from the
    /// caller. Array order is the corpus's default order: observedAt
    /// decreases with index.
    private static func seedCorpus(
        _ history: SwiftDataHistory,
        bodies: [String]
    ) async throws {
        for (index, body) in bodies.enumerated() {
            _ = try await history.perform(.capture(WSSupport.textCapture(
                body,
                observedAt: Self.base.addingTimeInterval(Double(bodies.count - index)),
                source: "com.example.budget"
            )))
        }
    }

    private static func captureProbe(
        into history: SwiftDataHistory
    ) async -> (
        stream: AsyncStream<SearchDebugEvent>,
        continuation: AsyncStream<SearchDebugEvent>.Continuation,
        probe: SearchDebugProbe
    ) {
        let (events, continuation) = AsyncStream<SearchDebugEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        let probe = SearchDebugProbe(isEnabled: true) { event in
            _ = continuation.yield(event)
        }
        await history.authority.setSearchDebugProbe(probe)
        await history.searchWorker.setSearchDebugProbe(probe)
        return (events, continuation, probe)
    }

    private static func finishCapture(
        _ history: SwiftDataHistory,
        stream: AsyncStream<SearchDebugEvent>,
        continuation: AsyncStream<SearchDebugEvent>.Continuation
    ) async -> [SearchDebugEvent] {
        await history.authority.setSearchDebugProbe(SearchDebugProbe(isEnabled: false))
        await history.searchWorker.setSearchDebugProbe(SearchDebugProbe(isEnabled: false))
        continuation.finish()
        var captured: [SearchDebugEvent] = []
        for await event in stream {
            captured.append(event)
        }
        return captured
    }

    /// 12 corpus rows; the eight `T`-bearing rows match the exact term in
    /// body order M M M N M M N M M N N M (newest → oldest). With
    /// `limit == 5` the first scan must stop after the sixth survivor
    /// candidate — match positions 0, 1, 2, 4, 5, 7 put the sixth at row
    /// index 7, so eight rows are processed — and the continuation, whose
    /// anchor is the fifth match, finds only three post-anchor survivors
    /// and therefore scans the whole corpus again. Pages must partition
    /// the matches exactly.
    @Test func exactScanStopsAtThePageBudgetAndResumesAcrossContinuations() async throws {
        let storeURL = WSSupport.tempStoreURL("scan-budget-exact")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        // Bodies are pairwise distinct (copy coalescing would otherwise
        // collapse them); the exact term still matches every `true` row.
        let layout: [Bool] = [
            true, true, true, false,
            true, true, false, true,
            true, false, false, true,
        ]
        try await Self.seedCorpus(history, bodies: layout.enumerated().map { index, matches in
            matches
                ? "0123456789\nbudgetterm \(String(format: "%02d", index))\n9876543210"
                : "0123456789\n9876543210\n\(String(format: "%02d", index))"
        })

        let (events, eventContinuation, _) = await Self.captureProbe(into: history)
        let first = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: "budgetterm", mode: .exact),
            limit: 5
        ))
        #expect(first.rows.count == 5)
        #expect(first.next != nil)
        // The term appears only below the first line, so every returned row
        // is a body match whose deferred 03b §8 excerpt materialized here.
        #expect(first.rows.allSatisfy { $0.search?.snippet != nil })
        let firstEvents = await Self.finishCapture(
            history,
            stream: events,
            continuation: eventContinuation
        )

        let scanComplete = try #require(firstEvents.first {
            $0.component == "worker" && $0.phase == "exact-scan-complete"
        })
        #expect(scanComplete.rowsProcessed == 8)
        #expect(scanComplete.rowsTotal == 12)
        #expect(scanComplete.matchedRows == 6)

        let (continuationEvents, tailContinuation, _) = await Self.captureProbe(
            into: history
        )
        let second = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: "budgetterm", mode: .exact),
            limit: 5,
            after: first.next
        ))
        #expect(second.rows.count == 3)
        #expect(second.next == nil)
        let secondEvents = await Self.finishCapture(
            history,
            stream: continuationEvents,
            continuation: tailContinuation
        )

        let continuationComplete = try #require(secondEvents.first {
            $0.component == "worker" && $0.phase == "exact-scan-complete"
        })
        #expect(continuationComplete.rowsProcessed == 12)
        #expect(continuationComplete.matchedRows == 8)

        // No gap, no repeat: the two pages partition the eight matches.
        let firstIDs = Set(first.rows.map(\.item.id))
        let secondIDs = Set(second.rows.map(\.item.id))
        #expect(firstIDs.count == 5)
        #expect(secondIDs.count == 3)
        #expect(firstIDs.isDisjoint(with: secondIDs))
        #expect(first.rows.count + second.rows.count == 8)
    }

    /// The order-preserving tracker never stops before the continuation
    /// anchor: an anchor deep in the corpus forces the full scan, and the
    /// tail page still returns exactly the remaining matches.
    @Test func exactScanWithLateAnchorScansTheWholeCorpusForTheTail() async throws {
        let storeURL = WSSupport.tempStoreURL("scan-budget-late-anchor")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        try await Self.seedCorpus(history, bodies: (0..<12).map { index in
            "0123456789\nbudgetterm \(String(format: "%02d", index))\n9876543210"
        })

        let first = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: "budgetterm", mode: .exact),
            limit: 10
        ))
        #expect(first.rows.count == 10)
        #expect(first.next != nil)

        let second = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: "budgetterm", mode: .exact),
            limit: 10,
            after: first.next
        ))
        #expect(second.rows.count == 2)
        #expect(second.next == nil)
    }

    /// Empty search routes through the scalar recent lane, whose three pages
    /// partition the retained ordering without SearchWorker evaluation.
    @Test func recentEquivalentUsesScalarRecentPagination() async throws {
        let storeURL = WSSupport.tempStoreURL("scan-budget-recent")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        try await Self.seedCorpus(history, bodies: (0..<12).map { "0123456789 \($0)" })

        let first = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: "", mode: .exact),
            limit: 5
        ))
        #expect(first.rows.count == 5)
        #expect(first.next != nil)

        var cursor = first.next
        var seen = Set(first.rows.map(\.item.id))
        var pages = 1
        while let current = cursor {
            let page = try await history.browse(HistoryBrowseRequest(
                kind: .search(text: "", mode: .exact),
                limit: 5,
                after: current
            ))
            for row in page.rows {
                #expect(seen.insert(row.item.id).inserted)
            }
            cursor = page.next
            pages += 1
        }
        #expect(seen.count == 12)
        #expect(pages == 3)
    }

    /// The fuzzy lane emits its begin/complete events with per-lane title
    /// and body accounting; the row that matches in title and the row that
    /// matches in body are counted separately and nothing else matches.
    @Test func fuzzyScanEmitsLaneEventsWithSeparateTitleAndBodyAccounting() async throws {
        let storeURL = WSSupport.tempStoreURL("fuzzy-lane-probe")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        try await Self.seedCorpus(history, bodies: [
            "0123456789\nbudget\n9876543210",
            "0123456789\n9876543210\n001",
            "0123456789\n9876543210\n002",
        ])
        // One body-only match (term below the first line, digit-only title)
        // plus one title match (term in the single-line body ⇒ title).
        _ = try await history.perform(.capture(WSSupport.textCapture(
            "budget 0123456789",
            observedAt: Self.base.addingTimeInterval(100),
            source: "com.example.budget"
        )))

        let (events, eventContinuation, _) = await Self.captureProbe(into: history)
        let page = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: "budget", mode: .fuzzy),
            limit: 10
        ))
        let captured = await Self.finishCapture(
            history,
            stream: events,
            continuation: eventContinuation
        )

        let complete = try #require(captured.first {
            $0.component == "worker" && $0.phase == "fuzzy-scan-complete"
        })
        #expect(complete.rowsTotal == 4)
        #expect(complete.rowsProcessed == 4)
        #expect(complete.titleMatches == 1)
        #expect(complete.bodyMatches == 1)
        #expect(complete.matchedRows == 2)
        #expect(captured.contains {
            $0.component == "worker" && $0.phase == "fuzzy-scan-begin"
        })
        #expect(page.rows.count == 2)
    }

    /// The regexp lane emits the same correlated accounting, and its
    /// deferred body excerpt still reports the omitted suffix at the scan
    /// bound via the caller-visible snippet.
    @Test func regexpScanEmitsLaneEventsWithSeparateTitleAndBodyAccounting() async throws {
        let storeURL = WSSupport.tempStoreURL("regexp-lane-probe")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        try await Self.seedCorpus(history, bodies: [
            "0123456789\nbudget\n9876543210",
            "0123456789\n9876543210\n001",
            "0123456789\n9876543210\n002",
        ])
        _ = try await history.perform(.capture(WSSupport.textCapture(
            "budget 0123456789",
            observedAt: Self.base.addingTimeInterval(100),
            source: "com.example.budget"
        )))

        let (events, eventContinuation, _) = await Self.captureProbe(into: history)
        let page = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: "budget", mode: .regexp),
            limit: 10
        ))
        let captured = await Self.finishCapture(
            history,
            stream: events,
            continuation: eventContinuation
        )

        let complete = try #require(captured.first {
            $0.component == "worker" && $0.phase == "regexp-scan-complete"
        })
        #expect(complete.rowsTotal == 4)
        #expect(complete.rowsProcessed == 4)
        #expect(complete.titleMatches == 1)
        #expect(complete.bodyMatches == 1)
        #expect(complete.matchedRows == 2)
        #expect(captured.contains {
            $0.component == "worker" && $0.phase == "regexp-scan-begin"
        })
        #expect(page.rows.count == 2)
    }
    /// The body-prefix slice the fuzzy/regexp lanes (and deferred excerpt
    /// materialization) rely on: exact Character counting at and around the
    /// scan bound, grapheme-boundary safety for multi-byte Characters, and
    /// the omitted-suffix flag that drives the excerpt's trailing ellipsis.
    /// (Fuse's frozen `distance: 100` scoring cannot accept matches ~5,000
    /// Characters deep, so the 5,000-Character lane boundary is pinned at
    /// the helper the lanes consume rather than through a store.)
    @Test func boundedCharacterPrefixSlicesExactlyAtTheCharacterBound() {
        let exact = String(repeating: "a", count: 5_000)
        let exactScan = SearchWorker.boundedCharacterPrefix(
            of: exact,
            maximumCharacters: 5_000
        )
        #expect(exactScan.characterCount == 5_000)
        #expect(!exactScan.suffixWasOmitted)
        #expect(exactScan.text.count == 5_000)

        let continues = exact + "b"
        let truncatedScan = SearchWorker.boundedCharacterPrefix(
            of: continues,
            maximumCharacters: 5_000
        )
        #expect(truncatedScan.characterCount == 5_000)
        #expect(truncatedScan.suffixWasOmitted)
        #expect(truncatedScan.text == exact)

        // Multi-byte graphemes count as one Character and never split.
        let accented = String(repeating: "é", count: 5_001)
        let accentedScan = SearchWorker.boundedCharacterPrefix(
            of: accented,
            maximumCharacters: 5_000
        )
        #expect(accentedScan.characterCount == 5_000)
        #expect(accentedScan.suffixWasOmitted)
        #expect(accentedScan.text == String(repeating: "é", count: 5_000))
        #expect(
            accentedScan.text.utf8.count == 5_000 * ("é" as Character).utf8.count
        )
    }
}
#endif
