import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

/// A retained ID locates a fresh query page without persisting a process-local
/// cursor. All reads use the real store and the public browse boundary.
/// Owning specification: docs/03a-instruction-set.md §7 / docs/04-coherence.md §6.
struct HistorySeekTests {
    private static let searchKinds: [HistoryBrowseKind] = [
        .search(text: "alpha", mode: .exact),
        .search(text: "alpha", mode: .fuzzy),
        .search(text: "alpha", mode: .regexp),
        .search(text: "alpha", mode: .expression),
    ]
    private static let kinds: [HistoryBrowseKind] = [.recent] + searchKinds

    @Test(arguments: HistorySeekTests.kinds, HistorySortOrder.allCases)
    func firstMiddleAndLastTargetsPreserveTheCompleteQueryInBothDirections(
        kind: HistoryBrowseKind, sortOrder: HistorySortOrder
    ) async throws {
        let history = try await WSSupport.makeHistory()
        _ = try await Self.seed(history)
        let baseline = try await history.browse(HistoryBrowseRequest(
            kind: kind, limit: 50, sortOrder: sortOrder
        ))
        try #require(baseline.rows.count == 9)
        #expect(baseline.next == nil)

        for targetIndex in [0, baseline.rows.count / 2, baseline.rows.count - 1] {
            try await Self.expectLocatedWindow(
                history, baseline: baseline, targetIndex: targetIndex,
                kind: kind, sortOrder: sortOrder
            )
        }
    }

    @Test(arguments: HistorySortOrder.allCases)
    func neighboringPagesKeepTheFilterUsedToLocateTheTarget(sortOrder: HistorySortOrder) async throws {
        let history = try await WSSupport.makeHistory()
        _ = try await Self.seed(history)
        let filter = HistoryFilter(type: .text, sourceApplicationIDs: ["com.example.seek"])
        let baseline = try await history.browse(HistoryBrowseRequest(
            kind: .recent, limit: 50, filter: filter, sortOrder: sortOrder
        ))
        try #require(baseline.rows.count == 5)
        try await Self.expectLocatedWindow(
            history, baseline: baseline, targetIndex: 2, kind: .recent,
            filter: filter, sortOrder: sortOrder
        )
    }

    @Test(arguments: HistorySortOrder.allCases)
    func savedIdentifierLocatesAfterReopeningWhileTheOldCursorExpires(sortOrder: HistorySortOrder) async throws {
        let storeURL = WSSupport.tempStoreURL("seek-bookmark-reopen")
        defer { WSSupport.removeStore(storeURL) }
        // The helper returns only immutable bookmark facts, releasing the
        // original facade and its persistent-store writer lease before reopen.
        let saved = try await Self.savedBookmark(at: storeURL, sortOrder: sortOrder)
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        let target = try #require(HistoryItemID(uuidString: saved.identifier))
        let baseline = try await history.browse(HistoryBrowseRequest(
            kind: .recent, limit: 50, sortOrder: sortOrder
        ))
        let targetIndex = try #require(baseline.rows.firstIndex { $0.item.id == target })
        #expect(baseline.position == saved.position)
        try await Self.expectLocatedWindow(
            history, baseline: baseline, targetIndex: targetIndex,
            kind: .recent, sortOrder: sortOrder
        )
        await #expect(throws: HistoryFailure.snapshotExpired(current: baseline.position)) {
            try await history.browse(HistoryBrowseRequest(
                kind: .recent, limit: 3, cursor: saved.cursor, sortOrder: sortOrder
            ))
        }
    }

    @Test(arguments: HistorySortOrder.allCases)
    func freshLocationUsesCurrentCopyAndPinFactsAfterTheTargetMoves(sortOrder: HistorySortOrder) async throws {
        let history = try await WSSupport.makeHistory()
        let ids = try await Self.seed(history)
        let target = ids[4]
        let oldPage = try await history.browse(HistoryBrowseRequest(
            kind: .recent, limit: 2, sortOrder: sortOrder, startAround: target
        ))
        let oldCursor = try #require(oldPage.next)
        for _ in 0..<4 {
            _ = try await history.perform(.capture(WSSupport.textCapture(
                "alpha entry 4", observedAt: Date(timeIntervalSinceReferenceDate: 2_000),
                source: "com.example.seek"
            )))
        }
        _ = try await history.perform(.placePinned(target, at: .first))
        _ = try await Self.capture(
            history, text: "alpha newly captured", seconds: 3_000, source: "com.example.seek"
        )
        let baseline = try await history.browse(HistoryBrowseRequest(
            kind: .recent, limit: 50, sortOrder: sortOrder
        ))
        let targetIndex = try #require(baseline.rows.firstIndex { $0.item.id == target })
        let current = baseline.rows[targetIndex]
        #expect(current.copyCount == 6)
        #expect(current.pinnedPosition == 0)
        #expect(baseline.position.rawValue > oldPage.position.rawValue)
        try await Self.expectLocatedWindow(
            history, baseline: baseline, targetIndex: targetIndex,
            kind: .recent, sortOrder: sortOrder
        )
        await #expect(throws: HistoryFailure.snapshotExpired(current: baseline.position)) {
            try await history.browse(HistoryBrowseRequest(
                kind: .recent, limit: 2, cursor: oldCursor, sortOrder: sortOrder
            ))
        }
    }

    @Test func missingAndDeletedTargetsReportTheirOwnIdentifier() async throws {
        let history = try await WSSupport.makeHistory()
        let ids = try await Self.seed(history)
        let deleted = ids[4]
        _ = try await history.perform(.remove(deleted))
        for target in [deleted, HistoryItemID(rawValue: UUID())] {
            await #expect(throws: HistoryFailure.notFound(target)) {
                try await history.browse(HistoryBrowseRequest(
                    kind: .recent, limit: 3, startAround: target
                ))
            }
        }
    }

    @Test(arguments: [
        HistoryFilter(type: .images),
        HistoryFilter(pinnedOnly: true),
        HistoryFilter(sourceApplicationIDs: ["com.example.other"]),
        HistoryFilter(copiedAfter: Date(timeIntervalSinceReferenceDate: 5_000)),
    ])
    func retainedTargetOutsideTheFilterReportsNotFound(filter: HistoryFilter) async throws {
        let history = try await WSSupport.makeHistory()
        let ids = try await Self.seed(history)
        let target = ids[4]
        await #expect(throws: HistoryFailure.notFound(target)) {
            try await history.browse(HistoryBrowseRequest(
                kind: .recent, limit: 3, filter: filter, startAround: target
            ))
        }
    }

    @Test(arguments: HistorySeekTests.searchKinds)
    func retainedTargetOutsideTheSearchReportsNotFound(kind: HistoryBrowseKind) async throws {
        let history = try await WSSupport.makeHistory()
        _ = try await Self.seed(history)
        let excluded = try await Self.capture(
            history, text: "qqqqqqqqqqqqqqqq", seconds: 2_000, source: "com.example.other"
        )
        let matches = try await history.browse(HistoryBrowseRequest(kind: kind, limit: 50))
        #expect(matches.rows.count == 9)
        #expect(!matches.rows.contains { $0.item.id == excluded })
        await #expect(throws: HistoryFailure.notFound(excluded)) {
            try await history.browse(HistoryBrowseRequest(kind: kind, limit: 3, startAround: excluded))
        }
    }

    @Test(arguments: HistorySeekTests.kinds)
    func cursorAndFreshTargetCannotBeCombined(kind: HistoryBrowseKind) async throws {
        let history = try await WSSupport.makeHistory()
        let ids = try await Self.seed(history)
        let first = try await history.browse(HistoryBrowseRequest(kind: kind, limit: 3))
        let cursor = try #require(first.next)
        for target in [ids[4], HistoryItemID(rawValue: UUID())] {
            await #expect(throws: HistoryFailure.invalidInput(.conflictingPageAnchors)) {
                try await history.browse(HistoryBrowseRequest(
                    kind: kind, limit: 3, cursor: cursor, startAround: target
                ))
            }
        }
    }

    @Test func locatingAnOlderTargetDoesNotDecodeTheUnrelatedHistoryPrefix() async throws {
        let storeURL = WSSupport.tempStoreURL("seek-unrelated-prefix")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        var ids: [HistoryItemID] = []
        for index in 0..<80 {
            ids.append(try await Self.capture(
                history, text: "seek prefix \(index)", seconds: Double(index), source: "com.example.seek"
            ))
        }
        let damaged = try #require(ids.last)
        let database = try WSSupport.makeDatabase(storeURL: storeURL)
        try database.execute(
            "UPDATE history_items SET titleUTF8 = ? WHERE id = ?",
            bindings: [.blob(Data([0xFF])), .text(damaged.rawValue.uuidString)]
        )
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 3))
        }

        let located = try await history.browse(HistoryBrowseRequest(
            kind: .recent, limit: 3, startAround: ids[8]
        ))
        #expect(located.rows.map(\.item.id) == [ids[8], ids[7], ids[6]])
        #expect(located.previous != nil)
        #expect(located.next != nil)
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 3, startAround: damaged))
        }
    }

    private static func expectLocatedWindow(
        _ history: SQLiteHistory, baseline: HistoryPage, targetIndex: Int,
        kind: HistoryBrowseKind, filter: HistoryFilter = .all, sortOrder: HistorySortOrder
    ) async throws {
        let limit = 3
        let located = try await history.browse(HistoryBrowseRequest(
            kind: kind, limit: limit, filter: filter, sortOrder: sortOrder,
            startAround: baseline.rows[targetIndex].item.id
        ))
        #expect(located.rows == Array(baseline.rows.dropFirst(targetIndex).prefix(limit)))
        #expect(located.position == baseline.position)
        #expect((located.previous == nil) == (targetIndex == 0))
        #expect((located.next == nil) == (targetIndex + limit >= baseline.rows.count))

        var following = located
        var collected = located.rows
        for _ in 0..<baseline.rows.count {
            guard let cursor = following.next else { break }
            following = try await history.browse(HistoryBrowseRequest(
                kind: kind, limit: limit, cursor: cursor, filter: filter, sortOrder: sortOrder
            ))
            #expect(following.position == located.position)
            #expect(!following.rows.isEmpty)
            #expect(following.rows.count <= limit)
            collected.append(contentsOf: following.rows)
        }
        #expect(following.next == nil)

        var preceding = located
        for _ in 0..<baseline.rows.count {
            guard let cursor = preceding.previous else { break }
            let nextExpected = preceding
            preceding = try await history.browse(HistoryBrowseRequest(
                kind: kind, limit: limit, cursor: cursor, filter: filter, sortOrder: sortOrder
            ))
            #expect(preceding.position == located.position)
            #expect(!preceding.rows.isEmpty)
            #expect(preceding.rows.count <= limit)
            collected.insert(contentsOf: preceding.rows, at: 0)
            let returnCursor = try #require(preceding.next)
            let returned = try await history.browse(HistoryBrowseRequest(
                kind: kind, limit: limit, cursor: returnCursor, filter: filter, sortOrder: sortOrder
            ))
            #expect(returned.rows == nextExpected.rows)
            #expect(returned.position == nextExpected.position)
        }
        #expect(preceding.previous == nil)
        #expect(collected == baseline.rows)
    }

    private static func savedBookmark(
        at storeURL: URL, sortOrder: HistorySortOrder
    ) async throws -> (identifier: String, cursor: HistoryPageCursor, position: ChangePosition) {
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        _ = try await seed(history)
        let baseline = try await history.browse(HistoryBrowseRequest(
            kind: .recent, limit: 50, sortOrder: sortOrder
        ))
        try #require(baseline.rows.count == 9)
        let target = baseline.rows[4].item.id
        let page = try await history.browse(HistoryBrowseRequest(
            kind: .recent, limit: 3, sortOrder: sortOrder, startAround: target
        ))
        return (target.description, try #require(page.next), page.position)
    }

    private static func seed(_ history: SQLiteHistory) async throws -> [HistoryItemID] {
        var ids: [HistoryItemID] = []
        for index in 0..<9 {
            let text = "alpha entry \(index)"
            let seconds = TimeInterval(100 + index)
            let source = index.isMultiple(of: 2) ? "com.example.seek" : "com.example.other"
            let id = try await capture(history, text: text, seconds: seconds, source: source)
            ids.append(id)
            for _ in 0..<(index % 3) {
                _ = try await history.perform(.capture(WSSupport.textCapture(
                    text, observedAt: Date(timeIntervalSinceReferenceDate: seconds), source: source
                )))
            }
        }
        _ = try await history.perform(.placePinned(ids[1], at: .last))
        _ = try await history.perform(.placePinned(ids[6], at: .last))
        return ids
    }

    private static func capture(
        _ history: SQLiteHistory, text: String, seconds: TimeInterval, source: String
    ) async throws -> HistoryItemID {
        let receipt = try await history.perform(.capture(WSSupport.textCapture(
            text, observedAt: Date(timeIntervalSinceReferenceDate: seconds), source: source
        )))
        guard case .committed(let commit) = receipt,
              case .inserted(let reference) = commit.outcome else {
            Issue.record("Expected a distinct retained item for a seek fixture")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return reference.id
    }
}
