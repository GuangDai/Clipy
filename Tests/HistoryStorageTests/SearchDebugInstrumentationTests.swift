#if DEBUG
/// Debug-only instrumentation proofs for the search pipeline. These tests
/// drive the real public facade and real SQLite implementation, then
/// inspect only aggregate events from the injected probe.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct SearchDebugInstrumentationTests {
    private static func row(index: Int) -> SearchCorpusRow {
        let title = "diagnostic-title-\(index)"
        let body = "diagnostic-body-\(index)"
        return SearchCorpusRow(
            id: HistoryItemID(rawValue: UUID()),
            contentVersion: .initial,
            title: title,
            searchBody: body,
            debugTitleUTF8Bytes: title.utf8.count,
            debugSearchBodyUTF8Bytes: body.utf8.count,
            typeIdentifiers: ["public.utf8-plain-text"],
            lastCopiedAt: Date(
                timeIntervalSinceReferenceDate: 710_100_000 + Double(index)
            ),
            copyCount: 1,
            lastSource: nil,
            pinOrdinal: nil
        )
    }

    @Test(arguments: [false, true])
    func exactSearchEmitsOnlyTheStagesActuallyNeeded(hasCandidates: Bool) async throws {
        let storeURL = WSSupport.tempStoreURL("search-debug-stages")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        let privateFragments = [
            "private alpha\nfirst concealed body",
            "private beta\nsecond concealed body",
            "private gamma\nthird concealed body",
        ]
        for (index, text) in privateFragments.enumerated() {
            _ = try await history.perform(.capture(WSSupport.textCapture(
                text,
                observedAt: Date(
                    timeIntervalSinceReferenceDate: 710_000_000 + Double(index)
                ),
                source: "com.example.private-source-\(index)"
            )))
        }

        let (events, continuation) = AsyncStream<SearchDebugEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        let probe = SearchDebugProbe(isEnabled: true) { event in
            _ = continuation.yield(event)
        }
        await history.authority.setSearchDebugProbe(probe)
        await history.searchWorker.setSearchDebugProbe(probe)

        let term = hasCandidates ? "concealed" : "absent diagnostic term"
        let page = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: term, mode: .exact),
            limit: 10
        ))
        #expect(page.rows.count == (hasCandidates ? privateFragments.count : 0))
        await history.authority.setSearchDebugProbe(
            SearchDebugProbe(isEnabled: false)
        )
        await history.searchWorker.setSearchDebugProbe(
            SearchDebugProbe(isEnabled: false)
        )
        continuation.finish()

        var captured: [SearchDebugEvent] = []
        for await event in events {
            captured.append(event)
        }
        #expect(!captured.isEmpty)
        #expect(captured.allSatisfy { $0.event == "clipy.search.trace" })
        #expect(Set(captured.map(\.traceID)).count == 1)

        let phases = Set(captured.map { "\($0.component).\($0.phase)" })
        let queryPhases: Set<String> = [
            "worker.entry", "worker.evaluation-complete", "worker.continuation",
            "worker.page-materialization", "worker.complete",
        ]
        #expect(queryPhases.isSubset(of: phases))
        if hasCandidates {
            let matcherPhases: Set<String> = [
                "worker.sqlite-batch", "worker.exact-scan-begin", "worker.exact-scan-progress",
                "worker.exact-title-scan", "worker.exact-body-scan", "worker.exact-scan-complete",
            ]
            #expect(matcherPhases.isSubset(of: phases))
            let fetch = try #require(captured.first { $0.phase == "sqlite-batch" })
            #expect(fetch.rowsProcessed == privateFragments.count)
            #expect(fetch.rowsTotal == privateFragments.count)
            #expect(fetch.sourceUTF8Bytes > 0)
            // Titles miss; all candidates take the body lane and return
            // actual excerpts, establishing that both matcher stages ran.
            #expect(page.rows.allSatisfy { $0.search?.snippet != nil })
            let bodyScan = try #require(captured.first { $0.phase == "exact-body-scan" })
            #expect(bodyScan.rowsProcessed == privateFragments.count)
            #expect(bodyScan.rowsTotal == privateFragments.count)
            #expect(bodyScan.bodyUTF8Bytes > 0)
            #expect(bodyScan.matchedRows == privateFragments.count)
            #expect(bodyScan.exactASCIIEvaluations == privateFragments.count * 2)
            #expect(bodyScan.exactFoundationEvaluations == 0)
        } else {
            // An absent gram proves there are no candidates, so neither
            // payload projection nor a fabricated matcher trace is required.
            #expect(phases == queryPhases)
            let complete = try #require(captured.first { $0.phase == "complete" })
            #expect(complete.rowsProcessed == 0)
            #expect(complete.rowsTotal == 0)
            #expect(complete.matchedRows == 0)
        }

        let rendered = captured.compactMap(\.jsonLine).joined(separator: "\n")
        for fragment in privateFragments {
            #expect(!rendered.contains(fragment))
        }
        #expect(!rendered.contains(term))
        #expect(!rendered.contains("com.example.private-source"))
        #expect(!rendered.contains(storeURL.path))
    }

    @Test func disabledProbeEmitsNothing() async {
        let (events, continuation) = AsyncStream<SearchDebugEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        let probe = SearchDebugProbe(isEnabled: false) { event in
            _ = continuation.yield(event)
        }
        probe.record(
            traceID: UUID(),
            component: "worker",
            phase: "entry",
            phaseElapsed: .zero,
            totalElapsed: .zero
        )
        continuation.finish()

        var count = 0
        for await _ in events {
            count += 1
        }
        #expect(count == 0)
    }

    @Test func exactWorkerFlushesIntermediateProgressBeforeCompletion() async throws {
        let trace = SearchDebugTrace(
            id: UUID(),
            startedAt: ContinuousClock().now
        )
        let corpus = SearchCorpusSnapshot(
            position: ChangePosition(rawValue: 1),
            rows: (0...250).map { Self.row(index: $0) },
            debugTrace: trace
        )
        let (events, continuation) = AsyncStream<SearchDebugEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        let probe = SearchDebugProbe(isEnabled: true) { event in
            _ = continuation.yield(event)
        }
        let worker = SearchWorker()
        await worker.setSearchDebugProbe(probe)

        let page = try await worker.page(
            HistoryBrowseRequest(
                kind: .search(text: "absent", mode: .exact),
                limit: 10
            ),
            in: corpus,
            continuationAnchor: nil,
            processMarker: UUID()
        )
        #expect(page.rows.isEmpty)
        await worker.setSearchDebugProbe(SearchDebugProbe(isEnabled: false))
        continuation.finish()

        var captured: [SearchDebugEvent] = []
        for await event in events {
            captured.append(event)
        }
        let intermediateIndex = try #require(captured.firstIndex {
            $0.phase == "exact-scan-progress" && $0.rowsProcessed == 250
        })
        let completionIndex = try #require(captured.firstIndex {
            $0.phase == "exact-scan-complete"
        })
        #expect(intermediateIndex < completionIndex)
        #expect(captured[intermediateIndex].rowsTotal == 251)
        #expect(captured.allSatisfy { $0.traceID == trace.id })

        let totals = captured.map(\.totalElapsedMilliseconds)
        #expect(zip(totals, totals.dropFirst()).allSatisfy { pair in
            pair.0 <= pair.1
        })
    }

    /// Route accounting: the completion event must separate title hits from
    /// body hits, sum only the bytes actually scanned per lane, and count
    /// compiled-ASCII vs Foundation evaluations — the exact counters a later
    /// IND-07 debugging session needs at a glance.
    @Test func exactScanSeparatesTitleAndBodyRouteAccounting() async throws {
        func customRow(
            _ index: Int,
            title: String,
            body: String
        ) -> SearchCorpusRow {
            SearchCorpusRow(
                id: HistoryItemID(rawValue: UUID()),
                contentVersion: .initial,
                title: title,
                searchBody: body,
                debugTitleUTF8Bytes: title.utf8.count,
                debugSearchBodyUTF8Bytes: body.utf8.count,
                typeIdentifiers: ["public.utf8-plain-text"],
                lastCopiedAt: Date(
                    timeIntervalSinceReferenceDate: 710_200_000 + Double(index)
                ),
                copyCount: 1,
                lastSource: nil,
                pinOrdinal: nil
            )
        }

        let titleHit = customRow(
            0,
            title: "NEEDLE-alpha-title",
            body: "plain-body-alpha-never-scanned"
        )
        let bodyHit = customRow(
            1,
            title: "plain-title-beta",
            body: "prefix beta needle-in-body suffix"
        )
        let foundationTitle = customRow(
            2,
            title: "t\u{EF}tle-c\u{E9}-non-ascii",
            body: "plain-body-gamma"
        )
        let trace = SearchDebugTrace(
            id: UUID(),
            startedAt: ContinuousClock().now
        )
        let corpus = SearchCorpusSnapshot(
            position: ChangePosition(rawValue: 1),
            rows: [titleHit, bodyHit, foundationTitle],
            debugTrace: trace
        )
        let (events, continuation) = AsyncStream<SearchDebugEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        let probe = SearchDebugProbe(isEnabled: true) { event in
            _ = continuation.yield(event)
        }
        let worker = SearchWorker()
        await worker.setSearchDebugProbe(probe)

        let page = try await worker.page(
            HistoryBrowseRequest(
                kind: .search(text: "needle", mode: .exact),
                limit: 10
            ),
            in: corpus,
            continuationAnchor: nil,
            processMarker: UUID()
        )
        #expect(page.rows.count == 2)
        await worker.setSearchDebugProbe(SearchDebugProbe(isEnabled: false))
        continuation.finish()

        var captured: [SearchDebugEvent] = []
        for await event in events {
            captured.append(event)
        }
        let complete = try #require(
            captured.first { $0.phase == "exact-scan-complete" }
        )
        #expect(complete.titleMatches == 1)
        #expect(complete.bodyMatches == 1)
        #expect(complete.matchedRows == 2)
        #expect(complete.exactASCIIEvaluations == 4)
        #expect(complete.exactFoundationEvaluations == 1)
        #expect(complete.titleUTF8Bytes
            == titleHit.title.utf8.count
                + bodyHit.title.utf8.count
                + foundationTitle.title.utf8.count)
        #expect(complete.bodyUTF8Bytes
            == bodyHit.searchBody.utf8.count
                + foundationTitle.searchBody.utf8.count)

        let titleScan = try #require(
            captured.first { $0.phase == "exact-title-scan" }
        )
        #expect(titleScan.rowsProcessed == 3)
        let bodyScan = try #require(
            captured.first { $0.phase == "exact-body-scan" }
        )
        #expect(bodyScan.rowsProcessed == 2)
    }

    /// Progress cadence: a 505-row corpus must flush exactly at the 250-row
    /// interval multiples and once more on the final row — no more, no less.
    @Test func progressCadenceFiresOnIntervalMultiplesAndLastRow() async throws {
        let trace = SearchDebugTrace(
            id: UUID(),
            startedAt: ContinuousClock().now
        )
        let corpus = SearchCorpusSnapshot(
            position: ChangePosition(rawValue: 1),
            rows: (0..<505).map { Self.row(index: $0) },
            debugTrace: trace
        )
        let (events, continuation) = AsyncStream<SearchDebugEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        let probe = SearchDebugProbe(isEnabled: true) { event in
            _ = continuation.yield(event)
        }
        let worker = SearchWorker()
        await worker.setSearchDebugProbe(probe)

        _ = try await worker.page(
            HistoryBrowseRequest(
                kind: .search(text: "absent", mode: .exact),
                limit: 10
            ),
            in: corpus,
            continuationAnchor: nil,
            processMarker: UUID()
        )
        await worker.setSearchDebugProbe(SearchDebugProbe(isEnabled: false))
        continuation.finish()

        var captured: [SearchDebugEvent] = []
        for await event in events {
            captured.append(event)
        }
        let progress = captured.filter { $0.phase == "exact-scan-progress" }
        #expect(progress.map(\.rowsProcessed) == [250, 500, 505])
        #expect(progress.allSatisfy { $0.rowsTotal == 505 })
    }
}
#endif
