import Foundation
import HistoryCore

/// A reusable search intent, never a snapshot of its clipboard results.
/// Relative dates remain relative when applied on a later day.
struct HistorySearchDefinition: Codable, Equatable, Sendable {
    var query: String
    var mode: SearchMode
    var typeFilter: HistoryTypeFilter
    var pinnedOnly: Bool
    var filters: HistorySearchFilters
    var sortOrder: HistorySortOrder

    init(
        query: String = "", mode: SearchMode = .fuzzy,
        typeFilter: HistoryTypeFilter = .all, pinnedOnly: Bool = false,
        filters: HistorySearchFilters = HistorySearchFilters(),
        sortOrder: HistorySortOrder = .automatic
    ) {
        self.query = query
        self.mode = mode
        self.typeFilter = typeFilter
        self.pinnedOnly = pinnedOnly
        self.filters = filters
        self.sortOrder = sortOrder
        if filters.dateRange != .custom {
            // These unused draft dates must not make the same "Today" search
            // look like a different definition every time it is submitted.
            self.filters.startDate = Date(timeIntervalSince1970: 0)
            self.filters.endDate = Date(timeIntervalSince1970: 0)
        }
    }

    var hasCriteria: Bool {
        !query.isEmpty || typeFilter != .all || pinnedOnly || filters.isActive || sortOrder != .automatic
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.query.utf8.elementsEqual(rhs.query.utf8)
            && lhs.mode == rhs.mode && lhs.typeFilter == rhs.typeFilter
            && lhs.pinnedOnly == rhs.pinnedOnly && lhs.filters == rhs.filters
            && lhs.sortOrder == rhs.sortOrder
    }

    private enum CodingKeys: String, CodingKey {
        case query, mode, typeFilter, pinnedOnly, filters, sortOrder
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let mode: SearchMode
        switch try values.decode(String.self, forKey: .mode) {
        case "exact": mode = .exact
        case "fuzzy": mode = .fuzzy
        case "regexp": mode = .regexp
        case "expression": mode = .expression
        default:
            throw DecodingError.dataCorruptedError(forKey: .mode, in: values,
                                                   debugDescription: "Unknown search mode")
        }
        guard let type = HistoryTypeFilter(rawValue: try values.decode(String.self, forKey: .typeFilter)),
              let sort = HistorySortOrder(rawValue: try values.decode(String.self, forKey: .sortOrder)) else {
            throw DecodingError.dataCorruptedError(forKey: .sortOrder, in: values,
                                                   debugDescription: "Unknown search option")
        }
        self.init(query: try values.decode(String.self, forKey: .query), mode: mode,
                  typeFilter: type, pinnedOnly: try values.decode(Bool.self, forKey: .pinnedOnly),
                  filters: try values.decode(HistorySearchFilters.self, forKey: .filters), sortOrder: sort)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(query, forKey: .query)
        let savedMode: String
        switch mode {
        case .exact: savedMode = "exact"
        case .fuzzy: savedMode = "fuzzy"
        case .regexp: savedMode = "regexp"
        case .expression: savedMode = "expression"
        }
        try values.encode(savedMode, forKey: .mode)
        try values.encode(typeFilter.rawValue, forKey: .typeFilter)
        try values.encode(pinnedOnly, forKey: .pinnedOnly)
        try values.encode(filters, forKey: .filters)
        try values.encode(sortOrder.rawValue, forKey: .sortOrder)
    }
}

extension HistorySearchDefinition {
    @MainActor
    init(viewState: HistoryViewState) {
        self.init(query: viewState.searchText, mode: viewState.searchMode,
                  typeFilter: viewState.typeFilter, pinnedOnly: viewState.showsPinnedOnly,
                  filters: viewState.searchFilters, sortOrder: viewState.sortOrder)
    }

    @MainActor
    func apply(to viewState: HistoryViewState) {
        // These synchronous edits retire earlier requests before any can
        // begin executing. Refresh submits the final intent without debounce.
        viewState.searchMode = mode
        viewState.typeFilter = typeFilter
        viewState.showsPinnedOnly = pinnedOnly
        var appliedFilters = filters
        if appliedFilters.dateRange != .custom {
            // The stored epoch represents an unused draft field, not a date
            // the user chose. Switching to Custom after replay starts today.
            let now = Date()
            appliedFilters.startDate = now
            appliedFilters.endDate = now
        }
        viewState.searchFilters = appliedFilters
        viewState.sortOrder = sortOrder
        viewState.searchText = query
        viewState.refresh()
    }
}
