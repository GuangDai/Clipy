/// Copy shared by the preview column and its Quick Look presentation.
/// Clipboard text remains literal; only surrounding UI and accessibility
/// metadata use these native resources and the selected numeric locale.
import Foundation

internal enum PreviewCopy {
    static var bundle: Bundle { .main }

    static func fileFailure(_ failure: FilePreviewFailure) -> String {
        let message: String
        switch failure {
        case .invalidReference: message = "This is not a local file reference."
        case .unavailable: message = "The file could not be read. It may have moved or been deleted."
        case .changedDuringRead: message = "The file changed while it was being read. Return to the file reference to load it again."
        case .permissionDenied: message = "Clipy does not have permission to read this file."
        case .tooLarge: message = "The file is too large to preview."
        case .unsupported: message = "This file type cannot be previewed."
        }
        return text(message)
    }

    static func text(_ english: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: english, value: english, table: "Preview")
    }

    /// The reference preview shows copied address/path data. This describes
    /// that preview's behavior, not a guarantee about other apps or processes.
    static func referenceDisclosure(bundle: Bundle = .main) -> String {
        text("Only the reference is shown. Its destination has not been opened.", bundle: bundle)
    }

    static func multiImageDisclosure(bundle: Bundle = .main) -> String {
        text("Showing one image from a multi-image item. Copying the item keeps its complete content.", bundle: bundle)
    }

    static func pdfPageDisclosure(
        pageNumber: Int = 1,
        pageCount: Int,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        String(
            format: text("Showing PDF page %@ of %@. Copying the item keeps its complete content.", bundle: bundle),
            LocalizedCountPresentation.number(pageNumber, locale: locale),
            LocalizedCountPresentation.number(pageCount, locale: locale)
        )
    }

    static func pdfPageAccessibilityLabel(
        pageNumber: Int = 1,
        pageCount: Int,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        String(
            format: text("PDF preview, page %@ of %@", bundle: bundle),
            LocalizedCountPresentation.number(pageNumber, locale: locale),
            LocalizedCountPresentation.number(pageCount, locale: locale)
        )
    }

    static func pdfPageCaption(
        pageNumber: Int,
        pageCount: Int,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        String(
            format: text("Page %@ of %@", bundle: bundle),
            LocalizedCountPresentation.number(pageNumber, locale: locale),
            LocalizedCountPresentation.number(pageCount, locale: locale)
        )
    }

    static func copyCount(
        _ count: UInt64,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        String(
            format: text("Copied %@×", bundle: bundle),
            count.formatted(.number.locale(locale))
        )
    }

    static func imageDimensions(
        width: Int,
        height: Int,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        String(
            format: text("Image preview, %@ by %@ pixels", bundle: bundle),
            LocalizedCountPresentation.number(width, locale: locale),
            LocalizedCountPresentation.number(height, locale: locale)
        )
    }
}
