#if DEBUG
/// REVIEW Card 11A — search request admission must reject an invalid query
/// before the Authority creates a ModelContext or begins corpus fetch. The
/// behavior seam is the public `SwiftDataHistory.browse`; the existing
/// privacy-safe aggregate search probe is only the I/O oracle.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

@Suite("Search admission before I/O (REVIEW Card 11A)")
struct SearchAdmissionBeforeIOTests {
    @Test("an exact term over 4,096 UTF-8 bytes is rejected before search I/O")
    func oversizedExactTermIsRejectedBeforeSearchIO() async throws {
        let request = HistoryBrowseRequest(
            kind: .search(
                text: String(repeating: "a", count: 4_097),
                mode: .exact
            ),
            limit: 10
        )

        let observation = try await observeSearch(request)

        #expect(
            observation.failure == .invalidInput(.invalidSearchTerm)
        )
        expectNoSearchStorageTouch(observation)
    }

    @Test("a fuzzy term over 64 Characters is rejected before search I/O")
    func oversizedFuzzyTermIsRejectedBeforeSearchIO() async throws {
        let request = HistoryBrowseRequest(
            kind: .search(
                text: String(repeating: "é", count: 65),
                mode: .fuzzy
            ),
            limit: 10
        )

        let observation = try await observeSearch(request)

        #expect(
            observation.failure == .invalidInput(.invalidSearchTerm)
        )
        expectNoSearchStorageTouch(observation)
    }

    @Test("an unsafe regexp is rejected before search I/O")
    func unsafeRegexpIsRejectedBeforeSearchIO() async throws {
        let request = HistoryBrowseRequest(
            kind: .search(text: "(a+)+", mode: .regexp),
            limit: 10
        )

        let observation = try await observeSearch(request)

        #expect(
            observation.failure
                == .invalidInput(.invalidRegularExpression)
        )
        expectNoSearchStorageTouch(observation)
    }

    @Test("an invalid regexp is rejected before search I/O")
    func invalidRegexpIsRejectedBeforeSearchIO() async throws {
        let request = HistoryBrowseRequest(
            kind: .search(text: "(", mode: .regexp),
            limit: 10
        )

        let observation = try await observeSearch(request)

        #expect(
            observation.failure
                == .invalidInput(.invalidRegularExpression)
        )
        expectNoSearchStorageTouch(observation)
    }

    @Test("an empty search remains a recent-equivalent scalar read")
    func emptySearchStillReadsRecentEquivalentCorpus() async throws {
        let request = HistoryBrowseRequest(
            kind: .search(text: "", mode: .fuzzy),
            limit: 1
        )

        let observation = try await observeSearch(
            request,
            seedText: "empty search recent control"
        )

        #expect(observation.failure == nil)
        #expect(observation.page == observation.recentControl)
        #expect(observation.page?.next != nil)
        #expect(observation.recentContinuation?.rows.count == 1)
        #expect(observation.recentContinuation?.next == nil)
        #expect(observation.storagePhases.count(where: { $0 == .recentFetchBegin }) == 1)
        #expect(observation.storagePhases.count(where: { $0 == .recentFetchComplete }) == 1)
        // PERF-1: the facade routes the empty term directly to the scalar
        // recent lane. No search Authority trace means no full-corpus fetch;
        // no worker trace means no matcher, continuation evaluation, or page
        // materialization was started.
        #expect(observation.phases.isEmpty)
    }

    private struct SearchObservation {
        let failure: HistoryFailure?
        let page: HistoryPage?
        let recentControl: HistoryPage?
        let recentContinuation: HistoryPage?
        let phases: [String]
        let storagePhases: [StorageLifecycleDebugPhase]
    }

    /// Card 11A's existing admission evidence is stated as exact zero touches
    /// across all expensive search stages. Checking only one fetch phase could
    /// miss a future path that creates a context, resolves store facts, or
    /// enters the worker before failing admission.
    private func expectNoSearchStorageTouch(_ observation: SearchObservation) {
        #expect(
            observation.phases.count(where: { $0 == "authority.context-create" }) == 0
        )
        #expect(
            observation.phases.count(where: { $0.hasPrefix("authority.corpus-") }) == 0
        )
        #expect(
            observation.phases.count(where: { $0.hasPrefix("worker.") }) == 0
        )
        #expect(observation.storagePhases.isEmpty)
    }

    private func observeSearch(
        _ request: HistoryBrowseRequest,
        seedText: String? = nil
    ) async throws -> SearchObservation {
        let storeURL = WSSupport.tempStoreURL("search-admission-before-io")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        let recentControl: HistoryPage?
        if let seedText {
            _ = try await history.perform(.capture(WSSupport.textCapture(
                seedText,
                observedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
                source: "search-admission-control"
            )))
            _ = try await history.perform(.capture(WSSupport.textCapture(
                "\(seedText) second",
                observedAt: Date(timeIntervalSinceReferenceDate: 800_000_001),
                source: "search-admission-control"
            )))
            recentControl = try await history.browse(HistoryBrowseRequest(
                kind: .recent,
                limit: request.limit
            ))
        } else {
            recentControl = nil
        }
        let (events, continuation) = AsyncStream<SearchDebugEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        let (storageEvents, storageContinuation) =
            AsyncStream<StorageLifecycleDebugEvent>.makeStream(
                bufferingPolicy: .unbounded
            )
        let probe = SearchDebugProbe(isEnabled: true) { event in
            _ = continuation.yield(event)
        }
        await history.authority.setSearchDebugProbe(probe)
        await history.searchWorker.setSearchDebugProbe(probe)
        await history.authority.setStorageLifecycleDebugProbe(
            StorageLifecycleDebugProbe(isEnabled: true) { event in
                _ = storageContinuation.yield(event)
            }
        )

        let failure: HistoryFailure?
        let page: HistoryPage?
        do {
            page = try await history.browse(request)
            failure = nil
        } catch let historyFailure as HistoryFailure {
            page = nil
            failure = historyFailure
        } catch {
            Issue.record("search failed outside the HistoryFailure vocabulary")
            page = nil
            failure = nil
        }
        // Stop the probes before the separate cursor-control read so the
        // counts below describe exactly one public empty-search request.
        await history.authority.setSearchDebugProbe(
            SearchDebugProbe(isEnabled: false)
        )
        await history.searchWorker.setSearchDebugProbe(
            SearchDebugProbe(isEnabled: false)
        )
        await history.authority.setStorageLifecycleDebugProbe(
            StorageLifecycleDebugProbe(isEnabled: false)
        )
        let recentContinuation: HistoryPage?
        if recentControl != nil, let next = page?.next {
            recentContinuation = try await history.browse(HistoryBrowseRequest(
                kind: .recent,
                limit: request.limit,
                after: next
            ))
        } else {
            recentContinuation = nil
        }
        continuation.finish()
        storageContinuation.finish()

        var phases: [String] = []
        for await event in events {
            phases.append("\(event.component).\(event.phase)")
        }
        var storagePhases: [StorageLifecycleDebugPhase] = []
        for await event in storageEvents {
            storagePhases.append(event.phase)
        }
        return SearchObservation(
            failure: failure,
            page: page,
            recentControl: recentControl,
            recentContinuation: recentContinuation,
            phases: phases,
            storagePhases: storagePhases
        )
    }
}
#endif
