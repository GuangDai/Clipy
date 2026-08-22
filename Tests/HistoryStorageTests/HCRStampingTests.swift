/// J.3 pure HCR stamping proofs.
/// Owning spec: `V2-03` §4.2/§5.2 and V2 roadmap J.3.
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

@Suite("History Change Record stamping (J.3)")
struct HCRStampingTests {
    private let first = Self.itemID(1)
    private let second = Self.itemID(2)
    private let third = Self.itemID(3)
    private let timestamp = Date(timeIntervalSinceReferenceDate: 701_000_000)

    @Test("Journal entry raw values are frozen and zero is invalid")
    func rawValuesAreFrozen() {
        #expect(HistoryChangeKindRawV1.insert.rawValue == 1)
        #expect(HistoryChangeKindRawV1.coalesce.rawValue == 2)
        #expect(HistoryChangeKindRawV1.pin.rawValue == 3)
        #expect(HistoryChangeKindRawV1.unpin.rawValue == 4)
        #expect(HistoryChangeKindRawV1.remove.rawValue == 5)
        #expect(HistoryChangeKindRawV1.clearAll.rawValue == 6)
        #expect(HistoryChangeKindRawV1.clearUnpinned.rawValue == 7)
        #expect(HistoryChangeKindRawV1.revise.rawValue == 8)
        #expect(HistoryChangeKindRawV1.retire.rawValue == 9)
        #expect(HistoryChangeKindRawV1.policySet.rawValue == 10)
        #expect(HistoryChangeKindRawV1.retireRevision.rawValue == 11)
        #expect(HistoryChangeKindRawV1(rawValue: 0) == nil)
    }

    @Test("Capture and coalesce outcomes designate their primary kind")
    func captureKindsAndAffectedUnion() throws {
        let inserted = try derive(
            mutations: [
                .delete(itemID: third, reason: .retention),
                .create(storedItem(first)),
                .delete(itemID: second, reason: .retention),
            ],
            outcome: .inserted(reference(first))
        )
        #expect(inserted.changeKind == .insert)
        #expect(inserted.affectedItemIDs == [first, second, third])

        let coalesced = try derive(
            mutations: [
                .delete(itemID: third, reason: .retention),
                .updateOccurrence(itemID: second, occurrence: occurrence),
            ],
            outcome: .coalesced(reference(second))
        )
        #expect(coalesced.changeKind == .coalesce)
        #expect(coalesced.affectedItemIDs == [second, third])
    }

    @Test("Pin, unpin, and remove use their explicit stamped payloads")
    func placementAndRemovalKinds() throws {
        let pinned = try derive(
            mutations: [.setPinOrdinal(itemID: second, ordinal: 0)],
            outcome: .placedPinned(second)
        )
        #expect(pinned.changeKind == .pin)
        #expect(pinned.affectedItemIDs == [second])

        let unpinned = try derive(
            mutations: [.setPinOrdinal(itemID: second, ordinal: nil)],
            outcome: .unpinned(second)
        )
        #expect(unpinned.changeKind == .unpin)
        #expect(unpinned.affectedItemIDs == [second])

        let removed = try derive(
            mutations: [.delete(itemID: second, reason: .userRemoval)],
            outcome: .removed(count: 1)
        )
        #expect(removed.changeKind == .remove)
        #expect(removed.affectedItemIDs == [second])
    }

    @Test("Clear scope is explicit and clear records carry no IDs")
    func clearScopeSpellsTheKind() throws {
        let mutations: [StampedMutation] = [
            .delete(itemID: second, reason: .clear),
            .delete(itemID: first, reason: .clear),
        ]
        let all = try derive(
            mutations: mutations,
            outcome: .cleared(count: 2),
            clearScope: .all
        )
        #expect(all.changeKind == .clearAll)
        #expect(all.affectedItemIDs.isEmpty)

        let unpinned = try derive(
            mutations: mutations,
            outcome: .cleared(count: 2),
            clearScope: .unpinned
        )
        #expect(unpinned.changeKind == .clearUnpinned)
        #expect(unpinned.affectedItemIDs.isEmpty)
    }

    @Test("Clear requires scope and non-clear rejects scope")
    func clearScopeIsRequiredOnlyForClear() {
        #expect(throws: StampingRejection.incoherentPlan) {
            try derive(
                mutations: [.delete(itemID: first, reason: .clear)],
                outcome: .cleared(count: 1)
            )
        }
        #expect(throws: StampingRejection.incoherentPlan) {
            try derive(
                mutations: [.setPinOrdinal(itemID: first, ordinal: 0)],
                outcome: .placedPinned(first),
                clearScope: .all
            )
        }
    }

    @Test("A revised primary outranks its retention side effects")
    func revisePrimaryOutranksRetention() throws {
        let payload = try derive(
            mutations: [
                .delete(itemID: third, reason: .retention),
                .appendRevision(revisionUpdate(second)),
            ],
            outcome: .revised(reference(second))
        )
        #expect(payload.changeKind == .revise)
        #expect(payload.affectedItemIDs == [second, third])
    }

    @Test("Policy primary follows membership then revision effects")
    func policyPrimaryKind() throws {
        let policyOnly = try derive(
            mutations: [.setRetentionPolicy(maximumUnpinnedItems: 20)],
            outcome: .retentionPolicySet(removedCount: 0)
        )
        #expect(policyOnly.changeKind == .policySet)
        #expect(policyOnly.affectedItemIDs.isEmpty)

        let retired = try derive(
            mutations: [
                .setRetentionPolicies(policies: policies),
                .delete(itemID: second, reason: .retention),
            ],
            outcome: .retentionPoliciesSet(
                retiredItems: 1,
                prunedRevisions: 0
            )
        )
        #expect(retired.changeKind == .retire)
        #expect(retired.affectedItemIDs == [second])

        let pruned = try derive(
            mutations: [
                .setRetentionPolicies(policies: policies),
                prune(first),
            ],
            outcome: .retentionPoliciesSet(
                retiredItems: 0,
                prunedRevisions: 1
            )
        )
        #expect(pruned.changeKind == .retireRevision)
        #expect(pruned.affectedItemIDs == [first])

        let mixed = try derive(
            mutations: [
                prune(third),
                .setRetentionPolicies(policies: policies),
                .delete(itemID: second, reason: .retention),
            ],
            outcome: .retentionPoliciesSet(
                retiredItems: 1,
                prunedRevisions: 1
            )
        )
        #expect(mixed.changeKind == .retire)
        #expect(mixed.affectedItemIDs == [second, third])
    }

    @Test("Affected IDs are deduplicated and sorted without truncation")
    func affectedIDsAreBoundedWithoutLoss() throws {
        let maximum = JournalLimits.standard.maxAffectedItemsPerRecord
        let mutations = (1 ... maximum)
            .reversed()
            .map { value in
                StampedMutation.setPinOrdinal(
                    itemID: Self.itemID(value),
                    ordinal: value
                )
            } + [
                .setPinOrdinal(itemID: first, ordinal: 0),
            ]

        let payload = try derive(
            mutations: mutations,
            outcome: .placedPinned(first)
        )
        #expect(payload.affectedItemIDs.count == maximum)
        #expect(payload.affectedItemIDs.first == first)
        #expect(payload.affectedItemIDs.last == Self.itemID(maximum))
    }

    @Test("An impossible affected-ID excess fails instead of truncating")
    func affectedIDExcessFailsClosed() {
        let maximum = JournalLimits.standard.maxAffectedItemsPerRecord
        let mutations = (1 ... (maximum + 1)).map { value in
            StampedMutation.setPinOrdinal(
                itemID: Self.itemID(value),
                ordinal: value
            )
        }
        #expect(throws: StampingRejection.incoherentPlan) {
            try derive(
                mutations: mutations,
                outcome: .placedPinned(first)
            )
        }
    }

    @Test("Payload reuses one position and preserves the supplied clock sample")
    func payloadTokensAndTimestamp() throws {
        let payload = try derive(
            mutations: [.setPinOrdinal(itemID: first, ordinal: 0)],
            outcome: .placedPinned(first)
        )
        #expect(payload.sequence == 41)
        #expect(payload.changePositionRaw == 41)
        #expect(payload.createdAt == timestamp)
    }

    @Test("Every non-empty stamped plan carries its derived HCR")
    func stampedPlanCarriesHCR() throws {
        let plan = MutationPlan(
            outcome: .placedPinned(first),
            mutations: [
                .assignPin(itemID: first, ordinal: PinOrdinal(rawValue: 0)),
            ]
        )
        let stamped = try CommitPlanStamper.stamp(
            plan,
            currentPosition: ChangePosition(rawValue: 40),
            inputs: .none,
            createdAt: timestamp
        )
        #expect(stamped.position.rawValue == 41)
        #expect(stamped.hcrAppend.sequence == 41)
        #expect(stamped.hcrAppend.changePositionRaw == 41)
        #expect(stamped.hcrAppend.changeKind == .pin)
        #expect(stamped.hcrAppend.affectedItemIDs == [first])
        #expect(stamped.hcrAppend.createdAt == timestamp)
    }

    private var occurrence: CopyOccurrence {
        CopyOccurrence(
            firstCopiedAt: timestamp,
            lastCopiedAt: timestamp,
            count: 1,
            firstSource: nil,
            lastSource: nil
        )
    }

    private var policies: HistoryRetentionPolicies {
        HistoryRetentionPolicies(
            age: nil,
            storage: nil,
            revisions: RevisionRetention(
                maxRevisionsPerItem: 3,
                maxRevisionBytesPerItem: nil
            )
        )
    }

    private func reference(_ id: HistoryItemID) -> HistoryItemReference {
        HistoryItemReference(
            id: id,
            contentVersion: ContentVersion(rawValue: 1)
        )
    }

    private func storedItem(_ id: HistoryItemID) -> StoredNewItem {
        StoredNewItem(
            id: id,
            contentVersion: ContentVersion(rawValue: 1),
            canonicalBlob: Data(),
            revisionStateBlob: Data(),
            canonicalSignatureBlob: Data(),
            projection: projection,
            effectiveTypeIdentifiersBlob: Data(),
            occurrence: occurrence
        )
    }

    private func revisionUpdate(_ id: HistoryItemID) -> StoredRevisionUpdate {
        StoredRevisionUpdate(
            itemID: id,
            expectedCurrentVersion: ContentVersion(rawValue: 1),
            nextVersion: ContentVersion(rawValue: 2),
            revisionStateBlob: Data(),
            projection: projection,
            effectiveTypeIdentifiersBlob: Data(),
            retainedRevisionScalars: RetainedRevisionScalars(count: 1, bytes: 1)
        )
    }

    private var projection: ContentProjection {
        ContentProjection(
            schemaVersion: ContentProjector.schemaVersion,
            title: "title",
            searchBody: "body",
            effectiveTypeIdentifiers: ["public.text"]
        )
    }

    private func prune(_ id: HistoryItemID) -> StampedMutation {
        .pruneRevisions(
            itemID: id,
            revisionStateBlob: Data(),
            retainedRevisionScalars: RetainedRevisionScalars(count: 1, bytes: 1)
        )
    }

    private func derive(
        mutations: [StampedMutation],
        outcome: HistoryCommitOutcome,
        clearScope: ClearScope? = nil
    ) throws -> HistoryChangeRecordPayload {
        try HistoryChangeRecordPayload.derive(
            position: ChangePosition(rawValue: 41),
            mutations: mutations,
            receiptOutcome: outcome,
            clearScope: clearScope,
            createdAt: timestamp
        )
    }

    private static func itemID(_ value: Int) -> HistoryItemID {
        let digits = String(value, radix: 16, uppercase: true)
        let suffix = String(repeating: "0", count: 12 - digits.count) + digits
        return HistoryItemID(rawValue: UUID(
            uuidString: "00000000-0000-0000-0000-\(suffix)"
        )!)
    }
}
