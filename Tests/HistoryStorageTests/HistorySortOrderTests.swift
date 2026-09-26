import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

/// Explicit order applies to the complete filtered history before paging;
/// observation and both cursor directions preserve that same query shape.
/// Owning specification: docs/03a-instruction-set.md §7 / docs/04-coherence.md §6.
struct HistorySortOrderTests {
    private static let kinds: [HistoryBrowseKind] = [
        .recent,
        .search(text: "alpha", mode: .exact),
        .search(text: "alpha", mode: .fuzzy),
        .search(text: "alpha", mode: .regexp),
        .search(text: "alpha", mode: .expression),
    ]

    @Test(arguments: HistorySortOrderTests.kinds, HistorySortOrder.allCases)
    func everyOrderTraversesTheWholeResultInBothDirections(
        kind: HistoryBrowseKind, sortOrder: HistorySortOrder
    ) async throws {
        let fixture = try await Self.makeFixture()
        let expected = fixture.expectedIDs(for: sortOrder)
        var pages: [HistoryPage] = []
        var cursor: HistoryPageCursor?

        // Nine rows make five pages, including a short final page. The group
        // with identical dates and counts crosses page boundaries, so UUID
        // tie-breaking is exercised by both forward and backward cursors.
        for start in stride(from: 0, to: expected.count, by: 2) {
            let page = try await fixture.history.browse(HistoryBrowseRequest(
                kind: kind, limit: 2, cursor: cursor, sortOrder: sortOrder
            ))
            #expect(page.rows.map(\.item.id) == Array(expected[start..<min(start + 2, expected.count)]))
            #expect((page.previous == nil) == (start == 0))
            #expect((page.next == nil) == (start + 2 >= expected.count))
            if let first = pages.first { #expect(page.position == first.position) }
            pages.append(page)
            if start + 2 < expected.count {
                let next: HistoryPageCursor = try #require(page.next)
                cursor = next
            }
        }

        let allRows = pages.flatMap(\.rows)
        #expect(Set(allRows.map(\.item.id)).count == expected.count)
        #expect(allRows.first { $0.item.id == fixture.ids[0] }?.pinnedPosition == 0)

        var backward = try #require(pages.last?.previous)
        for index in stride(from: pages.count - 2, through: 0, by: -1) {
            let page = try await fixture.history.browse(HistoryBrowseRequest(
                kind: kind, limit: 2, cursor: backward, sortOrder: sortOrder
            ))
            #expect(page.rows == pages[index].rows)
            #expect(page.position == pages[index].position)
            #expect((page.previous == nil) == (index == 0))
            #expect(page.next != nil)
            if index > 0 { backward = try #require(page.previous) }
        }
    }

    @Test(arguments: HistorySortOrderTests.kinds)
    func changingOrderExpiresForwardAndBackwardCursors(kind: HistoryBrowseKind) async throws {
        let fixture = try await Self.makeFixture()
        let first = try await fixture.history.browse(HistoryBrowseRequest(
            kind: kind, limit: 2, sortOrder: .newestFirst
        ))
        let forward = try #require(first.next)
        let second = try await fixture.history.browse(HistoryBrowseRequest(
            kind: kind, limit: 2, cursor: forward, sortOrder: .newestFirst
        ))
        let backward = try #require(second.previous)

        for sortOrder in [HistorySortOrder.automatic, .oldestFirst, .mostCopied] {
            for cursor in [forward, backward] {
                await #expect(throws: HistoryFailure.snapshotExpired(current: first.position)) {
                    _ = try await fixture.history.browse(HistoryBrowseRequest(
                        kind: kind, limit: 2, cursor: cursor, sortOrder: sortOrder
                    ))
                }
            }
        }
    }

    @Test(arguments: HistorySortOrderTests.kinds)
    func explicitOrdersCrossPhysicalSearchBatchesWithoutLosingMatches(kind: HistoryBrowseKind) async throws {
        let history = try await WSSupport.makeHistory()
        let indices = Array(0..<101)
        let frequent = [17, 77, 43]
        var ids: [HistoryItemID] = []
        for index in indices {
            // 84 matching rows exceed two 32-row search batches even when
            // SQLite candidate indexes omit every nonmatching value.
            let title = index.isMultiple(of: 6) ? "zzzz \(index)" : "alpha batch \(index)"
            let copies = index == 17 ? 3 : (frequent.contains(index) ? 2 : 1)
            ids.append(try await Self.insert(
                title, at: TimeInterval(10_000 + index), copies: copies, in: history
            ))
        }
        _ = try await history.perform(.placePinned(ids[1], at: .last))
        let visible = kind == .recent ? indices : indices.filter { !$0.isMultiple(of: 6) }
        let newest = Array(visible.reversed())
        let orders: [(sortOrder: HistorySortOrder, indices: [Int])] = [
            (.newestFirst, newest),
            (.oldestFirst, visible),
            (.mostCopied, frequent + newest.filter { !frequent.contains($0) }),
        ]

        for order in orders {
            let expected = order.indices.map { ids[$0] }
            var pages: [HistoryPage] = []
            var cursor: HistoryPageCursor?
            // A 37-row page itself requires more than one physical batch;
            // subsequent cursors must keep the same global metadata order.
            for start in stride(from: 0, to: expected.count, by: 37) {
                let page = try await history.browse(HistoryBrowseRequest(
                    kind: kind, limit: 37, cursor: cursor, sortOrder: order.sortOrder
                ))
                #expect(page.rows.map(\.item.id) == Array(expected[start..<min(start + 37, expected.count)]))
                #expect((page.previous == nil) == (start == 0))
                #expect((page.next == nil) == (start + 37 >= expected.count))
                if let first = pages.first { #expect(page.position == first.position) }
                pages.append(page)
                if start + 37 < expected.count {
                    let next: HistoryPageCursor = try #require(page.next)
                    cursor = next
                }
            }
            #expect(pages.flatMap(\.rows).map(\.item.id) == expected)
            var backward = try #require(pages.last?.previous)
            for index in stride(from: pages.count - 2, through: 0, by: -1) {
                let page = try await history.browse(HistoryBrowseRequest(
                    kind: kind, limit: 37, cursor: backward, sortOrder: order.sortOrder
                ))
                #expect(page.rows == pages[index].rows)
                #expect(page.position == pages[index].position)
                #expect((page.previous == nil) == (index == 0))
                #expect(page.next != nil)
                if index > 0 { backward = try #require(page.previous) }
            }
        }
    }

    @Test(arguments: HistorySortOrderTests.kinds, HistorySortOrder.allCases)
    func observationKeepsTheRequestedOrderAfterARepeatCopy(
        kind: HistoryBrowseKind, sortOrder: HistorySortOrder
    ) async throws {
        let fixture = try await Self.makeFixture()
        let stream = await fixture.history.observe(HistoryObservationRequest(
            kind: kind, limit: 6, sortOrder: sortOrder
        ))
        var iterator = stream.makeAsyncIterator()
        let initialResult = try await iterator.next()
        let initial = try #require(initialResult)
        #expect(initial.rows.map(\.item.id) == Array(fixture.expectedIDs(for: sortOrder).prefix(6)))

        let receipt = try await fixture.history.perform(.capture(WSSupport.textCapture(
            "alpha entry 0", observedAt: Date(timeIntervalSinceReferenceDate: 600)
        )))
        guard case .committed(let commit) = receipt,
              case .coalesced(let reference) = commit.outcome else {
            Issue.record("Expected a repeat copy of the pinned fixture")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        #expect(reference.id == fixture.ids[0])
        let updatedResult = try await iterator.next()
        let updated = try #require(updatedResult)
        #expect(updated.position == commit.position)
        #expect(updated.rows.map(\.item.id) == Array(fixture.expectedAfterRepeat(for: sortOrder).prefix(6)))
        if let updatedRow = updated.rows.first(where: { $0.item.id == reference.id }) {
            #expect(updatedRow.copyCount == 2)
            #expect(updatedRow.pinnedPosition == 0)
        }
    }

    private struct Fixture {
        let history: SQLiteHistory
        let ids: [HistoryItemID]

        // Only UUID order is derived: capture timestamps and occurrence
        // counts determine these explicit expected groups independently.
        private var tiedIDs: [HistoryItemID] { orderedIDs(at: [1, 3, 4, 5]) }

        private func orderedIDs(at indices: [Int]) -> [HistoryItemID] {
            indices.map { ids[$0] }.sorted()
        }

        func expectedIDs(for sortOrder: HistorySortOrder) -> [HistoryItemID] {
            switch sortOrder {
            case .automatic: [ids[0], ids[7], ids[6]] + tiedIDs + [ids[2], ids[8]]
            case .newestFirst: [ids[7], ids[6]] + tiedIDs + [ids[2]] + orderedIDs(at: [0, 8])
            case .oldestFirst: orderedIDs(at: [0, 8]) + [ids[2]] + tiedIDs + [ids[6], ids[7]]
            case .mostCopied: tiedIDs + [ids[8], ids[6], ids[2], ids[7], ids[0]]
            }
        }

        func expectedAfterRepeat(for sortOrder: HistorySortOrder) -> [HistoryItemID] {
            switch sortOrder {
            case .automatic, .newestFirst: [ids[0], ids[7], ids[6]] + tiedIDs + [ids[2], ids[8]]
            case .oldestFirst: [ids[8], ids[2]] + tiedIDs + [ids[6], ids[7], ids[0]]
            case .mostCopied: tiedIDs + [ids[8], ids[0], ids[6], ids[2], ids[7]]
            }
        }
    }

    private static func makeFixture() async throws -> Fixture {
        let history = try await WSSupport.makeHistory()
        let profiles: [(seconds: TimeInterval, copies: Int)] = [
            (100, 1), (300, 3), (200, 2), (300, 3), (300, 3),
            (300, 3), (400, 2), (500, 1), (100, 3),
        ]
        var ids: [HistoryItemID] = []
        for (index, profile) in profiles.enumerated() {
            // Equal-length titles match at the same offset, giving fuzzy
            // mode equal relevance without bypassing its real evaluator.
            ids.append(try await insert(
                "alpha entry \(index)", at: profile.seconds, copies: profile.copies, in: history
            ))
        }
        _ = try await history.perform(.placePinned(ids[0], at: .last))
        return Fixture(history: history, ids: ids)
    }

    private static func insert(
        _ text: String, at seconds: TimeInterval, copies: Int, in history: SQLiteHistory
    ) async throws -> HistoryItemID {
        let capture = WSSupport.textCapture(text, observedAt: Date(timeIntervalSinceReferenceDate: seconds))
        let receipt = try await history.perform(.capture(capture))
        guard case .committed(let commit) = receipt,
              case .inserted(let reference) = commit.outcome else {
            Issue.record("Expected a distinct inserted sorting fixture")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        for _ in 1..<copies {
            let repeated = try await history.perform(.capture(capture))
            guard case .committed(let repeatedCommit) = repeated,
                  case .coalesced(let repeatedReference) = repeatedCommit.outcome else {
                Issue.record("Expected a coalesced copy to increase the real occurrence count")
                throw HistoryFailure.persistence(.invariantViolation)
            }
            #expect(repeatedReference.id == reference.id)
        }
        return reference.id
    }
}
