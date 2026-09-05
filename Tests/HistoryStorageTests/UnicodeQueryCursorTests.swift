import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct UnicodeQueryCursorTests {
    @Test(arguments: [SearchMode.exact, .regexp, .fuzzy])
    func storedShapeBindsOriginalUnicodeSequence(mode: SearchMode) {
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        #expect(composed == decomposed)
        #expect(!composed.utf8.elementsEqual(decomposed.utf8))
        let shape = StoredQueryShape.search(text: composed, mode: mode, limit: 1)
        #expect(shape.matches(HistoryBrowseRequest(
            kind: .search(text: composed, mode: mode), limit: 1
        )))
        #expect(!shape.matches(HistoryBrowseRequest(
            kind: .search(text: decomposed, mode: mode), limit: 1
        )))
    }

    // Both queries match every row: the old anchor remains valid even for
    // the changed query, so only correct query binding can reject reuse.
    // This exercises the public browse path and real in-memory persistence.
    @Test(arguments: [SearchMode.exact, .regexp], [false, true])
    func equivalentSpellingCannotReuseAnotherQueryCursor(
        mode: SearchMode, reversed: Bool
    ) async throws {
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )
        for index in 0..<3 {
            _ = try await history.perform(.capture(WSSupport.textCapture(
                "row \(index) \u{00E9} e\u{0301}",
                observedAt: Date(timeIntervalSinceReferenceDate: Double(100 + index))
            )))
        }
        let original = reversed ? "e\u{0301}" : "\u{00E9}"
        let changed = reversed ? "\u{00E9}" : "e\u{0301}"
        let first = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: original, mode: mode), limit: 1
        ))
        let cursor = try #require(first.next)
        let firstID = try #require(first.rows.first?.item.id)
        let continued = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: original, mode: mode), limit: 1, after: cursor
        ))
        #expect(continued.rows.count == 1)
        #expect(continued.rows.first?.item.id != firstID)
        #expect(continued.position == first.position)
        await #expect(throws: HistoryFailure.snapshotExpired(current: first.position)) {
            try await history.browse(HistoryBrowseRequest(
                kind: .search(text: changed, mode: mode), limit: 1, after: cursor
            ))
        }
        let restarted = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: changed, mode: mode), limit: 1
        ))
        #expect(restarted.rows.first?.item.id == firstID)
        #expect(restarted.position == first.position)
        #expect(restarted.next != nil)
    }
}
