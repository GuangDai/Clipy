/// PLAY-PY-GW0 pure connection-kind allow matrix.
/// Owning spec: docs/v2/V2-05-external-gateway.md §0.2.
/// The raw-value ceiling below also guards the 47-4 adjudication that no
/// external retention operation spelling exists (V2-05 §2.2/§3.2; V2-02 §9).
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
        .adminRevokeCapability,
        .adminReadConnections,
        .adminReadGrants,
        .adminReadAudit,
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
    #expect(ExternalOperationKind(rawValue: 20) == nil)
    #expect(ExternalOperationKind(rawValue: 999) == nil)

    // Task 47-4 adjudication guard: the external operation vocabulary is
    // closed at exactly 19 cases (highest raw 19, `adminReadAudit`) because
    // V2-05 §2.2/§3.2 and V2-02 §9 exclude any external retention spelling.
    // A raw 20+ decoding to a case — e.g. a future retention operation — is
    // a deliberate red, not a bug: adding one requires a V2-05 amendment
    // that also updates this ceiling. The sweep runs to the same 999 anchor
    // as the literal checks above, so a future case at ANY raw beyond 19
    // (not just 20...40) trips this boundary.
    for raw in Int16(20)...999 {
        #expect(
            ExternalOperationKind(rawValue: raw) == nil,
            "new ExternalOperationKind requires a V2-05 amendment (§2.2 excludes external retention)"
        )
    }
    for raw in Int16(1)...19 {
        #expect(ExternalOperationKind(rawValue: raw) != nil)
    }
}
