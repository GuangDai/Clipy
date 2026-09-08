import Foundation
import HistoryCore

/// V2-09 §4: persistent candidate postings, never a second search matcher.
/// FTS5 compresses reversible scalar-gram tokens; its word tokenizer never
/// receives clipboard text. Every candidate still uses the owning exact,
/// regexp or Fuse matcher and the original UTF-8 projection for presentation.
internal enum SQLiteSearchIndex {
    /// The writer calls this after inserting/updating the item's projection,
    /// in the same transaction as History/Gateway state and ChangePosition.
    internal static func replace(
        itemID: HistoryItemID, title: String, body: String, in database: SQLiteDatabase
    ) throws {
        let tokens = documentTokens(title: title, body: body)
        try database.execute("""
            INSERT OR REPLACE INTO history_search(rowid, grams)
            SELECT rowid, ? FROM history_items WHERE id = ?
            """, bindings: [.text(tokens), .text(itemID.rawValue.uuidString)])
    }

    /// A nil expression means the existing bounded scan is required. Exact
    /// ANDs necessary grams (at most 16); fuzzy ORs every possible matching
    /// scalar. No caller-controlled text enters FTS query syntax directly.
    internal static func matchExpression(term: String, mode: SearchMode) -> String? {
        guard !term.isEmpty else { return nil }
        var indexedTerm = term
        if mode == .regexp {
            // A plain literal, optionally bounded by ^/$, is necessary text.
            // Escapes, flags, alternatives and quantifiers keep native scans.
            if indexedTerm.first == "^" { indexedTerm.removeFirst() }
            if indexedTerm.last == "$" { indexedTerm.removeLast() }
            let syntax = Set("\\.^$|?*+()[]{}".unicodeScalars)
            guard !indexedTerm.isEmpty,
                  !indexedTerm.unicodeScalars.contains(where: { syntax.contains($0) }) else { return nil }
        }
        let normalized = normalize(indexedTerm)
        if mode == .fuzzy {
            let scalars = Set(normalized.unicodeScalars.map { UInt64($0.value) + 1 })
            // A positive Fuse hit under its 0.7 error threshold has at least
            // one equal lowercased Character, hence a shared normalized
            // scalar. Preserve marks here: a combining-only Character can
            // be that sole equal Character. Unusually large queries scan.
            guard !scalars.isEmpty, scalars.count <= 128 else { return nil }
            return scalars.map { "f" + String($0, radix: 16) }.joined(separator: " OR ")
        }
        let scalars = normalized.unicodeScalars.filter { !isMark($0) }.map { UInt64($0.value) + 1 }
        guard !scalars.isEmpty else { return nil }
        let width = min(3, scalars.count)
        let count = scalars.count - width + 1
        // A subset of necessary grams stays a superset of true matches and
        // bounds the query even for the admitted 4,096-byte search term.
        let sampledCount = min(16, count)
        var grams: Set<UInt64> = []
        for sample in 0..<sampledCount {
            let offset = sampledCount == 1 ? 0 : sample * (count - 1) / (sampledCount - 1)
            var gram: UInt64 = 0
            for scalar in scalars[offset..<(offset + width)] { gram = (gram << 21) | scalar }
            grams.insert(gram)
        }
        return grams.map { "g" + String($0, radix: 16) }.joined(separator: " AND ")
    }

    /// Choose the driving table from limited posting reads. fts5vocab's row
    /// mode computes doc counts by traversing the entire posting list, even
    /// for a SELECT 1 existence check, so it is not used on this read path.
    /// Sparse searches visit only candidate items; dense ordered searches
    /// probe membership while walking recent rows.
    internal static func prefersSparseCandidates(expression: String, in database: SQLiteDatabase) throws -> Bool {
        if expression.contains(" OR ") {
            // Count actual union outputs, including overlap only once. OR
            // can stop as soon as the sparse threshold has been exceeded.
            return try hasAtMostSparseCandidateLimit(expression: expression, in: database)
        }
        var termCount = 0
        for token in expression.split(separator: " ") where token.first == "g" || token.first == "f" {
            termCount += 1
            // An AND result is a subset of every individual posting list.
            // A sparse constituent proves the whole expression sparse
            // without first computing its intersection with common terms.
            if try hasAtMostSparseCandidateLimit(expression: String(token), in: database) {
                return true
            }
        }
        guard termCount > 1 else { return false }
        // Common constituents do not imply a common intersection. Compute
        // it once here: leaving a sparse/empty intersection on the dense
        // correlated path would restart that work for every outer row.
        // Finding even the first AND result may traverse substantial postings;
        // LIMIT bounds outputs, not that internal intersection work.
        return try hasAtMostSparseCandidateLimit(expression: expression, in: database)
    }

    private static func hasAtMostSparseCandidateLimit(expression: String, in database: SQLiteDatabase) throws -> Bool {
        try Task.checkCancellation()
        let statement = try database.prepare(
            """
            SELECT count(*) FROM (
                SELECT rowid FROM history_search WHERE history_search MATCH ? LIMIT 4097
            )
            """,
            bindings: [.text(expression)]
        )
        defer { statement.finalize() }
        guard try statement.step() else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        try Task.checkCancellation()
        // SQLite counts only the limited subquery. One scalar crosses into
        // Swift, and the request's native progress callback remains active.
        return try statement.integer(at: 0) <= 4_096
    }

    /// Fuse counts edits in lowercased Characters. If any normalized scalar
    /// of a query Character is absent from every indexed field, that whole
    /// Character must cost an edit in every possible hit. The resulting
    /// score floor lets a full best-score page stop in default row order;
    /// postings remain only a necessary-condition proof, never the matcher.
    internal static func lowestPossibleFuzzyScore(term: String, in database: SQLiteDatabase) throws -> Double {
        let characters = Array(term.lowercased())
        guard !characters.isEmpty else { return 0 }
        var presence: [UInt32: Bool] = [:]
        var missing = 0
        for character in characters {
            var mustCostEdit = false
            for scalar in normalize(String(character)).unicodeScalars {
                let exists: Bool
                if let known = presence[scalar.value] {
                    exists = known
                } else {
                    let statement = try database.prepare(
                        "SELECT rowid FROM history_search WHERE history_search MATCH ? LIMIT 1",
                        bindings: [.text("f" + String(UInt64(scalar.value) + 1, radix: 16))]
                    )
                    defer { statement.finalize() }
                    exists = try statement.step()
                    presence[scalar.value] = exists
                }
                if !exists { mustCostEdit = true; break }
            }
            if mustCostEdit { missing += 1 }
        }
        return Double(missing) / Double(characters.count)
    }

    private static func documentTokens(title: String, body: String) -> String {
        var exact: Set<UInt64> = []
        var fuzzy: Set<UInt64> = []
        for text in [title, body] {
            var previous: UInt64 = 0
            var beforePrevious: UInt64 = 0
            for scalar in normalize(text).unicodeScalars {
                let value = UInt64(scalar.value) + 1
                fuzzy.insert(value)
                guard !isMark(scalar) else { continue }
                exact.insert(value)
                if previous != 0 { exact.insert((previous << 21) | value) }
                if beforePrevious != 0 {
                    exact.insert((beforePrevious << 42) | (previous << 21) | value)
                }
                beforePrevious = previous
                previous = value
            }
        }
        // Scalars use 21 bits, plus one so leading zero cannot conflate gram
        // lengths. Three scalars fit in 63 bits. This is a lossless encoding,
        // not a content hash, identity or probabilistic equality check.
        return (exact.map { "g" + String($0, radix: 16) }
            + fuzzy.map { "f" + String($0, radix: 16) }).joined(separator: " ")
    }

    private static func normalize(_ text: String) -> String {
        // Compatibility decomposition deliberately overincludes width and
        // ligature variants. Foundation's own locale-independent case fold
        // includes expansions, sigma and Kelvin; exact confirmation retains
        // `.literal` semantics. Removing marks only from exact grams avoids
        // normalization reordering across substring boundaries losing a hit.
        text.decomposedStringWithCompatibilityMapping
            .folding(options: .caseInsensitive, locale: nil)
            .decomposedStringWithCanonicalMapping
    }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: true
        default: false
        }
    }
}
