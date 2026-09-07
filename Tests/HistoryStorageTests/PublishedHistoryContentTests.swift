import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

/// Real files and the sole SQL writer exercise the publication/transaction
/// ordering and orphan recovery, including a failure before BEGIN succeeds.
struct PublishedHistoryContentTests {
    private let largeType = "com.example.publication"
    private let original = Data(repeating: 84, count: 200_000)

    @Test(arguments: [InjectedTransactionFailure.beforeHCRAppend, .beforeSingletonUpdate])
    func SQLRollbackLeavesOldHistoryAndAnUnreferencedPublishedFile(injection: InjectedTransactionFailure) async throws {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        let reference = try await insertOriginal(history)
        let before = try await history.authority.publicationSQLFactsForTest()
        #expect(try await history.authority.publicationBlobCountForTest() == 1)
        await history.authority.setTransactionFailureInjection(injection)
        await #expect(throws: HistoryFailure.persistence(.transaction)) {
            try await history.perform(.capture(capture(bytes: Data(repeating: 85, count: original.count), text: "new")))
        }
        #expect(try await history.authority.publicationSQLFactsForTest() == before)
        #expect(try await history.authority.publicationBlobCountForTest() == 2)
        #expect(try await history.pastePayload(for: reference.id).representations.contains { $0.bytes == original })
        try await history.authority.cleanPublicationOrphansForTest()
        #expect(try await history.authority.publicationBlobCountForTest() == 1)
        #expect(try await history.authority.publicationSQLFactsForTest() == before)
    }

    @Test
    func failedBeginCannotReferenceAnAlreadyPublishedFile() async throws {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        let reference = try await insertOriginal(history)
        let before = try await history.authority.publicationSQLFactsForTest()
        // The same actual connection refuses BEGIN IMMEDIATE. The first
        // transaction-body injection must remain unconsumed, proving no body
        // was entered; no second writer or replacement database is involved.
        await history.authority.setTransactionFailureInjection(.positionChanged)
        try await history.authority.setQueryOnlyForPublicationTest(true)
        await #expect(throws: HistoryFailure.persistence(.transaction)) {
            try await history.perform(.capture(capture(bytes: Data(repeating: 86, count: original.count), text: "new")))
        }
        #expect(await history.authority.injectedTransactionFailure == .positionChanged)
        try await history.authority.setQueryOnlyForPublicationTest(false)
        await history.authority.setTransactionFailureInjection(nil)
        #expect(try await history.authority.publicationSQLFactsForTest() == before)
        #expect(try await history.authority.publicationBlobCountForTest() == 2)
        try await history.authority.cleanPublicationOrphansForTest()
        #expect(try await history.authority.publicationBlobCountForTest() == 1)
        #expect(try await history.pastePayload(for: reference.id).representations.contains { $0.bytes == original })
    }

    @Test
    func lowCapacityAllowsReusedLargeContentButRefusesANewLargeFile() async throws {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        let reference = try await insertOriginal(history)
        // Only the new three-byte inline text needs payload space; inheriting
        // the 200 KB immutable file adds a database reference, not another file.
        await history.authority.setVolumeAvailableCapacityOverride(CaptureCapacityAdmission.marginBytes + 3)
        let receipt = try await history.perform(.revise(RevisionRequest(
            itemID: reference.id, expected: reference.contentVersion,
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(typeIdentifier: largeType, action: .inheritCanonical),
                RevisionDecision(typeIdentifier: "public.utf8-plain-text", action: .replace(bytes: Data("new".utf8))),
            ]))
        )))
        guard case .committed(let commit) = receipt, case .revised = commit.outcome else {
            Issue.record("Reused large content should fit the exact new inline demand")
            return
        }
        #expect(try await history.authority.publicationBlobCountForTest() == 1)
        let beforeRefusal = try await history.authority.publicationSQLFactsForTest()
        await #expect(throws: HistoryFailure.temporarilyUnavailable(.insufficientDiskSpace)) {
            try await history.perform(.capture(capture(bytes: Data(repeating: 87, count: original.count), text: "new")))
        }
        #expect(try await history.authority.publicationSQLFactsForTest() == beforeRefusal)
        #expect(try await history.authority.publicationBlobCountForTest() == 1)
    }

    private func insertOriginal(_ history: SQLiteHistory) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(capture(bytes: original, text: "base")))
        guard case .committed(let commit) = receipt, case .inserted(let reference) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return reference
    }

    private func capture(bytes: Data, text: String) -> ClipboardCapture {
        ClipboardCapture(
            representations: [
                CapturedRepresentation(typeIdentifier: largeType, bytes: bytes),
                CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(text.utf8)),
            ], origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_093_000)
        )
    }
}

private extension HistoryAuthority {
    func publicationSQLFactsForTest() throws -> [Int64] {
        let statement = try database.prepare("""
            SELECT changePosition, retainedItemCount, canonicalBytes, revisionBytes,
                (SELECT count(*) FROM contents), (SELECT count(*) FROM representations),
                (SELECT count(*) FROM history_change_records)
            FROM history_state WHERE key = 'retained-history'
            """)
        defer { statement.finalize() }
        guard try statement.step() else { throw HistoryFailure.persistence(.invariantViolation) }
        var result = [Int64(try sqliteUInt64(statement.blob(at: 0)))]
        for column in Int32(1)...Int32(6) { result.append(try statement.integer(at: column)) }
        return result
    }

    func publicationBlobCountForTest() throws -> Int {
        let enumerator = FileManager.default.enumerator(
            at: storeLocation.rootURL.appendingPathComponent("blobs"), includingPropertiesForKeys: nil
        )
        var count = 0
        while let url = enumerator?.nextObject() as? URL { if url.pathExtension == "blob" { count += 1 } }
        return count
    }

    func cleanPublicationOrphansForTest() throws {
        for _ in 0..<4 {
            try blobStore.cleanupBatch { id in
                let statement = try database.prepare("SELECT 1 FROM representations WHERE blobID = ? LIMIT 1", bindings: [.text(id.uuidString)])
                defer { statement.finalize() }
                return try statement.step()
            }
        }
    }

    func setQueryOnlyForPublicationTest(_ enabled: Bool) throws {
        try database.execute(enabled ? "PRAGMA query_only = ON" : "PRAGMA query_only = OFF")
    }
}
