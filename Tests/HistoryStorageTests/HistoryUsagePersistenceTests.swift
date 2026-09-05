import Foundation
import HistoryCore
import HistoryStorage
import Testing

struct HistoryUsagePersistenceTests {
    private struct Seeded: Sendable {
        let usage: HistoryUsage
        let pinnedID: HistoryItemID
        let retainedID: HistoryItemID
        let revisionIDs: [RevisionID]
    }

    @Test("reopened usage preserves pruned lineage bytes and decreases after removal")
    func usageSurvivesOwnerReleaseAndContinuesWithDeletion() async throws {
        // The shared fixture creates the directory before SwiftData opens it.
        let storeURL = WSSupport.tempStoreURL("usage-owner-release")
        defer { WSSupport.removeStore(storeURL) }
        let seeded = try await seedFirstOwner(at: storeURL)

        // Only immutable DTOs escaped the first helper; its facade and store
        // owner are out of scope before this second public open.
        let reopened = try await WSSupport.openHistory(storeURL: storeURL)
        let usage = try await reopened.usage()
        #expect(usage == seeded.usage)
        let recent = try await reopened.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
        #expect(recent.position == usage.position)
        #expect(recent.rows.map(\.item.id) == [seeded.pinnedID, seeded.retainedID])

        let details = try await reopened.details(for: seeded.pinnedID)
        #expect(details.canonical.map(\.bytes) == [Data([0x70, 0x69, 0x6E])])
        #expect(details.effective.map(\.bytes) == [Data([0x74, 0x68, 0x69, 0x72, 0x64, 0x3F])])
        #expect(details.revisions.map(\.id) == seeded.revisionIDs)
        #expect(details.revisions.map(\.title) == ["second!", "third?"])
        #expect(details.revisions.map(\.byteCount) == [7, 6])
        #expect(details.revisions.map(\.isActive) == [false, true])
        #expect(details.pinnedPosition == 0)

        let removal = try await reopened.perform(.remove(seeded.pinnedID))
        guard case .committed(let commit) = removal,
              case .removed(count: 1) = commit.outcome else {
            Issue.record("Expected removal of the reopened pinned item")
            return
        }
        #expect(commit.position.rawValue == 9)
        let after = try await reopened.usage()
        // Removal subtracts three canonical and all thirteen immutable
        // revision bytes. The other four-byte item is untouched.
        expectUsage(after, position: 9, items: 1, pinned: 0, canonical: 4, revisions: 0, total: 4)
        #expect(after.position == commit.position)
        let remaining = try await reopened.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
        #expect(remaining.rows.map(\.item.id) == [seeded.retainedID])
    }

    private func seedFirstOwner(at storeURL: URL) async throws -> Seeded {
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        _ = try await capture("older", at: 100, in: history)
        let pinned = try await capture("pin", at: 200, in: history)
        _ = try await history.perform(.placePinned(pinned.id, at: .first))
        let retained = try await capture("keep", at: 300, in: history)
        let first = try await replace(pinned, with: "first", in: history)
        let second = try await replace(first, with: "second!", in: history)
        _ = try await replace(second, with: "third?", in: history)
        expectUsage(try await history.usage(), position: 7, items: 3, pinned: 1,
                    canonical: 12, revisions: 18, total: 30)
        let before = try await history.details(for: pinned.id)
        let retainedRevisionIDs = before.revisions.dropFirst().map(\.id)
        #expect(retainedRevisionIDs.count == 2)

        // R3 removes "first" (5 B). R2 then sees 25 B and removes the
        // oldest unpinned "older" (5 B), leaving 20 B under its 21 B budget.
        let sweep = try await history.perform(.setRetentionPolicies(HistoryRetentionPolicies(
            age: nil,
            storage: StorageRetention(maxTotalBytes: 21),
            revisions: RevisionRetention(maxRevisionsPerItem: 2, maxRevisionBytesPerItem: nil)
        )))
        guard case .committed(let commit) = sweep,
              case .retentionPoliciesSet(retiredItems: 1, prunedRevisions: 1) = commit.outcome else {
            Issue.record("Expected one R3 prune and one R2 retirement")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        let usage = try await history.usage()
        expectUsage(usage, position: 8, items: 2, pinned: 1, canonical: 7, revisions: 13, total: 20)
        #expect(usage.position == commit.position)
        return Seeded(usage: usage, pinnedID: pinned.id, retainedID: retained.id,
                      revisionIDs: retainedRevisionIDs)
    }

    private func capture(
        _ text: String, at seconds: Double, in history: SwiftDataHistory
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(WSSupport.textCapture(
            text, observedAt: Date(timeIntervalSinceReferenceDate: seconds)
        )))
        guard case .committed(let commit) = receipt,
              case .inserted(let item) = commit.outcome else {
            Issue.record("Expected a new usage fixture item")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return item
    }

    private func replace(
        _ item: HistoryItemReference, with text: String, in history: SwiftDataHistory
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.revise(RevisionRequest(
            itemID: item.id, expected: item.contentVersion,
            intent: .replace(RevisionDraft(decisions: [RevisionDecision(
                typeIdentifier: "public.utf8-plain-text", action: .replace(bytes: Data(text.utf8))
            )]))
        )))
        guard case .committed(let commit) = receipt,
              case .revised(let revised) = commit.outcome else {
            Issue.record("Expected an immutable usage fixture revision")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return revised
    }

    private func expectUsage(
        _ usage: HistoryUsage, position: UInt64, items: Int, pinned: Int,
        canonical: Int, revisions: Int, total: Int
    ) {
        #expect(usage.position.rawValue == position)
        #expect(usage.itemCount == items)
        #expect(usage.pinnedItemCount == pinned)
        #expect(usage.canonicalBytes == canonical)
        #expect(usage.revisionBytes == revisions)
        #expect(usage.totalContentBytes == total)
    }
}
