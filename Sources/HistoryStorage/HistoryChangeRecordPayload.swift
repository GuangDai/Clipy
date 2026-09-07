/// Internal HCR-only semantic vocabulary and pure payload derivation.
/// Owning spec: `V2-03` §4.2/§5.2 and the X-HCR controlling amendment.
import Foundation
import HistoryCore
import HistoryDomain

/// Stable raw classification stored in `HistoryChangeRecordRow.changeKindRaw`.
/// This prerequisite remains internal until the reconnect contract is
/// separately admitted.
internal enum HistoryChangeKindRawV1: Int16, Sendable, Equatable {
    case insert = 1
    case coalesce = 2
    case pin = 3
    case unpin = 4
    case remove = 5
    case clearAll = 6
    case clearUnpinned = 7
    case revise = 8
    case retire = 9
    case policySet = 10
    case retireRevision = 11
}

/// Exact membership for bounded changes and bulk predicates. `retention` is
/// deliberately conservative: it covers the whole pre-commit History, while
/// its counts report only actual retirements and revision prunes (V2-03 §4.4).
internal enum HistoryAffectedItems: Sendable, Equatable {
    case explicit([HistoryItemID])
    case all(retiredItems: Int)
    case unpinned(retiredItems: Int)
    case unpinnedPrefix(through: RetentionEvictionKey, excluding: HistoryItemID?,
                        retiredItems: Int, primaryItemID: HistoryItemID?)
    case retention(retiredItems: Int, prunedRevisions: Int)
}

/// The complete immutable input for one same-transaction HCR append.
internal struct HistoryChangeRecordPayload: Sendable, Equatable {
    internal let sequence: UInt64
    internal let changePositionRaw: UInt64
    internal let changeKind: HistoryChangeKindRawV1
    internal let affectedItems: HistoryAffectedItems
    internal let createdAt: Date

    /// Derives one record from the explicit stamped plan. The outcome selects
    /// the primary mutation; mutation payloads spell its kind. Clear alone
    /// needs the originating action scope because `.delete(.clear)` is
    /// intentionally scope-less.
    internal static func derive(
        position: ChangePosition,
        mutations: [StampedMutation],
        receiptOutcome: HistoryCommitOutcome,
        clearScope: ClearScope?,
        createdAt: Date,
        limits: JournalLimits = .standard
    ) throws -> HistoryChangeRecordPayload {
        guard !mutations.isEmpty else {
            throw StampingRejection.incoherentPlan
        }

        let changeKind = try primaryChangeKind(
            mutations: mutations,
            receiptOutcome: receiptOutcome,
            clearScope: clearScope
        )
        let affectedItems: HistoryAffectedItems
        switch changeKind {
        case .clearAll, .clearUnpinned:
            guard case .cleared(let count) = receiptOutcome else {
                throw StampingRejection.incoherentPlan
            }
            affectedItems = changeKind == .clearAll
                ? .all(retiredItems: count) : .unpinned(retiredItems: count)
        case .policySet:
            affectedItems = .explicit([])
        case .insert,
             .coalesce,
             .pin,
             .unpin,
             .remove,
             .revise,
             .retire,
             .retireRevision:
            if let prefix = try retirementPrefix(in: mutations) {
                let primary: HistoryItemID?
                switch receiptOutcome {
                case .inserted(let reference), .coalesced(let reference), .revised(let reference):
                    primary = reference.id
                default:
                    primary = nil
                }
                // A prefix plus unrelated explicit changes cannot claim to
                // describe complete membership. Only the protected primary
                // and policy changes may accompany this compact predicate.
                let explicit = try sortedUniqueAffectedItemIDs(
                    mutations.filter { if case .retirePrefix = $0 { return false }; return true },
                    limits: limits
                )
                guard explicit == (primary.map({ [$0] }) ?? []) else {
                    throw StampingRejection.incoherentPlan
                }
                affectedItems = .unpinnedPrefix(through: prefix.through,
                    excluding: prefix.excludedItemID, retiredItems: prefix.itemCount,
                    primaryItemID: primary)
            } else {
                affectedItems = .explicit(try sortedUniqueAffectedItemIDs(mutations, limits: limits))
            }
        }

        do {
            try AffectedItemsBlobCodec.validate(affectedItems, for: changeKind, limits: limits)
        } catch {
            throw StampingRejection.incoherentPlan
        }

        return HistoryChangeRecordPayload(
            sequence: position.rawValue,
            changePositionRaw: position.rawValue,
            changeKind: changeKind,
            affectedItems: affectedItems,
            createdAt: createdAt
        )
    }

    private static func primaryChangeKind(
        mutations: [StampedMutation],
        receiptOutcome: HistoryCommitOutcome,
        clearScope: ClearScope?
    ) throws -> HistoryChangeKindRawV1 {
        switch receiptOutcome {
        case .inserted(let reference):
            guard clearScope == nil,
                  containsCreate(reference.id, in: mutations) else {
                throw StampingRejection.incoherentPlan
            }
            return .insert

        case .coalesced(let reference):
            guard clearScope == nil,
                  containsOccurrenceUpdate(reference.id, in: mutations) else {
                throw StampingRejection.incoherentPlan
            }
            return .coalesce

        case .placedPinned(let itemID):
            guard clearScope == nil,
                  containsPin(itemID, pinned: true, in: mutations) else {
                throw StampingRejection.incoherentPlan
            }
            return .pin

        case .unpinned(let itemID):
            guard clearScope == nil,
                  containsPin(itemID, pinned: false, in: mutations) else {
                throw StampingRejection.incoherentPlan
            }
            return .unpin

        case .removed:
            guard clearScope == nil,
                  containsRetirement(.userRemoval, in: mutations) else {
                throw StampingRejection.incoherentPlan
            }
            return .remove

        case .cleared(let count):
            guard let clearScope,
                  count > 0,
                  mutations.allSatisfy({ mutation in
                      if case .delete(_, .clear) = mutation { return true }
                      if case .bulkClear(let scope, let affectedCount) = mutation {
                          return mutations.count == 1 && scope == clearScope && affectedCount == count
                      }
                      return false
                  }) else {
                throw StampingRejection.incoherentPlan
            }
            if case .delete = mutations[0] {
                let ids = try sortedUniqueAffectedItemIDs(mutations, limits: .standard)
                guard ids.count == count, mutations.count == count else {
                    throw StampingRejection.incoherentPlan
                }
            }
            switch clearScope {
            case .all:
                return .clearAll
            case .unpinned:
                return .clearUnpinned
            }

        case .revised(let reference):
            guard clearScope == nil,
                  containsRevisionAppend(reference.id, in: mutations) else {
                throw StampingRejection.incoherentPlan
            }
            return .revise

        case .retentionPolicySet:
            guard clearScope == nil else {
                throw StampingRejection.incoherentPlan
            }
            if containsRetirement(.retention, in: mutations) {
                return .retire
            }
            guard mutations.contains(where: { mutation in
                if case .setRetentionPolicy(_) = mutation { return true }
                return false
            }) else {
                throw StampingRejection.incoherentPlan
            }
            return .policySet

        case .retentionPoliciesSet:
            guard clearScope == nil else {
                throw StampingRejection.incoherentPlan
            }
            if containsRetirement(.retention, in: mutations) {
                return .retire
            }
            if mutations.contains(where: { mutation in
                if case .pruneRevisions(_, _, _) = mutation { return true }
                return false
            }) {
                return .retireRevision
            }
            guard mutations.contains(where: { mutation in
                if case .setRetentionPolicies(_) = mutation { return true }
                return false
            }) else {
                throw StampingRejection.incoherentPlan
            }
            return .policySet
        }
    }

    private static func sortedUniqueAffectedItemIDs(
        _ mutations: [StampedMutation],
        limits: JournalLimits
    ) throws -> [HistoryItemID] {
        var itemIDs: [HistoryItemID] = []
        itemIDs.reserveCapacity(mutations.count)
        for mutation in mutations {
            switch mutation {
            case .create(let item):
                itemIDs.append(item.id)
            case .updateOccurrence(let itemID, _),
                 .setPinOrdinal(let itemID, _),
                 .delete(let itemID, _),
                 .pruneRevisions(let itemID, _, _):
                itemIDs.append(itemID)
            case .appendRevision(let update):
                itemIDs.append(update.itemID)
            case .setRetentionPolicy, .setRetentionPolicies:
                break
            case .bulkClear, .retirePrefix:
                throw StampingRejection.incoherentPlan
            }
        }
        // `HistoryItemID.<` is the literal UUID-byte ordering. Adjacent
        // deduplication after that sort needs no hash-derived state.
        itemIDs.sort()

        var unique: [HistoryItemID] = []
        unique.reserveCapacity(itemIDs.count)
        for itemID in itemIDs where unique.last != itemID {
            unique.append(itemID)
        }
        // X-HCR admits the full 5,001-ID constructive maximum and fails an
        // impossible excess; affected identities are never truncated.
        guard unique.count <= limits.maxAffectedItemsPerRecord else {
            throw StampingRejection.incoherentPlan
        }
        return unique
    }

    private static func containsCreate(
        _ itemID: HistoryItemID,
        in mutations: [StampedMutation]
    ) -> Bool {
        mutations.contains { mutation in
            if case .create(let item) = mutation { return item.id == itemID }
            return false
        }
    }

    private static func containsOccurrenceUpdate(
        _ itemID: HistoryItemID,
        in mutations: [StampedMutation]
    ) -> Bool {
        mutations.contains { mutation in
            if case .updateOccurrence(let found, _) = mutation {
                return found == itemID
            }
            return false
        }
    }

    private static func containsPin(
        _ itemID: HistoryItemID,
        pinned: Bool,
        in mutations: [StampedMutation]
    ) -> Bool {
        mutations.contains { mutation in
            guard case .setPinOrdinal(let found, let ordinal) = mutation,
                  found == itemID else { return false }
            return (ordinal != nil) == pinned
        }
    }

    private static func containsRevisionAppend(
        _ itemID: HistoryItemID,
        in mutations: [StampedMutation]
    ) -> Bool {
        mutations.contains { mutation in
            if case .appendRevision(let update) = mutation {
                return update.itemID == itemID
            }
            return false
        }
    }

    private static func containsRetirement(
        _ reason: RetirementReason,
        in mutations: [StampedMutation]
    ) -> Bool {
        mutations.contains { mutation in
            if case .retirePrefix = mutation, case .retention = reason { return true }
            guard case .delete(_, let found) = mutation else { return false }
            switch (reason, found) {
            case (.userRemoval, .userRemoval),
                 (.clear, .clear),
                 (.retention, .retention):
                return true
            case (.userRemoval, .clear),
                 (.userRemoval, .retention),
                 (.clear, .userRemoval),
                 (.clear, .retention),
                 (.retention, .userRemoval),
                 (.retention, .clear):
                return false
            }
        }
    }

    private static func retirementPrefix(in mutations: [StampedMutation]) throws -> RetentionRetirementPrefix? {
        var result: RetentionRetirementPrefix?
        for mutation in mutations {
            if case .retirePrefix(let prefix) = mutation {
                guard result == nil else { throw StampingRejection.incoherentPlan }
                result = prefix
            }
        }
        return result
    }
}
