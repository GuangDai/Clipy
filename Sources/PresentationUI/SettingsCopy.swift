/// General, Privacy, and Appearance copy (V2-07 §10 / UI17).
/// Native tables resolve identically in the SwiftPM and generated app builds.
import Foundation

internal enum SettingsCopy {
    static var bundle: Bundle { .module }

    static func text(_ english: String, bundle: Bundle = .module) -> String {
        bundle.localizedString(
            forKey: english, value: english,
            table: "GeneralAppearanceSettings"
        )
    }

    static func removeIgnoredApp(
        _ bundleID: String, bundle: Bundle = .module
    ) -> String {
        String(format: text("Remove %@", bundle: bundle), bundleID)
    }

    static func shortcutUnavailable(
        _ chord: String, bundle: Bundle = .module
    ) -> String {
        String(format: text("%@ is unavailable.", bundle: bundle), chord)
    }

    static func retainedShortcut(
        _ chord: String, bundle: Bundle = .module
    ) -> String {
        String(
            format: text("The current %@ shortcut still works.", bundle: bundle),
            chord
        )
    }
}
