import Foundation

/// App-owned copy for the adaptive Settings presentation.
enum AdaptiveSettingsCopy {
    static func text(_ english: String, bundle: Bundle = AppLocalization.bundle) -> String {
        bundle.localizedString(forKey: english, value: english, table: "AdaptiveSettings")
    }
}
