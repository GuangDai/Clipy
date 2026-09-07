import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct LineageHintSQLiteValidationTests {
    @Test
    func canonicalPointerWithRetainedRevisionCannotCoalesceThroughHint() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let original = try await RetainedBytesTestSupport.capture("canonical", in: history)
        let revised = try await RetainedBytesTestSupport.revise(original, text: "effective", in: history)
        let before = try await history.usage()
        // The foreign key remains valid, but this points at ordinal zero
        // despite revisionCount == 1. Capture must reject the same corruption
        // as Details, rather than treating Canonical as current Effective.
        try await history.authority.withTestDatabase { authority in
            try authority.database.execute("""
                UPDATE history_items SET currentContentID=(
                    SELECT id FROM contents WHERE itemID=? AND revisionOrdinal=0
                ) WHERE id=?
                """, bindings: [.text(revised.id.rawValue.uuidString), .text(revised.id.rawValue.uuidString)])
        }
        let hinted = ClipboardCapture(
            representations: [CapturedRepresentation(
                typeIdentifier: "public.utf8-plain-text", bytes: Data("canonical".utf8))],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: revised.id),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_100_001))
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.perform(.capture(hinted))
        }
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.details(for: revised.id)
        }
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.pastePayload(for: revised.id)
        }
        #expect(try await history.usage() == before)
        let durableVersion = try await history.authority.withTestDatabase { authority in
            try HistoryItemRowHydration.metadata(itemID: revised.id, in: authority.database)?.contentVersion
        }
        #expect(durableVersion == revised.contentVersion)
    }
}
