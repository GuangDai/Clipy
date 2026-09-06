/// The panel footer's actions, keyboard hints, and destructive clear copy.
/// Native tables keep the same English and Chinese text in both app builds.
import Foundation

internal enum PanelFooterCopy {
    static var bundle: Bundle { .module }

    static func text(_ english: String, bundle: Bundle = .module) -> String {
        bundle.localizedString(forKey: english, value: english, table: "PanelFooter")
    }
}
