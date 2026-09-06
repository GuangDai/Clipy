/// Localized messages for the existing typed History failure presentation.
/// The owning exhaustive switch selects fixed copy, never raw error payloads.
import Foundation

internal enum FailureCopy {
    static var bundle: Bundle { .module }

    static func text(_ english: String, bundle: Bundle = .module) -> String {
        bundle.localizedString(forKey: english, value: english, table: "Failure")
    }
}
