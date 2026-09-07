/// Unrelated content corruption does not make scalar or Effective-only reads
/// hydrate other revisions (05 §14; V2-09 §5).
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct ScalarReadIsolationProofTests {
    @Test func corruptCanonicalBytesLeaveMetadataAndCurrentEffectiveAvailable() async throws {
        let url = WSSupport.tempStoreURL("sqlite-lazy-canonical-corruption")
        defer { WSSupport.removeStore(url) }
        let item = try await Self.seedRevision(at: url)
        do {
            let database = try SQLiteDatabase(url: url)
            try database.execute("PRAGMA ignore_check_constraints = ON")
            try database.execute("""
                UPDATE representations SET inlineBytes = x'01'
                WHERE contentID IN (SELECT id FROM contents WHERE itemID = ? AND revisionOrdinal = 0)
                """, bindings: [.text(item.id.rawValue.uuidString)])
        }
        let history = try await WSSupport.openHistory(storeURL: url)
        let recent = try await history.browse(.init(kind: .recent, limit: 10))
        #expect(recent.rows.map(\.item) == [item])
        #expect(recent.rows.map(\.title) == ["current effective"])
        for mode in [SearchMode.exact, .fuzzy, .regexp] {
            let page = try await history.browse(.init(kind: .search(text: "current", mode: mode), limit: 10))
            #expect(page.rows.map(\.item) == [item])
        }
        // Current paste does not disclose or materialize original bytes.
        let payload = try await history.pastePayload(for: item.id)
        #expect(payload.representations.map(\.bytes) == [Data("current effective".utf8)])
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.details(for: item.id)
        }
    }

    @Test func corruptCurrentBytesFailContentReadsWhileMetadataStillWorks() async throws {
        let url = WSSupport.tempStoreURL("sqlite-lazy-effective-corruption")
        defer { WSSupport.removeStore(url) }
        let item = try await Self.seedRevision(at: url)
        do {
            let database = try SQLiteDatabase(url: url)
            try database.execute("PRAGMA ignore_check_constraints = ON")
            try database.execute("""
                UPDATE representations SET inlineBytes = x'01'
                WHERE contentID = (SELECT currentContentID FROM history_items WHERE id = ?)
                """, bindings: [.text(item.id.rawValue.uuidString)])
        }
        let history = try await WSSupport.openHistory(storeURL: url)
        let page = try await history.browse(.init(kind: .recent, limit: 10))
        #expect(page.rows.map(\.item) == [item])
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) { try await history.pastePayload(for: item.id) }
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) { try await history.details(for: item.id) }
    }

    private static func seedRevision(at url: URL) async throws -> HistoryItemReference {
        let history = try await WSSupport.openHistory(storeURL: url)
        let receipt = try await history.perform(.capture(WSSupport.textCapture("original bytes", observedAt: Date(timeIntervalSinceReferenceDate: 1000))))
        guard case let .committed(commit) = receipt, case let .inserted(item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        _ = try await history.perform(.revise(.init(itemID: item.id, expected: item.contentVersion,
            intent: .replace(.init(decisions: [.init(typeIdentifier: "public.utf8-plain-text", action: .replace(bytes: Data("current effective".utf8)))])))))
        return try await history.pastePayload(for: item.id).item
    }
}
