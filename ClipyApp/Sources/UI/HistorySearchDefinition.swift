import Foundation
import HistoryCore

/// A reusable search intent, never a snapshot of its clipboard results.
/// Relative dates remain relative when applied on a later day.
struct HistorySearchDefinition: Codable, Equatable, Sendable {
    let query: String
    let mode: SearchMode
    let typeFilter: HistoryTypeFilter
    let pinnedOnly: Bool
    let filters: HistorySearchFilters
    let sortOrder: HistorySortOrder
    /// The zone that gave the stored instants their originally selected days.
    /// Older definitions have no such fact and keep their original replay rules.
    let customDateTimeZone: TimeZone?

    init(
        query: String = "", mode: SearchMode = .exact,
        typeFilter: HistoryTypeFilter = .all, pinnedOnly: Bool = false,
        filters: HistorySearchFilters = HistorySearchFilters(),
        sortOrder: HistorySortOrder = .newestFirst,
        customDateTimeZone: TimeZone? = .current
    ) {
        self.query = query
        self.mode = mode
        self.typeFilter = typeFilter
        self.pinnedOnly = pinnedOnly
        self.sortOrder = sortOrder
        self.customDateTimeZone = filters.dateRange == .custom ? customDateTimeZone : nil
        var normalizedFilters = filters
        if filters.dateRange != .custom {
            // These unused draft dates must not make the same "Today" search
            // look like a different definition every time it is submitted.
            normalizedFilters.startDate = Date(timeIntervalSince1970: 0)
            normalizedFilters.endDate = Date(timeIntervalSince1970: 0)
        }
        self.filters = normalizedFilters
    }

    var hasCriteria: Bool {
        !query.isEmpty || typeFilter != .all || pinnedOnly || filters.isActive || sortOrder != .newestFirst
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.query.utf8.elementsEqual(rhs.query.utf8)
            && lhs.mode == rhs.mode && lhs.typeFilter == rhs.typeFilter
            && lhs.pinnedOnly == rhs.pinnedOnly && lhs.filters == rhs.filters
            && lhs.sortOrder == rhs.sortOrder && lhs.customDateTimeZone == rhs.customDateTimeZone
    }

    private enum CodingKeys: String, CodingKey {
        case query, mode, typeFilter, pinnedOnly, filters, sortOrder, customDateTimeZone
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
        let filters = try values.decode(HistorySearchFilters.self, forKey: .filters)
        let zone: TimeZone?
        if let identifier = try values.decodeIfPresent(String.self, forKey: .customDateTimeZone) {
            guard filters.dateRange == .custom, let parsed = TimeZone(identifier: identifier) else {
                throw DecodingError.dataCorruptedError(forKey: .customDateTimeZone, in: values,
                                                       debugDescription: "Invalid saved custom date time zone")
            }
            zone = parsed
        } else {
            zone = nil
        }
        self.init(query: try values.decode(String.self, forKey: .query), mode: mode,
                  typeFilter: type, pinnedOnly: try values.decode(Bool.self, forKey: .pinnedOnly),
                  filters: filters, sortOrder: sort, customDateTimeZone: zone)
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
        try values.encodeIfPresent(customDateTimeZone?.identifier, forKey: .customDateTimeZone)
    }

    /// Project the chosen calendar days into the viewer's local time zone.
    /// If that zone skipped a selected day, no equivalent range can be applied.
    func filtersForReplay(in timeZone: TimeZone) -> HistorySearchFilters? {
        guard let customDateTimeZone, customDateTimeZone != timeZone else { return filters }
        let dayComponents: Set<Calendar.Component> = [.era, .year, .month, .day]
        var original = Calendar(identifier: .gregorian)
        original.timeZone = customDateTimeZone
        var destination = Calendar(identifier: .gregorian)
        destination.timeZone = timeZone

        func replayDay(_ value: Date) -> Date? {
            let day = original.dateComponents(dayComponents, from: value)
            guard let local = destination.date(from: day),
                  destination.dateComponents(dayComponents, from: local) == day else { return nil }
            return destination.startOfDay(for: local)
        }

        guard let start = replayDay(filters.startDate), let end = replayDay(filters.endDate) else { return nil }
        var replay = filters
        replay.startDate = start
        replay.endDate = end
        return replay
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
    @discardableResult
    func apply(to viewState: HistoryViewState, timeZone: TimeZone = .current) -> Bool {
        guard var appliedFilters = filtersForReplay(in: timeZone) else { return false }
        // These synchronous edits retire earlier requests before any can
        // begin executing. Refresh submits the final intent without debounce.
        viewState.searchMode = mode == .expression ? .fuzzy : mode
        viewState.typeFilter = typeFilter
        viewState.showsPinnedOnly = pinnedOnly
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
        return true
    }
}
