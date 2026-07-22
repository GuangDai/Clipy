import Foundation

/// The complete typed failure vocabulary of the caller interface.
///
/// Storage maps package-only Domain rejections and platform errors to this
/// vocabulary at one boundary. Public failures contain no raw SQL, model
/// object, file path, or stringly typed reason.
///
/// docs/03b-instruction-set.md §10
public enum HistoryFailure: Error, Sendable, Equatable {
    /// The referenced item no longer exists in retained history.
    case notFound(HistoryItemID)
    /// The caller's expected Content Version no longer matches the durable one.
    case staleContent(
        expected: ContentVersion,
        current: ContentVersion
    )
    /// A request or draft failed caller-input validation.
    case invalidInput(InvalidInputReason)
    /// A pin placement request referenced an invalid target/anchor pair.
    case invalidPinnedPlacement(PinnedPlacementFailure)
    /// The referenced Revision does not exist on the target item.
    case revisionNotFound(RevisionID)
    /// A page cursor or observation snapshot predates the retained window.
    case snapshotExpired(current: ChangePosition)
    /// A configured capacity limit rejected the action.
    case capacityExceeded(CapacityKind)
    /// The action cannot complete right now; the caller may retry later.
    case temporarilyUnavailable(UnavailableReason)
    /// The persistence layer failed to complete the durable transaction.
    case persistence(PersistenceFailure)
}

/// Caller-input validation rejections.
///
/// docs/03b-instruction-set.md §10
public enum InvalidInputReason: Sendable, Equatable {
    /// A capture carried no representations.
    case emptyCapture
    /// A capture carried two representations with the same type identifier.
    case duplicateRepresentationType(String)
    /// A representation type identifier cannot be stored by the interface.
    case unsupportedRepresentationType(String)
    /// A capture exceeded the configured representation count limit.
    case representationLimit
    /// A capture exceeded the configured byte limit.
    case byteLimit
    /// A Revision Draft is not coherent with its target Revision.
    case incoherentRevisionDraft
    /// A search term is not a valid regular expression.
    case invalidRegularExpression
    /// A browse/observation limit is outside the allowed range.
    case invalidPageLimit
    /// A thumbnail pixel size is outside the allowed range.
    case invalidPixelSize
    /// A retention policy configuration is not valid.
    case invalidRetentionPolicy
    /// A search term is empty or otherwise not searchable.
    case invalidSearchTerm
}

/// Pin placement rejections.
///
/// docs/03b-instruction-set.md §10
public enum PinnedPlacementFailure: Sendable, Equatable {
    /// The item to be pinned no longer exists.
    case targetMissing
    /// The placement anchor is missing or is not itself pinned.
    case anchorMissingOrUnpinned
    /// The target and the anchor are the same item.
    case targetEqualsAnchor
}

/// The configured capacity dimension that rejected an action.
///
/// docs/03b-instruction-set.md §10
public enum CapacityKind: Sendable, Equatable {
    /// The retained item count limit.
    case retainedItems
    /// The per-item Revision count limit.
    case revisionCount
    /// The per-item Revision byte limit.
    case revisionBytes
    /// The per-item copy occurrence count limit.
    case copyCount
    /// The coherence token budget.
    case coherenceToken
}

/// Why an action is temporarily unavailable.
///
/// docs/03b-instruction-set.md §10
public enum UnavailableReason: Sendable, Equatable {
    /// A fact proof required for the action is being rebuilt.
    case factProof
    /// The dedup index is being rebuilt.
    case dedupIndexRebuild
}

/// Persistence-layer failures, mapped at the storage boundary.
///
/// docs/03b-instruction-set.md §10
public enum PersistenceFailure: Sendable, Equatable {
    /// The store could not be opened.
    case openStore
    /// A stored value failed decoding or integrity checks.
    case corruptStoredValue
    /// A storage invariant was violated.
    case invariantViolation
    /// The durable transaction failed.
    case transaction
}
