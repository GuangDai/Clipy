import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct RecentScalarPaginationTests {
    /// Exercise normal slices, the pinned/unpinned join, and UUID-tie
    /// fallback in the real in-memory store. Expected order is independent
    /// of the store's date-tie order and the production scalar comparator.
    @Test func smallPagesPreserveMixedDateTiesAndPinnedLookahead() async throws {
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )
        let dates = [3, 3, 3, 2, 2, 1, 1, 1]
        var captured: [(id: HistoryItemID, date: Int)] = []
        for (index, date) in dates.enumerated() {
            let receipt = try await history.perform(.capture(WSSupport.textCapture(
                "recent scalar page row \(index)",
                observedAt: Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(date)),
                source: "com.example.recent-scalar"
            )))
            guard case .committed(let commit) = receipt,
                  case .inserted(let item) = commit.outcome else {
                Issue.record("expected a distinct captured row")
                return
            }
            captured.append((item.id, date))
        }
        let pinned = captured[6].id
        _ = try await history.perform(.placePinned(pinned, at: .first))
        let expected = [pinned] + captured.filter { $0.id != pinned }.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id < $1.id
        }.map { $0.id }

        for limit in [1, 2, 3] {
            var cursor: HistoryPageCursor?
            var position: ChangePosition?
            var seen: [HistoryItemID] = []
            for _ in 0..<captured.count {
                let page = try await history.browse(HistoryBrowseRequest(
                    kind: .recent, limit: limit, after: cursor
                ))
                if let position {
                    #expect(page.position == position)
                } else {
                    position = page.position
                }
                #expect(page.rows.count == min(limit, captured.count - seen.count))
                #expect(page.rows.allSatisfy { $0.copyCount == 1 && $0.search == nil })
                for row in page.rows {
                    #expect(row.pinnedPosition == (row.item.id == pinned ? 0 : nil))
                }
                seen.append(contentsOf: page.rows.map(\.item.id))
                cursor = page.next
                #expect((cursor != nil) == (seen.count < captured.count))
                if cursor == nil { break }
            }
            #expect(seen == expected)
            #expect(cursor == nil)
        }
    }
}
