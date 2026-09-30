import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct CopySourceCancellationTests {
    @Test func cancelledRequestStopsBeforeMetadataReadsAndLeavesConnectionUsable() async throws {
        let history = try await WSSupport.makeHistory()
        _ = try await history.perform(.capture(WSSupport.textCapture(
            "note", observedAt: Date(timeIntervalSinceReferenceDate: 1), source: "com.example.Editor"
        )))
        let recent = try await history.browse(.init(kind: .recent, limit: 1))
        let item = try #require(recent.rows.first).item
        try await history.authority.withTestDatabase { authority in
            try authority.database.execute("UPDATE history_items SET firstCopiedAt = 2")
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await history.copySources(for: item.id, expectedCopyCount: 1, offset: 0)
        }
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.copySources(for: item.id, expectedCopyCount: 1, offset: 0)
        }
        try await history.authority.withTestDatabase { authority in
            try authority.database.execute("UPDATE history_items SET firstCopiedAt = 1")
        }
        let replacement = try await history.copySources(for: item.id, expectedCopyCount: 1, offset: 0)
        #expect(replacement.sources.map(\.application) == ["com.example.Editor"])
        #expect(replacement.sources.map(\.count) == [1])
    }
}
