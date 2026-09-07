import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

/// Scalar lineage and new bytes are sufficient for revision stamping;
/// immutable survivor payloads are absent from this Interface (V2-09 §§4/6).
struct StampedPlanTests {
    @Test(arguments: [false, true])
    func appendCarriesOnlyNewContentAndExplicitPruneIDs(pruneFirst: Bool) throws {
        let itemID = HistoryItemID(rawValue: UUID())
        let old = RevisionRetentionSummary(id: RevisionID(rawValue: UUID()), byteCount: 100_000_000)
        let survivor = RevisionRetentionSummary(id: RevisionID(rawValue: UUID()), byteCount: 3)
        let revision = newRevision()
        let append = HistoryMutation.appendRevision(itemID: itemID, revision: revision, activeRevisionID: revision.id)
        let prune = HistoryMutation.pruneRevisions(itemID: itemID, removedRevisionIDs: [old.id])
        let plan = MutationPlan(outcome: .revised(itemID), mutations: pruneFirst ? [prune, append] : [append, prune])
        let stamped = try CommitPlanStamper.stamp(
            plan, currentPosition: ChangePosition(rawValue: 40),
            inputs: .revision(
                currentVersion: ContentVersion(rawValue: 7),
                existingRevisions: [old, survivor], projection: projection
            ), createdAt: timestamp
        )
        #expect(stamped.mutations.count == 1)
        guard case .appendRevision(let payload) = stamped.mutations.first else {
            Issue.record("Expected one append carrying its explicit prune IDs")
            return
        }
        #expect(payload.revision == revision)
        #expect(payload.removedRevisionIDs == [old.id])
        #expect(payload.expectedCurrentVersion.rawValue == 7)
        #expect(payload.nextVersion.rawValue == 8)
        #expect(payload.retainedRevisionScalars == RetainedRevisionScalars(count: 2, bytes: 7))
        #expect(stamped.position.rawValue == 41)
        #expect(stamped.hasDestructiveRetentionEffects)
        #expect(stamped.hcrAppend.changePositionRaw == 41)
        #expect(stamped.hcrAppend.affectedItemIDs == [itemID])
        #expect(stamped.receiptOutcome == .revised(HistoryItemReference(id: itemID, contentVersion: ContentVersion(rawValue: 8))))
    }

    @Test
    func pruneCarriesOnlyRemovedIDsAndSurvivorScalars() throws {
        let itemID = HistoryItemID(rawValue: UUID())
        let removed = RevisionRetentionSummary(id: RevisionID(rawValue: UUID()), byteCount: 80_000_000)
        let active = RevisionRetentionSummary(id: RevisionID(rawValue: UUID()), byteCount: 7)
        let plan = MutationPlan(
            outcome: .retentionPoliciesSet(retiredItems: 0, prunedRevisions: 1),
            mutations: [.pruneRevisions(itemID: itemID, removedRevisionIDs: [removed.id])]
        )
        let stamped = try CommitPlanStamper.stamp(
            plan, currentPosition: ChangePosition(rawValue: 8),
            inputs: .prune(lineagesByItem: [itemID: PruneLineage(revisions: [removed, active], activeRevisionID: active.id)]),
            createdAt: timestamp
        )
        guard case .pruneRevisions(let target, let removedIDs, let scalars) = stamped.mutations.first else {
            Issue.record("Expected an explicit revision removal")
            return
        }
        #expect(target == itemID)
        #expect(removedIDs == [removed.id])
        #expect(scalars == RetainedRevisionScalars(count: 1, bytes: 7))
        #expect(stamped.position.rawValue == 9)
        #expect(!stamped.requiresFinalPinOrderValidation)
        #expect(stamped.hasDestructiveRetentionEffects)
        #expect(stamped.receiptOutcome == .retentionPoliciesSet(retiredItems: 0, prunedRevisions: 1))
    }

    @Test
    func standalonePruneCannotRemoveActiveRevision() throws {
        let itemID = HistoryItemID(rawValue: UUID())
        let active = RevisionRetentionSummary(id: RevisionID(rawValue: UUID()), byteCount: 7)
        let plan = MutationPlan(
            outcome: .retentionPoliciesSet(retiredItems: 0, prunedRevisions: 1),
            mutations: [.pruneRevisions(itemID: itemID, removedRevisionIDs: [active.id])]
        )
        #expect(throws: StampingRejection.incoherentPlan) {
            try CommitPlanStamper.stamp(
                plan, currentPosition: ChangePosition(rawValue: 8),
                inputs: .prune(lineagesByItem: [itemID: PruneLineage(revisions: [active], activeRevisionID: active.id)]),
                createdAt: timestamp
            )
        }
    }

    private var timestamp: Date { Date(timeIntervalSinceReferenceDate: 700_093_000) }

    private var projection: ContentProjection {
        ContentProjection(title: "next", searchBody: "next", effectiveTypeIdentifiers: ["public.utf8-plain-text"])
    }

    private func newRevision() -> ContentRevision {
        ContentRevision(
            id: RevisionID(rawValue: UUID()), createdAt: timestamp,
            content: EffectiveContent(representations: [
                ContentRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data("next".utf8)),
            ])
        )
    }
}
