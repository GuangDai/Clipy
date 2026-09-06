import Foundation

/// Counts of the rows the panel displays (Card 8C / V2-07 §10).
/// A remaining cursor keeps the count a lower bound after client filtering:
/// unloaded rows may still contain matches for the selected filter.
internal enum HistoryCountCopy {
    internal static var bundle: Bundle { .module }

    internal static func items(
        count: Int, hasNextPage: Bool,
        locale: Locale = .current, bundle: Bundle = .module
    ) -> String {
        text("items", singular: "item", plural: "items", count: count,
             hasNextPage: hasNextPage, locale: locale, bundle: bundle)
    }

    internal static func results(
        count: Int, hasNextPage: Bool,
        locale: Locale = .current, bundle: Bundle = .module
    ) -> String {
        text("results", singular: "result", plural: "results", count: count,
             hasNextPage: hasNextPage, locale: locale, bundle: bundle)
    }

    private static func text(
        _ key: String, singular: String, plural: String,
        count: Int, hasNextPage: Bool, locale: Locale, bundle: Bundle
    ) -> String {
        let digits = LocalizedCountPresentation.number(count, locale: locale)
        if hasNextPage {
            let format = bundle.localizedString(
                forKey: key + ".more", value: "%@+ " + plural, table: "HistoryCounts"
            )
            return String(format: format, locale: locale, arguments: [digits])
        }
        let format = bundle.localizedString(
            forKey: key, value: "%2$@ " + (count == 1 ? singular : plural),
            table: "HistoryCounts"
        )
        // The count selects the plural rule; the formatted argument supplies
        // locale-specific grouping and digits without changing that rule.
        return String(format: format, locale: locale, arguments: [count, digits])
    }
}
