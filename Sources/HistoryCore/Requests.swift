/// Browse/search request DTOs for the public History interface.
/// Owning spec: docs/03a-instruction-set.md §7. Foundation-only.
import Foundation

/// The three v1 search evaluation modes.
/// Dedup ranking is unrelated and not public.
///
/// docs/03a-instruction-set.md §7
public enum SearchMode: Sendable, Hashable {
    case exact
    case fuzzy
    case regexp
}

/// The kind of a browse or observation request: most recent items,
/// or a text search in one of the v1 modes.
///
/// docs/03a-instruction-set.md §7
public enum HistoryBrowseKind: Sendable, Hashable {
    case recent
    case search(text: String, mode: SearchMode)
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

    public init(type: HistoryContentType = .all, pinnedOnly: Bool = false) {
        self.type = type
        self.pinnedOnly = pinnedOnly
    }

    public static let all = HistoryFilter()
}

/// An opaque pagination cursor. It is bound to the complete query shape
/// and snapshot position, and has process-local validity.
/// Minted by the implementation, never by callers.
///
/// docs/03a-instruction-set.md §7
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
/// docs/03a-instruction-set.md §7
public struct HistoryBrowseRequest: Sendable, Hashable {
    public let kind: HistoryBrowseKind
    public let limit: Int
    public let filter: HistoryFilter
    public let cursor: HistoryPageCursor?

    public init(
        kind: HistoryBrowseKind,
        limit: Int,
        cursor: HistoryPageCursor? = nil,
        filter: HistoryFilter = .all
    ) {
        self.kind = kind
        self.limit = limit
        self.filter = filter
        self.cursor = cursor
    }
}

/// A request to observe one query. It intentionally has no cursor:
/// observation tracks the current first page for the query.
///
/// docs/03a-instruction-set.md §7
public struct HistoryObservationRequest: Sendable, Hashable {
    public let kind: HistoryBrowseKind
    public let limit: Int
    public let filter: HistoryFilter

    public init(kind: HistoryBrowseKind, limit: Int, filter: HistoryFilter = .all) {
        self.kind = kind
        self.limit = limit
        self.filter = filter
    }
}
