#if DEBUG
/// Debug-only instrumentation proofs for the search pipeline. These tests
/// drive the real public facade and real SwiftData implementation, then
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

    @Test func exactSearchEmitsCorrelatedAuthorityAndWorkerStages() async throws {
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

        let page = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: "absent diagnostic term", mode: .exact),
            limit: 10
        ))
        #expect(page.rows.isEmpty)
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
        let expectedPhases: Set<String> = [
            "authority.entry",
            "authority.request-admission",
            "authority.context-create",
            "authority.position-read",
            "authority.corpus-fetch-begin",
            "authority.corpus-fetch",
            "authority.corpus-projection-begin",
            "authority.corpus-projection-progress",
            "authority.corpus-projection-complete",
            "authority.corpus-sort-begin",
            "authority.corpus-sort",
            "authority.complete",
            "worker.entry",
            "worker.exact-scan-begin",
            "worker.exact-scan-progress",
            "worker.exact-title-scan",
            "worker.exact-body-scan",
            "worker.exact-scan-complete",
            "worker.evaluation-complete",
            "worker.continuation",
            "worker.page-materialization",
            "worker.complete",
        ]
        #expect(expectedPhases.isSubset(of: phases))

        let fetch = try #require(captured.first {
            $0.component == "authority" && $0.phase == "corpus-fetch"
        })
        #expect(fetch.rowsProcessed == 3)
        #expect(fetch.rowsTotal == 3)

        let bodyScan = try #require(captured.first {
            $0.component == "worker" && $0.phase == "exact-body-scan"
        })
        #expect(bodyScan.rowsProcessed == 3)
        #expect(bodyScan.rowsTotal == 3)
        #expect(bodyScan.bodyUTF8Bytes > 0)
        #expect(bodyScan.matchedRows == 0)

        let rendered = captured.compactMap(\.jsonLine).joined(separator: "\n")
        for fragment in privateFragments {
            #expect(!rendered.contains(fragment))
        }
        #expect(!rendered.contains("absent diagnostic term"))
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
}
#endif
