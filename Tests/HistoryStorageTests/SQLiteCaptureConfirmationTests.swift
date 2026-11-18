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

    @Test func externalCaptureSkipsEditedExactCandidateAndUsesEligibleRichItem() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let original = "orchid bank"
        let edited = "velvet shoal"
        let plainType = "public.utf8-plain-text"
        let markupType = "public.html"
        let markup = Data("<b>rich extra</b>".utf8)
        let firstCopy = Date(timeIntervalSinceReferenceDate: 900_010_000)
        let originalReceipt = try await history.perform(.capture(WSSupport.textCapture(original, observedAt: firstCopy)))
        let richReceipt = try await history.perform(.capture(WSSupport.textCapture(
            original, observedAt: firstCopy.addingTimeInterval(1), extra: [(markupType, Array("<i>extra</i>".utf8))]
        )))
        guard case .committed(let originalCommit) = originalReceipt, case .inserted(let plainItem) = originalCommit.outcome,
              case .committed(let richCommit) = richReceipt, case .inserted(let richItem) = richCommit.outcome else {
            Issue.record("Expected separate plain and rich captures")
            return
        }

        let editReceipt = try await history.perform(.revise(RevisionRequest(
            itemID: plainItem.id, expected: plainItem.contentVersion,
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(typeIdentifier: plainType, action: .replace(bytes: Data(edited.utf8)))
            ]))
        )))
        let richEditReceipt = try await history.perform(.revise(RevisionRequest(
            itemID: richItem.id, expected: richItem.contentVersion,
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(typeIdentifier: plainType, action: .inheritCurrent),
                RevisionDecision(typeIdentifier: markupType, action: .replace(bytes: markup)),
            ]))
        )))
        guard case .committed(let editCommit) = editReceipt, case .revised(let editedItem) = editCommit.outcome,
              case .committed(let richEditCommit) = richEditReceipt, case .revised(let usableItem) = richEditCommit.outcome else {
            Issue.record("Expected both edits to commit")
            return
        }

        let externalCopy = firstCopy.addingTimeInterval(2)
        let repeatReceipt = try await history.perform(.capture(WSSupport.textCapture(original, observedAt: externalCopy)))
        guard case .committed(let repeated) = repeatReceipt, case .coalesced(let winner) = repeated.outcome else {
            Issue.record("Expected the compatible rich candidate to remain eligible")
            return
        }
        #expect(winner == usableItem)
        let page = try await history.browse(.init(kind: .recent, limit: 10))
        #expect(page.position == repeated.position)
        #expect(page.rows.map(\.item) == [usableItem, editedItem])
        #expect(page.rows.map(\.copyCount) == [2, 1])
        let originalSearch = try await history.browse(.init(kind: .search(text: original, mode: .exact), limit: 10))
        let editedSearch = try await history.browse(.init(kind: .search(text: edited, mode: .exact), limit: 10))
        #expect(originalSearch.rows.map(\.item) == [usableItem])
        #expect(editedSearch.rows.map(\.item) == [editedItem])

        let richPayload = try await history.pastePayload(for: usableItem.id)
        let editedPayload = try await history.pastePayload(for: editedItem.id)
        #expect(richPayload.representations.first(where: { $0.typeIdentifier == plainType })?.bytes == Data(original.utf8))
        #expect(richPayload.representations.first(where: { $0.typeIdentifier == markupType })?.bytes == markup)
        #expect(editedPayload.representations.map(\.bytes) == [Data(edited.utf8)])

        let hintedReceipt = try await history.perform(.capture(WSSupport.textCapture(
            edited, observedAt: externalCopy.addingTimeInterval(1), lineageHint: editedPayload.lineageHint
        )))
        guard case .committed(let hintedCommit) = hintedReceipt, case .coalesced(let hintedWinner) = hintedCommit.outcome else {
            Issue.record("Expected copied edited bytes to match their valid lineage hint")
            return
        }
        #expect(hintedWinner == editedItem)
    }

    private func capture(_ representations: [CapturedRepresentation], hint: HistoryItemID? = nil) -> ClipboardCapture {
        ClipboardCapture(representations: representations,
            origin: .init(sourceApplication: nil, lineageHint: hint),
            observedAt: Date(timeIntervalSinceReferenceDate: 900_000_000))
    }
}
