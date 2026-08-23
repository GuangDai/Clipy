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
        #expect(!observation.phases.contains("authority.context-create"))
        #expect(!observation.phases.contains("authority.corpus-fetch-begin"))
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
        #expect(!observation.phases.contains("authority.context-create"))
        #expect(!observation.phases.contains("authority.corpus-fetch-begin"))
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
        #expect(!observation.phases.contains("authority.context-create"))
        #expect(!observation.phases.contains("authority.corpus-fetch-begin"))
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
        #expect(!observation.phases.contains("authority.context-create"))
        #expect(!observation.phases.contains("authority.corpus-fetch-begin"))
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
        #expect(observation.storagePhases.contains(.recentFetchBegin))
        #expect(observation.storagePhases.contains(.recentFetchComplete))
        #expect(!observation.phases.contains("authority.context-create"))
        #expect(!observation.phases.contains("authority.corpus-fetch-begin"))
    }

    private struct SearchObservation {
        let failure: HistoryFailure?
        let page: HistoryPage?
        let recentControl: HistoryPage?
        let recentContinuation: HistoryPage?
        let phases: Set<String>
        let storagePhases: Set<StorageLifecycleDebugPhase>
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

        await history.authority.setSearchDebugProbe(
            SearchDebugProbe(isEnabled: false)
        )
        await history.searchWorker.setSearchDebugProbe(
            SearchDebugProbe(isEnabled: false)
        )
        await history.authority.setStorageLifecycleDebugProbe(
            StorageLifecycleDebugProbe(isEnabled: false)
        )
        continuation.finish()
        storageContinuation.finish()

        var phases: Set<String> = []
        for await event in events {
            phases.insert("\(event.component).\(event.phase)")
        }
        var storagePhases: Set<StorageLifecycleDebugPhase> = []
        for await event in storageEvents {
            storagePhases.insert(event.phase)
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
