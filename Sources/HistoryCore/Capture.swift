import Foundation

/// One raw pasteboard representation observed at capture time: a Uniform Type
/// Identifier plus its uninterpreted bytes.
///
/// This is an observation, not trusted Domain state — it carries no Canonical
/// marker, fingerprint, title, or search text. `HistoryStorage` validates and
/// prepares it.
///
/// docs/03a-instruction-set.md §4
public struct CapturedRepresentation: Sendable, Hashable {
    public let typeIdentifier: String
    public let bytes: Data

    public init(typeIdentifier: String, bytes: Data) {
        self.typeIdentifier = typeIdentifier
        self.bytes = bytes
    }
}

/// Best-effort observation of where a copy came from: the source application
/// name (when knowable) and an optional lineage hint pointing at a retained
/// item the copy may descend from.
///
/// This is an observation, not trusted Domain state — the hint is not an item
/// ID to create. `HistoryStorage` validates and prepares it.
///
/// docs/03a-instruction-set.md §4
public struct CopyOriginObservation: Sendable, Hashable {
    public let sourceApplication: String?
    public let lineageHint: HistoryItemID?

    public init(
        sourceApplication: String?,
        lineageHint: HistoryItemID?
    ) {
        self.sourceApplication = sourceApplication
        self.lineageHint = lineageHint
    }
}

/// A single raw clipboard observation handed to History via
/// `HistoryAction.capture`: the observed representations, the observed copy
/// origin, and the observation timestamp.
///
/// This is an observation, not trusted Domain state — it contains no
/// fingerprint, item ID to create, or version to mint. `HistoryStorage`
/// validates and prepares it.
///
/// docs/03a-instruction-set.md §4
public struct ClipboardCapture: Sendable, Hashable {
    public let representations: [CapturedRepresentation]
    public let origin: CopyOriginObservation
    public let observedAt: Date

    public init(
        representations: [CapturedRepresentation],
        origin: CopyOriginObservation,
        observedAt: Date
    ) {
        self.representations = representations
        self.origin = origin
        self.observedAt = observedAt
    }
}
