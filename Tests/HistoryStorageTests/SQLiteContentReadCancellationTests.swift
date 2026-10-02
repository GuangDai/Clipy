import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct SQLiteContentReadCancellationTests {
    enum Purpose: Sendable { case paste, representation, thumbnailSource, thumbnailJoin }

    @Test(arguments: [Purpose.paste, .representation, .thumbnailSource, .thumbnailJoin])
    func cancelledContentRequestStopsBeforeStoredValues(purpose: Purpose) async throws {
        let history = try await WSSupport.makeHistory()
        _ = try await history.perform(.capture(WSSupport.textCapture(
            "stored text", observedAt: Date(timeIntervalSinceReferenceDate: 1)
        )))
        let page = try await history.browse(.init(kind: .recent, limit: 1))
        let item = try #require(page.rows.first).item
        try await history.authority.withTestDatabase { authority in
            try authority.database.execute("UPDATE history_items SET titleUTF8 = ?",
                                           bindings: [.blob(Data([0xFF]))])
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            switch purpose {
            case .paste:
                _ = try await history.pastePayload(for: item.id)
            case .representation:
                _ = try await history.representation(.init(
                    item: item, basis: .effective, typeIdentifier: "public.utf8-plain-text"
                ))
            case .thumbnailSource:
                _ = try await history.authority.thumbnailSource(for: item, pixels: PixelSize(width: 64, height: 64))
            case .thumbnailJoin:
                try await history.authority.validateThumbnailFlightJoin(for: item, pixels: PixelSize(width: 64, height: 64))
            }
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try await history.authority.withTestDatabase { authority in
            try authority.database.execute("UPDATE history_items SET titleUTF8 = ?",
                                           bindings: [.blob(Data("stored text".utf8))])
        }
        // Reuse the same connection after the cancelled read transaction.
        let replacement = try await history.pastePayload(for: item.id)
        #expect(replacement.representations.map(\.bytes) == [Data("stored text".utf8)])
    }
}
