/// Copy shared by the preview column and its Quick Look presentation.
/// Clipboard text remains literal; only surrounding UI and accessibility
/// metadata use these native resources and the selected numeric locale.
import Foundation

internal enum PreviewCopy {
    static var bundle: Bundle { .module }

    static func text(_ english: String, bundle: Bundle = .module) -> String {
        bundle.localizedString(forKey: english, value: english, table: "Preview")
    }

    static func copyCount(
        _ count: UInt64,
        bundle: Bundle = .module,
        locale: Locale = .current
    ) -> String {
        String(
            format: text("Copied %@×", bundle: bundle),
            count.formatted(.number.locale(locale))
        )
    }

    static func imageDimensions(
        width: Int,
        height: Int,
        bundle: Bundle = .module,
        locale: Locale = .current
    ) -> String {
        String(
            format: text("Image preview, %@ by %@ pixels", bundle: bundle),
            LocalizedCountPresentation.number(width, locale: locale),
            LocalizedCountPresentation.number(height, locale: locale)
        )
    }
}
