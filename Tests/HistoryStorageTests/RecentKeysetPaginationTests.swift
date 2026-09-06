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
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
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
        var position: ChangePosition?
        for _ in 0..<ids.count {
            let page = try await history.browse(HistoryBrowseRequest(
                kind: .recent, limit: limit, after: cursor
            ))
            if let position {
                #expect(page.position == position)
            }
            position = page.position
            #expect(page.rows.count == limit)
            actual.append(contentsOf: page.rows.map(\.item.id))
            cursor = page.next
            if let cursor {
                #expect(cursor.payload.count < 512)
            } else {
                break
            }
        }
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
        #expect(fetchedRowsByPage.count == ids.count / limit)
        #expect(fetchedRowsByPage.first == limit + 1)
        #expect(fetchedRowsByPage.allSatisfy { $0 <= limit + 2 })
    }

    @Test func missingUnpinnedAnchorExpiresInsteadOfSkippingToNextUUID() async throws {
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )
        for index in 0..<3 {
            _ = try await history.perform(.capture(WSSupport.textCapture(
                "missing keyset anchor \(index)",
                observedAt: Date(timeIntervalSinceReferenceDate: 840_000_100)
            )))
        }
        let page = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 1))
        let cursor = try #require(page.next)
        let resolved = try PageCursorCodec.decode(
            cursor, processMarker: history.authority.cursorProcessMarker
        )
        let malformed = try PageCursorCodec.encode(ResolvedPageCursor(
            queryShape: resolved.queryShape,
            position: resolved.position,
            anchor: .defaultOrder(
                pinnedOrdinal: nil,
                lastCopiedAt: Date(timeIntervalSinceReferenceDate: 840_000_100),
                id: HistoryItemID(rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
            )
        ), processMarker: history.authority.cursorProcessMarker)

        await #expect(throws: HistoryFailure.snapshotExpired(current: page.position)) {
            try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 1, after: malformed))
        }
    }
}
#endif
