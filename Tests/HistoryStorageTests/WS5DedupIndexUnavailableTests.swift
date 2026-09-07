import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

/// WS5 (06 §8): unavailable candidate evidence cannot become an empty
/// candidate set. SQL failure rejects capture before planning or publication.
struct WS5DedupIndexUnavailableTests {
    @Test func candidateQueryFailureCommitsNothingAndRetryFindsExistingCanonical() async throws {
        let url = WSSupport.tempStoreURL("ws5-candidate-query-failure")
        defer { WSSupport.removeStore(url) }
        let history = try await WSSupport.openHistory(storeURL: url)
        let capture = WSSupport.textCapture("ws5 persisted candidate", observedAt: Date(timeIntervalSince1970: 100))
        let inserted = try await history.perform(.capture(capture))
        guard case .committed(let firstCommit) = inserted,
              case .inserted(let reference) = firstCommit.outcome else {
            Issue.record("Expected seed insertion")
            return
        }
        let database = try WSSupport.makeDatabase(storeURL: url)
        let before = try TransactionStoreSnapshot.read(from: url)
        let probe = await SingleOperationInvalidationPublicationProbe.begin(on: history.authority)

        // A real SQL prepare failure, not a fake writer or an index-ready flag.
        // Renaming preserves all bytes so the retry can prove no partial write.
        try database.execute("ALTER TABLE representations RENAME TO unavailable_representations")
        defer { try? database.execute("ALTER TABLE unavailable_representations RENAME TO representations") }
        await #expect(throws: HistoryFailure.persistence(.transaction)) {
            try await history.perform(.capture(capture))
        }
        #expect(try WSSupport.fetchRows(database) == before.items)
        #expect(try WSSupport.fetchPosition(database).rawValue == firstCommit.position.rawValue)
        let publications = try await probe.finish(on: history.authority)
        #expect(publications.count == 0)

        try database.execute("ALTER TABLE unavailable_representations RENAME TO representations")
        let after = try TransactionStoreSnapshot.read(from: url)
        #expect(after == before)
        let retry = try await history.perform(.capture(capture))
        guard case .committed(let retryCommit) = retry,
              case .coalesced(let winner) = retryCommit.outcome else {
            Issue.record("Expected existing Canonical candidate after restoring query availability")
            return
        }
        #expect(winner == reference)
        #expect(retryCommit.position.rawValue == firstCommit.position.rawValue + 1)
        let rows = try WSSupport.fetchRows(database)
        #expect(rows.count == 1)
        #expect(rows.first?.copyCount == 2)
    }
}
