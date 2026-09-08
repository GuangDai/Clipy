/// Pure stamping from Domain mutations to typed SQL writes (05 §9; V2-09 §§4/6).
/// Payloads contain only newly introduced content; surviving revision bytes
/// are never loaded, copied, or re-encoded here. File I/O belongs to execution.
import Foundation
import HistoryCore
import HistoryDomain

/// Mechanical Domain rename; each payload explicitly describes its write.
internal enum StampedMutation: Sendable {
    case create(StoredNewItem)

    case updateOccurrence(
        itemID: HistoryItemID,
        occurrence: CopyOccurrence
    )

    case relocatePin(PinRelocation)

    case appendRevision(StoredRevisionUpdate)

    case delete(
        itemID: HistoryItemID,
        reason: RetirementReason
    )

    case bulkClear(scope: ClearScope, affectedCount: Int)
    case retirePrefix(RetentionRetirementPrefix)

    case setRetentionPolicy(maximumUnpinnedItems: Int?)

    case pruneRevisions(
        itemID: HistoryItemID,
        removedRevisionIDs: [RevisionID],
        retainedRevisionScalars: RetainedRevisionScalars
    )

    case setRetentionPolicies(
        policies: HistoryRetentionPolicies
    )
}

/// Canonical representations carry their existing xxh3 candidate facts;
/// SQL inserts those facts alongside each representation, with no index delta.
internal struct StoredNewItem: Sendable {
    internal let id: HistoryItemID
    internal let contentVersion: ContentVersion
    internal let canonical: CanonicalContent
    internal let projection: ContentProjection
    internal let occurrence: CopyOccurrence
}

/// Only the appended revision owns content bytes. Folded R3 removals are IDs;
/// all surviving contents keep their immutable SQL rows and file references.
internal struct StoredRevisionUpdate: Sendable {
    internal let itemID: HistoryItemID
    internal let expectedCurrentVersion: ContentVersion
    internal let nextVersion: ContentVersion
    internal let revision: ContentRevision
    internal let removedRevisionIDs: [RevisionID]
    internal let projection: ContentProjection
    internal let effectiveMatchesCanonical: Bool
    internal let retainedRevisionScalars: RetainedRevisionScalars
}

/// One HistoryCommit has one ChangePosition, one receipt and one HCR.
/// External audit provenance joins the same durable transaction (V2-03 §5).
internal struct StampedCommitPlan: Sendable {
    internal let position: ChangePosition
    internal let mutations: [StampedMutation]
    internal let receiptOutcome: HistoryCommitOutcome
    internal let hcrAppend: HistoryChangeRecordPayload
    internal let auditAppend: OperationRecordPayload?
    internal let hasDestructiveRetentionEffects: Bool

    internal init(
        position: ChangePosition,
        mutations: [StampedMutation],
        receiptOutcome: HistoryCommitOutcome,
        hcrAppend: HistoryChangeRecordPayload,
        auditAppend: OperationRecordPayload? = nil,
        hasDestructiveRetentionEffects: Bool = false
    ) {
        self.position = position
        self.mutations = mutations
        self.receiptOutcome = receiptOutcome
        self.hcrAppend = hcrAppend
        self.auditAppend = auditAppend
        self.hasDestructiveRetentionEffects = hasDestructiveRetentionEffects
    }

    /// Adds successful external provenance without changing any History fact.
    internal func attachingAuditAppend(
        _ payload: OperationRecordPayload
    ) throws -> Self {
        guard auditAppend == nil,
              payload.outcome == .succeeded,
              payload.changePosition == position else {
            throw StampingRejection.incoherentPlan
        }
        return Self(
            position: position,
            mutations: mutations,
            receiptOutcome: receiptOutcome,
            hcrAppend: hcrAppend,
            auditAppend: payload,
            hasDestructiveRetentionEffects: hasDestructiveRetentionEffects
        )
    }

    /// Only user pin mutations/removal/clear can change the pinned lane (D12).
    internal var requiresFinalPinOrderValidation: Bool {
        mutations.contains { mutation in
            switch mutation {
            case .relocatePin:
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
            case .pruneRevisions, .setRetentionPolicies, .bulkClear, .retirePrefix:
                return false
            }
        }
    }
}

/// Metadata-only pre-prune facts; active revision protection is D23.
internal struct PruneLineage: Sendable {
    internal let revisions: [RevisionRetentionSummary]
    internal let activeRevisionID: RevisionID?
}

/// Preparation contributes projections; SQL loading contributes current
/// versions and revision byte summaries, never historical representation bytes.
internal enum StampingInputs: Sendable {
    case capture(
        projection: ContentProjection,
        coalescedWinnerVersion: ContentVersion?
    )

    case revision(
        currentVersion: ContentVersion,
        existingRevisions: [RevisionRetentionSummary],
        projection: ContentProjection,
        effectiveMatchesCanonical: Bool
    )

    case prune(itemID: HistoryItemID, lineage: PruneLineage)

    case none
}

internal enum StampingRejection: Error, Sendable, Equatable {
    case missingStampingInputs

    case incoherentPlan

    case changePositionExhausted

    case contentVersionExhausted(itemID: HistoryItemID)
}

extension StampingRejection {
    internal var historyFailure: HistoryFailure {
        switch self {
        case .missingStampingInputs, .incoherentPlan:
            return .persistence(.invariantViolation)
        case .changePositionExhausted, .contentVersionExhausted:
            return .capacityExceeded(.coherenceToken)
        }
    }
}

/// Checked token successors and mechanical plan translation (02 §7/§13).
internal enum CommitPlanStamper {
    internal static func stamp(
        _ plan: MutationPlan,
        currentPosition: ChangePosition,
        inputs: StampingInputs,
        createdAt: Date,
        clearScope: ClearScope? = nil
    ) throws -> StampedCommitPlan {
        guard !plan.mutations.isEmpty else {
            throw StampingRejection.incoherentPlan
        }
        guard let position = currentPosition.successor() else {
            throw StampingRejection.changePositionExhausted
        }

        var mutations: [StampedMutation] = []
        mutations.reserveCapacity(plan.mutations.count)
        var createdItemIDs = Set<HistoryItemID>()
        var revisedNextVersion: ContentVersion?
        var appendedRevisionItemIDs = Set<HistoryItemID>()
        var retiredItemIDs = Set<HistoryItemID>()
        var prunedItemIDs = Set<HistoryItemID>()
        var pruneIDsByItem: [HistoryItemID: [RevisionID]] = [:]
        for mutation in plan.mutations {
            if case .appendRevision(let itemID, _, _) = mutation {
                appendedRevisionItemIDs.insert(itemID)
            }
            if case .pruneRevisions(let itemID, let removedRevisionIDs) = mutation {
                guard pruneIDsByItem[itemID] == nil else {
                    throw StampingRejection.incoherentPlan
                }
                pruneIDsByItem[itemID] = removedRevisionIDs
            }
        }
        for mutation in plan.mutations {
            switch mutation {
            case .create(let item):
                guard case .capture(let projection, _) = inputs else {
                    throw StampingRejection.missingStampingInputs
                }
                let stored = prepareNewItem(
                    id: item.id,
                    canonical: item.canonical,
                    projection: projection,
                    occurrence: item.occurrence
                )
                mutations.append(.create(stored))
                createdItemIDs.insert(item.id)

            case .recordCopy(let itemID, let occurrence):
                mutations.append(.updateOccurrence(
                    itemID: itemID,
                    occurrence: occurrence
                ))

            case .relocatePin(let relocation):
                mutations.append(.relocatePin(relocation))

            case .appendRevision(let itemID, let revision, let activeRevisionID):
                guard case .revision(
                    let currentVersion,
                    let existingRevisions,
                    let projection,
                    let effectiveMatchesCanonical
                ) = inputs else {
                    throw StampingRejection.missingStampingInputs
                }
                guard activeRevisionID == revision.id else {
                    throw StampingRejection.incoherentPlan
                }
                guard let nextVersion = currentVersion.successor() else {
                    throw StampingRejection.contentVersionExhausted(itemID: itemID)
                }
                let composedRevisions: [RevisionRetentionSummary]
                if let removedRevisionIDs = pruneIDsByItem[itemID] {
                    guard !removedRevisionIDs.isEmpty else {
                        throw StampingRejection.incoherentPlan
                    }
                    guard !removedRevisionIDs.contains(activeRevisionID) else {
                        throw StampingRejection.incoherentPlan
                    }
                    let removedIDs = Set(removedRevisionIDs)
                    guard removedIDs.count == removedRevisionIDs.count else {
                        throw StampingRejection.incoherentPlan
                    }
                    let survivors = existingRevisions.filter {
                        !removedIDs.contains($0.id)
                    }
                    guard survivors.count
                        == existingRevisions.count - removedIDs.count else {
                        throw StampingRejection.incoherentPlan
                    }
                    composedRevisions = survivors
                } else {
                    composedRevisions = existingRevisions
                }
                revisedNextVersion = nextVersion
                mutations.append(.appendRevision(StoredRevisionUpdate(
                    itemID: itemID,
                    expectedCurrentVersion: currentVersion,
                    nextVersion: nextVersion,
                    revision: revision,
                    removedRevisionIDs: pruneIDsByItem[itemID] ?? [],
                    projection: projection,
                    effectiveMatchesCanonical: effectiveMatchesCanonical,
                    retainedRevisionScalars: RetainedRevisionScalars(
                        count: composedRevisions.count + 1,
                        bytes: composedRevisions.reduce(0) { $0 + $1.byteCount }
                            + revision.content.representations.reduce(0) { $0 + $1.bytes.count }
                    )
                )))

            case .retire(let itemID, let reason):
                retiredItemIDs.insert(itemID)
                mutations.append(.delete(itemID: itemID, reason: reason))

            case .bulkClear(let scope, let affectedCount):
                mutations.append(.bulkClear(scope: scope, affectedCount: affectedCount))

            case .retirePrefix(let prefix):
                mutations.append(.retirePrefix(prefix))

            case .setRetentionPolicy(let maximumUnpinnedItems):
                mutations.append(.setRetentionPolicy(
                    maximumUnpinnedItems: maximumUnpinnedItems
                ))

            case .pruneRevisions(let itemID, let removedRevisionIDs):
                // Fold regardless of the explicit Domain mutations' order.
                guard !appendedRevisionItemIDs.contains(itemID) else { continue }
                guard case .prune(let suppliedItemID, let lineage) = inputs,
                      suppliedItemID == itemID else {
                    throw StampingRejection.missingStampingInputs
                }
                let removed = Set(removedRevisionIDs)
                guard !removed.isEmpty, removed.count == removedRevisionIDs.count,
                      let activeRevisionID = lineage.activeRevisionID,
                      !removed.contains(activeRevisionID) else {
                    throw StampingRejection.incoherentPlan
                }
                let survivors = lineage.revisions.filter { !removed.contains($0.id) }
                guard survivors.count == lineage.revisions.count - removed.count,
                      survivors.contains(where: { $0.id == activeRevisionID }) else {
                    throw StampingRejection.incoherentPlan
                }
                mutations.append(.pruneRevisions(
                    itemID: itemID,
                    removedRevisionIDs: removedRevisionIDs,
                    retainedRevisionScalars: RetainedRevisionScalars(
                        count: survivors.count,
                        bytes: survivors.reduce(0) { $0 + $1.byteCount }
                    )
                ))
                prunedItemIDs.insert(itemID)

            case .setRetentionPolicies(let policies):
                mutations.append(.setRetentionPolicies(policies: policies))
            }
        }

        guard createdItemIDs.isDisjoint(with: retiredItemIDs) else {
            throw StampingRejection.incoherentPlan
        }

        guard prunedItemIDs.isDisjoint(with: appendedRevisionItemIDs),
              prunedItemIDs.isDisjoint(with: retiredItemIDs)
        else {
            throw StampingRejection.incoherentPlan
        }

        let stampedReceiptOutcome = try receiptOutcome(
            for: plan.outcome,
            inputs: inputs,
            revisedNextVersion: revisedNextVersion
        )
        let hcrAppend = try HistoryChangeRecordPayload.derive(
            position: position,
            mutations: mutations,
            receiptOutcome: stampedReceiptOutcome,
            clearScope: clearScope,
            createdAt: createdAt
        )
        return StampedCommitPlan(
            position: position,
            mutations: mutations,
            receiptOutcome: stampedReceiptOutcome,
            hcrAppend: hcrAppend,
            hasDestructiveRetentionEffects: plan.mutations.contains { mutation in
                switch mutation {
                case .retire(_, .retention), .retirePrefix, .pruneRevisions:
                    return true
                case .create,
                     .recordCopy,
                     .relocatePin,
                     .appendRevision,
                     .retire,
                     .bulkClear,
                     .setRetentionPolicy,
                     .setRetentionPolicies:
                    return false
                }
            }
        )
    }

    /// A typed value construction, with no encoding or content duplication.
    internal static func prepareNewItem(
        id: HistoryItemID,
        canonical: CanonicalContent,
        projection: ContentProjection,
        occurrence: CopyOccurrence
    ) -> StoredNewItem {
        StoredNewItem(
            id: id,
            contentVersion: .initial,
            canonical: canonical,
            projection: projection,
            occurrence: occurrence
        )
    }

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
            return .retentionPoliciesSet(
                retiredItems: retiredItems,
                prunedRevisions: prunedRevisions
            )
        }
    }

}
