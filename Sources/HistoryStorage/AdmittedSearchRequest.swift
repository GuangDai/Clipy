/// Search request admission performed before any operation-local context or
/// corpus exists (REVIEW Card 11A; docs/architecture.md; 06 §2).
import Foundation
import HistoryCore

/// Immutable result of the caller-input checks shared by the Authority's
/// pre-I/O boundary and the SearchWorker's defensive boundary. It contains no
/// store facts and performs no I/O.
internal struct AdmittedSearchRequest {
    internal let term: String
    internal let mode: SearchMode
    internal let expression: HistorySearchExpression?
    internal let conditionExpression: HistorySearchExpression?

    internal var expressionRoot: HistorySearchExpression.Node? {
        if let expression, let conditionExpression { return .and(expression.root, conditionExpression.root) }
        return expression?.root ?? conditionExpression?.root
    }

    /// Metadata/application-only expressions have no body consumer. Their
    /// SQLite batches should not copy or decode an unrelated text projection
    /// (03b §8; V2-09 §4). Text under NOT still needs the original body.
    internal var requiresSearchBody: Bool {
        if !term.isEmpty, mode != .expression { return true }
        return expressionRoot.map(Self.requiresSearchBody) ?? false
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
        // Independent conditions travel in cursors as canonical DSL. Aliases
        // can expand during serialization; reject that excess before SQL,
        // rather than minting a continuation that its own decoder rejects.
        if let condition = request.conditionExpression,
           condition.serialized.utf8.count > limits.maximumSearchTermUTF8Bytes {
            throw HistoryFailure.invalidInput(.invalidSearchTerm)
        }
        let term: String
        let mode: SearchMode
        switch request.kind {
        case .search(let text, let searchMode): term = text; mode = searchMode
        case .recent where request.conditionExpression != nil: term = ""; mode = .exact
        case .recent: throw HistoryFailure.persistence(.invariantViolation)
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
        self.conditionExpression = request.conditionExpression
        self.term = term
        self.mode = mode
    }
}
