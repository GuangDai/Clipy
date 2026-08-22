/// Closed External Gateway classification values.
/// Owning spec: docs/v2/V2-05-external-gateway.md §0.2/§3.2/§3.3.
/// Foundation-only; these values carry no credential, transport, registry, or
/// History lookup behavior.
import Foundation

/// The durable enrollment surface that owns an external connection.
public enum ConnectionEnrollKind: Int16, Sendable, Hashable, Codable {
    case appIntents = 1
    case localAutomation = 2
}

/// A grant that may authorize one closed subset of external operations.
///
/// Constructibility does not imply grantability. `HistoryStorage` applies the
/// connection-kind matrix before any future History or audit lookup.
public enum ExternalCapability: Int16, Sendable, Hashable, Codable {
    // Existing App Intents capabilities (V2-05 §3.2), unchanged.
    case browse = 1
    case readContent = 2
    case manage = 3

    // Local Automation capabilities (V2-05 §0.2).
    case browsePreview = 10
    case readEffectiveContent = 11
    case organize = 12
    case deleteItem = 13
    case reviseContent = 14
}

/// Stable classification of an external operation before request dispatch.
///
/// The connection-kind policy decides which capability may use each operation;
/// sharing this vocabulary never shares or implies a grant.
public enum ExternalOperationKind: Int16, Sendable, Hashable, Codable {
    // Existing App Intents operation set (V2-05 §3.2), unchanged.
    case readRecent = 1
    case readSearch = 2
    case readDetails = 3
    case readPastePayload = 4
    case managePin = 5
    case manageUnpin = 6
    case manageRemove = 7

    // In-app administration is declared for the later Gateway substrate but
    // is never admitted by the external connection-kind policy.
    case adminEnroll = 8
    case adminGrant = 9
    case adminRevoke = 10 // Connection revoke; capability revoke is raw 16.
    case adminRebase = 11
    case adminCompact = 12

    // Local Automation additions (V2-05 §0.2). `reviseContent` and the format
    // declaration are intentionally constructible but not yet admitted.
    case readEffectiveContent = 13
    case reviseContent = 14
    case describeFormatCapabilities = 15

    // Further in-app administration vocabulary remains forbidden to every
    // external connection kind and capability.
    case adminRevokeCapability = 16
    case adminReadConnections = 17
    case adminReadGrants = 18
    case adminReadAudit = 19
}
