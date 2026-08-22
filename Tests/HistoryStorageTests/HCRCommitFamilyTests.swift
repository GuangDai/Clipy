/// Batch 12 durable HCR coverage for every reachable commit family.
/// Every mutation crosses the public `SwiftDataHistory.perform` seam; the
/// assertions then read the real in-memory V4 journal as the durable oracle.
import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

@Suite("HCR reachable commit families")
struct HCRCommitFamilyTests {
    private static let epoch = Date(
        timeIntervalSinceReferenceDate: 910_000_000
    )

    private struct StoredRecord: Sendable, Equatable {
        let sequence: UInt64
        let changePositionRaw: UInt64
        let changeKindRaw: Int16
        let affectedItemsBlob: Data
    }

    private struct JournalState: Sendable, Equatable {
        let position: UInt64
        let records: [StoredRecord]
    }

    private static func makeHistory() async throws -> SwiftDataHistory {
        try await SwiftDataHistory.open(configuration: HistoryConfiguration(
            persistence: .memory
        ))
    }

    private static func journalState(
        in history: SwiftDataHistory
    ) async throws -> JournalState {
        let container = await history.authority.container
        let context = ModelContext(container)
        let position = try #require(
            context.fetch(FetchDescriptor<LastChangePositionRow>()).first
        )
        let records = try context.fetch(
            FetchDescriptor<HistoryChangeRecordRow>(
                sortBy: [SortDescriptor(\.sequence)]
            )
        )
        return JournalState(
            position: position.rawValue,
            records: records.map {
                StoredRecord(
                    sequence: $0.sequence,
                    changePositionRaw: $0.changePositionRaw,
                    changeKindRaw: $0.changeKindRaw,
                    affectedItemsBlob: $0.affectedItemsBlob
                )
            }
        )
    }

    /// Proves the public action produced exactly one new durable HCR, and that
    /// its two sequence fields equal the public commit and current position.
    private static func performCommitted(
        _ action: HistoryAction,
        expecting expectedKind: HistoryChangeKindRawV1,
        in history: SwiftDataHistory
    ) async throws -> (commit: HistoryCommit, affected: [HistoryItemID]) {
        let before = try await journalState(in: history)

        let receipt = try await history.perform(action)
        guard case .committed(let commit) = receipt else {
            Issue.record("expected a committed receipt, got \(receipt)")
            throw HistoryFailure.persistence(.invariantViolation)
        }

        let after = try await journalState(in: history)
        #expect(after.records.count == before.records.count + 1)
        #expect(after.records.dropLast() == before.records[...])
        #expect(after.position == before.position + 1)
        #expect(after.position == commit.position.rawValue)

        let record = try #require(after.records.last)
        #expect(record.sequence == commit.position.rawValue)
        #expect(record.changePositionRaw == record.sequence)
        #expect(record.changeKindRaw == expectedKind.rawValue)
        let affected = try AffectedItemsBlobCodec.decode(
            record.affectedItemsBlob,
            for: expectedKind
        )
        return (commit, affected)
    }

    private static func captureAction(
        _ text: String,
        offset: TimeInterval
    ) -> HistoryAction {
        .capture(WSSupport.textCapture(
            text,
            observedAt: epoch.addingTimeInterval(offset),
            source: "com.example.hcr.commit-families"
        ))
    }

    private static func insertedReference(
        from commit: HistoryCommit
    ) throws -> HistoryItemReference {
        guard case .inserted(let reference) = commit.outcome else {
            Issue.record("expected inserted outcome, got \(commit.outcome)")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return reference
    }

    private static func revisedReference(
        from commit: HistoryCommit
    ) throws -> HistoryItemReference {
        guard case .revised(let reference) = commit.outcome else {
            Issue.record("expected revised outcome, got \(commit.outcome)")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return reference
    }

    private static func replaceAction(
        item: HistoryItemReference,
        text: String
    ) -> HistoryAction {
        .revise(RevisionRequest(
            itemID: item.id,
            expected: item.contentVersion,
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(
                    typeIdentifier: "public.utf8-plain-text",
                    action: .replace(bytes: Data(text.utf8))
                ),
            ]))
        ))
    }

    @Test("insert and coalesce append their actual winner ID")
    func insertAndCoalesce() async throws {
        let history = try await Self.makeHistory()

        let inserted = try await Self.performCommitted(
            Self.captureAction("same canonical value", offset: 1),
            expecting: .insert,
            in: history
        )
        let item = try Self.insertedReference(from: inserted.commit)
        #expect(inserted.affected == [item.id])

        let coalesced = try await Self.performCommitted(
            Self.captureAction("same canonical value", offset: 2),
            expecting: .coalesce,
            in: history
        )
        guard case .coalesced(let winner) = coalesced.commit.outcome else {
            Issue.record(
                "expected coalesced outcome, got \(coalesced.commit.outcome)"
            )
            return
        }
        #expect(winner.id == item.id)
        #expect(coalesced.affected == [item.id])
    }

    @Test("pin, unpin, and remove append the targeted item ID")
    func placementAndRemove() async throws {
        let history = try await Self.makeHistory()
        let inserted = try await Self.performCommitted(
            Self.captureAction("placement target", offset: 10),
            expecting: .insert,
            in: history
        )
        let item = try Self.insertedReference(from: inserted.commit)

        let pinned = try await Self.performCommitted(
            .placePinned(item.id, at: .first),
            expecting: .pin,
            in: history
        )
        #expect(pinned.affected == [item.id])

        let unpinned = try await Self.performCommitted(
            .unpin(item.id),
            expecting: .unpin,
            in: history
        )
        #expect(unpinned.affected == [item.id])

        let removed = try await Self.performCommitted(
            .remove(item.id),
            expecting: .remove,
            in: history
        )
        #expect(removed.affected == [item.id])
    }

    @Test("clear all and clear unpinned use self-describing empty payloads")
    func clearScopes() async throws {
        let allHistory = try await Self.makeHistory()
        _ = try await Self.performCommitted(
            Self.captureAction("clear all target", offset: 20),
            expecting: .insert,
            in: allHistory
        )
        let clearAll = try await Self.performCommitted(
            .clear(.all),
            expecting: .clearAll,
            in: allHistory
        )
        #expect(clearAll.affected.isEmpty)

        let unpinnedHistory = try await Self.makeHistory()
        let pinnedInsert = try await Self.performCommitted(
            Self.captureAction("pinned survivor", offset: 30),
            expecting: .insert,
            in: unpinnedHistory
        )
        let pinned = try Self.insertedReference(from: pinnedInsert.commit)
        _ = try await Self.performCommitted(
            .placePinned(pinned.id, at: .first),
            expecting: .pin,
            in: unpinnedHistory
        )
        _ = try await Self.performCommitted(
            Self.captureAction("unpinned victim", offset: 31),
            expecting: .insert,
            in: unpinnedHistory
        )
        let clearUnpinned = try await Self.performCommitted(
            .clear(.unpinned),
            expecting: .clearUnpinned,
            in: unpinnedHistory
        )
        #expect(clearUnpinned.affected.isEmpty)
    }

    @Test("revision append records the revised item")
    func revise() async throws {
        let history = try await Self.makeHistory()
        let inserted = try await Self.performCommitted(
            Self.captureAction("canonical", offset: 40),
            expecting: .insert,
            in: history
        )
        let item = try Self.insertedReference(from: inserted.commit)

        let revised = try await Self.performCommitted(
            Self.replaceAction(item: item, text: "revision one"),
            expecting: .revise,
            in: history
        )
        let revisedItem = try Self.revisedReference(from: revised.commit)
        #expect(revisedItem.id == item.id)
        #expect(revised.affected == [item.id])
    }

    @Test("policy-only and retention retirement select distinct families")
    func policySetAndRetentionRetire() async throws {
        let policyHistory = try await Self.makeHistory()
        let policy = try await Self.performCommitted(
            .setRetentionPolicy(maximumUnpinnedItems: 199),
            expecting: .policySet,
            in: policyHistory
        )
        guard case .retentionPolicySet(
            let policyRemoved
        ) = policy.commit.outcome else {
            Issue.record(
                "expected retentionPolicySet, got \(policy.commit.outcome)"
            )
            return
        }
        #expect(policyRemoved == 0)
        #expect(policy.affected.isEmpty)

        let retireHistory = try await Self.makeHistory()
        let oldestInsert = try await Self.performCommitted(
            Self.captureAction("oldest", offset: 50),
            expecting: .insert,
            in: retireHistory
        )
        let oldest = try Self.insertedReference(from: oldestInsert.commit)
        _ = try await Self.performCommitted(
            Self.captureAction("newest", offset: 51),
            expecting: .insert,
            in: retireHistory
        )

        let retire = try await Self.performCommitted(
            .setRetentionPolicy(maximumUnpinnedItems: 1),
            expecting: .retire,
            in: retireHistory
        )
        guard case .retentionPolicySet(
            let retiredCount
        ) = retire.commit.outcome else {
            Issue.record(
                "expected retentionPolicySet, got \(retire.commit.outcome)"
            )
            return
        }
        #expect(retiredCount == 1)
        #expect(retire.affected == [oldest.id])
    }

    @Test("retention revision prune records its surviving item")
    func retentionRevisionPrune() async throws {
        let history = try await Self.makeHistory()
        let inserted = try await Self.performCommitted(
            Self.captureAction("revision lineage", offset: 60),
            expecting: .insert,
            in: history
        )
        let item = try Self.insertedReference(from: inserted.commit)

        let firstRevision = try await Self.performCommitted(
            Self.replaceAction(item: item, text: "revision one"),
            expecting: .revise,
            in: history
        )
        let versionTwo = try Self.revisedReference(from: firstRevision.commit)
        let secondRevision = try await Self.performCommitted(
            Self.replaceAction(item: versionTwo, text: "revision two"),
            expecting: .revise,
            in: history
        )
        let versionThree = try Self.revisedReference(from: secondRevision.commit)
        #expect(versionThree.id == item.id)

        let prune = try await Self.performCommitted(
            .setRetentionPolicies(HistoryRetentionPolicies(
                age: nil,
                storage: nil,
                revisions: RevisionRetention(
                    maxRevisionsPerItem: 1,
                    maxRevisionBytesPerItem: nil
                )
            )),
            expecting: .retireRevision,
            in: history
        )
        guard case .retentionPoliciesSet(
            let retiredItems,
            let prunedRevisions
        ) = prune.commit.outcome else {
            Issue.record(
                "expected retentionPoliciesSet, got \(prune.commit.outcome)"
            )
            return
        }
        #expect(retiredItems == 0)
        #expect(prunedRevisions == 1)
        #expect(prune.affected == [item.id])
    }
}
