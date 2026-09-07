/// DATA-2: an impossible target's scalar relations must stop revision
/// preparation before the real transaction, without repairing durable facts.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct RetainedBytesRelationalValidationTests {
    @Test(arguments: [
        RetainedBytesTestSupport.Counts(canonical: 0, revisions: 0, revisionBytes: 0),
        .init(canonical: 5, revisions: 1, revisionBytes: 0),
        .init(canonical: 5, revisions: 2, revisionBytes: 1),
    ])
    func rejectedRelationsDoNotEnterTheTransaction(_ damaged: RetainedBytesTestSupport.Counts) async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let item = try await RetainedBytesTestSupport.capture("alpha", in: history)
        let original = try #require(try await RetainedBytesTestSupport.counts(item.id, in: history))
        let before = try await history.usage()
        let action = RetainedBytesTestSupport.revisionAction(item, text: "replacement")
        try await RetainedBytesTestSupport.replaceCounts(item.id, with: damaged, in: history)
        await history.authority.setTransactionFailureInjection(.beforeSingletonUpdate)
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.perform(action)
        }
        #expect(try await RetainedBytesTestSupport.counts(item.id, in: history) == damaged)
        #expect(try await history.usage() == before)
        try await RetainedBytesTestSupport.replaceCounts(item.id, with: original, in: history)
        await #expect(throws: HistoryFailure.persistence(.transaction)) {
            try await history.perform(action)
        }
        #expect(try await history.usage() == before)
        #expect(try await history.pastePayload(for: item.id).representations.first?.bytes == Data("alpha".utf8))
    }
}
