/// Copy owned by search, row/details actions, and the revision editor.
/// V2-07 §10: native resources keep SwiftPM and app localization identical.
import Foundation

internal enum PanelActionsCopy {
    static var bundle: Bundle { .module }

    /// Respect a view's locale independently of the process's preferred
    /// language. Foundation owns language/script/region matching; the module's
    /// declared development localization remains the unsupported-locale fallback.
    static func bundle(for locale: Locale) -> Bundle {
        let resources = Bundle.module
        var preferences = [locale.identifier(.bcp47)]
        if let development = resources.developmentLocalization {
            preferences.append(development)
        }
        guard let localization = Bundle.preferredLocalizations(
            from: resources.localizations, forPreferences: preferences
        ).first,
              let resourceURL = resources.resourceURL,
              let localized = Bundle(url: resourceURL.appendingPathComponent(
                "\(localization).lproj", isDirectory: true
              )) else { return resources }
        return localized
    }

    static func text(_ english: String, bundle: Bundle = .module) -> String {
        bundle.localizedString(forKey: english, value: english, table: "PanelActions")
    }

    static func format(
        _ english: String, _ value: String, bundle: Bundle = .module
    ) -> String {
        String(format: text(english, bundle: bundle), value)
    }

    static func pinnedPosition(
        _ ordinal: Int, compact: Bool = false,
        bundle: Bundle = .module, locale: Locale = .current
    ) -> String {
        format(
            compact ? "Pinned #%@" : "Pinned at position %@",
            LocalizedCountPresentation.number(ordinal, locale: locale),
            bundle: bundle
        )
    }

    static func revisionDisclosure(bundle: Bundle = .module) -> String {
        text(
            "Save appends an immutable revision. Previous and original content "
                + "may remain in this item's revision history.",
            bundle: bundle
        )
    }
}
