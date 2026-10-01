/// Explicit expression search extends the §8 literal matcher with Boolean
/// and metadata predicates. Requests retain the default History ordering and
/// the same bounded row batches, page window and cancellation checkpoints.
import Foundation
import HistoryCore

/// One request's necessary FTS condition and its bounded posting proof.
/// Readers reuse this choice inside that request's existing SQLite snapshot.
internal typealias SearchCandidateSelection = (expression: String, isSparse: Bool)

internal indirect enum PreparedSearchExpression {
    case all
    case noMatch
    case text(ExactLiteralMatcher)
    case application(ExactLiteralMatcher)
    case sourceID(String)
    case copiedDate(from: Date?, until: Date?)
    case type(HistoryContentType)
    case pinned
    case and(Self, Self)
    case or(Self, Self)
    case not(Self)

    init(_ node: HistorySearchExpression.Node) {
        switch node {
        case .all: self = .all
        case .noMatch: self = .noMatch
        case .text(let term): self = .text(ExactLiteralMatcher(term: term))
        case .application(let term): self = .application(ExactLiteralMatcher(term: term))
        case .sourceID(let identifier): self = .sourceID(identifier)
        case .copiedDate(let from, let until): self = .copiedDate(from: from, until: until)
        case .type(let type): self = .type(type)
        case .pinned: self = .pinned
        case .and(let lhs, let rhs): self = .and(Self(lhs), Self(rhs))
        case .or(let lhs, let rhs): self = .or(Self(lhs), Self(rhs))
        case .not(let child): self = .not(Self(child))
        }
    }

    /// Only necessary positive text grams may reduce the candidate set.
    /// Negation cannot invert an approximate posting match; metadata-only
    /// OR branches likewise need rows without any text posting.
    static func candidateExpression(
        _ node: HistorySearchExpression.Node, in database: SQLiteDatabase
    ) throws -> SearchCandidateSelection? {
        var probeResults: [Data: Bool] = [:]
        return try candidateExpression(node, in: database, probeResults: &probeResults)
    }

    static func candidateExpression(
        _ node: HistorySearchExpression.Node, in database: SQLiteDatabase, probeResults: inout [Data: Bool]
    ) throws -> SearchCandidateSelection? {
        try candidateExpression(node, in: database, checkingSparsity: true, probeResults: &probeResults)
    }

    private static func candidateExpression(
        _ node: HistorySearchExpression.Node, in database: SQLiteDatabase, checkingSparsity: Bool,
        probeResults: inout [Data: Bool]
    ) throws -> SearchCandidateSelection? {
        switch node {
        case .text(let term):
            guard let expression = SQLiteSearchIndex.matchExpression(term: term, mode: .exact) else { return nil }
            let isSparse = checkingSparsity
                ? try SQLiteSearchIndex.prefersSparseCandidates(expression: expression, in: database,
                                                               probeResults: &probeResults) : false
            return (expression, isSparse)
        case .and(let lhs, let rhs):
            // Every hit must satisfy both operands. A sparse necessary
            // condition on either side therefore bounds candidate decoding,
            // even when the caller wrote a common term first. Do not reorder
            // the matcher: its original left operand still owns presentation.
            // Keep one condition rather than expanding a long AND into a
            // deeply nested FTS intersection or reprobing each dense prefix.
            let left = try candidateExpression(lhs, in: database, probeResults: &probeResults)
            if left?.isSparse == true { return left }
            let right = try candidateExpression(rhs, in: database, probeResults: &probeResults)
            return right?.isSparse == true ? right : (left ?? right)
        case .or:
            var branches: [HistorySearchExpression.Node] = []
            collectOrBranches(node, into: &branches)
            var expressions: [String] = []
            for branch in branches {
                // The union, rather than each leaf or left-associated OR
                // prefix, needs a posting proof. AND branches still select
                // their own necessary sparse operand before joining it.
                guard let candidate = try candidateExpression(branch, in: database, checkingSparsity: false,
                                                              probeResults: &probeResults) else {
                    return nil
                }
                expressions.append(candidate.expression)
            }
            // Leaves contain only AND-ed grams; FTS AND binds before OR.
            // Flatten the union rather than nesting every left-associated OR.
            let expression = expressions.joined(separator: " OR ")
            // Sparse branches do not prove their union is sparse. Count the
            // actual union under the same 4,097-output probe as ordinary FTS.
            let isSparse = checkingSparsity
                ? try SQLiteSearchIndex.prefersSparseCandidates(expression: expression, in: database,
                                                               probeResults: &probeResults) : false
            return (expression, isSparse)
        default: return nil
        }
    }

    private static func collectOrBranches(
        _ node: HistorySearchExpression.Node, into branches: inout [HistorySearchExpression.Node]
    ) {
        if case .or(let lhs, let rhs) = node {
            collectOrBranches(lhs, into: &branches)
            collectOrBranches(rhs, into: &branches)
        } else {
            branches.append(node)
        }
    }

    func match(_ row: SearchCorpusRow) -> (matches: Bool, presentation: SearchWorker.DeferredSearchPresentation?) {
        match(row, anySource: { _, _, predicate in row.lastSource.map(predicate) ?? false })
    }

    private func match(
        _ row: SearchCorpusRow,
        anySource: (HistoryItemID, String?, (String) -> Bool) throws -> Bool
    ) rethrows -> (matches: Bool, presentation: SearchWorker.DeferredSearchPresentation?) {
        switch self {
        case .all: return (true, nil)
        case .noMatch: return (false, nil)
        case .text(let matcher):
            if let found = matcher.firstMatch(in: row.title) {
                return (true, .ready(SearchPresentation(snippet: nil, matchedRanges: [
                    UTF16TextRange(location: found.utf16Offset, length: found.utf16Length),
                ])))
            }
            if let found = matcher.firstMatch(in: row.searchBody) {
                return (true, .bodyExcerpt(
                    characterRanges: [], maximumCharacters: nil, bodySuffixWasOmitted: false,
                    utf16Range: UTF16TextRange(location: found.utf16Offset, length: found.utf16Length)
                ))
            }
            return (false, nil)
        case .application(let matcher):
            return (try anySource(row.id, nil) { matcher.firstMatch(in: $0) != nil }, nil)
        case .sourceID(let identifier):
            return (try anySource(row.id, identifier) { $0.utf8.elementsEqual(identifier.utf8) }, nil)
        case .copiedDate(let from, let until):
            return ((from.map { row.lastCopiedAt >= $0 } ?? true)
                    && (until.map { row.lastCopiedAt < $0 } ?? true), nil)
        case .type(let type): return (HistoryFilterSQL.admits(row, filter: HistoryFilter(type: type)), nil)
        case .pinned: return (row.pinOrdinal != nil, nil)
        case .not(let child): return (try !child.match(row, anySource: anySource).matches, nil)
        case .and(let lhs, let rhs):
            let left = try lhs.match(row, anySource: anySource)
            guard left.matches else { return (false, nil) }
            let right = try rhs.match(row, anySource: anySource)
            return (right.matches, right.matches ? (left.presentation ?? right.presentation) : nil)
        case .or(let lhs, let rhs):
            let left = try lhs.match(row, anySource: anySource)
            if left.matches { return left }
            return try rhs.match(row, anySource: anySource)
        }
    }

    /// SQL search evaluates source leaves against ANY recorded copy source.
    /// Negation wraps that complete Boolean, not an individual source row.
    /// Other leaves keep their existing pure matcher/presentation behavior.
    func match(
        _ row: SearchCorpusRow, sources: SQLiteExpressionSources
    ) throws -> (matches: Bool, presentation: SearchWorker.DeferredSearchPresentation?) {
        try match(row, anySource: { item, identifier, predicate in
            try sources.contains(item, identifier: identifier, matching: predicate)
        })
    }
}

extension SearchWorker {
    internal func evaluateExpression(
        _ expression: PreparedSearchExpression,
        in corpus: SearchCorpusSnapshot,
        directive: ScanDirective,
        work: SearchWorkCounter? = nil,
        sources: SQLiteExpressionSources? = nil
    ) async throws -> EvaluationResult {
        var evaluated: [EvaluatedRow] = []
        var tracker = OrderPreservingScanTracker(directive: directive)
#if DEBUG
        var processed = 0
        var matches = 0
#endif
        for (offset, row) in corpus.rows.enumerated() {
            try await scanCheckpoint(.expression, beforeRowAt: offset)
            work?.rowsEvaluated += 1
#if DEBUG
            processed += 1
#endif
            let result = try sources.map { try expression.match(row, sources: $0) } ?? expression.match(row)
            guard result.matches else { continue }
            work?.matchesFound += 1
#if DEBUG
            matches += 1
#endif
            let anchor = Self.defaultOrderAnchor(for: row)
            tracker.appendIfRetained(
                EvaluatedRow(corpusRow: row, search: result.presentation, anchor: anchor), to: &evaluated
            )
            if !tracker.recordMatch(ofRow: anchor) { break }
        }
        try Task.checkCancellation()
#if DEBUG
        return EvaluationResult(rows: evaluated, debugRowsProcessed: processed, debugMatchedRows: matches)
#else
        return EvaluationResult(rows: evaluated)
#endif
    }
}
