## Part III — Caller Interface (A): identity, protocol, actions & receipts

### 1. Role and ownership

`HistoryCore` owns the complete public interface between callers and retained History. It is Foundation-only and contains no persistence, Domain aggregate, fingerprint, framework object, or service locator.

The interface is deliberately closed for v1. Adding a new History Action is an owned source change across Core, Domain planning, Storage fact loading/execution, and tests. A generic command protocol does not make that change free; it only hides the required dispatch behind existential casts. The closed enum makes every required switch compiler-visible.

### 2. Public identity and coherence values

```swift
public struct HistoryItemID:
    Sendable, Hashable, Comparable, CustomStringConvertible
{
    public let rawValue: UUID

    package init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        withUnsafeBytes(of: lhs.rawValue.uuid) { left in
            withUnsafeBytes(of: rhs.rawValue.uuid) { right in
                left.lexicographicallyPrecedes(right)
            }
        }
    }
}

public struct RevisionID: Sendable, Hashable, Comparable {
    public let rawValue: UUID
    package init(rawValue: UUID) { self.rawValue = rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        withUnsafeBytes(of: lhs.rawValue.uuid) { left in
            withUnsafeBytes(of: rhs.rawValue.uuid) { right in
                left.lexicographicallyPrecedes(right)
            }
        }
    }
}

public struct ContentVersion: Sendable, Hashable, Comparable {
    public let rawValue: UInt64
    package init(rawValue: UInt64) { self.rawValue = rawValue }
    package static let initial = ContentVersion(rawValue: 1)

    package func successor() -> ContentVersion? {
        guard rawValue < UInt64.max else { return nil }
        return ContentVersion(rawValue: rawValue + 1)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ChangePosition: Sendable, Hashable, Comparable {
    public let rawValue: UInt64
    package init(rawValue: UInt64) { self.rawValue = rawValue }
    package static let zero = ChangePosition(rawValue: 0)

    package func successor() -> ChangePosition? {
        guard rawValue < UInt64.max else { return nil }
        return ChangePosition(rawValue: rawValue + 1)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
```

The raw UUID is observable for logging, pasteboard lineage encoding, and stable persistence, but its initializers are package-only. This is not a security boundary; it centralizes minting in `HistoryStorage`. Versions use checked arithmetic and never wrap.

```swift
public struct HistoryItemReference: Sendable, Hashable {
    public let id: HistoryItemID
    public let contentVersion: ContentVersion

    public init(id: HistoryItemID, contentVersion: ContentVersion) {
        self.id = id
        self.contentVersion = contentVersion
    }
}
```

A reference identifies one retained item and one Effective Content state. UI thumbnail/detail/edit work should retain the reference rather than an ID alone.

### 3. The public History interface

```swift
public protocol ClipboardHistory: Sendable {
    func perform(_ action: HistoryAction) async throws -> HistoryReceipt

    func browse(
        _ request: HistoryBrowseRequest
    ) async throws -> HistoryPage

    func observe(
        _ request: HistoryObservationRequest
    ) async -> AsyncThrowingStream<HistoryPage, Error>

    func details(
        for id: HistoryItemID
    ) async throws -> HistoryDetails

    func pastePayload(
        for id: HistoryItemID
    ) async throws -> PastePayload

    func thumbnail(
        for item: HistoryItemReference,
        pixels: PixelSize
    ) async throws -> ThumbnailPayload?
}
```

`SwiftDataHistory` is the production implementation. UI previews may use a scripted implementation, which must itself conform to `Sendable` (because `ClipboardHistory: Sendable`) and must not be used as a substitute for storage semantic tests. Persistence semantic tests use `SwiftDataHistory` with an in-memory container, not a behavior-reimplementing fake.

### 4. Raw capture seam

```swift
public struct CapturedRepresentation: Sendable, Hashable {
    public let typeIdentifier: String
    public let bytes: Data

    public init(typeIdentifier: String, bytes: Data) {
        self.typeIdentifier = typeIdentifier
        self.bytes = bytes
    }
}

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
```

These are observations, not trusted Domain state. They contain no Canonical marker, fingerprint, title, search text, item ID to create, or version to mint. `HistoryStorage` validates and prepares them.

### 5. Closed History Action set

```swift
public enum HistoryAction: Sendable {
    case capture(ClipboardCapture)
    case placePinned(HistoryItemID, at: PinnedPlacement)
    case unpin(HistoryItemID)
    case remove(HistoryItemID)
    case clear(ClearScope)
    case revise(RevisionRequest)
    case setRetentionPolicy(maximumUnpinnedItems: Int)
}

public enum PinnedPlacement: Sendable, Hashable {
    case first
    case last
    case before(HistoryItemID)
}

public enum ClearScope: Sendable, Hashable {
    case unpinned
    case all
}
```

`.placePinned` covers first pin and reorder. It never accepts a numeric slot. `.before(anchor)` requires a different retained pinned item. `.unpin` on an unpinned item and a placement that produces the existing order are no-ops.

#### Revision input

```swift
public struct RevisionRequest: Sendable {
    public let itemID: HistoryItemID
    public let expected: ContentVersion
    public let intent: RevisionIntent

    public init(
        itemID: HistoryItemID,
        expected: ContentVersion,
        intent: RevisionIntent
    ) {
        self.itemID = itemID
        self.expected = expected
        self.intent = intent
    }
}

public enum RevisionIntent: Sendable {
    case replace(RevisionDraft)
    case revert(to: RevisionTarget)
}

public enum RevisionTarget: Sendable, Hashable {
    case canonical
    case revision(RevisionID)
}

public struct RevisionDraft: Sendable, Hashable {
    public let decisions: [RevisionDecision]

    public init(decisions: [RevisionDecision]) {
        self.decisions = decisions
    }
}

public struct RevisionDecision: Sendable, Hashable {
    public let typeIdentifier: String
    public let action: RevisionDecisionAction

    public init(
        typeIdentifier: String,
        action: RevisionDecisionAction
    ) {
        self.typeIdentifier = typeIdentifier
        self.action = action
    }
}

public enum RevisionDecisionAction: Sendable, Hashable {
    case inheritCanonical
    case hide
    case replace(bytes: Data)
}
```

A replace draft must make one explicit decision for every Canonical type and no decision for a foreign type. Callers do not mint the new Revision ID or timestamp.

Decision resolution into the proposed Effective Content (performed by `RevisionPreparationActor`, Part V §6.2):

- `.inheritCanonical` carries the Canonical representation's bytes into Effective unchanged;
- `.replace(bytes:)` substitutes the supplied bytes for that type in Effective;
- `.hide` omits that representation from Effective Content entirely. The Canonical representation is retained for lineage and general-lane dedup, so hiding never changes Canonical Content or its signature. Hiding does change Effective Content (it carries fewer representations), which is exactly why a hide-bearing revision is a real revision with a non-nil active ID.

The proposed Effective Content must remain non-empty — a draft that hides every Canonical type is rejected as `invalidInput(.incoherentRevisionDraft)`. Hidden types do not appear in `HistoryDetails.effective` or `PastePayload`; a later revision's `.inheritCanonical` or `.replace` restores them.

### 6. Receipts and History Commit outcomes

```swift
public enum HistoryReceipt: Sendable {
    case unchanged
    case committed(HistoryCommit)
}

public struct HistoryCommit: Sendable {
    public let position: ChangePosition
    public let outcome: HistoryCommitOutcome

    public init(
        position: ChangePosition,
        outcome: HistoryCommitOutcome
    ) {
        self.position = position
        self.outcome = outcome
    }
}

public enum HistoryCommitOutcome: Sendable {
    case inserted(HistoryItemReference)
    case coalesced(HistoryItemReference)
    case placedPinned(HistoryItemID)
    case unpinned(HistoryItemID)
    case removed(count: Int)
    case cleared(count: Int)
    case revised(HistoryItemReference)
    case retentionPolicySet(removedCount: Int)
}
```

`unchanged` means there was no durable mutation. It has no position, publishes no invalidation, and is not a History Commit.

A committed capture returns the stable winner/new item reference. Metadata-only outcomes keep the existing Content Version, so the outcome does not pretend to mint a new reference state.

### 7. Browse and search requests

```swift
public enum SearchMode: Sendable, Hashable {
    case exact
    case fuzzy
    case regexp
}

public enum HistoryBrowseKind: Sendable, Hashable {
    case recent
    case search(text: String, mode: SearchMode)
}

public struct HistoryPageCursor: Sendable, Hashable {
    package let payload: Data
    package init(payload: Data) { self.payload = payload }
}

public struct HistoryBrowseRequest: Sendable, Hashable {
    public let kind: HistoryBrowseKind
    public let limit: Int
    public let after: HistoryPageCursor?

    public init(
        kind: HistoryBrowseKind,
        limit: Int,
        after: HistoryPageCursor? = nil
    ) {
        self.kind = kind
        self.limit = limit
        self.after = after
    }
}

public struct HistoryObservationRequest: Sendable, Hashable {
    public let kind: HistoryBrowseKind
    public let limit: Int

    public init(kind: HistoryBrowseKind, limit: Int) {
        self.kind = kind
        self.limit = limit
    }
}
```

Observation intentionally has no cursor: it tracks the current first page for one query. Additional pages are one-shot `browse` requests. A cursor is opaque, bound to the complete query shape and snapshot position, and has process-local v1 validity.

Invalid regular expressions and out-of-range limits are typed input failures. Search evaluation has exactly the three v1 modes above; dedup ranking is unrelated and not public.

