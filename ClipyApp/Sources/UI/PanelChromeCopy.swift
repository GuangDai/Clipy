import Foundation

/// Copy for the panel's compact search and display controls.
enum PanelChromeCopy {
    static func text(_ english: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: english, value: english, table: "PanelChrome")
    }
}
