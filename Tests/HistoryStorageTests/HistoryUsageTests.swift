import Foundation
import HistoryCore
import HistoryStorage
import Testing

@Suite("Retained content usage")
struct HistoryUsageTests {
    private func openHistory() async throws -> SwiftDataHistory {
        try await SwiftDataHistory.open(configuration: HistoryConfiguration(persistence: .memory))
    }

    private func capture(
        _ text: String,
        at seconds: Double,
        in history: SwiftDataHistory
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(WSSupport.textCapture(
            text, observedAt: Date(timeIntervalSinceReferenceDate: seconds)
        )))
        guard case .committed(let commit) = receipt,
              case .inserted(let item) = commit.outcome else {
            Issue.record("Expected a new captured item")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return item
    }

    private func replace(
        _ item: HistoryItemReference,
        with text: String,
        in history: SwiftDataHistory
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.revise(RevisionRequest(
            itemID: item.id,
            expected: item.contentVersion,
            intent: .replace(RevisionDraft(decisions: [RevisionDecision(
                typeIdentifier: "public.utf8-plain-text",
                action: .replace(bytes: Data(text.utf8))
            )]))
        )))
        guard case .committed(let commit) = receipt,
              case .revised(let revised) = commit.outcome else {
            Issue.record("Expected an appended content revision")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return revised
    }

    // Expected quantities are hand-counted from the fixtures below, not
    // derived from storage rows, projection helpers, or the returned DTO.
    private func expectUsage(
        _ history: SwiftDataHistory,
        position: UInt64,
        items: Int,
        pinned: Int,
        canonical: Int,
        revisions: Int,
        total: Int
    ) async throws {
        let usage = try await history.usage()
        #expect(usage.position == ChangePosition(rawValue: position))
        #expect(usage.itemCount == items)
        #expect(usage.pinnedItemCount == pinned)
        #expect(usage.canonicalBytes == canonical)
        #expect(usage.revisionBytes == revisions)
        #expect(usage.totalContentBytes == total)
        #expect(try await history.usage() == usage)
    }

    @Test("capture, coalescing, revisions and removal report exact logical bytes")
    func usageFollowsPublicMutations() async throws {
        let history = try await openHistory()
        try await expectUsage(history, position: 0, items: 0, pinned: 0, canonical: 0, revisions: 0, total: 0)

        // Two UTF-8 bytes, although the title contains one Character.
        let alpha = try await capture("é", at: 100, in: history)
        try await expectUsage(history, position: 1, items: 1, pinned: 0, canonical: 2, revisions: 0, total: 2)
        let beta = try await capture("hello", at: 200, in: history)
        try await expectUsage(history, position: 2, items: 2, pinned: 0, canonical: 7, revisions: 0, total: 7)

        let copiedAgain = try await history.perform(.capture(WSSupport.textCapture(
            "é", observedAt: Date(timeIntervalSinceReferenceDate: 300)
        )))
        guard case .committed(let copyCommit) = copiedAgain,
              case .coalesced(let winner) = copyCommit.outcome else {
            Issue.record("Repeated canonical bytes must coalesce")
            return
        }
        #expect(winner == alpha)
        try await expectUsage(history, position: 3, items: 2, pinned: 0, canonical: 7, revisions: 0, total: 7)

        _ = try await history.perform(.placePinned(alpha.id, at: .first))
        try await expectUsage(history, position: 4, items: 2, pinned: 1, canonical: 7, revisions: 0, total: 7)
        let revised = try await replace(alpha, with: "four", in: history)
        try await expectUsage(history, position: 5, items: 2, pinned: 1, canonical: 7, revisions: 4, total: 11)

        // Revert appends two bytes; the four-byte inactive revision remains.
        _ = try await history.perform(.revise(RevisionRequest(
            itemID: revised.id, expected: revised.contentVersion,
            intent: .revert(to: .canonical)
        )))
        try await expectUsage(history, position: 6, items: 2, pinned: 1, canonical: 7, revisions: 6, total: 13)
        _ = try await history.perform(.remove(beta.id))
        try await expectUsage(history, position: 7, items: 1, pinned: 1, canonical: 2, revisions: 6, total: 8)

        _ = try await capture("xyz", at: 400, in: history)
        try await expectUsage(history, position: 8, items: 2, pinned: 1, canonical: 5, revisions: 6, total: 11)
        _ = try await history.perform(.clear(.unpinned))
        try await expectUsage(history, position: 9, items: 1, pinned: 1, canonical: 2, revisions: 6, total: 8)
        _ = try await history.perform(.unpin(alpha.id))
        try await expectUsage(history, position: 10, items: 1, pinned: 0, canonical: 2, revisions: 6, total: 8)
        _ = try await history.perform(.clear(.all))
        try await expectUsage(history, position: 11, items: 0, pinned: 0, canonical: 0, revisions: 0, total: 0)
        guard case .unchanged = try await history.perform(.clear(.all)) else {
            Issue.record("Clearing empty history must not commit")
            return
        }
        try await expectUsage(history, position: 11, items: 0, pinned: 0, canonical: 0, revisions: 0, total: 0)
    }

    @Test("R3 pruning and R2 retirement update usage in their committing snapshot")
    func usageFollowsRetention() async throws {
        let history = try await openHistory()
        let alpha = try await capture("aaaa", at: 100, in: history)
        _ = try await capture("bbbbbb", at: 200, in: history)
        let pinned = try await capture("pp", at: 300, in: history)
        _ = try await history.perform(.placePinned(pinned.id, at: .first))
        let firstRevision = try await replace(alpha, with: "12345", in: history)
        let secondRevision = try await replace(firstRevision, with: "abcdefg", in: history)
        // Canonical: 4 + 6 + 2; stored revisions: 5 + 7.
        try await expectUsage(history, position: 6, items: 3, pinned: 1, canonical: 12, revisions: 12, total: 24)

        let revisionPolicy = RevisionRetention(maxRevisionsPerItem: 1, maxRevisionBytesPerItem: nil)
        let sweep = try await history.perform(.setRetentionPolicies(HistoryRetentionPolicies(
            age: nil, storage: nil, revisions: revisionPolicy
        )))
        guard case .committed(let pruneCommit) = sweep,
              case .retentionPoliciesSet(retiredItems: 0, prunedRevisions: 1) = pruneCommit.outcome else {
            Issue.record("The sweep must prune only the five-byte inactive revision")
            return
        }
        try await expectUsage(history, position: 7, items: 3, pinned: 1, canonical: 12, revisions: 7, total: 19)

        // Appending under R3 replaces the retained seven-byte revision with
        // the new eight-byte revision in one commit, not a transient sum of 15.
        _ = try await replace(secondRevision, with: "abcdefgh", in: history)
        try await expectUsage(history, position: 8, items: 3, pinned: 1, canonical: 12, revisions: 8, total: 20)

        let retirement = try await history.perform(.setRetentionPolicies(HistoryRetentionPolicies(
            age: nil, storage: StorageRetention(maxTotalBytes: 10), revisions: revisionPolicy
        )))
        guard case .committed(let retirementCommit) = retirement,
              case .retentionPoliciesSet(retiredItems: 1, prunedRevisions: 0) = retirementCommit.outcome else {
            Issue.record("R2 must retire the oldest item and all its revision bytes")
            return
        }
        // A's 4 canonical + 8 revision bytes are removed; B and pinned P remain.
        try await expectUsage(history, position: 9, items: 2, pinned: 1, canonical: 8, revisions: 0, total: 8)
    }
}
