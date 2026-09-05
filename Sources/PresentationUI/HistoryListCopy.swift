/// History list sections, empty states, and pagination copy (V2-07 §10).
/// Native tables resolve identically in SwiftPM and the generated app.
import Foundation

internal enum HistoryListCopy {
    static var bundle: Bundle { .module }

    static func text(_ english: String, bundle: Bundle = .module) -> String {
        bundle.localizedString(forKey: english, value: english, table: "HistoryList")
    }

    /// Query text is an argument, never part of the localization key or
    /// format string; percent signs and quotes remain literal user content.
    static func searchMiss(_ query: String, bundle: Bundle = .module) -> String {
        String(format: text("No items match “%@”.", bundle: bundle), query)
    }
}
