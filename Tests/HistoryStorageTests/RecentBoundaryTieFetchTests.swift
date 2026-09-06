#if DEBUG
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct RecentBoundaryTieFetchTests {
    /// Both first-page ties and post-anchor ties need the complete boundary
    /// date group, but neither needs older dates to choose page + lookahead.
    /// Count the real SwiftData fetch, then finish pagination to prove the
    /// excluded older rows still appear on their later pages (05 §14.1).
    @Test(arguments: [false, true])
    func boundaryExpansionExcludesOlderDates(withNewestSingleton: Bool) async throws {
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )
        var captured: [(id: HistoryItemID, date: Int)] = []
        let dates = Array(repeating: 1, count: 6)
            + Array(repeating: 2, count: 5)
            + (withNewestSingleton ? [3] : [])
        for (index, date) in dates.enumerated() {
            let receipt = try await history.perform(.capture(WSSupport.textCapture(
                "boundary tie row \(index)",
                observedAt: Date(timeIntervalSinceReferenceDate: 810_000_000 + Double(date))
            )))
            guard case .committed(let commit) = receipt,
                  case .inserted(let item) = commit.outcome else {
                Issue.record("Expected a distinct boundary tie fixture")
                return
            }
            captured.append((item.id, date))
        }
        let expected = captured.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id < $1.id
        }.map(\.id)

        var cursor: HistoryPageCursor?
        var seen: [HistoryItemID] = []
        if withNewestSingleton {
            let first = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 1))
            seen.append(contentsOf: first.rows.map(\.item.id))
            let next = try #require(first.next)
            cursor = next
        }

        let (events, continuation) = AsyncStream<StorageLifecycleDebugEvent>.makeStream()
        await history.authority.setStorageLifecycleDebugProbe(
            StorageLifecycleDebugProbe(isEnabled: true) { event in
                _ = continuation.yield(event)
            }
        )
        let page = try await history.browse(HistoryBrowseRequest(
            kind: .recent, limit: 1, after: cursor
        ))
        await history.authority.setStorageLifecycleDebugProbe(
            StorageLifecycleDebugProbe(isEnabled: false)
        )
        continuation.finish()

        var fallbackCounts: [Int] = []
        for await event in events where event.phase == .recentUnpinnedFallbackFetchComplete {
            fallbackCounts.append(event.rows)
        }
        // Five tied rows, plus the inclusive singleton continuation anchor.
        // The six older rows must never enter this fallback fetch.
        #expect(fallbackCounts == [withNewestSingleton ? 6 : 5])
        #expect(page.rows.map(\.item.id) == [expected[seen.count]])
        seen.append(contentsOf: page.rows.map(\.item.id))
        let next = try #require(page.next)
        cursor = next

        for _ in 0..<captured.count {
            let nextPage = try await history.browse(HistoryBrowseRequest(
                kind: .recent, limit: 1, after: cursor
            ))
            seen.append(contentsOf: nextPage.rows.map(\.item.id))
            cursor = nextPage.next
            if cursor == nil { break }
        }
        #expect(seen == expected)
        #expect(cursor == nil)
    }
}
#endif
