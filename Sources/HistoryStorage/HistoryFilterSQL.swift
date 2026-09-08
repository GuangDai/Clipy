/// History-wide family/pin selection, applied before bounded row projection.
/// Effective content is selected by currentContentID; immutable old revisions
/// must not make a row appear in a family it no longer contains.
import ClipboardFormats
import HistoryCore

internal enum HistoryFilterSQL {
    private static let images: [ClipboardFormatIdentifier] = [.image, .png, .jpeg, .tiff, .heic, .heif, .gif, .bmp]
    private static let links: [ClipboardFormatIdentifier] = [.url, .fileURL]
    private static let text: [ClipboardFormatIdentifier] = [
        .text, .plainText, .utf8PlainText, .utf16PlainText, .utf16ExternalPlainText,
        .html, .rtf, .flatRTFD,
    ]

    internal static func admits(_ row: SearchCorpusRow, filter: HistoryFilter) -> Bool {
        if filter.pinnedOnly && row.pinOrdinal == nil { return false }
        if filter.type == .all { return true }
        let types = row.typeIdentifiers.map(ClipboardFormatIdentifier.init(rawValue:))
        let family: HistoryContentType?
        if types.contains(where: images.contains) { family = .images }
        else if types.contains(where: links.contains) { family = .links }
        else if types.contains(where: text.contains) { family = .text }
        else { family = nil }
        return family == filter.type
    }

    internal static func predicate(_ filter: HistoryFilter) -> (sql: String, bindings: [SQLiteValue]) {
        var clauses: [String] = []
        var bindings: [SQLiteValue] = []
        if filter.pinnedOnly { clauses.append("pinOrdinal IS NOT NULL") }
        func contains(_ identifiers: [ClipboardFormatIdentifier], negated: Bool = false) {
            // The (contentID, typeKey) uniqueness index bounds each lookup to
            // one current content value; only exact identifiers classify it.
            let placeholders = Array(repeating: "?", count: identifiers.count).joined(separator: ",")
            clauses.append("""
                \(negated ? "NOT " : "")EXISTS (
                    SELECT 1 FROM representations
                    WHERE contentID = history_items.currentContentID
                      AND typeKey IN (\(placeholders))
                )
                """)
            bindings += identifiers.map { .text($0.rawValue) }
        }
        switch filter.type {
        case .all: break
        case .images:
            contains(images)
        case .links:
            contains(images, negated: true)
            contains(links)
        case .text:
            contains(images, negated: true)
            contains(links, negated: true)
            contains(text)
        }
        return (clauses.isEmpty ? "1" : clauses.joined(separator: " AND "), bindings)
    }
}
