/// Compact retention planning over complete, oldest-first scalar facts.
/// SQL owns iteration; Domain owns selection. One value carries the selected
/// prefix, never its member IDs (02 §12; V2-02 §4.1–§4.4).
import Foundation
import HistoryCore

package struct RetentionEvictionKey: Sendable, Hashable, Comparable {
    package let lastCopiedAt: Date
    package let itemID: HistoryItemID

    package init(lastCopiedAt: Date, itemID: HistoryItemID) {
        self.lastCopiedAt = lastCopiedAt
        self.itemID = itemID
    }

    package static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.lastCopiedAt != rhs.lastCopiedAt { return lhs.lastCopiedAt < rhs.lastCopiedAt }
        return lhs.itemID < rhs.itemID
    }
}

/// All unpinned rows whose eviction key is <= `through`, except the primary.
/// Byte totals describe the ORIGINAL rows this predicate deletes. R3's
/// projected bytes affect selection, not accounting for a retired item.
package struct RetentionRetirementPrefix: Sendable, Equatable {
    package let through: RetentionEvictionKey
    package let excludedItemID: HistoryItemID?
    package let itemCount: Int
    package let canonicalBytes: Int
    package let revisionBytes: Int

    package init(through: RetentionEvictionKey, excludedItemID: HistoryItemID?,
                 itemCount: Int, canonicalBytes: Int, revisionBytes: Int) {
        self.through = through
        self.excludedItemID = excludedItemID
        self.itemCount = itemCount
        self.canonicalBytes = canonicalBytes
        self.revisionBytes = revisionBytes
    }

    package func contains(_ item: RetainedItemSummary) -> Bool {
        item.pinOrdinal == nil && item.id != excludedItemID
            && RetentionEvictionKey(lastCopiedAt: item.lastCopiedAt, itemID: item.id) <= through
    }
}

/// A pure value fold, used for count, age and byte retention. Candidates are
/// complete in oldest-copy/ID order; omitting an eligible row would change
/// the eventual SQL predicate. Storage checks that loading completes.
package struct OrderedRetentionSelection: Sendable {
    package private(set) var prefix: RetentionRetirementPrefix?
    package private(set) var remainingBytes: Int
    package private(set) var remainingRequiredItems: Int
    private let policies: HistoryRetentionPolicies
    private let now: Date
    private let protectedItemID: HistoryItemID?
    private var previousKey: RetentionEvictionKey?

    package init(policies: HistoryRetentionPolicies, now: Date,
                 protectedItemID: HistoryItemID?, projectedTotalBytes: Int,
                 minimumRetiredItems: Int = 0) {
        self.policies = policies
        self.now = now
        self.protectedItemID = protectedItemID
        self.remainingBytes = projectedTotalBytes
        self.remainingRequiredItems = minimumRetiredItems
    }

    /// Returns false when the first surviving eligible row establishes that
    /// every later row also survives. R1 is strict; its victims precede all
    /// remaining R2/count candidates. The caller may stop its SQL cursor.
    @discardableResult
    package mutating func consider(_ candidate: RetentionExpansionItemSummary,
                                  projectedRevisionBytes: Int? = nil) throws -> Bool {
        let key = RetentionEvictionKey(lastCopiedAt: candidate.lastCopiedAt, itemID: candidate.id)
        guard key.lastCopiedAt.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite,
              previousKey.map({ $0 < key }) ?? true,
              remainingBytes >= 0, remainingRequiredItems >= 0 else {
            throw DomainRejection.corruptLineage
        }
        previousKey = key
        guard candidate.pinOrdinal == nil, candidate.id != protectedItemID else { return true }
        let aged = policies.age.map { candidate.lastCopiedAt < now.addingTimeInterval(-$0.maxAge) } ?? false
        let overBudget = policies.storage.map { remainingBytes > $0.maxTotalBytes } ?? false
        guard aged || overBudget || remainingRequiredItems > 0 else { return false }

        let projectedRevisions = projectedRevisionBytes ?? candidate.revisionBytes
        let projectedFootprint = try Self.add(candidate.canonicalBytes, projectedRevisions)
        guard candidate.canonicalBytes > 0, remainingBytes >= projectedFootprint else {
            throw DomainRejection.corruptLineage
        }
        let canonicalBytes = try Self.add(prefix?.canonicalBytes ?? 0, candidate.canonicalBytes)
        let revisionBytes = try Self.add(prefix?.revisionBytes ?? 0, candidate.revisionBytes)
        let itemCount = try Self.add(prefix?.itemCount ?? 0, 1)
        prefix = RetentionRetirementPrefix(through: key, excludedItemID: protectedItemID,
            itemCount: itemCount, canonicalBytes: canonicalBytes, revisionBytes: revisionBytes)
        remainingBytes -= projectedFootprint
        remainingRequiredItems = max(0, remainingRequiredItems - 1)
        return true
    }

    private static func add(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard lhs >= 0, rhs >= 0, !overflow else { throw DomainRejection.corruptLineage }
        return value
    }
}
