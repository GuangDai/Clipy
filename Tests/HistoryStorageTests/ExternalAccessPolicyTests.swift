/// PLAY-PY-GW0 pure connection-kind allow matrix.
/// Owning spec: docs/v2/V2-05-external-gateway.md §0.2.
import Testing
@testable import HistoryCore
@testable import HistoryStorage

@Test func externalAccessPolicyMatchesTheLiteralClosedMatrix() {
    struct Admission: Hashable {
        let connectionKind: ConnectionEnrollKind
        let capability: ExternalCapability
        let operation: ExternalOperationKind
    }

    let admitted: Set<Admission> = [
        // Existing App Intents surface. `manage` continues to imply browse.
        Admission(connectionKind: .appIntents, capability: .browse, operation: .readRecent),
        Admission(connectionKind: .appIntents, capability: .browse, operation: .readSearch),
        Admission(connectionKind: .appIntents, capability: .readContent, operation: .readDetails),
        Admission(connectionKind: .appIntents, capability: .readContent, operation: .readPastePayload),
        Admission(connectionKind: .appIntents, capability: .manage, operation: .readRecent),
        Admission(connectionKind: .appIntents, capability: .manage, operation: .readSearch),
        Admission(connectionKind: .appIntents, capability: .manage, operation: .managePin),
        Admission(connectionKind: .appIntents, capability: .manage, operation: .manageUnpin),
        Admission(connectionKind: .appIntents, capability: .manage, operation: .manageRemove),

        // Local Automation has separate, narrower capabilities and operations.
        Admission(connectionKind: .localAutomation, capability: .browsePreview, operation: .readRecent),
        Admission(connectionKind: .localAutomation, capability: .browsePreview, operation: .readSearch),
        Admission(
            connectionKind: .localAutomation,
            capability: .readEffectiveContent,
            operation: .readEffectiveContent
        ),
        Admission(connectionKind: .localAutomation, capability: .organize, operation: .managePin),
        Admission(connectionKind: .localAutomation, capability: .organize, operation: .manageUnpin),
        Admission(connectionKind: .localAutomation, capability: .deleteItem, operation: .manageRemove),
    ]

    let connectionKinds: [ConnectionEnrollKind] = [.appIntents, .localAutomation]
    let capabilities: [ExternalCapability] = [
        .browse,
        .readContent,
        .manage,
        .browsePreview,
        .readEffectiveContent,
        .organize,
        .deleteItem,
        .reviseContent,
    ]
    let operations: [ExternalOperationKind] = [
        .readRecent,
        .readSearch,
        .readDetails,
        .readPastePayload,
        .managePin,
        .manageUnpin,
        .manageRemove,
        .adminEnroll,
        .adminGrant,
        .adminRevoke,
        .adminRebase,
        .adminCompact,
        .readEffectiveContent,
        .reviseContent,
        .describeFormatCapabilities,
    ]

    for connectionKind in connectionKinds {
        for capability in capabilities {
            for operation in operations {
                let candidate = Admission(
                    connectionKind: connectionKind,
                    capability: capability,
                    operation: operation
                )
                #expect(
                    ExternalAccessPolicy.admits(
                        connectionKind: connectionKind,
                        capability: capability,
                        operation: operation
                    ) == admitted.contains(candidate),
                    "Unexpected classification for \(connectionKind), \(capability), \(operation)"
                )
            }
        }
    }
}

@Test func externalAccessVocabularyRejectsUnknownRawValues() {
    #expect(ConnectionEnrollKind(rawValue: 999) == nil)
    #expect(ExternalCapability(rawValue: 999) == nil)
    #expect(ExternalOperationKind(rawValue: 999) == nil)
}
