import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct SQLiteCaptureConfirmationTests {
    @Test func canonicalByteAggregateMismatchRejectsCoalescingWithoutCommit() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let item = try await RetainedBytesTestSupport.capture("canonical", in: history)
        try await history.authority.withTestDatabase { authority in
            try authority.database.execute("UPDATE history_items SET canonicalBytes=canonicalBytes+1 WHERE id=?",
                bindings: [.text(item.id.rawValue.uuidString)])
        }
        let before = try await history.browse(.init(kind: .recent, limit: 10))
        let usage = try await history.usage()
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.perform(.capture(WSSupport.textCapture(
                "canonical", observedAt: Date(timeIntervalSinceReferenceDate: 900_000_001)
            )))
        }
        #expect(try await history.browse(.init(kind: .recent, limit: 10)) == before)
        #expect(try await history.usage() == usage)
    }

    @Test func confirmedSubsetStillValidatesTheCandidatesRemainingPayloads() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let required = CapturedRepresentation(typeIdentifier: "com.example.a", bytes: Data("match".utf8))
        let extra = CapturedRepresentation(typeIdentifier: "com.example.z", bytes: Data(repeating: 0x61, count: 70_000))
        let inserted = try await history.perform(.capture(capture([required, extra])))
        guard case .committed(let commit) = inserted, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        try await history.authority.makePayloadUnavailable(
            itemID: item.id, revisionOrdinal: 0, typeIdentifier: extra.typeIdentifier
        )
        let before = try await history.browse(.init(kind: .recent, limit: 10))
        let usage = try await history.usage()
        // The first representation fully matches the incoming subset. A
        // streaming confirmer must still reject the corrupt extra payload.
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.perform(.capture(capture([required])))
        }
        #expect(try await history.browse(.init(kind: .recent, limit: 10)) == before)
        #expect(try await history.usage() == usage)
    }

    @Test func equivalentTypesAcrossDifferentScalarOrdersConfirmCanonicalAndLineage() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let originalType = "com.example.e\u{301}"
        let equivalentType = "com.example.é"
        let bytes = Data(repeating: 0x41, count: 70_000)
        let other = CapturedRepresentation(typeIdentifier: "com.example.z", bytes: Data(repeating: 0x42, count: 70_000))
        let inserted = try await history.perform(.capture(capture([
            CapturedRepresentation(typeIdentifier: originalType, bytes: bytes), other
        ])))
        guard case .committed(let commit) = inserted, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        // Canonically equivalent spelling moves this type from before z to
        // after z. Matching by scalar position would incorrectly insert.
        let hints: [HistoryItemID?] = [nil, item.id]
        for hint in hints {
            let repeated = try await history.perform(.capture(capture([
                other, CapturedRepresentation(typeIdentifier: equivalentType, bytes: bytes)
            ], hint: hint)))
            guard case .committed(let repeatedCommit) = repeated, case .coalesced(let winner) = repeatedCommit.outcome else {
                Issue.record("Both Canonical and lineage confirmation must preserve type equivalence")
                throw HistoryFailure.persistence(.invariantViolation)
            }
            #expect(winner == item)
        }
        let payload = try await history.pastePayload(for: item.id)
        #expect(payload.representations.map { Data($0.typeIdentifier.utf8) }
                == [Data(originalType.utf8), Data(other.typeIdentifier.utf8)])
        #expect(payload.representations.map(\.bytes) == [bytes, other.bytes])
        let page = try await history.browse(.init(kind: .recent, limit: 10))
        #expect(page.rows.count == 1)
        #expect(page.rows.first?.copyCount == 3)
    }

    private func capture(_ representations: [CapturedRepresentation], hint: HistoryItemID? = nil) -> ClipboardCapture {
        ClipboardCapture(representations: representations,
            origin: .init(sourceApplication: nil, lineageHint: hint),
            observedAt: Date(timeIntervalSinceReferenceDate: 900_000_000))
    }
}
