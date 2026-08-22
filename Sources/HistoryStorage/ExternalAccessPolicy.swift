/// Pure connection-kind admission policy for PLAY-PY-GW0.
/// Owning spec: docs/v2/V2-05-external-gateway.md §0.2.
import HistoryCore

/// Classifies the closed `(connection kind, capability, operation)` matrix
/// before any future connection, History, or audit lookup.
internal enum ExternalAccessPolicy {
    private enum OperationClass: Equatable {
        case browse
        case contentRead
        case organize
        case delete
        case effectiveContentRead
        case forbidden
    }

    internal static func admits(
        connectionKind: ConnectionEnrollKind,
        capability: ExternalCapability,
        operation: ExternalOperationKind
    ) -> Bool {
        let operationClass = classify(operation: operation)

        return switch connectionKind {
        case .appIntents:
            switch capability {
            case .browse:
                operationClass == .browse
            case .readContent:
                operationClass == .contentRead
            case .manage:
                // Existing implication is preserved: manage can enumerate the
                // items it may pin, unpin, or remove (V2-05 §3.2).
                operationClass == .browse
                    || operationClass == .organize
                    || operationClass == .delete
            case .browsePreview,
                 .readEffectiveContent,
                 .organize,
                 .deleteItem,
                 .reviseContent:
                false
            }

        case .localAutomation:
            switch capability {
            case .browsePreview:
                operationClass == .browse
            case .readEffectiveContent:
                operationClass == .effectiveContentRead
            case .organize:
                operationClass == .organize
            case .deleteItem:
                operationClass == .delete
            case .browse,
                 .readContent,
                 .manage,
                 .reviseContent:
                false
            }
        }
    }

    private static func classify(
        operation: ExternalOperationKind
    ) -> OperationClass {
        switch operation {
        case .readRecent, .readSearch:
            .browse
        case .readDetails, .readPastePayload:
            .contentRead
        case .managePin, .manageUnpin:
            .organize
        case .manageRemove:
            .delete
        case .readEffectiveContent:
            .effectiveContentRead
        case .adminEnroll,
             .adminGrant,
             .adminRevoke,
             .adminRebase,
             .adminCompact,
             .adminRevokeCapability,
             .adminReadConnections,
             .adminReadGrants,
             .adminReadAudit,
             .reviseContent,
             .describeFormatCapabilities:
            .forbidden
        }
    }
}
