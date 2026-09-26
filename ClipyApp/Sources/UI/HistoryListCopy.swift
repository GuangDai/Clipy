/// History list sections, empty states, and pagination copy (V2-07 §10).
/// Native tables resolve identically in SwiftPM and the generated app.
import Foundation

internal enum HistoryListCopy {
    static var bundle: Bundle { AppLocalization.bundle }

    static func text(_ english: String, bundle: Bundle = AppLocalization.bundle) -> String {
        bundle.localizedString(forKey: english, value: english, table: "HistoryList")
    }

    /// Query text is an argument, never part of the localization key or
    /// format string; percent signs and quotes remain literal user content.
    static func searchMiss(_ query: String, bundle: Bundle = AppLocalization.bundle) -> String {
        String(format: text("No items match “%@”.", bundle: bundle), query)
    }

    static func loadedRange(_ range: ClosedRange<Int>, bundle: Bundle = AppLocalization.bundle) -> String {
        String(format: text("Items %lld–%lld", bundle: bundle),
               Int64(range.lowerBound), Int64(range.upperBound))
    }
}
