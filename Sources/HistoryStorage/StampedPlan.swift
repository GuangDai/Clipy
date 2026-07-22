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
/// (§9; docs/02-domain.md §14 D18).
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
    internal let occurrence: CopyOccurrence
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
    ///   (revise).
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

        for mutation in plan.mutations {
            switch mutation {
            case .create(let item):
                guard case .capture(let projection, _) = inputs else {
                    throw StampingRejection.missingStampingInputs
                }
                let entries = signatureEntries(of: item.canonical)
                mutations.append(.create(StoredNewItem(
                    id: item.id,
                    contentVersion: .initial,
                    canonicalBlob: try CanonicalBlobCodec.encode(item.canonical),
                    revisionStateBlob: try RevisionStateBlobCodec.encode(
                        revisions: [],
                        activeRevisionID: nil
                    ),
                    canonicalSignatureBlob: try SignatureBlobCodec.encode(entries),
                    projection: projection,
                    occurrence: item.occurrence
                )))
                additions[item.id] = entries

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
                    revisions: existingRevisions + [revision],
                    activeRevisionID: activeRevisionID
                )
                revisedNextVersion = nextVersion
                mutations.append(.appendRevision(StoredRevisionUpdate(
                    itemID: itemID,
                    expectedCurrentVersion: currentVersion,
                    nextVersion: nextVersion,
                    revisionStateBlob: revisionStateBlob,
                    projection: projection
                )))

            case .retire(let itemID, let reason):
                removals.insert(itemID)
                mutations.append(.delete(itemID: itemID, reason: reason))

            case .setRetentionPolicy(let maximumUnpinnedItems):
                mutations.append(.setRetentionPolicy(
                    maximumUnpinnedItems: maximumUnpinnedItems
                ))
            }
        }

        // Plan invariant 7 (docs/02-domain.md §7): the primary created item is
        // never retired in the same plan, so delta additions and removals
        // cannot intersect.
        guard additions.keys.allSatisfy({ !removals.contains($0) }) else {
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
