import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct SQLiteDedupCandidateTests {
    @Test func collidingMultiRepresentationPostingsStillRequireOneByteExactCandidate() async throws {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        let preparation = IngestPreparationActor(fingerprint: ForcedCollisionFingerprint.digest(of:))
        var inserted: [HistoryItemReference] = []
        for (html, text) in [("h1", "t1"), ("h1", "t2"), ("h2", "t1"), ("h2", "t2")] {
            let prepared = try await preparation.prepare(capture(html: html, text: text))
            let receipt = try await history.authority.commitCapture(prepared)
            guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
                Issue.record("Distinct byte pairs must not coalesce through shared postings")
                throw HistoryFailure.persistence(.invariantViolation)
            }
            inserted.append(item)
        }
        // Every (type, length, fingerprint) posting collides. In particular,
        // matching HTML from one row and text from another is not a match.
        let postingCount = try await history.authority.collidingPostingCount()
        #expect(postingCount == 8)
        let prepared = try await preparation.prepare(capture(html: "h2", text: "t1"))
        let receipt = try await history.authority.commitCapture(prepared)
        guard case .committed(let commit) = receipt, case .coalesced(let winner) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        #expect(winner == inserted[2])
        let page = try await history.browse(.init(kind: .recent, limit: 10))
        #expect(page.rows.count == 4)
        #expect(page.rows.first(where: { $0.item == winner })?.copyCount == 2)
    }

    @Test func candidateKeysUseCanonicalEquivalenceButOutputKeepsExactTypeSpelling() async throws {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        let originalType = "com.example.e\u{301}"
        let equivalentType = "com.example.é"
        let bytes = Data("opaque value".utf8)
        let first = try await history.perform(.capture(ClipboardCapture(
            representations: [CapturedRepresentation(typeIdentifier: originalType, bytes: bytes)],
            origin: .init(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_300_000)
        )))
        guard case .committed(let commit) = first, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        let repeatReceipt = try await history.perform(.capture(ClipboardCapture(
            representations: [CapturedRepresentation(typeIdentifier: equivalentType, bytes: bytes)],
            origin: .init(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_300_001)
        )))
        guard case .committed(let repeated) = repeatReceipt, case .coalesced(let winner) = repeated.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        #expect(winner == item)
        let payload = try await history.pastePayload(for: item.id)
        #expect(payload.representations.count == 1)
        #expect(Data(payload.representations[0].typeIdentifier.utf8) == Data(originalType.utf8))
        #expect(payload.representations[0].bytes == bytes)
        let key = try await history.authority.canonicalPostingTypeKey(item.id)
        #expect(Data(key.utf8) == Data(equivalentType.utf8))
    }

    @Test func reopenAndUnrelatedCaptureDoNotReadUnrequestedCandidatePayload() async throws {
        let storeURL = WSSupport.tempStoreURL("sqlite-dedup-no-startup-content")
        defer { WSSupport.removeStore(storeURL) }
        let text = String(repeating: "original candidate ", count: 8_192)
        let item = try await seedDamagedCandidate(storeURL: storeURL, text: text)
        // The first facade has left scope. Startup can use persistent
        // postings without reconstructing an index or reading clipboard data.
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        let initial = try await history.browse(.init(kind: .recent, limit: 10))
        #expect(initial.rows.map(\.item) == [item])
        _ = try await history.perform(.capture(WSSupport.textCapture(
            "unrelated incoming", observedAt: Date(timeIntervalSinceReferenceDate: 700_300_002)
        )))
        let before = try await history.browse(.init(kind: .recent, limit: 10))
        let usage = try await history.usage()
        // A real posting hit must read its Canonical bytes. Missing bytes
        // are a typed failure, never permission to silently insert a duplicate.
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.perform(.capture(WSSupport.textCapture(
                text, observedAt: Date(timeIntervalSinceReferenceDate: 700_300_003)
            )))
        }
        #expect(try await history.browse(.init(kind: .recent, limit: 10)) == before)
        #expect(try await history.usage() == usage)
    }

    private func seedDamagedCandidate(storeURL: URL, text: String) async throws -> HistoryItemReference {
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        let receipt = try await history.perform(.capture(WSSupport.textCapture(
            text, observedAt: Date(timeIntervalSinceReferenceDate: 700_300_000)
        )))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        try await history.authority.makePayloadUnavailable(
            itemID: item.id, revisionOrdinal: 0, typeIdentifier: "public.utf8-plain-text"
        )
        return item
    }

    private func capture(html: String, text: String) -> ClipboardCapture {
        WSSupport.textCapture(text, observedAt: Date(timeIntervalSinceReferenceDate: 700_300_000),
                              extra: [(typeIdentifier: "public.html", bytes: Array(html.utf8))])
    }
}

private extension HistoryAuthority {
    func collidingPostingCount() throws -> Int64 {
        let query = try database.prepare("""
            SELECT COUNT(*) FROM representations r JOIN contents c ON r.contentID = c.id
            WHERE c.revisionOrdinal = 0 AND r.fingerprint = ? AND r.byteCount = 2
            """, bindings: [.blob(sqliteUInt64(ForcedCollisionFingerprint.collisionValue))])
        defer { query.finalize() }
        guard try query.step() else { throw HistoryFailure.persistence(.invariantViolation) }
        return try query.integer(at: 0)
    }

    func canonicalPostingTypeKey(_ item: HistoryItemID) throws -> String {
        let query = try database.prepare("""
            SELECT r.typeKey FROM representations r JOIN contents c ON r.contentID = c.id
            WHERE c.itemID = ? AND c.revisionOrdinal = 0
            """, bindings: [.text(item.rawValue.uuidString)])
        defer { query.finalize() }
        guard try query.step() else { throw HistoryFailure.persistence(.invariantViolation) }
        return try query.text(at: 0)
    }
}
