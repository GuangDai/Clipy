import Foundation

/// A range expressed in UTF-16 code units, relative to the string it
/// annotates (a row title or a search snippet).
/// Owning spec: docs/03b-instruction-set.md §8.
public struct UTF16TextRange: Sendable, Hashable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

/// Presentation evidence for a search-matched row: an optional bounded body
/// excerpt plus the UTF-16 ranges that matched within the title (when
/// `snippet == nil`) or within `snippet`.
/// Owning spec: docs/03b-instruction-set.md §8.
public struct SearchPresentation: Sendable, Hashable {
    public let snippet: String?
    public let matchedRanges: [UTF16TextRange]

    public init(
        snippet: String?,
        matchedRanges: [UTF16TextRange]
    ) {
        self.snippet = snippet
        self.matchedRanges = matchedRanges
    }
}

/// One row of a browse or search page. `pinnedPosition` is 0-based within the
/// pinned group (`nil` when unpinned); `search` is `nil` for recent rows and
/// carries presentation evidence for search rows.
/// Owning spec: docs/03b-instruction-set.md §8.
public struct HistoryRow: Sendable, Hashable {
    public let item: HistoryItemReference
    public let title: String
    public let typeIdentifiers: [String]
    public let lastCopiedAt: Date
    public let copyCount: UInt64
    public let lastSource: String?
    public let pinnedPosition: Int?
    public let search: SearchPresentation?

    package init(
        item: HistoryItemReference,
        title: String,
        typeIdentifiers: [String],
        lastCopiedAt: Date,
        copyCount: UInt64,
        lastSource: String?,
        pinnedPosition: Int?,
        search: SearchPresentation?
    ) {
        self.item = item
        self.title = title
        self.typeIdentifiers = typeIdentifiers
        self.lastCopiedAt = lastCopiedAt
        self.copyCount = copyCount
        self.lastSource = lastSource
        self.pinnedPosition = pinnedPosition
        self.search = search
    }
}

/// A deterministically ordered page of rows, stamped with the change position
/// it was read at and carrying a cursor to the next page when one exists.
/// Owning spec: docs/03b-instruction-set.md §8.
public struct HistoryPage: Sendable, Hashable {
    public let position: ChangePosition
    public let rows: [HistoryRow]
    public let next: HistoryPageCursor?

    package init(
        position: ChangePosition,
        rows: [HistoryRow],
        next: HistoryPageCursor?
    ) {
        self.position = position
        self.rows = rows
        self.next = next
    }
}
