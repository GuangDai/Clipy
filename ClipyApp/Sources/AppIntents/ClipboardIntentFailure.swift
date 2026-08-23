/// One localized, content-free failure vocabulary for every App Intent.
/// Associated IDs, query text, titles, type identifiers, bytes, and paths are
/// deliberately discarded at this user-facing boundary (V2-05 §7.3; X.7).
import Foundation
import HistoryCore

enum ClipboardIntentFailure:
    Error,
    LocalizedError,
    CustomLocalizedStringResourceConvertible,
    Equatable
{
    case invalidRequest
    case permissionDenied
    case itemUnavailable
    case temporarilyUnavailable
    case clipboardUnavailable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .invalidRequest:
            "The clipboard request is invalid."
        case .permissionDenied:
            "Clipboard access is not allowed."
        case .itemUnavailable:
            "The clipboard item is no longer available."
        case .temporarilyUnavailable:
            "Clipboard history is temporarily unavailable."
        case .clipboardUnavailable:
            "The clipboard could not be updated."
        }
    }

    var errorDescription: String? {
        String(localized: localizedStringResource)
    }

    static func map(_ error: any Error) -> Self {
        if let failure = error as? Self {
            return failure
        }
        guard let failure = error as? ExternalFailure else {
            return .clipboardUnavailable
        }
        switch failure {
        case .unauthorized, .connectionRevoked:
            return .permissionDenied
        case .requestDenied(.invalidInput),
             .history(.invalidInput(.invalidRegularExpression)),
             .history(.invalidInput(.invalidPageLimit)),
             .history(.invalidInput(.invalidSearchTerm)):
            return .invalidRequest
        case .notFound:
            return .itemUnavailable
        case .requestDenied(.rateLimited),
             .history,
             .temporarilyUnavailable,
             .persistence,
             .auditCompactedBefore:
            return .temporarilyUnavailable
        }
    }
}
