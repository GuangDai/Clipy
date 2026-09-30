/// Search request admission performed before any operation-local context or
/// corpus exists (REVIEW Card 11A; docs/03b-instruction-set.md §8; 06 §2).
import Foundation
import HistoryCore

/// Immutable result of the caller-input checks shared by the Authority's
/// pre-I/O boundary and the SearchWorker's defensive boundary. It contains no
/// store facts and performs no I/O.
internal struct AdmittedSearchRequest {
    internal let term: String
    internal let mode: SearchMode
    internal let expression: HistorySearchExpression?

    /// Metadata/application-only expressions have no body consumer. Their
    /// SQLite batches should not copy or decode an unrelated text projection
    /// (03b §8; V2-09 §4). Text under NOT still needs the original body.
    internal var requiresSearchBody: Bool {
        guard !term.isEmpty else { return false }
        guard let expression else { return true }
        return Self.requiresSearchBody(expression.root)
    }

    private static func requiresSearchBody(_ node: HistorySearchExpression.Node) -> Bool {
        switch node {
        case .text: true
        case .and(let left, let right), .or(let left, let right):
            requiresSearchBody(left) || requiresSearchBody(right)
        case .not(let child): requiresSearchBody(child)
        default: false
        }
    }

    internal init(
        _ request: HistoryBrowseRequest,
        limits: HistoryLimits
    ) throws {
        try HistoryFilterSQL.validate(request.filter, limits: limits)
        guard case .search(let term, let mode) = request.kind else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        guard term.utf8.count <= limits.maximumSearchTermUTF8Bytes else {
            throw HistoryFailure.invalidInput(.invalidSearchTerm)
        }
        // Inspect only the first over-limit Character; counting the entire
        // rejected suffix adds work without changing fuzzy admission.
        if mode == .fuzzy,
           term.prefix(limits.maximumFuzzyQueryCharacters + 1).count
                > limits.maximumFuzzyQueryCharacters {
            throw HistoryFailure.invalidInput(.invalidSearchTerm)
        }
        if mode == .regexp, !term.isEmpty {
            guard term.count <= limits.maximumRegexpPatternCharacters,
                  !SearchWorker.containsRejectedPatternShape(term) else {
                throw HistoryFailure.invalidInput(.invalidRegularExpression)
            }
            do {
                _ = try NSRegularExpression(pattern: term)
            } catch {
                throw HistoryFailure.invalidInput(.invalidRegularExpression)
            }
        }
        if mode == .expression {
            do { expression = try HistorySearchExpression.parse(term) }
            catch { throw HistoryFailure.invalidInput(.invalidSearchTerm) }
        } else { expression = nil }
        self.term = term
        self.mode = mode
    }
}
