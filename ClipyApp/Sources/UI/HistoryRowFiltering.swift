/// Panel filter labels, row symbols, and the source-application icon seam.
/// Filters are passed to History before ranking/pagination; row classification
/// here keeps the visible family and fallback symbol in agreement.
import ClipboardFormats
import CoreGraphics
import Foundation
import HistoryCore

/// The user-facing header selection maps directly to the History query.
enum HistoryTypeFilter: String, CaseIterable, Sendable {
    case all
    case text
    case images
    case links
}

/// The representation family of one loaded row, classified from its effective
/// type identifiers. Priority matches the row's fallback symbol
/// (image > link > text): a row carrying BOTH a URL and its plain-text title
/// is a link, not a text clipping.
enum HistoryRowKind: Sendable, Equatable {
    case text
    case link
    case image
    case other

    /// Exact image identifiers the row maps to the "photo" symbol. This UI
    /// family does not imply decoder support (01 §2 stable-facts ownership).
    static let imageTypes: [ClipboardFormatIdentifier] = [
        .image, .png, .jpeg, .tiff, .heic, .heif, .gif, .bmp,
    ]

    /// URL UTIs — the row's "link" symbol set.
    static let linkTypes: [ClipboardFormatIdentifier] = [
        .url, .fileURL,
    ]

    /// Rich-text UTIs — the row's "doc.text" symbol set. For filtering these
    /// are the text FAMILY even though the fallback symbol distinguishes
    /// them from plain text.
    static let richTextTypes: [ClipboardFormatIdentifier] = [
        .html, .rtf, .flatRTFD,
    ]

    /// Plain-text UTIs — text rows the fallback renders as the generic
    /// clipboard document. Mirrors ClipboardFormats' exact text identifiers.
    static let plainTextTypes: [ClipboardFormatIdentifier] = [
        .text, .plainText, .utf8PlainText, .utf16PlainText, .utf16ExternalPlainText,
    ]

    /// Exact membership: a similar identifier prefix does not establish UTI
    /// conformance. Unknown identifiers stay opaque (01 §2).
    static func matchesAny(
        _ typeIdentifiers: [String],
        types: [ClipboardFormatIdentifier]
    ) -> Bool {
        typeIdentifiers.contains { identifier in
            types.contains(ClipboardFormatIdentifier(rawValue: identifier))
        }
    }

    /// The row's family in fallback-symbol priority order; a row with no
    /// recognizable representation is `.other` and passes only the `.all`
    /// filter.
    static func classify(
        effectiveTypeIdentifiers: [String]
    ) -> HistoryRowKind {
        if matchesAny(effectiveTypeIdentifiers, types: imageTypes) {
            return .image
        }
        if matchesAny(effectiveTypeIdentifiers, types: linkTypes) {
            return .link
        }
        if matchesAny(effectiveTypeIdentifiers, types: richTextTypes)
            || matchesAny(effectiveTypeIdentifiers, types: plainTextTypes) {
            return .text
        }
        return .other
    }
}

extension HistoryTypeFilter {
    var contentType: HistoryContentType {
        switch self {
        case .all: .all
        case .text: .text
        case .images: .images
        case .links: .links
        }
    }

    /// Whether one loaded row passes this filter. The families are the
    /// user-recognizable clipboard kinds, not an exhaustive partition:
    /// `.other` rows (PDFs, files, app-specific types) pass only `.all`.
    func admits(_ row: HistoryRow) -> Bool {
        switch self {
        case .all:
            true
        case .text:
            HistoryRowKind.classify(effectiveTypeIdentifiers: row.typeIdentifiers) == .text
        case .images:
            HistoryRowKind.classify(effectiveTypeIdentifiers: row.typeIdentifiers) == .image
        case .links:
            HistoryRowKind.classify(effectiveTypeIdentifiers: row.typeIdentifiers) == .link
        }
    }
}

/// The composition-root seam that loads one source application's icon by
/// bundle identifier. `NSWorkspace` is AppKit and PresentationUI must not
/// import it (docs/01-architecture.md §6 keeps PresentationUI
/// Foundation/SwiftUI-only), so the app injects this value-typed loader
/// instead. `.none` keeps previews and tests icon-free without a nil store.
struct SourceIconProvider: Sendable {
    var loadIcon: @MainActor @Sendable (String) -> CGImage?
    var loadName: @MainActor @Sendable (String) -> String?

    init(loadIcon: @escaping @MainActor @Sendable (String) -> CGImage?) {
        self.init(loadIcon: loadIcon, loadName: { _ in nil })
    }

    init(loadIcon: @escaping @MainActor @Sendable (String) -> CGImage?,
         loadName: @escaping @MainActor @Sendable (String) -> String?) {
        self.loadIcon = loadIcon
        self.loadName = loadName
    }

    static let none = SourceIconProvider(loadIcon: { _ in nil })
}
