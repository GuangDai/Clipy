import Foundation

/// Secondary preview controls use the app's native localization resources.
enum PreviewPresentationCopy {
    static func text(_ english: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: english, value: english, table: "PreviewPresentation")
    }
}
