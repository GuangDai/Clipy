/// Localized copy owned by the app's store-open and paste recovery surface.
/// Typed History messages stay in PresentationUI's FailurePresentation.
import Foundation

enum AppRecoveryCopy {
    static func text(_ english: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: english, value: english, table: "AppRecovery")
    }
}
