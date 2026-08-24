#if DEBUG
/// REVIEW Card 11B cooperative-cancellation proofs. The seam is the existing
/// `SearchWorker.page` value boundary plus its nil-in-production suspension
/// handler: the real exact/regexp/fuzzy algorithms run over an immutable
/// corpus, while `SuspensionGate` fixes the cancellation/replacement order
/// without timing guesses (review playbook §16; architecture deepening §5).
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

@Suite("SearchWorker cooperative cancellation (REVIEW Card 11B)")
struct SearchWorkerCancellationTests {
    private actor FirstChunkParkLatch {
        private var armed = true

        func consume() -> Bool {
            defer { armed = false }
            return armed
        }
    }

    private static func row(index: Int) -> SearchCorpusRow {
        let title = index == 0
            ? "replacement query result"
            : "zzzzzzzzzzzzzz title \(index)"
        let body = "zzzzzzzzzzzzzz body \(index)"
        return SearchCorpusRow(
            id: HistoryItemID(rawValue: UUID()),
            contentVersion: .initial,
            title: title,
            searchBody: body,
            debugTitleUTF8Bytes: title.utf8.count,
            debugSearchBodyUTF8Bytes: body.utf8.count,
            typeIdentifiers: ["public.utf8-plain-text"],
            lastCopiedAt: Date(
                timeIntervalSinceReferenceDate: 730_000_000 - Double(index)
            ),
            copyCount: 1,
            lastSource: nil,
            pinOrdinal: nil
        )
    }

    private static func corpus() -> SearchCorpusSnapshot {
        SearchCorpusSnapshot(
            position: ChangePosition(rawValue: 7),
            rows: (0..<128).map { Self.row(index: $0) },
            debugTrace: SearchDebugTrace(
                id: UUID(),
                startedAt: ContinuousClock().now
            )
        )
    }

    private static func proveReplacementDoesNotWaitForCancelledScan(
        mode: SearchMode,
        point: SearchWorkerSuspensionPoint
    ) async throws {
        let worker = SearchWorker()
        let gate = SuspensionGate()
        let latch = FirstChunkParkLatch()
        await worker.setSuspensionHandler { reachedPoint in
            guard reachedPoint == point else { return }
            guard await latch.consume() else { return }
            await gate.park(at: reachedPoint.rawValue)
        }

        let corpus = Self.corpus()
        let marker = UUID()
        let cancelled = Task {
            try await worker.page(
                HistoryBrowseRequest(
                    kind: .search(text: "query absent from every row", mode: mode),
                    limit: 10
                ),
                in: corpus,
                continuationAnchor: nil,
                processMarker: marker
            )
        }
        await gate.waitForPark(point.rawValue)
        cancelled.cancel()

        do {
            // A is still parked at its first scan chunk. Actor reentrancy lets
            // B enter, while the one-shot latch keeps B from parking. If the
            // worker serialized a whole uncancelled A scan, this await could
            // not finish before the explicit A resume below.
            let replacement = try await worker.page(
                HistoryBrowseRequest(
                    kind: .search(text: "replacement", mode: mode),
                    limit: 10
                ),
                in: corpus,
                continuationAnchor: nil,
                processMarker: marker
            )
            #expect(replacement.rows.map(\.title) == ["replacement query result"])

            await gate.resume(point.rawValue)
            await #expect(throws: CancellationError.self) {
                _ = try await cancelled.value
            }
            await worker.setSuspensionHandler(nil)
        } catch {
            await gate.resume(point.rawValue)
            cancelled.cancel()
            _ = try? await cancelled.value
            await worker.setSuspensionHandler(nil)
            throw error
        }
    }

    /// Cancels the child from the existing 250-row aggregate progress probe.
    /// The next 32-row checkpoint must stop before the 500-row progress event;
    /// an entry-only or post-evaluation cancellation check would still emit it.
    private static func proveCancellationStopsAtNextChunk(
        mode: SearchMode,
        progressPhase: String,
        completionPhase: String
    ) async throws {
        let worker = SearchWorker()
        let corpus = SearchCorpusSnapshot(
            position: ChangePosition(rawValue: 8),
            rows: (0..<600).map { Self.row(index: $0) },
            debugTrace: SearchDebugTrace(
                id: UUID(),
                startedAt: ContinuousClock().now
            )
        )
        let (events, continuation) = AsyncStream<SearchDebugEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        await worker.setSearchDebugProbe(SearchDebugProbe(isEnabled: true) { event in
            _ = continuation.yield(event)
            guard event.phase == progressPhase,
                  event.rowsProcessed == SearchDebugProbe.progressRowInterval
            else {
                return
            }
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
        })

        let cancelled = Task {
            try await worker.page(
                HistoryBrowseRequest(
                    kind: .search(text: "nevermatches", mode: mode),
                    limit: 10
                ),
                in: corpus,
                continuationAnchor: nil,
                processMarker: UUID()
            )
        }
        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.value
        }
        await worker.setSearchDebugProbe(SearchDebugProbe(isEnabled: false))
        continuation.finish()

        var captured: [SearchDebugEvent] = []
        for await event in events {
            captured.append(event)
        }
        #expect(
            captured
                .filter { $0.phase == progressPhase }
                .map(\.rowsProcessed) == [SearchDebugProbe.progressRowInterval]
        )
        #expect(!captured.contains { $0.phase == completionPhase })
        #expect(!captured.contains { $0.phase == "evaluation-complete" })
    }

    @Test("exact A cancellation does not delay exact B or return A's page")
    func exactScanCancellationIsCooperative() async throws {
        try await Self.proveReplacementDoesNotWaitForCancelledScan(
            mode: .exact,
            point: .exactScanChunk
        )
    }

    @Test("regexp A cancellation does not delay regexp B or return A's page")
    func regexpScanCancellationIsCooperative() async throws {
        try await Self.proveReplacementDoesNotWaitForCancelledScan(
            mode: .regexp,
            point: .regexpScanChunk
        )
    }

    @Test("fuzzy A cancellation does not delay fuzzy B or return A's page")
    func fuzzyScanCancellationIsCooperative() async throws {
        try await Self.proveReplacementDoesNotWaitForCancelledScan(
            mode: .fuzzy,
            point: .fuzzyScanChunk
        )
    }

    @Test("exact cancellation exits at the next fixed chunk checkpoint")
    func exactCancellationStopsAtNextChunk() async throws {
        try await Self.proveCancellationStopsAtNextChunk(
            mode: .exact,
            progressPhase: "exact-scan-progress",
            completionPhase: "exact-scan-complete"
        )
    }

    @Test("regexp cancellation exits at the next fixed chunk checkpoint")
    func regexpCancellationStopsAtNextChunk() async throws {
        try await Self.proveCancellationStopsAtNextChunk(
            mode: .regexp,
            progressPhase: "regexp-scan-progress",
            completionPhase: "regexp-scan-complete"
        )
    }

    @Test("fuzzy cancellation exits at the next fixed chunk checkpoint")
    func fuzzyCancellationStopsAtNextChunk() async throws {
        try await Self.proveCancellationStopsAtNextChunk(
            mode: .fuzzy,
            progressPhase: "fuzzy-scan-progress",
            completionPhase: "fuzzy-scan-complete"
        )
    }

    @Test("cancelled Authority projection exits before completing the corpus")
    func authorityProjectionCancellationIsCooperative() async throws {
        let storeURL = WSSupport.tempStoreURL(
            "search-authority-cancellation"
        )
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(
            storeURL: storeURL,
            maximumUnpinned: 600
        )
        _ = try await history.seedPerformanceFixture(rowCount: 600) { index in
            Self.fixtureCapture(index: index)
        }

        let (events, continuation) = AsyncStream<SearchDebugEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        await history.authority.setSearchDebugProbe(
            SearchDebugProbe(isEnabled: true) { event in
                _ = continuation.yield(event)
                guard event.phase == "corpus-projection-progress",
                      event.rowsProcessed
                        == SearchDebugProbe.progressRowInterval
                else { return }
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
            }
        )

        let cancelled = Task {
            try await history.browse(HistoryBrowseRequest(
                kind: .search(text: "absent-authority-term", mode: .exact),
                limit: 10
            ))
        }
        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.value
        }
        await history.authority.setSearchDebugProbe(
            SearchDebugProbe(isEnabled: false)
        )
        continuation.finish()

        var captured: [SearchDebugEvent] = []
        for await event in events {
            captured.append(event)
        }
        #expect(
            captured
                .filter { $0.phase == "corpus-projection-progress" }
                .map(\.rowsProcessed)
                == [SearchDebugProbe.progressRowInterval]
        )
        #expect(!captured.contains { $0.phase == "corpus-projection-complete" })
        #expect(!captured.contains { $0.phase == "corpus-sort" })
    }

    @Test("cancelled observed search cannot publish a completed stale page")
    func cancelledObservationFencesItsPendingYield() async throws {
        let storeURL = WSSupport.tempStoreURL("search-cancellation-publish-fence")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        _ = try await history.perform(.capture(WSSupport.textCapture(
            "replacement query result",
            observedAt: Date(timeIntervalSinceReferenceDate: 730_100_000),
            source: "com.example.search-cancellation"
        )))

        let gate = SuspensionGate()
        let latch = FirstChunkParkLatch()
        let willYieldPoint = "SearchWorkerCancellation.pageWillYield"
        let (yieldedPages, yieldedContinuation) =
            AsyncStream<HistoryPage>.makeStream(bufferingPolicy: .unbounded)

        let stream = await ObservationDebugInstrumentation.$pageWillYield.withValue(
            { _ in
                guard await latch.consume() else { return }
                // Cancel the real observation producer Task at the exact
                // pre-publication seam, then keep it parked while B runs.
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
                await gate.park(at: willYieldPoint)
            }
        ) {
            await ObservationDebugInstrumentation.$pageDidYield.withValue(
                { page in
                    _ = yieldedContinuation.yield(page)
                }
            ) {
                await history.observe(HistoryObservationRequest(
                    kind: .search(text: "replacement", mode: .exact),
                    limit: 10
                ))
            }
        }

        let consumer = Task { () -> HistoryPage? in
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }
        await gate.waitForPark(willYieldPoint)

        do {
            // The old observation producer is still parked immediately before
            // publication. An independent replacement read remains usable.
            let replacement = try await history.browse(HistoryBrowseRequest(
                kind: .search(text: "replacement", mode: .exact),
                limit: 10
            ))
            #expect(replacement.rows.map(\.title) == ["replacement query result"])

            await gate.resume(willYieldPoint)
            await #expect(throws: CancellationError.self) {
                _ = try await consumer.value
            }
            yieldedContinuation.finish()

            var attemptedPublications: [HistoryPage] = []
            for await page in yieldedPages {
                attemptedPublications.append(page)
            }
            #expect(
                attemptedPublications.isEmpty,
                "the cancelled producer must fail its yield fence"
            )
        } catch {
            await gate.resume(willYieldPoint)
            consumer.cancel()
            _ = try? await consumer.value
            yieldedContinuation.finish()
            throw error
        }
    }

    private static func fixtureCapture(index: Int) -> ClipboardCapture {
        let prefix = Data("cancel-row-\(index)-".utf8)
        let suffix = Data("-tail-\(index)".utf8)
        var bytes = Data(repeating: 0x78, count: 96)
        bytes.replaceSubrange(0..<prefix.count, with: prefix)
        bytes.replaceSubrange(
            (bytes.count - suffix.count)..<bytes.count,
            with: suffix
        )
        return ClipboardCapture(
            representations: [CapturedRepresentation(
                typeIdentifier: "public.utf8-plain-text",
                bytes: bytes
            )],
            origin: CopyOriginObservation(
                sourceApplication: "search-cancellation-fixture"
            ),
            observedAt: Date(timeIntervalSinceReferenceDate: 730_200_000)
        )
    }
}
#endif
