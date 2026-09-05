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

    internal init(
        _ request: HistoryBrowseRequest,
        limits: HistoryLimits
    ) throws {
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
        self.term = term
        self.mode = mode
    }
}
