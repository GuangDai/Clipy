/// Summon-shortcut recorder copy belongs to the application bundle, alongside
/// its SwiftUI owner. Package-local strings remain in their owning package.
import Foundation

enum ShortcutRecorderCopy {
    static func text(_ english: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: english, value: english, table: "ShortcutRecorder")
    }
}
