/// HistoryRowFiltering.swift — the panel's client-side row-filter vocabulary
/// (type families + pinned-only), the single UTI classification source shared
/// by the filter and the row's fallback SF Symbol, and the composition-root
/// seam that loads source-application icons.
///
/// Filtering is a FRONT-END narrowing over the already-loaded rows (product
/// decision: no storage-level type query in v1). It never restarts search,
/// observation, or pagination — docs/04-coherence.md §5's replacement pages
/// remain the only row source, and pagination keeps walking the unfiltered
/// stream. The exact UTI vocabulary below is shared by
/// `HistoryRowKind.classify` and `HistoryRowView.typeSymbol` so the filter
/// and the row's type fallback always agree on a row's family.
import ClipboardFormats
import CoreGraphics
import Foundation
import HistoryCore

/// The user-facing type filter in the panel header (All/Text/Images/Links).
/// Front-end only: it narrows which loaded rows render without touching the
/// History query. Raw values are stable strings so a future preference can
/// persist the selection without a migration. Package (GOV-3): panel-header
/// vocabulary only — the header control, the view state it binds, and owner
/// tests are all in-package; ClipyApp never names the filter.
package enum HistoryTypeFilter: String, CaseIterable, Sendable {
    case all
    case text
    case images
    case links
}

/// The representation family of one loaded row, classified from its effective
/// type identifiers. Priority matches the row's fallback symbol
/// (image > link > text): a row carrying BOTH a URL and its plain-text title
/// is a link, not a text clipping.
package enum HistoryRowKind: Sendable, Equatable {
    case text
    case link
    case image
    case other

    /// Exact image identifiers the row maps to the "photo" symbol. This UI
    /// family does not imply decoder support (01 §2 stable-facts ownership).
    package static let imageTypes: [ClipboardFormatIdentifier] = [
        .image, .png, .jpeg, .tiff, .heic, .heif, .gif, .bmp,
    ]

    /// URL UTIs — the row's "link" symbol set.
    package static let linkTypes: [ClipboardFormatIdentifier] = [
        .url, .fileURL,
    ]

    /// Rich-text UTIs — the row's "doc.text" symbol set. For filtering these
    /// are the text FAMILY even though the fallback symbol distinguishes
    /// them from plain text.
    package static let richTextTypes: [ClipboardFormatIdentifier] = [
        .html, .rtf, .flatRTFD,
    ]

    /// Plain-text UTIs — text rows the fallback renders as the generic
    /// clipboard document. Mirrors ClipboardFormats' exact text identifiers.
    package static let plainTextTypes: [ClipboardFormatIdentifier] = [
        .text, .plainText, .utf8PlainText, .utf16PlainText, .utf16ExternalPlainText,
    ]

    /// Exact membership: a similar identifier prefix does not establish UTI
    /// conformance. Unknown identifiers stay opaque (01 §2).
    package static func matchesAny(
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
    package static func classify(
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

package extension HistoryTypeFilter {
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
public struct SourceIconProvider: Sendable {
    public var loadIcon: @MainActor @Sendable (String) -> CGImage?

    public init(loadIcon: @escaping @MainActor @Sendable (String) -> CGImage?) {
        self.loadIcon = loadIcon
    }

    public static let none: SourceIconProvider = SourceIconProvider(loadIcon: { _ in nil })
}
