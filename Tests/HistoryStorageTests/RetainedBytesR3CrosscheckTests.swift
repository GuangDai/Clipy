/// Revision planning compares each selected item's scalar counts against
/// normalized immutable content metadata before pruning or appending.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct RetainedBytesR3CrosscheckTests {
    enum Mismatch: CaseIterable, Sendable { case canonicalBytes, revisionCount, revisionBytes }

    @Test(arguments: Mismatch.allCases)
    func plausibleMismatchRejectsBeforeWriting(_ mismatch: Mismatch) async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let originalItem = try await RetainedBytesTestSupport.capture(String(repeating: "c", count: 30), in: history)
        let first = try await RetainedBytesTestSupport.revise(originalItem, text: String(repeating: "a", count: 10), in: history)
        let item = try await RetainedBytesTestSupport.revise(first, text: String(repeating: "b", count: 10), in: history)
        let original = try #require(try await RetainedBytesTestSupport.counts(item.id, in: history))
        #expect(original == RetainedBytesTestSupport.Counts(canonical: 30, revisions: 2, revisionBytes: 20))
        let before = try await history.usage()
        let configuration = try await history.retentionConfiguration()
        let damaged: RetainedBytesTestSupport.Counts
        let action: HistoryAction
        switch mismatch {
        case .canonicalBytes:
            damaged = .init(canonical: 29, revisions: 2, revisionBytes: 20)
            // Revision preparation reads Canonical; R3-only pruning has no
            // reason to hydrate unrelated Canonical bytes in the new layout.
            action = RetainedBytesTestSupport.revisionAction(item, text: "next revision")
        case .revisionCount:
            damaged = .init(canonical: 30, revisions: 3, revisionBytes: 20)
            action = .setRetentionPolicies(.init(age: nil, storage: nil,
                revisions: RevisionRetention(maxRevisionsPerItem: 2, maxRevisionBytesPerItem: nil)))
        case .revisionBytes:
            damaged = .init(canonical: 30, revisions: 2, revisionBytes: 19)
            action = .setRetentionPolicies(.init(age: nil, storage: nil,
                revisions: RevisionRetention(maxRevisionsPerItem: nil, maxRevisionBytesPerItem: 18)))
        }
        try await RetainedBytesTestSupport.replaceCounts(item.id, with: damaged, in: history)
        await history.authority.setTransactionFailureInjection(.beforeSingletonUpdate)
        await #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
            try await history.perform(action)
        }
        #expect(try await history.usage() == before)
        #expect(try await history.retentionConfiguration() == configuration)
        #expect(try await RetainedBytesTestSupport.counts(item.id, in: history) == damaged)
        try await RetainedBytesTestSupport.replaceCounts(item.id, with: original, in: history)
        // The count policy equals the current count after restoration; choose
        // a real pruning change so the still-armed injection must fire.
        let retry: HistoryAction = mismatch == .revisionCount
            ? .setRetentionPolicies(.init(age: nil, storage: nil,
                revisions: RevisionRetention(maxRevisionsPerItem: 1, maxRevisionBytesPerItem: nil)))
            : action
        await #expect(throws: HistoryFailure.persistence(.transaction)) {
            try await history.perform(retry)
        }
        #expect(try await history.usage() == before)
        try await RetainedBytesTestSupport.assertAccounting(in: history)
    }
}
