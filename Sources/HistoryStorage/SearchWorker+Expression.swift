/// Explicit expression search extends the §8 literal matcher with Boolean
/// and metadata predicates. Requests retain the default History ordering and
/// the same bounded row batches, page window and cancellation checkpoints.
import Foundation
import HistoryCore

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
    static func candidateExpression(_ node: HistorySearchExpression.Node) -> String? {
        switch node {
        case .text(let term): return SQLiteSearchIndex.matchExpression(term: term, mode: .exact)
        case .and(let lhs, let rhs):
            // One required operand is sufficient. Keeping a single necessary
            // posting avoids expanding 128 adjacent terms into thousands of
            // grams and a deeply nested FTS expression; the row matcher still
            // evaluates every Boolean condition.
            return candidateExpression(lhs) ?? candidateExpression(rhs)
        case .or(let lhs, let rhs):
            guard let left = candidateExpression(lhs), let right = candidateExpression(rhs) else { return nil }
            // Leaves contain only AND-ed grams; FTS AND binds before OR.
            // Flatten the union rather than nesting every left-associated OR.
            return "\(left) OR \(right)"
        default: return nil
        }
    }

    func match(_ row: SearchCorpusRow) -> (matches: Bool, presentation: SearchWorker.DeferredSearchPresentation?) {
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
            return (row.lastSource.map { matcher.firstMatch(in: $0) != nil } ?? false, nil)
        case .sourceID(let identifier):
            return (row.lastSource.map { $0.utf8.elementsEqual(identifier.utf8) } ?? false, nil)
        case .copiedDate(let from, let until):
            return ((from.map { row.lastCopiedAt >= $0 } ?? true)
                    && (until.map { row.lastCopiedAt < $0 } ?? true), nil)
        case .type(let type): return (HistoryFilterSQL.admits(row, filter: HistoryFilter(type: type)), nil)
        case .pinned: return (row.pinOrdinal != nil, nil)
        case .not(let child): return (!child.match(row).matches, nil)
        case .and(let lhs, let rhs):
            let left = lhs.match(row)
            guard left.matches else { return (false, nil) }
            let right = rhs.match(row)
            return (right.matches, right.matches ? (left.presentation ?? right.presentation) : nil)
        case .or(let lhs, let rhs):
            let left = lhs.match(row)
            return left.matches ? left : rhs.match(row)
        }
    }
}

extension SearchWorker {
    internal func evaluateExpression(
        _ expression: PreparedSearchExpression,
        in corpus: SearchCorpusSnapshot,
        directive: ScanDirective,
        work: SearchWorkCounter? = nil
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
            let result = expression.match(row)
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
