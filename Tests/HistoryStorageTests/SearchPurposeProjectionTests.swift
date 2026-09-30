#if DEBUG
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

/// Search consumes the projections its expression needs, inside one snapshot.
/// Unused bodies neither fill a batch nor turn a metadata read into corruption.
struct SearchPurposeProjectionTests {
    @Test(arguments: [HistorySortOrder.automatic, .newestFirst, .oldestFirst, .mostCopied])
    func metadataExpressionPagesDoNotReadUnusedBodies(sortOrder: HistorySortOrder) async throws {
        let history = try await WSSupport.makeHistory()
        _ = try await history.seedPerformanceFixture(rowCount: 12) { index in
            WSSupport.textCapture(
                "entry \(index)\n" + String(repeating: "x", count: HistoryLimits.standard.maximumStoredSearchBodyUTF8Bytes),
                observedAt: Date(timeIntervalSinceReferenceDate: Double(index)), source: "com.apple.Notes"
            )
        }
        let kind = HistoryBrowseKind.search(text: "app:notes AND NOT app:safari", mode: .expression)
        let first = await history.measureSearch(.init(kind: kind, limit: 7, sortOrder: sortOrder))
        let firstPage = try first.result.get()
        #expect(firstPage.rows.count == 7)
        #expect(first.metrics.rowsDecoded == 12)
        #expect(first.metrics.batchCount == 1)
        #expect(firstPage.rows.allSatisfy { $0.search == nil })

        // Over-bound, malformed bytes cannot be decoded as any body's text.
        // They are intentionally outside this request's metadata projection.
        try await history.authority.withTestDatabase { authority in
            try authority.database.execute("UPDATE history_items SET searchBodyUTF8 = ?",
                bindings: [.blob(Data(repeating: 0xFF, count: HistoryLimits.standard.maximumStoredSearchBodyUTF8Bytes + 1))])
        }
        let cursor = try #require(firstPage.next)
        let second = try await history.browse(.init(kind: kind, limit: 7, cursor: cursor, sortOrder: sortOrder))
        #expect(second.rows.count == 5)
        let recent = try await history.browse(.init(kind: .recent, limit: 12, sortOrder: sortOrder))
        #expect(firstPage.rows + second.rows == recent.rows)
        let previous = try #require(second.previous)
        let backward = try await history.browse(.init(kind: kind, limit: 7, cursor: previous, sortOrder: sortOrder))
        #expect(backward.rows == firstPage.rows)

        // Resolving a remembered row uses the same purpose-specific projection.
        let target = firstPage.rows[3].item.id
        let sought = try await history.browse(.init(kind: kind, limit: 7, sortOrder: sortOrder, startAround: target))
        #expect(sought.rows.first?.item.id == target)
    }

    @Test(arguments: ["needle", "NOT absent", "app:notes AND NOT absent", "app:safari OR needle"])
    func textOperandsStillValidateBodies(query: String) async throws {
        let history = try await WSSupport.makeHistory()
        _ = try await history.perform(.capture(WSSupport.textCapture(
            "title\nneedle", observedAt: Date(timeIntervalSinceReferenceDate: 1), source: "com.apple.Notes"
        )))
        try await history.authority.withTestDatabase { authority in
            try authority.database.execute("UPDATE history_items SET searchBodyUTF8 = ?",
                bindings: [.blob(Data([0xFF]))])
        }
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.browse(.init(kind: .search(text: query, mode: .expression), limit: 7))
        }
    }
}
#endif
