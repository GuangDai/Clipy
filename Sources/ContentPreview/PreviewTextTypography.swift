import CoreText
import Foundation

/// Resolve the first two segments' system-font fallback on the renderer actor.
/// Cold CJK layout was substantially slower than a second CJK document in
/// the native preview test. Core Text functions are thread-safe; the local
/// line and attributed string never leave this one operation (01 §6).
internal enum PreviewTextTypography {
    internal static func prepare(_ text: PreviewText) {
        autoreleasepool {
            // Zero requests the system's own UI font size, not an app-owned
            // typography constant. The visible view still uses SwiftUI .body.
            guard let font = CTFontCreateUIFontForLanguage(.system, 0, nil) else { return }
            // A short prefix can occupy the first segment by itself, leaving
            // the next segment's combining sequence cold at publication.
            for segment in text.displaySegments.prefix(2) where !segment.isEmpty {
                let attributed = NSAttributedString(string: String(segment), attributes: [
                    NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font
                ])
                let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
                // Force fallback resolution while the line stays off MainActor.
                _ = CTLineGetGlyphCount(line)
            }
        }
    }
}
