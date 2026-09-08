/// Human-readable representation headings. These labels do not decide which
/// formats can be read, edited, or exported; the exact identifier stays in
/// each row's Format Details disclosure and in its existing action identity.
import Foundation

internal enum DetailsPresentationCopy {
    static func text(_ key: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: key, value: key, table: "DetailsPresentation")
    }

    static func formatName(_ identifier: String, bundle: Bundle = .main) -> String {
        let name: String
        switch identifier {
        case "public.utf8-plain-text": name = "Text · UTF-8"
        case "public.utf16-plain-text": name = "Text · UTF-16"
        case "public.utf16-external-plain-text": name = "Text · UTF-16 External"
        case "public.rtf": name = "Rich Text"
        case "com.apple.flat-rtfd": name = "Rich Text with Attachments"
        case "public.html": name = "HTML"
        case "com.adobe.pdf": name = "PDF"
        case "public.png": name = "PNG Image"
        case "public.jpeg": name = "JPEG Image"
        case "public.tiff": name = "TIFF Image"
        case "public.heic", "public.heif": name = "HEIF Image"
        case "com.compuserve.gif": name = "GIF Image"
        case "com.microsoft.bmp": name = "Bitmap Image"
        case "public.image": name = "Image"
        case "public.url": name = "Link"
        case "public.file-url": name = "File Reference"
        default: return identifier
        }
        return text(name, bundle: bundle)
    }
}
