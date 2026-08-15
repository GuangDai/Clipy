/// StampedPlan.swift — the storage-internal stamped mutations carrying
/// absolute row values, and the pure stamping function that mechanically
/// renames a Domain `MutationPlan` into a `StampedCommitPlan`, minting the
/// Content Version / Change Position successors the Domain never mints
/// (docs/02-domain.md §4, §13).
/// Owning spec: docs/05-authority-kernel.md §9 (from Domain plan to stamped
/// commit plan); stamping contract: docs/02-domain.md §7 (plan invariants)
/// and §13 (Content Version and Change Position effects); failure mapping:
/// docs/05-authority-kernel.md §16.
import Foundation
import HistoryCore
import HistoryDomain

// MARK: - Stamped mutations (docs/05-authority-kernel.md §9)

/// One storage-internal mutation carrying absolute row values.
/// docs/05-authority-kernel.md §9
///
/// Each Domain `HistoryMutation` maps to exactly one `StampedMutation`; the
/// rename is fixed and mechanical (§9 rename table): `.create` → `.create`,
/// `.recordCopy` → `.updateOccurrence`, `.assignPin` → `.setPinOrdinal`,
/// `.appendRevision` → `.appendRevision`, `.retire` → `.delete`,
/// `.setRetentionPolicy` → `.setRetentionPolicy`. The Authority never decides
/// after planning that a case "means" anything beyond its explicit payload
/// (§9; docs/02-domain.md §14 D18). The two V2-02 rows are additive
/// (`V2-02` §5.3/§5.6/§6.3): `.pruneRevisions` → `.pruneRevisions` (the
/// per-case row applies only when no `.appendRevision` shares the item — the
/// compose-with-append rule folds the prune into the append's single blob
/// write — and the composer drops it for items R2 retires,
/// retire-subsumes-prune), and `.setRetentionPolicy`'s V2 analog writes the
/// `RetentionExpansionConfigRow` singleton.
internal enum StampedMutation: Sendable {
    /// Insert one new row with the complete stamped payload.
    /// docs/05-authority-kernel.md §9
    case create(StoredNewItem)

    /// Replace the row's occurrence columns with the folded value the Domain
    /// planner computed; the loaded Content Version and projections are
    /// preserved (docs/02-domain.md §13). Storage does not reconstruct the
    /// fold (docs/02-domain.md §7 invariant 3).
    /// docs/05-authority-kernel.md §9
    case updateOccurrence(
        itemID: HistoryItemID,
        occurrence: CopyOccurrence
    )

    /// Write the row's pin-ordinal column (`nil` is unpinned,
    /// docs/02-domain.md §3.2); the loaded Content Version and projections
    /// are preserved (docs/02-domain.md §13).
    /// docs/05-authority-kernel.md §9
    case setPinOrdinal(
        itemID: HistoryItemID,
        ordinal: Int?
    )

    /// Append the complete revision, store its active ID, write the prepared
    /// projection, and advance the Content Version.
    /// docs/05-authority-kernel.md §9
    case appendRevision(StoredRevisionUpdate)

    /// Remove the row and its Canonical signature postings (§11).
    /// docs/05-authority-kernel.md §9
    case delete(
        itemID: HistoryItemID,
        reason: RetirementReason
    )

    /// Write the new `maximumUnpinnedItems` to the singleton row; every
    /// item's Content Version and projections are preserved, and any victim
    /// `.delete` mutations are already explicit in the same plan
    /// (docs/02-domain.md §7, §13).
    /// docs/05-authority-kernel.md §9
    case setRetentionPolicy(maximumUnpinnedItems: Int)

    /// Rewrite the row's `revisionStateBlob` with the pruned
    /// `RevisionStateBlobV1` (`formatVersion == 1`, fewer revisions, same
    /// `activeRevisionID`); the item's Content Version, projections, and
    /// Signature Index postings are preserved (V2-02 §5.3/§5.2, D23). Carries
    /// no per-item version field: the protection is the serialized Authority
    /// interval plus the singleton position guard, exactly as
    /// `.setRetentionPolicy` (V2-02 §5.3). The `retainedRevisionScalars`
    /// payload is the post-prune revision summary stamped from the same
    /// survivor list the blob was encoded from, so the executor restamps the
    /// 1:1 `RetainedBytesRow` in the same transaction without a blob decode
    /// (V2-02 §6.3/§3.3b; roadmap R.3).
    case pruneRevisions(
        itemID: HistoryItemID,
        revisionStateBlob: Data,
        retainedRevisionScalars: RetainedRevisionScalars
    )

    /// Write the new V2 retention policies to the
    /// `RetentionExpansionConfigRow` singleton (normalized per §3.1's
    /// both-nil rule); every item's Content Version, rows, and projections
    /// are preserved (V2-02 §5.6). Carries no position field, mirroring v1
    /// `.setRetentionPolicy`: the plan-level singleton position guard
    /// suffices, and an unchecked position-looking payload would be the D18
    /// smell §5.6 rejects.
    case setRetentionPolicies(
        policies: HistoryRetentionPolicies
    )
}

/// The complete stamped payload of a `.create` mutation.
/// docs/05-authority-kernel.md §9
///
/// Stamping receives `ContentVersion.initial`, the prepared
/// Canonical/projection, an empty revision state (a Canonical-state item,
/// §3.1), the initial occurrence, and no pin (§9).
internal struct StoredNewItem: Sendable {
    internal let id: HistoryItemID
    internal let contentVersion: ContentVersion
    internal let canonicalBlob: Data
    internal let revisionStateBlob: Data
    internal let canonicalSignatureBlob: Data
    internal let projection: ContentProjection
    internal let effectiveTypeIdentifiersBlob: Data
    internal let occurrence: CopyOccurrence
}

/// The encoded row payload and its still-typed Signature Index entries.
///
/// Keeping these values together gives ordinary capture stamping and the
/// package-only performance-fixture seeder one encoding implementation. The
/// fixture path may batch physical writes, but it must not invent a second
/// Canonical/signature/projection wire format.
internal struct EncodedNewItem: Sendable {
    internal let stored: StoredNewItem
    internal let signatureEntries: [ContentSignatureEntry]
}

/// The complete stamped payload of an `.appendRevision` mutation.
/// docs/05-authority-kernel.md §9
///
/// `expectedCurrentVersion` is the reloaded item version the transaction
/// executor re-verifies before writing; `nextVersion` is its checked
/// successor (docs/02-domain.md §13). Revision state, Content Version, and
/// effective projections are written together (§10).
internal struct StoredRevisionUpdate: Sendable {
    internal let itemID: HistoryItemID
    internal let expectedCurrentVersion: ContentVersion
    internal let nextVersion: ContentVersion
    internal let revisionStateBlob: Data
    internal let projection: ContentProjection
    internal let effectiveTypeIdentifiersBlob: Data
    /// The post-append revision summary (`V2-02` §3.3b/§6.3), stamped from
    /// the same loaded-plus-appended revision list the blob was encoded
    /// from; the executor restamps the 1:1 `RetainedBytesRow` from it in the
    /// same transaction (roadmap R.3; R.5's compose-with-append will compute
    /// it over the post-prune post-append list, §6.3).
    internal let retainedRevisionScalars: RetainedRevisionScalars
}

/// The precomputed Signature Index effect of one plan.
/// docs/05-authority-kernel.md §9, §11
///
/// Deltas exist only for create and delete because Canonical Content never
/// changes: Copy Coalescing and revision leave Canonical signatures
/// untouched (§11). The delta is precomputed and checked before the
/// transaction so the post-commit dictionary application cannot fail (§11).
internal struct SignatureIndexDelta: Sendable {
    internal let additions: [HistoryItemID: [ContentSignatureEntry]]
    internal let removals: Set<HistoryItemID>
}

/// One plan ready for the atomic transaction: the single minted Change
/// Position, the ordered stamped mutations, the caller-visible receipt
/// outcome, and the precomputed Signature Index delta.
/// docs/05-authority-kernel.md §9
///
/// `ChangePosition` advances exactly once for the whole plan, never once per
/// mutation: the same checked successor of the current singleton position is
/// used for every mutation in the plan (docs/02-domain.md §13, D6).
internal struct StampedCommitPlan: Sendable {
    internal let position: ChangePosition
    internal let mutations: [StampedMutation]
    internal let receiptOutcome: HistoryCommitOutcome
    internal let indexDelta: SignatureIndexDelta

    /// Whether §10 must re-prove D12 before transaction success. Revision,
    /// occurrence, create, retention-only deletion, and policy mutations
    /// cannot change the pinned lane. User removal and clear stay
    /// conservative because their target/scope may include pinned rows. The
    /// V2-02 rows are lane-neutral for the same reason: an R3 prune
    /// rewrites only the revision-state blob of a surviving row (V2-02
    /// §5.5/§5.6), and the policy write touches no item row (§5.6).
    internal var requiresFinalPinOrderValidation: Bool {
        mutations.contains { mutation in
            switch mutation {
            case .setPinOrdinal:
                return true
            case .delete(_, let reason):
                switch reason {
                case .userRemoval, .clear:
                    return true
                case .retention:
                    return false
                }
            case .create, .updateOccurrence, .appendRevision, .setRetentionPolicy:
                return false
            case .pruneRevisions, .setRetentionPolicies:
                return false
            }
        }
    }
}

// MARK: - Stamping inputs (docs/05-authority-kernel.md §9)

/// The values stamping needs that the Domain plan intentionally does not
/// carry (docs/02-domain.md §7 invariant 10): the prepared projections and
/// the loaded Content Versions / revision lists tokens are stamped from.
/// docs/05-authority-kernel.md §9
internal enum StampingInputs: Sendable {
    /// Capture stamping inputs: the prepared capture projection (Part V §6.1,
    /// consumed only when the plan inserts — Copy Coalescing does not
    /// recompute content projection, §15) and the coalescing winner's loaded
    /// Content Version (non-nil exactly when the plan outcome is
    /// `.coalesced`; Copy Coalescing preserves it — docs/02-domain.md §13).
    case capture(
        projection: ContentProjection,
        coalescedWinnerVersion: ContentVersion?
    )

    /// Revision stamping inputs taken from the reloaded `RevisionFacts`
    /// (Part V §6.2): the item's current Content Version, its complete
    /// existing revision list, and the prepared revision projection.
    case revision(
        currentVersion: ContentVersion,
        existingRevisions: [ContentRevision],
        projection: ContentProjection
    )

    /// V2-02 §5.3/§6.3 prune-alone stamping inputs, taken from the pruned
    /// item's loaded revision lineage: the complete pre-prune list and its
    /// active Revision ID. The per-case `.pruneRevisions` stamped row
    /// applies only when no `.appendRevision` in the plan shares the item
    /// (§6.3 compose-with-append — the revise path folds its prune into the
    /// append's single blob write through `.revision` inputs, R.5); the
    /// production loader that supplies these inputs is the R.6
    /// `.setRetentionPolicies` sweep (`V2-roadmap` §6 R.6), so no production
    /// caller passes them until that slice lands — the arm itself is real
    /// from R.3 and unit-proven at this seam.
    case prune(
        revisions: [ContentRevision],
        activeRevisionID: RevisionID?
    )

    /// Pin, unpin, remove, clear, and retention plans stamp from the Domain
    /// payloads alone.
    case none
}

// MARK: - Stamping rejection vocabulary (docs/05-authority-kernel.md §16)

/// Rejection of a Domain plan at stamping time.
/// docs/05-authority-kernel.md §9, §16
///
/// Successor overflow is the only failure reachable from a well-formed plan;
/// the remaining cases are defensive backstops against an Authority/planner
/// contract violation and never trigger on a well-formed plan.
internal enum StampingRejection: Error, Sendable, Equatable {
    /// A mutation or outcome required stamping inputs the Authority did not
    /// supply (§9).
    case missingStampingInputs

    /// The plan violates a docs/02-domain.md §7 invariant the stamper
    /// re-guards defensively: an empty mutation list (invariant 1), an item
    /// both created and retired in one plan (invariant 7), a stored active
    /// Revision ID differing from the appended revision's ID (invariant 5),
    /// or a `.revised` outcome with no stamped revision.
    case incoherentPlan

    /// The singleton Change Position has no successor; checked arithmetic
    /// fails closed and never wraps (docs/02-domain.md §13).
    case changePositionExhausted

    /// The item's Content Version has no successor; checked arithmetic fails
    /// closed and never wraps (docs/02-domain.md §13).
    case contentVersionExhausted(itemID: HistoryItemID)
}

extension StampingRejection {
    /// The docs/05-authority-kernel.md §16 boundary mapping: a
    /// `ContentVersion` / `ChangePosition` successor overflow is
    /// `.capacityExceeded(.coherenceToken)`; a contract violation is a
    /// storage invariant failure.
    internal var historyFailure: HistoryFailure {
        switch self {
        case .missingStampingInputs, .incoherentPlan:
            return .persistence(.invariantViolation)
        case .changePositionExhausted, .contentVersionExhausted:
            return .capacityExceeded(.coherenceToken)
        }
    }
}

// MARK: - Stamping (docs/05-authority-kernel.md §9)

/// The pure stamping function: Domain `MutationPlan` plus minted tokens to
/// `StampedCommitPlan`, following the §9 rename table mechanically.
/// docs/05-authority-kernel.md §9
internal enum CommitPlanStamper {
    /// Stamps one Domain plan into a commit plan.
    /// docs/05-authority-kernel.md §9
    ///
    /// Fixed, mechanical behavior by semantic case (§9; docs/02-domain.md
    /// §13):
    ///
    /// - the whole plan receives exactly one checked `ChangePosition`
    ///   successor of `currentPosition`, minted here in Storage;
    /// - `.create` receives `ContentVersion.initial`, the encoded prepared
    ///   Canonical and signature blobs, an empty revision state, the
    ///   prepared projection, the initial occurrence, and no pin;
    /// - `.recordCopy` and `.assignPin` carry their folded occurrence /
    ///   ordinal payloads only — the loaded Content Version and projections
    ///   are preserved by absence from the stamped payload;
    /// - `.appendRevision` mints `currentVersion.successor()`, appends the
    ///   complete revision to the loaded list, stores its active ID, and
    ///   writes the prepared projection;
    /// - `.retire` removes the row and its Canonical signature postings;
    /// - `.setRetentionPolicy` writes the new value; victim `.retire`
    ///   mutations are already explicit in the plan;
    /// - the Signature Index delta covers creates (additions) and deletes
    ///   (removals) only (§11);
    /// - the receipt outcome is the mechanical Part III mapping of
    ///   `PlannedOutcome`, with references stamped `.initial` (insert), the
    ///   preserved winner version (coalesce), or the minted successor
    ///   (revise);
    /// - `.appendRevision` also stamps the post-append `RetainedRevisionScalars`
    ///   and `.pruneRevisions` (the per-case prune row) re-encodes the shorter
    ///   `RevisionStateBlobV1` from the loaded lineage plus its post-prune
    ///   scalars, so the executor restamps the 1:1 `RetainedBytesRow` in the
    ///   same transaction (`V2-02` §3.3b/§6.3; roadmap R.3). A plan whose
    ///   `.pruneRevisions` shares an item with an `.appendRevision` (the
    ///   compose-with-append shape) or with a `.retire` (the
    ///   retire-subsumes-prune shape) is rejected here: those compositions are
    ///   specified stamping-stage rules owned by R.5/R.6 (`V2-02` §6.3;
    ///   `RET-STAMP-1/2`), and rejecting the undecomposed plan guarantees the
    ///   executor never applies two blob writes to one item in one
    ///   transaction;
    /// - the one remaining V2-02 row (`.setRetentionPolicies`, `V2-02` §5.6)
    ///   defers to its owning roadmap slice R.6 (`V2-roadmap` §6) — its arm
    ///   below throws the internal `StepDeferredError` exactly as R.1's
    ///   `SwiftDataHistory.perform` arm does, so no half-composed policy plan
    ///   can be stamped before that slice lands.
    ///
    /// No pasteboard access, fingerprinting, or projection happens here; all
    /// blob encoding starts from validated Domain values (§4). A `.unchanged`
    /// planning result never reaches this function (§9 flow) — neither does
    /// a same-value no-victim retention set, which `planRetention` returns
    /// as `.unchanged` before stamping.
    ///
    /// - Throws: `StampingRejection` (mapped at the boundary by
    ///   `historyFailure`), or the codec `CodecRejection.encodingFailed`
    ///   backstop.
    internal static func stamp(
        _ plan: MutationPlan,
        currentPosition: ChangePosition,
        inputs: StampingInputs
    ) throws -> StampedCommitPlan {
        // Plan invariant 1 (docs/02-domain.md §7): a commit plan is non-empty.
        guard !plan.mutations.isEmpty else {
            throw StampingRejection.incoherentPlan
        }
        // docs/02-domain.md §13: ChangePosition advances exactly once for the
        // whole plan; the checked successor never wraps.
        guard let position = currentPosition.successor() else {
            throw StampingRejection.changePositionExhausted
        }

        var mutations: [StampedMutation] = []
        mutations.reserveCapacity(plan.mutations.count)
        var additions: [HistoryItemID: [ContentSignatureEntry]] = [:]
        var removals = Set<HistoryItemID>()
        var revisedNextVersion: ContentVersion?
        // V2-02 §6.3 composition guards (R.3): items receiving an
        // `.appendRevision`, a `.retire`, or a per-case `.pruneRevisions` in
        // this plan, so the post-loop check can reject an undecomposed prune
        // before any stamped write exists.
        var appendedRevisionItemIDs = Set<HistoryItemID>()
        var retiredItemIDs = Set<HistoryItemID>()
        var prunedItemIDs = Set<HistoryItemID>()

        for mutation in plan.mutations {
            switch mutation {
            case .create(let item):
                guard case .capture(let projection, _) = inputs else {
                    throw StampingRejection.missingStampingInputs
                }
                let encoded = try encodeNewItem(
                    id: item.id,
                    canonical: item.canonical,
                    projection: projection,
                    occurrence: item.occurrence
                )
                mutations.append(.create(encoded.stored))
                additions[item.id] = encoded.signatureEntries

            case .recordCopy(let itemID, let occurrence):
                mutations.append(.updateOccurrence(
                    itemID: itemID,
                    occurrence: occurrence
                ))

            case .assignPin(let itemID, let ordinal):
                mutations.append(.setPinOrdinal(
                    itemID: itemID,
                    ordinal: ordinal?.rawValue
                ))

            case .appendRevision(let itemID, let revision, let activeRevisionID):
                guard case .revision(
                    let currentVersion,
                    let existingRevisions,
                    let projection
                ) = inputs else {
                    throw StampingRejection.missingStampingInputs
                }
                // Plan invariant 5 (docs/02-domain.md §7): the stored active ID
                // is the appended revision's ID.
                guard activeRevisionID == revision.id else {
                    throw StampingRejection.incoherentPlan
                }
                guard let nextVersion = currentVersion.successor() else {
                    throw StampingRejection.contentVersionExhausted(itemID: itemID)
                }
                let revisionStateBlob = try RevisionStateBlobCodec.encode(
                    revisions: existingRevisions,
                    appending: revision,
                    activeRevisionID: activeRevisionID
                )
                revisedNextVersion = nextVersion
                appendedRevisionItemIDs.insert(itemID)
                mutations.append(.appendRevision(StoredRevisionUpdate(
                    itemID: itemID,
                    expectedCurrentVersion: currentVersion,
                    nextVersion: nextVersion,
                    revisionStateBlob: revisionStateBlob,
                    projection: projection,
                    effectiveTypeIdentifiersBlob: try EffectiveTypeIdentifiersBlobCodec
                        .encode(projection.effectiveTypeIdentifiers),
                    // V2-02 §3.3b/§6.3 (roadmap R.3): the post-append
                    // revision summary over the exact list the blob was
                    // encoded from — existing plus appended — so the
                    // executor's same-transaction restamp decodes nothing.
                    retainedRevisionScalars: RetainedBytesStamping.revisionScalars(
                        of: existingRevisions + [revision]
                    )
                )))

            case .retire(let itemID, let reason):
                removals.insert(itemID)
                retiredItemIDs.insert(itemID)
                mutations.append(.delete(itemID: itemID, reason: reason))

            case .setRetentionPolicy(let maximumUnpinnedItems):
                mutations.append(.setRetentionPolicy(
                    maximumUnpinnedItems: maximumUnpinnedItems
                ))

            case .pruneRevisions(let itemID, let removedRevisionIDs):
                // V2-02 §5.3/§6.3 stamping (roadmap R.3): re-encode the
                // shorter `RevisionStateBlobV1` from the loaded lineage —
                // survivors keep append order, `formatVersion == 1`, same
                // `activeRevisionID` — and stamp the post-prune revision
                // scalars so the executor's restamp decodes nothing. The
                // loaded lineage arrives through the `.prune` inputs; WHICH
                // revisions are removed is decided by
                // `planRevisionRetentionExpansion` (`V2-02` §5.1/§6.5),
                // composed by the owning slices R.5/R.6 — never here.
                guard case .prune(
                    let loadedRevisions,
                    let activeRevisionID
                ) = inputs else {
                    throw StampingRejection.missingStampingInputs
                }
                let pruned = try RetainedBytesStamping.prunedRevisionState(
                    loadedRevisions: loadedRevisions,
                    activeRevisionID: activeRevisionID,
                    removedRevisionIDs: removedRevisionIDs
                )
                mutations.append(.pruneRevisions(
                    itemID: itemID,
                    revisionStateBlob: pruned.revisionStateBlob,
                    retainedRevisionScalars: pruned.retainedRevisionScalars
                ))
                prunedItemIDs.insert(itemID)

            case .setRetentionPolicies:
                // V2-02 §5.6 stamping: append the
                // `.setRetentionPolicies(policies:)` row writing the
                // `RetentionExpansionConfigRow` singleton. Emitted only by
                // the R.6 policy-sweep commit (`V2-roadmap` §6), which also
                // owns the same-value/satisfied `.unchanged` decision that
                // precedes any plan carrying this mutation; deferred with it
                // so no half-composed policy plan can exist before R.6.
                throw StepDeferredError.notYetImplemented(
                    operation: "setRetentionPolicies stamping"
                )
            }
        }

        // Plan invariant 7 (docs/02-domain.md §7): the primary created item is
        // never retired in the same plan, so delta additions and removals
        // cannot intersect.
        guard additions.keys.allSatisfy({ !removals.contains($0) }) else {
            throw StampingRejection.incoherentPlan
        }

        // V2-02 §6.3 composition discipline (roadmap R.3 guard, R.5/R.6
        // composition): the per-case `.pruneRevisions` row applies only when
        // the plan contains no other stamped write for the same item. A plan
        // that revises AND prunes one item must arrive pre-composed as the
        // append's single folded blob write (compose-with-append,
        // `RET-STAMP-1`, R.5), and a plan that retires AND prunes one item
        // must have had the prune dropped by the composer
        // (retire-subsumes-prune, `RET-STAMP-2`, R.6) — otherwise the
        // executor would apply two `revisionStateBlob` writes to one item or
        // fetch a row the same transaction deleted (§10 row-existence rule).
        // Both shapes are rejected here until their owning slices land the
        // composition; no stamped write exists yet, so nothing half-applies.
        guard prunedItemIDs.isDisjoint(with: appendedRevisionItemIDs),
              prunedItemIDs.isDisjoint(with: retiredItemIDs)
        else {
            throw StampingRejection.incoherentPlan
        }

        return StampedCommitPlan(
            position: position,
            mutations: mutations,
            receiptOutcome: try receiptOutcome(
                for: plan.outcome,
                inputs: inputs,
                revisedNextVersion: revisedNextVersion
            ),
            indexDelta: SignatureIndexDelta(additions: additions, removals: removals)
        )
    }

    /// Encodes one validated Canonical-state item exactly as capture stamping
    /// does. The result intentionally retains typed signature entries beside
    /// their durable blob so an Authority-owned batch can update its in-memory
    /// Signature Index without decoding the bytes it just encoded.
    internal static func encodeNewItem(
        id: HistoryItemID,
        canonical: CanonicalContent,
        projection: ContentProjection,
        occurrence: CopyOccurrence
    ) throws -> EncodedNewItem {
        let entries = signatureEntries(of: canonical)
        return EncodedNewItem(
            stored: StoredNewItem(
                id: id,
                contentVersion: .initial,
                canonicalBlob: try CanonicalBlobCodec.encode(canonical),
                revisionStateBlob: try RevisionStateBlobCodec.encode(
                    revisions: [],
                    activeRevisionID: nil
                ),
                canonicalSignatureBlob: try SignatureBlobCodec.encode(entries),
                projection: projection,
                effectiveTypeIdentifiersBlob: try EffectiveTypeIdentifiersBlobCodec
                    .encode(projection.effectiveTypeIdentifiers),
                occurrence: occurrence
            ),
            signatureEntries: entries
        )
    }

    /// The mechanical `PlannedOutcome` → `HistoryCommitOutcome` mapping
    /// (docs/02-domain.md §7; Part III receipt vocabulary), stamping the
    /// reference versions the Domain deliberately did not carry.
    private static func receiptOutcome(
        for outcome: PlannedOutcome,
        inputs: StampingInputs,
        revisedNextVersion: ContentVersion?
    ) throws -> HistoryCommitOutcome {
        switch outcome {
        case .inserted(let itemID):
            return .inserted(HistoryItemReference(
                id: itemID,
                contentVersion: .initial
            ))
        case .coalesced(let itemID):
            // Copy Coalescing preserves the winner's loaded Content Version
            // (docs/02-domain.md §13); the reference names that exact state.
            guard case .capture(_, let winnerVersion) = inputs,
                  let winnerVersion
            else {
                throw StampingRejection.missingStampingInputs
            }
            return .coalesced(HistoryItemReference(
                id: itemID,
                contentVersion: winnerVersion
            ))
        case .placedPinned(let itemID):
            return .placedPinned(itemID)
        case .unpinned(let itemID):
            return .unpinned(itemID)
        case .removed(let count):
            return .removed(count: count)
        case .cleared(let count):
            return .cleared(count: count)
        case .revised(let itemID):
            guard let nextVersion = revisedNextVersion else {
                throw StampingRejection.incoherentPlan
            }
            return .revised(HistoryItemReference(
                id: itemID,
                contentVersion: nextVersion
            ))
        case .retentionPolicySet(let removedCount):
            return .retentionPolicySet(removedCount: removedCount)
        case .retentionPoliciesSet(let retiredItems, let prunedRevisions):
            // V2-02 §8.1: the mechanical mapping — `retiredItems` counts
            // R1/R2 item retirements, `prunedRevisions` counts R3 revisions
            // pruned for surviving (non-retired) items (§6.3
            // retire-subsumes-prune; `RET-STAMP-2`). Metadata-only like its
            // v1 analog: no reference state is minted.
            return .retentionPoliciesSet(
                retiredItems: retiredItems,
                prunedRevisions: prunedRevisions
            )
        }
    }

    /// Signature entries derived one-to-one from Canonical representations in
    /// their normalized order (Part V §6.1 step 6, §12).
    private static func signatureEntries(
        of canonical: CanonicalContent
    ) -> [ContentSignatureEntry] {
        canonical.representations.map { representation in
            ContentSignatureEntry(
                typeIdentifier: representation.content.typeIdentifier,
                fingerprint: representation.fingerprint,
                byteCount: representation.content.bytes.count
            )
        }
    }
}
