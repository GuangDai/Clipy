import ContentPreview
import Foundation

/// App preferences for the text preview, shared by Settings, the floating
/// pane and Quick Look. The enable flag is separate so switching to complete
/// text and back preserves a custom count. Copy and search use neither key.
enum PreviewTextSettings {
    static let isLengthLimitedKey = "clipy.preview.isTextLengthLimited"
    static let maximumCharactersKey = "clipy.preview.maximumTextCharacters"
    static let defaultMaximumCharacters = PreviewTextConfiguration.defaultMaximumCharacters

    static func configuration(from defaults: UserDefaults) -> PreviewTextConfiguration {
        configuration(maximumCharacters: (defaults.object(forKey: maximumCharactersKey) as? Int)
            ?? defaultMaximumCharacters,
            isLengthLimited: (defaults.object(forKey: isLengthLimitedKey) as? Bool) ?? true)
    }

    static func configuration(maximumCharacters: Int, isLengthLimited: Bool) -> PreviewTextConfiguration {
        PreviewTextConfiguration(maximumCharacters: isLengthLimited
            ? (maximumCharacters > 0 ? maximumCharacters : defaultMaximumCharacters) : nil)
    }
}
