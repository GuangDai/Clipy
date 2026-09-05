/// Row occurrence-count presentation (V2-07 §9/§10). Displayed counts keep
/// the full UInt64 value independently of the native plural-rule operand.
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
        // Foundation's native plural formatting interprets integer operands
        // as signed, even with "llu". The shipped English/Chinese resources
        // use only one/other: saturating this selector keeps large counts in
        // "other". The displayed count below remains the exact UInt64 value.
        let pluralSelector = Int64(clamping: count)
        return String(
            format: format, locale: locale,
            arguments: [pluralSelector, count.formatted(.number.locale(locale))]
        )
    }
}
