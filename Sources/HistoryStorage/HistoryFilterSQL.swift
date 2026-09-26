/// History-wide family/pin selection, applied before bounded row projection.
/// Effective content is selected by currentContentID; immutable old revisions
/// must not make a row appear in a family it no longer contains.
import ClipboardFormats
import Foundation
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
        if let source = filter.sourceApplication {
            guard let lastSource = row.lastSource,
                  asciiLowercase(lastSource).range(of: asciiLowercase(source), options: .literal) != nil
            else { return false }
        }
        if let sourceIDs = filter.sourceApplicationIDs {
            guard let lastSource = row.lastSource,
                  sourceIDs.contains(where: { $0.utf8.elementsEqual(lastSource.utf8) })
            else { return false }
        }
        if let after = filter.copiedAfter, row.lastCopiedAt < after { return false }
        if let before = filter.copiedBefore, row.lastCopiedAt >= before { return false }
        if filter.type == .all { return true }
        let types = row.typeIdentifiers.map(ClipboardFormatIdentifier.init(rawValue:))
        let family: HistoryContentType?
        if types.contains(where: images.contains) { family = .images }
        else if types.contains(where: links.contains) { family = .links }
        else if types.contains(where: text.contains) { family = .text }
        else { family = nil }
        return family == filter.type
    }

    /// Keep query metadata bounded before opening a read snapshot. Invalid
    /// timestamps must not reach SQLite's REAL bindings or cursor encoding.
    internal static func validate(_ filter: HistoryFilter, limits: HistoryLimits) throws {
        if let source = filter.sourceApplication,
           source.utf8.count > limits.maximumSourceApplicationObservationUTF8Bytes {
            throw HistoryFailure.invalidInput(.invalidSearchTerm)
        }
        if let sourceIDs = filter.sourceApplicationIDs {
            guard sourceIDs.count <= 64 else {
                throw HistoryFailure.invalidInput(.invalidSearchTerm)
            }
            var totalBytes = 0
            for identifier in sourceIDs {
                let bytes = identifier.utf8.count
                guard bytes <= limits.maximumSourceApplicationObservationUTF8Bytes else {
                    throw HistoryFailure.invalidInput(.invalidSearchTerm)
                }
                totalBytes += bytes
            }
            guard totalBytes <= limits.maximumSearchTermUTF8Bytes else {
                throw HistoryFailure.invalidInput(.invalidSearchTerm)
            }
        }
        guard filter.copiedAfter.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
              filter.copiedBefore.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true
        else { throw HistoryFailure.invalidInput(.invalidTimestamp) }
    }

    /// SQLite's built-in lower() folds only ASCII. The matcher fixture path
    /// uses the same rule, including literal treatment of Unicode and SQL
    /// wildcard characters in a caller-supplied bundle-identifier substring.
    private static func asciiLowercase(_ value: String) -> String {
        String(decoding: value.utf8.map { byte in
            (65...90).contains(byte) ? byte + 32 : byte
        }, as: UTF8.self)
    }

    internal static func predicate(_ filter: HistoryFilter) -> (sql: String, bindings: [SQLiteValue]) {
        var clauses: [String] = []
        var bindings: [SQLiteValue] = []
        if filter.pinnedOnly { clauses.append("pinOrdinal IS NOT NULL") }
        if let source = filter.sourceApplication {
            clauses.append("instr(lower(lastSource), lower(?)) > 0")
            bindings.append(.text(source))
        }
        if let sourceIDs = filter.sourceApplicationIDs {
            if sourceIDs.isEmpty {
                clauses.append("0")
            } else {
                let placeholders = Array(repeating: "?", count: sourceIDs.count).joined(separator: ",")
                clauses.append("lastSource IN (\(placeholders))")
                bindings += sourceIDs.map(SQLiteValue.text)
            }
        }
        if let after = filter.copiedAfter {
            clauses.append("lastCopiedAt >= ?")
            bindings.append(.real(after.timeIntervalSinceReferenceDate))
        }
        if let before = filter.copiedBefore {
            clauses.append("lastCopiedAt < ?")
            bindings.append(.real(before.timeIntervalSinceReferenceDate))
        }
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

    /// Metadata predicates prune a request's SQLite batch before projection
    /// decoding. Every result remains a necessary condition: text and Unicode
    /// application matching stay with the expression matcher, and NOT may only
    /// invert a predicate that SQLite evaluates exactly (03b §8; V2-09 §4).
    internal static func expressionPredicate(
        _ node: HistorySearchExpression.Node
    ) -> (sql: String, bindings: [SQLiteValue]) {
        func collect(
            _ node: HistorySearchExpression.Node,
            conjunction: Bool,
            into terms: inout [HistorySearchExpression.Node]
        ) {
            switch node {
            case .and(let lhs, let rhs) where conjunction,
                 .or(let lhs, let rhs) where !conjunction:
                collect(lhs, conjunction: conjunction, into: &terms)
                collect(rhs, conjunction: conjunction, into: &terms)
            default: terms.append(node)
            }
        }
        func compile(_ node: HistorySearchExpression.Node) -> (
            sql: String, bindings: [SQLiteValue], exact: Bool
        ) {
            switch node {
            case .all: return ("1", [], true)
            case .noMatch: return ("0", [], true)
            case .text, .application: return ("1", [], false)
            case .sourceID(let identifier):
                // Unknown sources evaluate to false, so NOT source-id also
                // includes unknown rows instead of inheriting SQL's NULL.
                return ("COALESCE(lastSource = ?, 0)", [.text(identifier)], true)
            case .copiedDate(let from, let until):
                let result = predicate(HistoryFilter(copiedAfter: from, copiedBefore: until))
                return (result.sql, result.bindings, true)
            case .type(let type):
                let result = predicate(HistoryFilter(type: type))
                return (result.sql, result.bindings, true)
            case .pinned: return ("pinOrdinal IS NOT NULL", [], true)
            case .and, .or:
                let conjunction: Bool
                if case .and = node { conjunction = true } else { conjunction = false }
                // A legal sequence of 128 adjacent terms creates a deep
                // left-associated AST. Flatten equal operators so SQL parser
                // stack depth follows grouping, not the number of terms.
                var terms: [HistorySearchExpression.Node] = []
                collect(node, conjunction: conjunction, into: &terms)
                var clauses: [String] = []
                var bindings: [SQLiteValue] = []
                var exact = true
                for term in terms {
                    let result = compile(term)
                    switch term {
                    case .or where conjunction, .and where !conjunction:
                        clauses.append("(\(result.sql))")
                    default: clauses.append(result.sql)
                    }
                    bindings += result.bindings
                    exact = exact && result.exact
                }
                return (clauses.joined(separator: conjunction ? " AND " : " OR "), bindings, exact)
            case .not(let child):
                let result = compile(child)
                return result.exact ? ("NOT (\(result.sql))", result.bindings, true) : ("1", [], false)
            }
        }
        let result = compile(node)
        return (result.sql, result.bindings)
    }
}
