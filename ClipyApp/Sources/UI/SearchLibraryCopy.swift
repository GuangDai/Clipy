import Foundation
import HistoryCore

enum SearchLibraryCopy {
    static func text(_ english: String, bundle: Bundle = AppLocalization.bundle) -> String {
        bundle.localizedString(forKey: english, value: english, table: "SearchLibrary")
    }

    static func count(_ english: String, _ count: Int, bundle: Bundle = AppLocalization.bundle) -> String {
        String(format: text(english, bundle: bundle), count)
    }

    static func feedback(_ result: SearchHistoryWriteResult, bundle: Bundle = AppLocalization.bundle) -> SettingStatus {
        switch result {
        case .saved: .success(text("Search saved.", bundle: bundle))
        case .disabled: .cancelled(text("Search saving is off. Enable it to save search conditions.", bundle: bundle))
        case .recentSearchesDisabled: .cancelled(text("Automatic search history is off. You can still save a favorite.", bundle: bundle))
        case .excluded: .cancelled(text("Not saved because these conditions match an exclusion rule.", bundle: bundle))
        case .empty: .cancelled(text("Enter a query or choose a filter before saving.", bundle: bundle))
        case .favoriteLimitReached: .failure(text("The favorite limit has been reached. Remove a favorite before adding another.", bundle: bundle))
        case .invalidDefinition: .failure(text("These search conditions are invalid. Check the query and dates before saving.", bundle: bundle))
        case .unavailable: .failure(text("Search preferences could not be saved. Try again.", bundle: bundle))
        }
    }

    static func failure(_ failure: SearchHistoryFailure, bundle: Bundle = AppLocalization.bundle) -> String {
        switch failure {
        case .unreadableStore: text("Saved searches could not be read. Clear saved searches to start again.", bundle: bundle)
        case .writeFailed: text("Search preferences could not be saved. Try again.", bundle: bundle)
        }
    }

    /// List summaries explain which saved conditions will replace the live
    /// query, without retaining or displaying old search results.
    static func summary(
        _ definition: HistorySearchDefinition, locale: Locale = .current,
        bundle: Bundle = AppLocalization.bundle
    ) -> String {
        var parts: [String] = []
        switch definition.mode {
        case .exact: parts.append(PanelActionsCopy.text("Exact", bundle: bundle))
        case .fuzzy: parts.append(PanelActionsCopy.text("Fuzzy", bundle: bundle))
        case .regexp: parts.append(PanelActionsCopy.text("Regular Expression", bundle: bundle))
        case .expression: parts.append(HistorySearchCopy.text("Expression", bundle: bundle))
        }
        switch definition.typeFilter {
        case .all: break
        case .text: parts.append(PanelActionsCopy.text("Text", bundle: bundle))
        case .images: parts.append(PanelActionsCopy.text("Images", bundle: bundle))
        case .links: parts.append(PanelActionsCopy.text("Links", bundle: bundle))
        }
        if definition.pinnedOnly { parts.append(PanelActionsCopy.text("Pinned Only", bundle: bundle)) }
        if let source = definition.filters.source { parts.append(source) }
        if definition.filters.dateRange == .custom {
            let style = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)
            parts.append(definition.filters.startDate.formatted(style)
                + " – " + definition.filters.endDate.formatted(style))
        } else if definition.filters.dateRange != .anyTime {
            parts.append(HistorySearchCopy.text(definition.filters.dateRange.title, bundle: bundle))
        }
        if definition.sortOrder != .automatic {
            parts.append(HistorySearchCopy.sortTitle(definition.sortOrder, bundle: bundle))
        }
        return parts.joined(separator: " · ")
    }
}
