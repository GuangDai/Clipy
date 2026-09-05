/// Row occurrence-count presentation (V2-07 §9/§10). Counts stay UInt64;
/// formatting never narrows the History occurrence counter to a signed Int.
import Foundation

internal enum HistoryRowCopy {
    static var bundle: Bundle { .module }

    static func copyCount(_ count: UInt64, locale: Locale = .current) -> String {
        "×" + count.formatted(.number.locale(locale))
    }

    static func copiedCount(
        _ count: UInt64, bundle: Bundle = .module, locale: Locale = .current
    ) -> String {
        let format = bundle.localizedString(
            forKey: "Copied %llu times",
            value: count == 1 ? "Copied %2$@ time" : "Copied %2$@ times",
            table: "HistoryRow"
        )
        return String(
            format: format, locale: locale,
            arguments: [count, count.formatted(.number.locale(locale))]
        )
    }
}
