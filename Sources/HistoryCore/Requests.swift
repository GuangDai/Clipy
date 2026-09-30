/// Browse/search request DTOs for the public History interface.
/// Owning spec: docs/architecture.md Foundation-only.
import Foundation

/// Search evaluation modes. Expression search is explicitly selected so
/// literal text, fuzzy queries and regular expressions retain their meaning.
/// Dedup ranking is unrelated and not public.
///
/// docs/architecture.md
public enum SearchMode: Sendable, Hashable {
    case exact
    case fuzzy
    case regexp
    case expression
}

/// The kind of a browse or observation request: most recent items,
/// or a text search in one of the v1 modes.
///
/// docs/architecture.md
public enum HistoryBrowseKind: Sendable, Hashable {
    case recent
    case search(text: String, mode: SearchMode)

    /// Search consumes the original scalar sequence, including literal
    /// exact/regexp terms. Canonically equivalent spellings may match
    /// different rows and therefore cannot share a query/cursor identity.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.recent, .recent): true
        case (.search(let left, let leftMode), .search(let right, let rightMode)):
            leftMode == rightMode && left.utf8.elementsEqual(right.utf8)
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .recent:
            hasher.combine(0)
        case .search(let text, let mode):
            hasher.combine(1)
            hasher.combine(mode)
            hashLiteralString(text, into: &hasher)
        }
    }
}

private func hashLiteralString(_ value: String, into hasher: inout Hasher) {
    var value = value
    value.withUTF8 {
        hasher.combine($0.count)
        hasher.combine(bytes: UnsafeRawBufferPointer($0))
    }
}

/// Ordering applied after filtering and before pagination. Automatic preserves
/// pinned priority and each search mode's ranking; explicit orders use copy
/// metadata across all matching rows. docs/architecture.md
public enum HistorySortOrder: String, CaseIterable, Sendable, Hashable {
    case automatic
    case newestFirst
    case oldestFirst
    case mostCopied
}

/// The panel's recognizable content families. A row with several families
/// belongs to images before links before text; unknown formats remain in all.
public enum HistoryContentType: String, CaseIterable, Sendable, Hashable {
    case all
    case text
    case images
    case links
}

/// Narrows the complete retained history before ranking and pagination.
public struct HistoryFilter: Sendable, Hashable {
    public let type: HistoryContentType
    public let pinnedOnly: Bool
    /// A literal substring of any retained copy source's bundle identifier.
    /// ASCII letters are matched without case; an empty string means all sources.
    public let sourceApplication: String?
    /// Exact bundle identifiers resolved from an application selection,
    /// matched against any retained copy source of the item.
    /// `nil` means all sources; an empty list matches no source. This condition
    /// intersects with the optional source substring and the other filters.
    public let sourceApplicationIDs: [String]?
    /// Inclusive lower bound on the item's most recent copy timestamp.
    public let copiedAfter: Date?
    /// Exclusive upper bound on the item's most recent copy timestamp.
    public let copiedBefore: Date?

    public init(
        type: HistoryContentType = .all,
        pinnedOnly: Bool = false,
        sourceApplication: String? = nil,
        sourceApplicationIDs: [String]? = nil,
        copiedAfter: Date? = nil,
        copiedBefore: Date? = nil
    ) {
        self.type = type
        self.pinnedOnly = pinnedOnly
        self.sourceApplication = sourceApplication.flatMap { $0.isEmpty ? nil : $0 }
        self.sourceApplicationIDs = sourceApplicationIDs
        self.copiedAfter = copiedAfter
        self.copiedBefore = copiedBefore
    }

    /// Query identity preserves literal source bytes. Swift String equality
    /// treats canonically equivalent Unicode strings as equal, while the
    /// source predicate matches their actual scalar sequences.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.type == rhs.type, lhs.pinnedOnly == rhs.pinnedOnly,
              lhs.copiedAfter == rhs.copiedAfter, lhs.copiedBefore == rhs.copiedBefore
        else { return false }
        switch (lhs.sourceApplicationIDs, rhs.sourceApplicationIDs) {
        case (.none, .none): break
        case (.some(let left), .some(let right)):
            guard left.count == right.count,
                  zip(left, right).allSatisfy({ pair in pair.0.utf8.elementsEqual(pair.1.utf8) })
            else { return false }
        default: return false
        }
        switch (lhs.sourceApplication, rhs.sourceApplication) {
        case (.none, .none): return true
        case (.some(let left), .some(let right)): return left.utf8.elementsEqual(right.utf8)
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(type)
        hasher.combine(pinnedOnly)
        hasher.combine(copiedAfter)
        hasher.combine(copiedBefore)
        hasher.combine(sourceApplicationIDs != nil)
        if let sourceApplicationIDs {
            hasher.combine(sourceApplicationIDs.count)
            for identifier in sourceApplicationIDs {
                hashLiteralString(identifier, into: &hasher)
            }
        }
        hasher.combine(sourceApplication != nil)
        if let sourceApplication {
            hashLiteralString(sourceApplication, into: &hasher)
        }
    }

    public static let all = HistoryFilter()
}

/// An opaque pagination cursor. It is bound to the complete query shape
/// and snapshot position, and has process-local validity.
/// Minted by the implementation, never by callers.
///
/// docs/architecture.md
public struct HistoryPageCursor: Sendable, Hashable {
    package let payload: Data

    package init(payload: Data) {
        self.payload = payload
    }
}

/// A one-shot request for a page of History rows. Additional pages use
/// further `browse` requests carrying either adjacent-page cursor. Direction
/// belongs to the opaque cursor; callers never reverse the returned row order.
///
/// docs/architecture.md
public struct HistoryBrowseRequest: Sendable, Hashable {
    public let kind: HistoryBrowseKind
    public let limit: Int
    public let filter: HistoryFilter
    public let cursor: HistoryPageCursor?
    public let sortOrder: HistorySortOrder
    /// An independent DSL condition intersected with the ordinary text mode
    /// and filters. It does not change exact, fuzzy, or regexp text semantics.
    public let conditionExpression: HistorySearchExpression?
    /// Starts a fresh page at this retained item using its current ordering
    /// facts. The first row is the requested item; adjacent cursors continue
    /// normally without repeating this field. No persisted cursor is needed.
    /// A missing item or one outside this query throws `notFound`; supplying
    /// both this value and `cursor` throws `conflictingPageAnchors`.
    public let startAround: HistoryItemID?

    public init(
        kind: HistoryBrowseKind,
        limit: Int,
        cursor: HistoryPageCursor? = nil,
        filter: HistoryFilter = .all,
        sortOrder: HistorySortOrder = .automatic,
        startAround: HistoryItemID? = nil,
        conditionExpression: HistorySearchExpression? = nil
    ) {
        self.kind = kind
        self.limit = limit
        self.filter = filter
        self.cursor = cursor
        self.sortOrder = sortOrder
        self.startAround = startAround
        self.conditionExpression = conditionExpression
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.limit == rhs.limit && lhs.filter == rhs.filter
            && lhs.cursor == rhs.cursor && lhs.sortOrder == rhs.sortOrder
            && lhs.startAround == rhs.startAround
            && equalConditions(lhs.conditionExpression, rhs.conditionExpression)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(limit)
        hasher.combine(filter)
        hasher.combine(cursor)
        hasher.combine(sortOrder)
        hasher.combine(startAround)
        hashCondition(conditionExpression, into: &hasher)
    }
}

/// A request to observe one query. It intentionally has no cursor:
/// observation tracks the current first page for the query.
///
/// docs/architecture.md
public struct HistoryObservationRequest: Sendable, Hashable {
    public let kind: HistoryBrowseKind
    public let limit: Int
    public let filter: HistoryFilter
    public let sortOrder: HistorySortOrder
    /// An independent DSL condition applied as an AND alongside `kind`.
    public let conditionExpression: HistorySearchExpression?

    public init(
        kind: HistoryBrowseKind,
        limit: Int,
        filter: HistoryFilter = .all,
        sortOrder: HistorySortOrder = .automatic,
        conditionExpression: HistorySearchExpression? = nil
    ) {
        self.kind = kind
        self.limit = limit
        self.filter = filter
        self.sortOrder = sortOrder
        self.conditionExpression = conditionExpression
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.limit == rhs.limit && lhs.filter == rhs.filter
            && lhs.sortOrder == rhs.sortOrder
            && equalConditions(lhs.conditionExpression, rhs.conditionExpression)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(limit)
        hasher.combine(filter)
        hasher.combine(sortOrder)
        hashCondition(conditionExpression, into: &hasher)
    }
}

/// DSL literals are evaluated as their original scalar sequences. AST's
/// String equality must not merge two observation or pagination identities.
private func equalConditions(_ lhs: HistorySearchExpression?, _ rhs: HistorySearchExpression?) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none): true
    case (.some(let left), .some(let right)): left.serialized.utf8.elementsEqual(right.serialized.utf8)
    default: false
    }
}

private func hashCondition(_ expression: HistorySearchExpression?, into hasher: inout Hasher) {
    hasher.combine(expression != nil)
    if let expression { hashLiteralString(expression.serialized, into: &hasher) }
}
