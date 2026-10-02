import Foundation

enum BuiltInAutomationCopy {
    static func text(_ key: String, bundle: Bundle = AppLocalization.bundle) -> String {
        bundle.localizedString(forKey: key, value: key, table: "BuiltInAutomation")
    }
}
