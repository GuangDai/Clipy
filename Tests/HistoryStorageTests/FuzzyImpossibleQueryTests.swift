#if DEBUG
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct FuzzyImpossibleQueryTests {
    @Test func commonPostingDoesNotReadRowsWhenTheRequiredEditsExceedTheThreshold() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        _ = try await history.perform(.capture(WSSupport.textCapture(
            "alphabet soup", observedAt: Date(timeIntervalSinceReferenceDate: 1_000)
        )))
        let position = try await history.usage().position
        let (events, continuation) = AsyncStream<SearchDebugEvent>.makeStream()
        await history.searchWorker.setSearchDebugProbe(SearchDebugProbe(isEnabled: true) {
            _ = continuation.yield($0)
        })
        // The a posting exists, so the ordinary fuzzy OR candidate query
        // would select this row. Seven missing z positions require 7/8 edits.
        let page = try await history.browse(.init(kind: .search(text: "aZZZZZZZ", mode: .fuzzy), limit: 10))
        await history.searchWorker.setSearchDebugProbe(SearchDebugProbe(isEnabled: false))
        continuation.finish()
        #expect(page.position == position)
        #expect(page.rows.isEmpty)
        #expect(page.previous == nil && page.next == nil)
        var phases: [String] = []
        for await event in events { phases.append(event.phase) }
        #expect(!phases.contains("sqlite-batch"))
        #expect(phases.contains("complete"))
    }

    @Test func aMatchAtTheFrozenErrorThresholdStillRunsFuse() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let receipt = try await history.perform(.capture(WSSupport.textCapture(
            "abc", observedAt: Date(timeIntervalSinceReferenceDate: 1_000)
        )))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        // Seven deletions out of ten is exactly .7, not a proven miss.
        // A strict comparison is required; >= would incorrectly lose this.
        let page = try await history.browse(.init(kind: .search(text: "abcZZZZZZZ", mode: .fuzzy), limit: 10))
        #expect(page.rows.map(\.item) == [item])
        #expect(page.rows.first?.search?.matchedRanges == [UTF16TextRange(location: 0, length: 3)])
    }

    @Test func impossibleQueryStillRejectsCursorPositionShapeAndMissingAnchor() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        _ = try await history.perform(.capture(WSSupport.textCapture(
            "abc", observedAt: Date(timeIntervalSinceReferenceDate: 1_000)
        )))
        let recent = try await history.browse(.init(kind: .recent, limit: 10))
        let row = try #require(recent.rows.first)
        let marker = await history.authority.cursorProcessMarker
        let request = HistoryBrowseRequest(kind: .search(text: "aZZZZZZZ", mode: .fuzzy), limit: 10)
        let correctShape = StoredQueryShape(request: request)
        let otherShape = StoredQueryShape(request: .init(kind: .search(text: "abc", mode: .fuzzy), limit: 10))
        let anchor = StoredOrderingAnchor.fuzzyUnpinned(score: 0, lastCopiedAt: row.lastCopiedAt, id: row.item.id)
        let cursors = [
            ResolvedPageCursor(queryShape: correctShape, position: recent.position, anchor: anchor, direction: .forward),
            ResolvedPageCursor(queryShape: correctShape, position: recent.position, anchor: anchor, direction: .backward),
            ResolvedPageCursor(queryShape: otherShape, position: recent.position, anchor: anchor),
            ResolvedPageCursor(queryShape: correctShape, position: .init(rawValue: recent.position.rawValue + 1), anchor: anchor),
        ]
        for resolved in cursors {
            let cursor = try PageCursorCodec.encode(resolved, processMarker: marker)
            await #expect(throws: HistoryFailure.snapshotExpired(current: recent.position)) {
                _ = try await history.browse(.init(kind: request.kind, limit: request.limit, cursor: cursor))
            }
        }
    }
}
#endif
