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
        _ history: SQLiteHistory,
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
        into history: SQLiteHistory
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
        _ history: SQLiteHistory,
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

    /// Twelve retained rows include eight body matches. The index omits
    /// numeric-only noncandidates, then the matcher stops at page+lookahead.
    /// Continuation reads its anchor and the remaining three candidates,
    /// preserving the exact public ordering without re-reading earlier hits.
    @Test(arguments: [SearchMode.exact, .regexp])
    func orderedScanStopsAtThePageBudgetAndResumesAcrossContinuations(mode: SearchMode) async throws {
        let storeURL = WSSupport.tempStoreURL("scan-budget-ordered")
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

        let retained = try await history.browse(.init(kind: .recent, limit: 20))
        let expectedIDs = zip(retained.rows, layout).compactMap { row, matches in
            matches ? row.item.id : nil
        }
        #expect(expectedIDs.count == 8)
        let (events, eventContinuation, _) = await Self.captureProbe(into: history)
        let first = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: "budgetterm", mode: mode),
            limit: 5
        ))
        #expect(first.rows.map(\.item.id) == Array(expectedIDs.prefix(5)))
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
            $0.component == "worker"
                && $0.phase == (mode == .exact ? "exact-scan-complete" : "regexp-scan-complete")
        })
        #expect(scanComplete.rowsProcessed == first.rows.count + 1)
        #expect(scanComplete.rowsTotal == expectedIDs.count)
        #expect(firstEvents.filter { $0.phase == "sqlite-batch" }.reduce(0) { $0 + $1.rowsProcessed } == expectedIDs.count)
        #expect(scanComplete.rowsTotal < retained.rows.count)
        #expect(scanComplete.matchedRows == 6)
        for phase in ["evaluation-complete", "continuation", "page-materialization", "complete"] {
            let summary = try #require(firstEvents.first {
                $0.component == "worker" && $0.phase == phase
            })
            #expect(summary.matchedRows == 6)
            if phase == "evaluation-complete" || phase == "complete" {
                #expect(summary.rowsProcessed == first.rows.count + 1)
                #expect(summary.rowsTotal == expectedIDs.count)
            }
        }

        let (continuationEvents, tailContinuation, _) = await Self.captureProbe(
            into: history
        )
        let second = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: "budgetterm", mode: mode),
            limit: 5,
            cursor: first.next
        ))
        #expect(second.rows.map(\.item.id) == Array(expectedIDs.dropFirst(5)))
        #expect(second.next == nil)
        let secondEvents = await Self.finishCapture(
            history,
            stream: continuationEvents,
            continuation: tailContinuation
        )

        let continuationComplete = try #require(secondEvents.first {
            $0.component == "worker"
                && $0.phase == (mode == .exact ? "exact-scan-complete" : "regexp-scan-complete")
        })
        let anchorAndTailCount = second.rows.count + 1
        #expect(continuationComplete.rowsProcessed == anchorAndTailCount)
        #expect(continuationComplete.rowsTotal == anchorAndTailCount)
        #expect(continuationComplete.matchedRows == anchorAndTailCount)
        #expect(secondEvents.filter { $0.phase == "sqlite-batch" }.reduce(0) { $0 + $1.rowsProcessed } == anchorAndTailCount)
        for phase in ["evaluation-complete", "continuation", "page-materialization", "complete"] {
            let summary = try #require(secondEvents.first {
                $0.component == "worker" && $0.phase == phase
            })
            // The inclusive anchor is validated again, while earlier matches
            // and numeric-only rows are outside this keyset read.
            #expect(summary.matchedRows == anchorAndTailCount)
            if phase == "evaluation-complete" || phase == "complete" {
                #expect(summary.rowsProcessed == anchorAndTailCount)
                #expect(summary.rowsTotal == anchorAndTailCount)
            }
        }

        // No gap, no repeat: the two pages partition the eight matches.
        let firstIDs = Set(first.rows.map(\.item.id))
        let secondIDs = Set(second.rows.map(\.item.id))
        #expect(firstIDs.count == 5)
        #expect(secondIDs.count == 3)
        #expect(firstIDs.isDisjoint(with: secondIDs))
        #expect(first.rows.count + second.rows.count == 8)
    }

    /// A late anchor reads only itself and the remaining candidates; the
    /// matcher still confirms that anchor before publishing its tail.
    @Test func exactScanWithLateAnchorReadsOnlyItsAdjacentTail() async throws {
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

        let (events, continuation, _) = await Self.captureProbe(into: history)
        let second = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: "budgetterm", mode: .exact),
            limit: 10,
            cursor: first.next
        ))
        #expect(second.rows.count == 2)
        #expect(second.next == nil)
        #expect(Set(first.rows.map(\.item.id)).isDisjoint(with: second.rows.map(\.item.id)))
        let captured = await Self.finishCapture(history, stream: events, continuation: continuation)
        let batchRows = captured.filter { $0.phase == "sqlite-batch" }.reduce(0) { $0 + $1.rowsProcessed }
        #expect(batchRows == second.rows.count + 1)
        let scan = try #require(captured.first { $0.phase == "exact-scan-complete" })
        #expect(scan.rowsProcessed == second.rows.count + 1)
        #expect(scan.matchedRows == second.rows.count + 1)
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
                cursor: current
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
    /// and body accounting. Three matches exceed the two-candidate heap for
    /// a one-row page; post-scan totals must still report all three hits.
    @Test func fuzzyScanEmitsLaneEventsWithSeparateTitleAndBodyAccounting() async throws {
        let storeURL = WSSupport.tempStoreURL("fuzzy-lane-probe")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        try await Self.seedCorpus(history, bodies: [
            "0123456789\nbudget\n9876543210",
            "0123456789\n9876543210\n001",
            "0123456789\nbbbbbbbbbb\n002",
        ])
        // One body-only match (term below the first line, digit-only title)
        // plus two title matches (term in the single-line body ⇒ title).
        _ = try await history.perform(.capture(WSSupport.textCapture(
            "budget 0123456789",
            observedAt: Self.base.addingTimeInterval(100),
            source: "com.example.budget"
        )))
        _ = try await history.perform(.capture(WSSupport.textCapture(
            "budget another title",
            observedAt: Self.base.addingTimeInterval(101),
            source: "com.example.budget"
        )))

        let (events, eventContinuation, _) = await Self.captureProbe(into: history)
        let page = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: "budget", mode: .fuzzy),
            limit: 1
        ))
        let captured = await Self.finishCapture(
            history,
            stream: events,
            continuation: eventContinuation
        )

        let complete = try #require(captured.first {
            $0.component == "worker" && $0.phase == "fuzzy-scan-complete"
        })
        // The numeric-only row is pruned; the b-only candidate shares an
        // indexed scalar but Fuse rejects it. The remaining three really match.
        #expect(complete.rowsTotal == 4)
        #expect(complete.rowsProcessed == 4)
        #expect(complete.matchedRows < complete.rowsProcessed)
        #expect(captured.filter { $0.phase == "sqlite-batch" }.reduce(0) { $0 + $1.rowsProcessed } == 4)
        #expect(complete.titleMatches == 2)
        #expect(complete.bodyMatches == 1)
        #expect(complete.matchedRows == 3)
        for phase in ["evaluation-complete", "continuation", "page-materialization", "complete"] {
            let summary = try #require(captured.first {
                $0.component == "worker" && $0.phase == phase
            })
            #expect(summary.matchedRows == 3)
            if phase == "evaluation-complete" || phase == "complete" {
                #expect(summary.rowsProcessed == 4)
            }
        }
        #expect(captured.contains {
            $0.component == "worker" && $0.phase == "fuzzy-scan-begin"
        })
        #expect(page.rows.count == 1)
        #expect(page.next != nil)
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
            "0123456789\nbud udg dge get\n002",
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
        // Split grams admit one false-positive candidate; native regexp
        // matching rejects it, while the numeric-only row is never decoded.
        #expect(complete.rowsTotal == 3)
        #expect(complete.rowsProcessed == 3)
        #expect(captured.filter { $0.phase == "sqlite-batch" }.reduce(0) { $0 + $1.rowsProcessed } == 3)
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
