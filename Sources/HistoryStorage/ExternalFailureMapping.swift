/// Pure X-BEHAVIOR-1 classification for the seven frozen App Intents
/// operations. Owning spec: `V2-05` §5.1–§5.3/§7.3.1.
import HistoryCore

#if DEBUG
internal enum ExternalFailureDebugInstrumentation {
    @TaskLocal static var injectedFailure: HistoryFailure?
}
#endif

/// The operation fact needed by §7.3.1 P3. Keeping the seven cases closed
/// makes a future external operation an exhaustive mapping change.
internal enum ExternalHistoryOperationContext: Sendable {
    case readRecent
    case readSearch
    case readDetails
    case readPastePayload
    case managePin
    case manageUnpin
    case manageRemove
}

/// One caller failure and the exact metadata persisted for its failed audit
/// record. Only SearchWorker input rejection has different thrown and audit
/// classifications (§5.2 D35).
internal struct ExternalHistoryFailureMapping: Sendable, Equatable {
    internal let failure: ExternalFailure
    internal let auditFailureKind: ExternalFailureKindRaw
    internal let auditDenialReason: ExternalDenialReason?
}

/// Applies the frozen sibling precedence and search-only audit
/// reclassification without changing the underlying History failure.
internal func mapExternalHistoryFailure(
    _ source: HistoryFailure,
    for operation: ExternalHistoryOperationContext
) -> ExternalHistoryFailureMapping {
    switch source {
    case .notFound(let id):
        switch operation {
        case .readDetails, .readPastePayload, .manageUnpin, .manageRemove:
            return ExternalHistoryFailureMapping(
                failure: .notFound(id),
                auditFailureKind: .notFound,
                auditDenialReason: nil
            )
        case .readRecent, .readSearch, .managePin:
            return invariantMapping()
        }

    case .persistence(let reason):
        switch reason {
        case .openStore:
            return invariantMapping()
        case .corruptStoredValue, .invariantViolation, .transaction:
            return ExternalHistoryFailureMapping(
                failure: .persistence(reason),
                auditFailureKind: .persistence,
                auditDenialReason: nil
            )
        }

    case .temporarilyUnavailable(let reason):
        switch reason {
        case .factProof:
            return ExternalHistoryFailureMapping(
                failure: .temporarilyUnavailable(.storeLocked),
                auditFailureKind: .temporarilyUnavailable,
                auditDenialReason: nil
            )
        case .dedupIndexRebuild:
            return invariantMapping()
        case .insufficientDiskSpace:
            switch operation {
            case .managePin, .manageUnpin, .manageRemove:
                return ExternalHistoryFailureMapping(
                    failure: .temporarilyUnavailable(.insufficientDiskSpace),
                    auditFailureKind: .temporarilyUnavailable,
                    auditDenialReason: nil
                )
            case .readRecent, .readSearch, .readDetails, .readPastePayload:
                return invariantMapping()
            }
        }

    case .invalidInput(let reason):
        switch reason {
        case .invalidSearchTerm, .invalidRegularExpression:
            switch operation {
            case .readSearch:
                return ExternalHistoryFailureMapping(
                    failure: .history(source),
                    auditFailureKind: .requestDenied,
                    auditDenialReason: .invalidInput
                )
            case .readRecent,
                 .readDetails,
                 .readPastePayload,
                 .managePin,
                 .manageUnpin,
                 .manageRemove:
                return invariantMapping()
            }
        case .emptyCapture,
             .excludedFromHistory,
             .duplicateRepresentationType,
             .unsupportedRepresentationType,
             .representationLimit,
             .byteLimit,
             .invalidTimestamp,
             .incoherentRevisionDraft,
             .invalidPageLimit,
             .invalidPixelSize,
             .invalidRetentionPolicy:
            return invariantMapping()
        }

    case .invalidPinnedPlacement(let reason):
        switch reason {
        case .targetMissing:
            switch operation {
            case .managePin:
                return historyMapping(source)
            case .readRecent,
                 .readSearch,
                 .readDetails,
                 .readPastePayload,
                 .manageUnpin,
                 .manageRemove:
                return invariantMapping()
            }
        case .anchorMissingOrUnpinned, .targetEqualsAnchor:
            return invariantMapping()
        }

    case .capacityExceeded(let kind):
        switch kind {
        case .coherenceToken:
            switch operation {
            case .managePin, .manageUnpin, .manageRemove:
                return historyMapping(source)
            case .readRecent, .readSearch, .readDetails, .readPastePayload:
                return invariantMapping()
            }
        case .retainedItems,
             .revisionCount,
             .revisionBytes,
             .copyCount,
             .thumbnailBytes,
             .storageBytes:
            return invariantMapping()
        }

    case .staleContent, .revisionNotFound, .snapshotExpired:
        return invariantMapping()
    }
}

private func historyMapping(
    _ source: HistoryFailure
) -> ExternalHistoryFailureMapping {
    ExternalHistoryFailureMapping(
        failure: .history(source),
        auditFailureKind: .history,
        auditDenialReason: nil
    )
}

private func invariantMapping() -> ExternalHistoryFailureMapping {
    ExternalHistoryFailureMapping(
        failure: .persistence(.invariantViolation),
        auditFailureKind: .persistence,
        auditDenialReason: nil
    )
}
