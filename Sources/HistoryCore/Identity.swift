/// Public identity and coherence values: item/revision IDs, content versions,
/// change positions, and item references.
/// Owning spec: docs/03a-instruction-set.md §2. Foundation-only.
import Foundation

/// Stable identity of one retained history item.
/// docs/03a-instruction-set.md §2
///
/// The raw UUID is observable for logging, pasteboard lineage encoding, and
/// stable persistence, but minting is centralized in `HistoryStorage`: the
/// initializer is package-only. This is not a security boundary.
public struct HistoryItemID:
    Sendable, Hashable, Comparable, CustomStringConvertible
{
    public let rawValue: UUID

    package init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        withUnsafeBytes(of: lhs.rawValue.uuid) { left in
            withUnsafeBytes(of: rhs.rawValue.uuid) { right in
                left.lexicographicallyPrecedes(right)
            }
        }
    }
}

/// Stable identity of one revision of a retained history item.
/// docs/03a-instruction-set.md §2
///
/// Minting is centralized in `HistoryStorage`: the initializer is
/// package-only.
public struct RevisionID: Sendable, Hashable, Comparable {
    public let rawValue: UUID
    package init(rawValue: UUID) { self.rawValue = rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        withUnsafeBytes(of: lhs.rawValue.uuid) { left in
            withUnsafeBytes(of: rhs.rawValue.uuid) { right in
                left.lexicographicallyPrecedes(right)
            }
        }
    }
}

/// Version of an item's Effective Content state; monotonically increasing.
/// docs/03a-instruction-set.md §2
///
/// Versions use checked arithmetic and never wrap. `.initial` and
/// `successor()` are package-only so versioning is minted centrally.
public struct ContentVersion: Sendable, Hashable, Comparable {
    public let rawValue: UInt64
    package init(rawValue: UInt64) { self.rawValue = rawValue }
    package static let initial = ContentVersion(rawValue: 1)

    package func successor() -> ContentVersion? {
        guard rawValue < UInt64.max else { return nil }
        return ContentVersion(rawValue: rawValue + 1)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Position of one change in the history's global change order.
/// docs/03a-instruction-set.md §2
///
/// Positions use checked arithmetic and never wrap. `.zero` and
/// `successor()` are package-only so positions are minted centrally.
public struct ChangePosition: Sendable, Hashable, Comparable {
    public let rawValue: UInt64
    package init(rawValue: UInt64) { self.rawValue = rawValue }
    package static let zero = ChangePosition(rawValue: 0)

    package func successor() -> ChangePosition? {
        guard rawValue < UInt64.max else { return nil }
        return ChangePosition(rawValue: rawValue + 1)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Reference to one retained item at one Effective Content state.
/// docs/03a-instruction-set.md §2
///
/// UI thumbnail/detail/edit work should retain the reference rather than an
/// ID alone.
public struct HistoryItemReference: Sendable, Hashable {
    public let id: HistoryItemID
    public let contentVersion: ContentVersion

    public init(id: HistoryItemID, contentVersion: ContentVersion) {
        self.id = id
        self.contentVersion = contentVersion
    }
}
