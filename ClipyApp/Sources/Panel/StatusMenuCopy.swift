/// Status-item menu copy belongs to the application bundle, alongside its
/// AppKit owner. Package-local strings remain in their owning package.
import Foundation

enum StatusMenuCopy {
    static func text(_ english: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: english, value: english, table: "StatusMenu")
    }
}
