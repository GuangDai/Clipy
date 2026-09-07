#if DEBUG
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct RecentKeysetPaginationTests {
    /// Every page is bounded even when the whole store shares a timestamp.
    /// Cover no pins, a page crossing the pinned/unpinned join, and all pins;
    /// cursor size and fetch work must not accumulate previously visited IDs.
    @Test(arguments: [0, 5, 12])
    func everyPagePreservesGlobalOrderWithBoundedFetchAndCursor(pinnedCount: Int) async throws {
        let history = try await SQLiteHistory.open(
            configuration: HistoryConfiguration(persistence: .temporary)
        )
        let suffixes: [UInt8] = [0x20, 0x0A, 0x10, 0x02, 0x0B, 0x01, 0x03, 0x0C, 0x04, 0x0D, 0x05, 0x0E]
        var ids: [HistoryItemID] = []
        for suffix in suffixes {
            let id = HistoryItemID(rawValue: UUID(uuid: (
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix
            )))
            ids.append(id)
            let preparation = IngestPreparationActor(makeCandidateID: { id })
            let prepared = try await preparation.prepare(WSSupport.textCapture(
                "keyset row \(suffix)", observedAt: Date(timeIntervalSinceReferenceDate: 840_000_000)
            ))
            _ = try await history.authority.commitCapture(prepared)
        }
        for id in ids.prefix(pinnedCount) {
            _ = try await history.perform(.placePinned(id, at: .last))
        }
        let expected = Array(ids.prefix(pinnedCount)) + ids.dropFirst(pinnedCount).sorted()
        let (events, continuation) = AsyncStream<StorageLifecycleDebugEvent>.makeStream()
        await history.authority.setStorageLifecycleDebugProbe(
            StorageLifecycleDebugProbe(isEnabled: true) { event in
                _ = continuation.yield(event)
            }
        )

        let limit = 2
        var cursor: HistoryPageCursor?
        var actual: [HistoryItemID] = []
        var pages: [HistoryPage] = []
        var position: ChangePosition?
        for _ in 0..<ids.count {
            let page = try await history.browse(HistoryBrowseRequest(
                kind: .recent, limit: limit, cursor: cursor
            ))
            if let position {
                #expect(page.position == position)
            }
            position = page.position
            #expect(page.rows.count == limit)
            pages.append(page)
            actual.append(contentsOf: page.rows.map(\.item.id))
            cursor = page.next
            if let cursor {
                #expect(cursor.payload.count < 512)
            } else {
                break
            }
        }
        #expect(pages.first?.previous == nil)
        var backward = try #require(pages.last)
        for index in stride(from: pages.count - 2, through: 0, by: -1) {
            let previous = try #require(backward.previous)
            #expect(previous.payload.count < 512)
            backward = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: limit, cursor: previous))
            #expect(backward == pages[index])
        }
        #expect(backward.previous == nil)
        await history.authority.setStorageLifecycleDebugProbe(
            StorageLifecycleDebugProbe(isEnabled: false)
        )
        continuation.finish()
        #expect(actual == expected)
        #expect(cursor == nil)

        var fetchedRowsByPage: [Int] = []
        var fetchedRows = 0
        for await event in events {
            switch event.phase {
            case .recentFetchBegin:
                fetchedRows = 0
            case .recentPinnedFetchComplete, .recentUnpinnedFetchComplete:
                fetchedRows += event.rows
            case .recentFetchComplete:
                fetchedRowsByPage.append(fetchedRows)
            default:
                break
            }
        }
        #expect(fetchedRowsByPage.count == pages.count * 2 - 1)
        #expect(fetchedRowsByPage.first == limit + 1)
        #expect(fetchedRowsByPage.allSatisfy { $0 <= limit + 2 })
    }

    @Test(arguments: [0, 5, 15])
    func partialTailAndMixedDateUUIDGroupsRoundTripAcrossPinnedJoin(pinnedCount: Int) async throws {
        let history = try await WSSupport.makeHistory()
        var ids: [HistoryItemID] = []
        var dates: [Date] = []
        for index in 0..<15 {
            let id = HistoryItemID(rawValue: UUID(uuid: (
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(index + 1)
            )))
            let date = Date(timeIntervalSinceReferenceDate: 840_000_000 + Double(index / 3))
            ids.append(id)
            dates.append(date)
            let prepared = try await IngestPreparationActor(makeCandidateID: { id }).prepare(
                WSSupport.textCapture("bidirectional row \(index)", observedAt: date)
            )
            _ = try await history.authority.commitCapture(prepared)
        }
        // Pin order deliberately differs from both UUID and recency order.
        let pinOrder = [3, 13, 1, 8, 6, 0, 2, 4, 5, 7, 9, 10, 11, 12, 14]
        let pinned = pinOrder.prefix(pinnedCount).map { ids[$0] }
        for id in pinned { _ = try await history.perform(.placePinned(id, at: .last)) }
        let unpinned = ids.indices.filter { !pinned.contains(ids[$0]) }.sorted { left, right in
            dates[left] == dates[right] ? ids[left] < ids[right] : dates[left] > dates[right]
        }.map { ids[$0] }
        let expected = pinned + unpinned

        for kind in [HistoryBrowseKind.recent, .search(text: "", mode: .exact)] {
            var pages: [HistoryPage] = []
            var cursor: HistoryPageCursor?
            for _ in 0..<15 {
                let page = try await history.browse(HistoryBrowseRequest(kind: kind, limit: 2, cursor: cursor))
                #expect(!page.rows.isEmpty)
                pages.append(page)
                cursor = page.next
                if cursor == nil { break }
            }
            #expect(cursor == nil)
            #expect(pages.flatMap { $0.rows.map(\.item.id) } == expected)
            #expect(pages.first?.previous == nil)
            var page = try #require(pages.last)
            #expect(page.rows.count == 1)
            #expect(page.next == nil)
            for index in stride(from: pages.count - 2, through: 0, by: -1) {
                let previousCursor = try #require(page.previous)
                page = try await history.browse(HistoryBrowseRequest(
                    kind: kind, limit: 2, cursor: previousCursor
                ))
                #expect(page.rows.count == 2)
                #expect(page == pages[index])
                let nextCursor = try #require(page.next)
                let forward = try await history.browse(HistoryBrowseRequest(
                    kind: kind, limit: 2, cursor: nextCursor
                ))
                #expect(forward == pages[index + 1])
            }
            #expect(page.previous == nil)
        }
    }

    @Test func backwardCursorChecksCompleteAnchorPositionLimitAndProcess() async throws {
        let url = WSSupport.tempStoreURL("backward-cursor-expiration")
        defer { WSSupport.removeStore(url) }
        let history = try await WSSupport.openHistory(storeURL: url)
        for index in 0..<3 {
            _ = try await history.perform(.capture(WSSupport.textCapture(
                "backward expiration \(index)", observedAt: Date(timeIntervalSinceReferenceDate: 840_000_000 + Double(index))
            )))
        }
        let first = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 1))
        let nextCursor = try #require(first.next)
        let second = try await history.browse(HistoryBrowseRequest(
            kind: .recent, limit: 1, cursor: nextCursor
        ))
        let cursor = try #require(second.previous)
        let marker = await history.authority.cursorProcessMarker
        let resolved = try PageCursorCodec.decode(cursor, processMarker: marker)
        #expect(resolved.direction == .backward)
        let anchor = try #require(second.rows.first)
        let wrongDate = try PageCursorCodec.encode(ResolvedPageCursor(
            queryShape: resolved.queryShape, position: resolved.position,
            anchor: .defaultOrder(pinnedOrdinal: nil, lastCopiedAt: anchor.lastCopiedAt.addingTimeInterval(1), id: anchor.item.id),
            direction: .backward
        ), processMarker: marker)
        await #expect(throws: HistoryFailure.snapshotExpired(current: first.position)) {
            try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 1, cursor: wrongDate))
        }
        await #expect(throws: HistoryFailure.snapshotExpired(current: first.position)) {
            try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 2, cursor: cursor))
        }
        let reopened = try await WSSupport.openHistory(storeURL: url)
        await #expect(throws: HistoryFailure.snapshotExpired(current: first.position)) {
            try await reopened.browse(HistoryBrowseRequest(kind: .recent, limit: 1, cursor: cursor))
        }
        _ = try await history.perform(.capture(WSSupport.textCapture(
            "newer commit", observedAt: Date(timeIntervalSinceReferenceDate: 840_000_100)
        )))
        let latest = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 1))
        await #expect(throws: HistoryFailure.snapshotExpired(current: latest.position)) {
            try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 1, cursor: cursor))
        }
    }

    @Test func emptyAndSingletonPagesHaveNoAdjacentLinks() async throws {
        let history = try await WSSupport.makeHistory()
        let empty = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 2))
        #expect(empty.rows.isEmpty)
        #expect(empty.previous == nil && empty.next == nil)
        _ = try await history.perform(.capture(WSSupport.textCapture(
            "only row", observedAt: Date(timeIntervalSinceReferenceDate: 840_000_000)
        )))
        let only = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 2))
        let row = try #require(only.rows.first)
        #expect(only.previous == nil && only.next == nil)
        let marker = await history.authority.cursorProcessMarker
        // Even a manually minted direction beyond a real edge cannot create
        // a phantom link. Normal callers never receive either of these tokens.
        for direction in [HistoryPageDirection.forward, .backward] {
            let cursor = try PageCursorCodec.encode(ResolvedPageCursor(
                queryShape: .recent(limit: 2), position: only.position,
                anchor: .defaultOrder(pinnedOrdinal: nil, lastCopiedAt: row.lastCopiedAt, id: row.item.id), direction: direction
            ), processMarker: marker)
            let result = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 2, cursor: cursor))
            #expect(result.rows.isEmpty)
            #expect(result.previous == nil && result.next == nil)
        }
    }

    @Test(arguments: [HistoryPageDirection.forward, .backward])
    func missingUnpinnedAnchorExpiresInsteadOfSkippingToNextUUID(direction: HistoryPageDirection) async throws {
        let history = try await SQLiteHistory.open(
            configuration: HistoryConfiguration(persistence: .temporary)
        )
        for index in 0..<3 {
            _ = try await history.perform(.capture(WSSupport.textCapture(
                "missing keyset anchor \(index)",
                observedAt: Date(timeIntervalSinceReferenceDate: 840_000_100)
            )))
        }
        let page = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 1))
        let cursor = try #require(page.next)
        let processMarker = await history.authority.cursorProcessMarker
        let resolved = try PageCursorCodec.decode(
            cursor, processMarker: processMarker
        )
        let malformed = try PageCursorCodec.encode(ResolvedPageCursor(
            queryShape: resolved.queryShape,
            position: resolved.position,
            anchor: .defaultOrder(
                pinnedOrdinal: nil,
                lastCopiedAt: Date(timeIntervalSinceReferenceDate: 840_000_100),
                id: HistoryItemID(rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
            ),
            direction: direction
        ), processMarker: processMarker)

        await #expect(throws: HistoryFailure.snapshotExpired(current: page.position)) {
            try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 1, cursor: malformed))
        }
    }
}
#endif
