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

/// An opaque pagination cursor. It is bound to the complete query shape
/// and snapshot position, and has process-local v1 validity.
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
/// further `browse` requests carrying the cursor of the previous page.
///
/// docs/03a-instruction-set.md §7
public struct HistoryBrowseRequest: Sendable, Hashable {
    public let kind: HistoryBrowseKind
    public let limit: Int
    public let after: HistoryPageCursor?

    public init(
        kind: HistoryBrowseKind,
        limit: Int,
        after: HistoryPageCursor? = nil
    ) {
        self.kind = kind
        self.limit = limit
        self.after = after
    }
}

/// A request to observe one query. It intentionally has no cursor:
/// observation tracks the current first page for the query.
///
/// docs/03a-instruction-set.md §7
public struct HistoryObservationRequest: Sendable, Hashable {
    public let kind: HistoryBrowseKind
    public let limit: Int

    public init(kind: HistoryBrowseKind, limit: Int) {
        self.kind = kind
        self.limit = limit
    }
}
