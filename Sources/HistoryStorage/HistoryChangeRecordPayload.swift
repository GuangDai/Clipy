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

/// The complete immutable input for one same-transaction HCR append.
internal struct HistoryChangeRecordPayload: Sendable, Equatable {
    internal let sequence: UInt64
    internal let changePositionRaw: UInt64
    internal let changeKind: HistoryChangeKindRawV1
    internal let affectedItemIDs: [HistoryItemID]
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
        let affectedItemIDs: [HistoryItemID]
        switch changeKind {
        case .clearAll, .clearUnpinned, .policySet:
            affectedItemIDs = []
        case .insert,
             .coalesce,
             .pin,
             .unpin,
             .remove,
             .revise,
             .retire,
             .retireRevision:
            affectedItemIDs = try sortedUniqueAffectedItemIDs(
                mutations,
                limits: limits
            )
        }

        return HistoryChangeRecordPayload(
            sequence: position.rawValue,
            changePositionRaw: position.rawValue,
            changeKind: changeKind,
            affectedItemIDs: affectedItemIDs,
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

        case .cleared:
            guard let clearScope,
                  mutations.allSatisfy({ mutation in
                      if case .delete(_, .clear) = mutation { return true }
                      return false
                  }) else {
                throw StampingRejection.incoherentPlan
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
}
