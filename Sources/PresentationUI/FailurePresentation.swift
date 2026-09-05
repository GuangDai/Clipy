/// FailurePresentation.swift — typed-failure → user-facing message mapping
/// (docs/03b-instruction-set.md §10; roadmap 05). Used by the panel failure
/// banner and the settings surfaces. Short, plain English; no raw payloads,
/// paths, or type identifiers leak into the strings.
import HistoryCore

/// Produces one-line user-facing messages for the typed `HistoryFailure`
/// vocabulary (docs/03b-instruction-set.md §10). The switch is complete over
/// every case — a new failure case is an owned source change that must be
/// answered here.
public enum FailurePresentation {

    /// The message for one typed failure.
    public static func message(for failure: HistoryFailure) -> String {
        switch failure {
        case .notFound:
            return "Item was removed"
        case .staleContent:
            return "Item changed while editing"
        case .invalidInput(let reason):
            return message(for: reason)
        case .invalidPinnedPlacement:
            return "The item to pin next to is no longer available"
        case .revisionNotFound:
            return "That revision was removed"
        case .snapshotExpired:
            return "Results changed — showing the latest page"
        case .capacityExceeded(let kind):
            return message(for: kind)
        case .thumbnailUnavailable:
            return "A thumbnail isn't available for this image"
        case .temporarilyUnavailable(let reason):
            return message(for: reason)
        case .persistence:
            return "History storage error"
        }
    }

    // MARK: - Nested-vocabulary messages (private)

    /// Caller-input validation rejections (docs/03b-instruction-set.md §10).
    private static func message(for reason: InvalidInputReason) -> String {
        switch reason {
        case .emptyCapture, .excludedFromHistory:
            // Capture-side rejections the capture loop swallows; surfaced
            // only if a manual path ever surfaces them.
            return "That content can't be kept in history"
        case .duplicateRepresentationType, .invalidTimestamp:
            return "That content can't be kept in history"
        case .unsupportedRepresentationType:
            return "That content isn't supported"
        case .representationLimit, .byteLimit:
            return "That content is too large to keep"
        case .incoherentRevisionDraft:
            return "Hiding every representation is not allowed"
        case .invalidRegularExpression:
            return "Invalid regular expression"
        case .invalidPageLimit, .invalidPixelSize:
            return "That request isn't valid"
        case .invalidRetentionPolicy:
            return "Pinned items exceed this budget. Unpin items or raise the budget."
        case .invalidSearchTerm:
            return "Search term not supported for this mode"
        }
    }

    /// Capacity rejections (docs/03b-instruction-set.md §10). The R2
    /// storage-budget case carries the settings-surface wording
    /// (docs/v2/V2-07-ux.md §5).
    private static func message(for kind: CapacityKind) -> String {
        switch kind {
        case .storageBytes:
            return "This budget can't be satisfied with the current history."
        case .retainedItems,
             .revisionCount,
             .revisionBytes,
             .copyCount,
             .coherenceToken,
             .thumbnailBytes:
            return "This action exceeds a history limit"
        }
    }

    /// Temporary-unavailability rejections (docs/03b-instruction-set.md §10)
    /// — retryable, so the message says so.
    private static func message(for reason: UnavailableReason) -> String {
        switch reason {
        case .factProof:
            return "History is busy. Try again shortly."
        case .dedupIndexRebuild:
            return "History is reindexing. Try again shortly."
        case .insufficientDiskSpace:
            return "Not enough disk space. Free some space and try again."
        case .searchEngineDeadline:
            return "Search is taking too long. Try again."
        }
    }
}
