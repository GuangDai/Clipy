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
        #expect(inserted.affectedItems == .explicit([first, second, third]))

        let coalesced = try derive(
            mutations: [
                .delete(itemID: third, reason: .retention),
                .updateOccurrence(itemID: second, occurrence: occurrence),
            ],
            outcome: .coalesced(reference(second))
        )
        #expect(coalesced.changeKind == .coalesce)
        #expect(coalesced.affectedItems == .explicit([second, third]))
    }

    @Test("Pin, unpin, and remove use their explicit stamped payloads")
    func placementAndRemovalKinds() throws {
        let pinned = try derive(
            mutations: [.setPinOrdinal(itemID: second, ordinal: 0)],
            outcome: .placedPinned(second)
        )
        #expect(pinned.changeKind == .pin)
        #expect(pinned.affectedItems == .explicit([second]))

        let unpinned = try derive(
            mutations: [.setPinOrdinal(itemID: second, ordinal: nil)],
            outcome: .unpinned(second)
        )
        #expect(unpinned.changeKind == .unpin)
        #expect(unpinned.affectedItems == .explicit([second]))

        let removed = try derive(
            mutations: [.delete(itemID: second, reason: .userRemoval)],
            outcome: .removed(count: 1)
        )
        #expect(removed.changeKind == .remove)
        #expect(removed.affectedItems == .explicit([second]))
    }

    @Test("Clear records preserve scope and actual retired count")
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
        #expect(all.affectedItems == .all(retiredItems: 2))

        let unpinned = try derive(
            mutations: mutations,
            outcome: .cleared(count: 2),
            clearScope: .unpinned
        )
        #expect(unpinned.changeKind == .clearUnpinned)
        #expect(unpinned.affectedItems == .unpinned(retiredItems: 2))
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
        #expect(payload.affectedItems == .explicit([second, third]))
    }

    @Test("Policy primary follows membership then revision effects")
    func policyPrimaryKind() throws {
        let policyOnly = try derive(
            mutations: [.setRetentionPolicy(maximumUnpinnedItems: 20)],
            outcome: .retentionPolicySet(removedCount: 0)
        )
        #expect(policyOnly.changeKind == .policySet)
        #expect(policyOnly.affectedItems == .explicit([]))

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
        #expect(retired.affectedItems == .explicit([second]))

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
        #expect(pruned.affectedItems == .explicit([first]))

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
        #expect(mixed.affectedItems == .explicit([second, third]))
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
        guard case .explicit(let ids) = payload.affectedItems else {
            Issue.record("expected explicit pin identities")
            return
        }
        #expect(ids.count == maximum)
        #expect(ids.first == first)
        #expect(ids.last == Self.itemID(maximum))
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
        #expect(stamped.hcrAppend.affectedItems == .explicit([first]))
        #expect(stamped.hcrAppend.createdAt == timestamp)
    }

    @Test("bulk clear stamping keeps one scope and the exact receipt count")
    func bulkClearScopeMatchesItsReceipt() throws {
        for count in [1, 5_001, 1_000_000] {
            let all = try derive(
                mutations: [.bulkClear(scope: .all, affectedCount: count)],
                outcome: .cleared(count: count), clearScope: .all
            )
            #expect(all.changeKind == .clearAll)
            #expect(all.affectedItems == .all(retiredItems: count))
            let unpinned = try derive(
                mutations: [.bulkClear(scope: .unpinned, affectedCount: count)],
                outcome: .cleared(count: count), clearScope: .unpinned
            )
            #expect(unpinned.changeKind == .clearUnpinned)
            #expect(unpinned.affectedItems == .unpinned(retiredItems: count))
        }
        #expect(throws: StampingRejection.incoherentPlan) {
            try derive(
                mutations: [.bulkClear(scope: .all, affectedCount: 2)],
                outcome: .cleared(count: 3), clearScope: .all
            )
        }
        #expect(throws: StampingRejection.incoherentPlan) {
            try derive(
                mutations: [.bulkClear(scope: .all, affectedCount: 2)],
                outcome: .cleared(count: 2), clearScope: .unpinned
            )
        }
    }

    @Test("retention prefix carries the eviction key, exclusion and capture primary")
    func prefixPreservesMembershipAndPrimary() throws {
        let through = RetentionEvictionKey(lastCopiedAt: timestamp, itemID: third)
        let prefix = RetentionRetirementPrefix(
            through: through, excludedItemID: first,
            itemCount: 1_000_000, canonicalBytes: 1_000_000, revisionBytes: 0
        )
        let captured = try derive(
            mutations: [.retirePrefix(prefix), .create(storedItem(first))],
            outcome: .inserted(reference(first))
        )
        #expect(captured.changeKind == .insert)
        #expect(captured.affectedItems == .unpinnedPrefix(
            through: through, excluding: first, retiredItems: 1_000_000, primaryItemID: first
        ))
        let policyPrefix = RetentionRetirementPrefix(
            through: through, excludedItemID: nil,
            itemCount: 1_000_000, canonicalBytes: 1_000_000, revisionBytes: 0
        )
        let retired = try derive(
            mutations: [.setRetentionPolicy(maximumUnpinnedItems: 1), .retirePrefix(policyPrefix)],
            outcome: .retentionPolicySet(removedCount: 1_000_000)
        )
        #expect(retired.changeKind == .retire)
        #expect(retired.affectedItems == .unpinnedPrefix(
            through: through, excluding: nil, retiredItems: 1_000_000, primaryItemID: nil
        ))
    }

    @Test("bulk affected payload size is independent of membership and prune counts")
    func scopePayloadSizeIsConstant() throws {
        let through = RetentionEvictionKey(lastCopiedAt: timestamp, itemID: third)
        let cases: [(HistoryChangeKindRawV1, HistoryAffectedItems, HistoryAffectedItems)] = [
            (HistoryChangeKindRawV1.clearAll,
             HistoryAffectedItems.all(retiredItems: 1), .all(retiredItems: 1_000_000)),
            (.clearUnpinned, .unpinned(retiredItems: 1), .unpinned(retiredItems: 1_000_000)),
            (.insert,
             .unpinnedPrefix(through: through, excluding: first, retiredItems: 1, primaryItemID: first),
             .unpinnedPrefix(through: through, excluding: first, retiredItems: 1_000_000, primaryItemID: first)),
            (.retire, .retention(retiredItems: 1, prunedRevisions: 1),
             .retention(retiredItems: 1_000_000, prunedRevisions: 1_000_000)),
        ]
        for (kind, small, large) in cases {
            let smallBlob = try AffectedItemsBlobCodec.encode(small, for: kind)
            let largeBlob = try AffectedItemsBlobCodec.encode(large, for: kind)
            #expect(largeBlob.count == smallBlob.count)
            #expect(largeBlob.count <= 69)
            #expect(try AffectedItemsBlobCodec.decode(largeBlob, for: kind) == large)
        }
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

    private func storedItem(_ id: HistoryItemID) throws -> StoredNewItem {
        StoredNewItem(
            id: id,
            contentVersion: ContentVersion(rawValue: 1),
            canonical: try CanonicalContent(representations: [CanonicalRepresentation(
                content: ContentRepresentation(typeIdentifier: "public.text", bytes: Data([1])),
                fingerprint: ContentFingerprint(rawValue: 1)
            )]),
            projection: projection,
            occurrence: occurrence
        )
    }

    private func revisionUpdate(_ id: HistoryItemID) -> StoredRevisionUpdate {
        StoredRevisionUpdate(
            itemID: id,
            expectedCurrentVersion: ContentVersion(rawValue: 1),
            nextVersion: ContentVersion(rawValue: 2),
            revision: ContentRevision(
                id: RevisionID(rawValue: id.rawValue),
                createdAt: timestamp,
                content: EffectiveContent(representations: [
                    ContentRepresentation(typeIdentifier: "public.text", bytes: Data([1])),
                ])
            ),
            removedRevisionIDs: [],
            projection: projection,
            effectiveMatchesCanonical: false,
            retainedRevisionScalars: RetainedRevisionScalars(count: 1, bytes: 1)
        )
    }

    private var projection: ContentProjection {
        ContentProjection(
            title: "title",
            searchBody: "body",
            effectiveTypeIdentifiers: ["public.text"]
        )
    }

    private func prune(_ id: HistoryItemID) -> StampedMutation {
        .pruneRevisions(
            itemID: id,
            removedRevisionIDs: [RevisionID(rawValue: id.rawValue)],
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
