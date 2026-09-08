/// Retained-content usage copy and display formatting (V2-07 §6/§10).
/// These labels describe logical content bytes, including retained revisions;
/// native formatting never changes the exact counts supplied by History.
import Foundation

internal enum HistoryUsageCopy {
    static var bundle: Bundle { .main }

    static func text(_ english: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: english, value: english, table: "HistoryUsage")
    }

    static func disclosure(bundle: Bundle = .main) -> String {
        text(
            "Content size includes originals and retained revisions. "
                + "Actual disk usage may differ.",
            bundle: bundle
        )
    }

    /// A compact decimal byte count using the native file-size convention.
    /// Spell zero numerically so an empty store reads as a measured zero.
    static func contentBytes(_ bytes: Int, locale: Locale = .current) -> String {
        bytes.formatted(ByteCountFormatStyle(
            style: .file,
            spellsOutZero: false,
            locale: locale
        ))
    }
}
