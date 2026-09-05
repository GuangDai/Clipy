/// StableFormatFacts — immutable, Foundation-only facts about exact clipboard
/// format identifiers. Behavior owners decide independently whether a fact is
/// eligible for projection, preview, presentation, or editing.
/// Owning review: 08 §4.1; 06 §9.
import Foundation

/// An open-world exact clipboard format identifier. Unknown values remain
/// representable and opaque; constructing this value is not admission or
/// validation.
package struct ClipboardFormatIdentifier: Hashable, Sendable {
    package let rawValue: String

    package init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The string codec declared by this exact identifier, when Clipy has an
    /// explicit byte-order contract. This is a wire fact, not permission to
    /// project, preview, present, or edit the representation.
    package var declaredStringCodec: DeclaredStringCodec? {
        switch self {
        case .utf8PlainText:
            .utf8
        case .utf16PlainText:
            .nativeUTF16
        case .utf16ExternalPlainText:
            .externalUTF16
        default:
            nil
        }
    }
}

/// Stable string encodings declared by exact identifiers. Decoding remains in
/// each behavior owner so byte handling and malformed-input policy do not leak
/// into this facts-only module.
package enum DeclaredStringCodec: Equatable, Sendable {
    case utf8
    case nativeUTF16
    /// UTF-16 with an optional byte-order mark; absent a BOM, big-endian.
    /// Apple UTTypeUTF16ExternalPlainText declares this external byte order.
    case externalUTF16
}

package extension ClipboardFormatIdentifier {
    static let plainText = Self(rawValue: "public.plain-text")
    static let utf8PlainText = Self(rawValue: "public.utf8-plain-text")
    static let utf16PlainText = Self(rawValue: "public.utf16-plain-text")
    static let utf16ExternalPlainText = Self(
        rawValue: "public.utf16-external-plain-text"
    )
    static let text = Self(rawValue: "public.text")
    static let rtf = Self(rawValue: "public.rtf")
    static let html = Self(rawValue: "public.html")
    static let flatRTFD = Self(rawValue: "com.apple.flat-rtfd")
    static let url = Self(rawValue: "public.url")
    static let fileURL = Self(rawValue: "public.file-url")
    static let image = Self(rawValue: "public.image")
    static let png = Self(rawValue: "public.png")
    static let jpeg = Self(rawValue: "public.jpeg")
    static let tiff = Self(rawValue: "public.tiff")
    static let heic = Self(rawValue: "public.heic")
    static let heif = Self(rawValue: "public.heif")
    static let gif = Self(rawValue: "com.compuserve.gif")
    static let bmp = Self(rawValue: "com.microsoft.bmp")
}
