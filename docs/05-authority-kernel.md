## Part V — Authority Commit Kernel

### 1. Role

`HistoryStorage` is the only target that imports SwiftData and xxh3. It provides `SwiftDataHistory`, the production `ClipboardHistory` adapter, and hides all persistence types.

Its responsibilities are deliberately asymmetric:

- translate raw public values into validated Domain inputs;
- load action-specific facts with proved completeness;
- invoke pure Domain planners;
- mechanically stamp semantic plans with versions and durable projections;
- apply one atomic SwiftData transaction;
- update the complete in-memory Signature Index;
- publish a process-local invalidation;
- project purpose-specific read values.

It does not duplicate dedup winner selection, Copy Occurrence folding, pin-order planning, revision semantics, or retention victim selection.

### 2. Public concrete adapter and internal actors

```swift
public struct SwiftDataHistory: ClipboardHistory, Sendable {
    // All five stored fields are `actor` types, so each is Sendable and the
    // Sendable conformance is derived without @unchecked Sendable.
    private let authority: HistoryAuthority
    private let ingestPreparation: IngestPreparationActor
    private let revisionPreparation: RevisionPreparationActor
    private let searchWorker: SearchWorker
    private let thumbnailService: ThumbnailService

    public static func open(
        configuration: HistoryConfiguration
    ) async throws -> SwiftDataHistory
}

public enum HistoryPersistence: Sendable, Hashable {
    case persistent(storeURL: URL)
    case memory
}

public struct HistoryConfiguration: Sendable, Hashable {
    public let persistence: HistoryPersistence
    public let initialMaximumUnpinnedItems: Int

    public init(
        persistence: HistoryPersistence,
        initialMaximumUnpinnedItems: Int = 200
    ) {
        self.persistence = persistence
        self.initialMaximumUnpinnedItems = initialMaximumUnpinnedItems
    }
}
```

`HistoryConfiguration` selects persistent or in-memory storage and the initial retention value for a new store. An existing store uses its durable singleton value; the public retention action changes it. `open` validates the initial value against Part VI's fixed range and always uses the fixed `HistoryLimits.standard` safety profile. It throws `HistoryFailure`: `.invalidInput(.invalidRetentionPolicy)` for an out-of-range `initialMaximumUnpinnedItems`, or `.persistence(.openStore)` / `.persistence(.corruptStoredValue)` / `.persistence(.invariantViolation)` for store-open or startup-corruption failures (Part V §13). `.memory` changes durability medium only; it uses the same Authority, planners, codecs, and transaction path.

Internal isolation:

```text
SwiftDataHistory facade
├── IngestPreparationActor
├── RevisionPreparationActor
├── SearchWorker
├── ThumbnailService / ThumbnailWorker
└── HistoryAuthority
    ├── ModelContainer
    ├── SignatureIndex value
    ├── validated settings
    └── observation continuations
```

`HistoryAuthority` is the sole writer. It is also the serialization point for source snapshot capture and observer registration. It stores no `@Model` instance or `ModelContext` across operations.

### 3. SwiftData schema v1

All model types are internal to `HistoryStorage`.

The v1 schema (`HistorySchemaV1`) is the `Schema` containing exactly `HistoryItemRow` and `LastChangePositionRow`, registered with the `ModelContainer` at `open` time:

```swift
internal let v1Schema = Schema(HistoryItemRow.self, LastChangePositionRow.self)
```

`HistorySchemaV1` is also the conceptual version label referenced by the Part V §17 migration stance; a future schema change increments it and adds a migration plan.

#### 3.1 History Item row

```swift
@Model
internal final class HistoryItemRow {
    @Attribute(.unique)
    var id: UUID

    var contentVersionRaw: UInt64

    @Attribute(.externalStorage)
    var canonicalBlob: Data

    @Attribute(.externalStorage)
    var revisionStateBlob: Data

    var canonicalSignatureBlob: Data

    var projectionSchemaVersion: UInt16
    var title: String
    var searchBody: String
    var effectiveTypeIdentifiersBlob: Data

    var firstCopiedAt: Date
    var lastCopiedAt: Date
    var copyCount: UInt64
    var firstSource: String?
    var lastSource: String?

    var pinOrdinal: Int?
}
```

Semantic mapping:

| Column | Meaning |
|---|---|
| `id` | Stable business ID. Never expose `PersistentIdentifier`. |
| `contentVersionRaw` | Current Effective Content version, always at least 1. |
| `canonicalBlob` | Immutable Canonical representations including per-representation fingerprint evidence. |
| `revisionStateBlob` | Full revision list plus active Revision ID. The active revision's bytes are present whenever `activeRevisionID` is non-nil; for a Canonical-state item (`activeRevisionID == nil`) the revision list is empty and there are no revision bytes — Effective Content equals Canonical Content. |
| `canonicalSignatureBlob` | Durable scalar metadata used to rebuild the complete Signature Index without decoding content bytes. |
| projection fields | Durable bounded projection of current Effective Content for list/search. |
| occurrence fields | Full first/last time and source summary. |
| `pinOrdinal` | Internal encoding of pinned order; `nil` is unpinned. |

`@Attribute(.externalStorage)` is an implementation hint. Correctness, byte limits, and read isolation do not depend on whether SwiftData stores a blob inline or externally.

There is no `pinned: Bool`, inactive-only revision list, single `application` column, enrichment field, tombstone, cache payload, durable change record, or SwiftData identity map.

#### 3.2 Change Position singleton

```swift
@Model
internal final class LastChangePositionRow {
    @Attribute(.unique)
    var key: String        // always "retained-history"
    var rawValue: UInt64   // 0 before the first History Commit
    var maximumUnpinnedItems: Int
}
```

Every non-empty History Commit updates this row in the same transaction as its item mutations. The first commit moves `0 → 1`. Empty stores therefore still support an authoritative `HistoryPage(position: 0, rows: [])`. The same singleton owns the current v1 retention policy so capture and policy changes read one authoritative value.

The singleton is not a journal. It only identifies the latest durable History Commit.

#### 3.3 Explicitly absent schema

- No History Change Record table.
- No Operation Record or external connection table.
- No thumbnail/list/search cache table.
- No version-map/checkpoint row.
- No separate pin table or denormalized occupancy map.
- No enrichment or revision-retention metadata.
- No migration bridge from the current Maccy models.

### 4. Versioned storage codecs

Domain values do not gain synthesized `Codable` conformance merely for SwiftData. `HistoryStorage` owns explicit versioned wire values:

```swift
internal struct CanonicalBlobV1: Codable {
    let formatVersion: UInt16       // exactly 1
    let representations: [StoredCanonicalRepresentationV1]
}

internal struct StoredCanonicalRepresentationV1: Codable {
    let typeIdentifier: String
    let bytes: Data
    let fingerprint: UInt64
}

internal struct RevisionStateBlobV1: Codable {
    let formatVersion: UInt16       // exactly 1
    let revisions: [StoredRevisionV1]
    let activeRevisionID: UUID?
}

internal struct StoredRevisionV1: Codable {
    let id: UUID
    let createdAt: Date
    let representations: [StoredRepresentationV1]
}

internal struct StoredRepresentationV1: Codable {
    let typeIdentifier: String
    let bytes: Data
}

internal struct SignatureBlobV1: Codable {
    let formatVersion: UInt16       // exactly 1
    let entries: [StoredSignatureEntryV1]
}

internal struct StoredSignatureEntryV1: Codable {
    let typeIdentifier: String
    let fingerprint: UInt64
    let byteCount: Int
}

internal struct EffectiveTypeIdentifiersBlobV1: Codable {
    let formatVersion: UInt16       // exactly 1
    let typeIdentifiers: [String]   // sorted, unique, non-empty
}
```

Decode is not a blind memberwise conversion. It reconstructs Domain values through their validators and checks:

- known blob version (exactly 1 for each V1 blob);
- bounded byte/count values before any large allocation;
- normalized, unique, non-empty type identifiers, with no empty-bytes representation;
- fingerprint/signature coverage is checked **bidirectionally** against Canonical representations — every Canonical representation has a signature entry and every signature entry corresponds to a Canonical representation (no orphan entries). Fingerprint correctness is **not** re-verified at decode, because by D7 a divergent fingerprint may add a spurious candidate but can never produce a false byte-confirmed match;
- unique revision IDs and bounded full revision history within the per-item revision-count/byte bounds;
- active ID: when non-nil it is unique and names exactly one stored revision; `nil` is valid only when the revision list is empty (D3); a non-nil active ID with no matching revision, or a non-empty list with a nil active ID, is corruption;
- normalized, non-empty revision content containing only Canonical representation types;
- a valid (≥1) Content Version and valid occurrence values;
- a non-negative pin ordinal (negative is corruption);
- the `effectiveTypeIdentifiersBlob` decodes to a sorted, unique, non-empty list of type identifiers at format version 1;
- `projectionSchemaVersion` is exactly the v1 value, and the stored `title` (≤ 1,024 UTF-8 bytes) and `searchBody` (≤ 256 KiB) obey their Part VI bounds.

Any violation is `.persistence(.corruptStoredValue)` or `.persistence(.invariantViolation)`. The decoder does not silently drop bad representations, choose a duplicate, reset to Canonical, or repair pin order locally.

Encode starts from validated Domain/stamped values and is deterministic. Round-trip equivalence is a Part VI gate.

### 5. Context confinement

The single-writer rule is:

> Only `HistoryAuthority` may create a writable `ModelContext`, and at most one Authority operation uses one at a time.

For each read or commit:

1. create a context from the Authority-owned `ModelContainer`;
2. configure autosave off if applicable to the chosen API surface;
3. synchronously fetch, decode, plan, transact, and/or extract value snapshots;
4. retain no row or context after returning from the isolated helper.

There is no context crossing an actor boundary and no `await` while a commit context, fetched row, complete facts, or commit plan is live.

This replaces the earlier permanent-context plus manual-refresh design. It does not use nonexistent `refresh(_:mergeChanges:)`/`refreshAllObjects()` APIs and does not misuse `registeredModel(for:)` with a business ID.

All business-ID lookup uses a bounded fetch predicate on `HistoryItemRow.id`. Exactly zero or one row is valid; duplicates are persistence corruption even though the schema also declares uniqueness.

### 6. Preparation outside the commit interval

#### 6.1 Capture preparation

`IngestPreparationActor` converts `ClipboardCapture` into:

```swift
internal struct PreparedCaptureBundle: Sendable {
    let domain: PreparedCapture
    let projection: ContentProjection
}

internal struct ContentProjection: Sendable {
    let schemaVersion: UInt16       // v1 = 1
    let title: String
    let searchBody: String
    let effectiveTypeIdentifiers: [String]
}
```

Fixed order:

1. Reject an empty capture or hard-limit violation.
2. Reject invalid/oversized type identifiers and bytes.
3. Remove the explicitly configured transient/private framework types.
4. Sort by type identifier and reject duplicate identifiers, including duplicates with equal bytes.
5. Compute xxh3-64 once for every remaining representation.
6. Construct validated Canonical Content and signature entries.
7. Mint a candidate History Item ID through the package ID source.
8. Project initial title/search/type summary from Canonical-as-Effective Content.

The serial commit interval performs no pasteboard access, rich-text parsing, fingerprinting, or initial projection.

#### 6.2 Revision preparation

Revision needs latest Canonical/revision facts before it can resolve a public draft, but expensive normalization/projection must stay outside the commit interval. It therefore uses an OCC-safe two-phase preparation:

```swift
internal struct PreparedRevisionBundle: Sendable {
    let domain: PreparedRevision
    let projection: ContentProjection
}
```

```text
Authority captures RevisionPreparationSnapshot(item, current version)
→ reject immediately if request.expected is already stale
→ RevisionPreparationActor resolves replace/revert to complete proposed Effective Content
→ validate hard limits and project title/search/type summary
→ Authority reloads RevisionFacts
→ Domain rechecks expected version and prepared.basedOn
→ commit or stale failure
```

`RevisionPreparationSnapshot` is a Sendable value containing the target's validated Canonical Content, complete revision list, active ID, and Content Version. No row/context escapes.

```swift
internal struct RevisionPreparationSnapshot: Sendable {
    let canonical: CanonicalContent
    let revisions: [ContentRevision]
    let activeRevisionID: RevisionID?
    let contentVersion: ContentVersion
}
```

Replace resolution applies exactly one draft decision to every Canonical type. Revert-to-Canonical strips Canonical fingerprints; revert-to-revision copies the target's complete stored content. Missing targets and incoherent drafts fail before the second Authority entry.

A pin or Copy Coalescing commit between the two phases preserves Content Version and content lineage, so the proposal remains valid; the second fact load preserves that newer metadata. A content-changing revision advances Content Version and causes the second OCC check to reject the prepared proposal.

### 7. Complete fact loading

Each public action selects one loader. There is no generic partial map.

#### 7.1 Capture

1. Require Signature Index state `.ready` for the current retained ID set. If unready, attempt a complete rebuild from every retained row's signature blob within the hard item bound.
2. Intersect posting sets for all incoming signature entries.
3. Fetch and fully decode every candidate ID.
4. If a lineage hint exists, fetch it separately by ID even when it is absent from the candidate intersection.
5. Fetch scalar retention summaries for every retained row.
6. Verify candidate IDs, retained IDs, and index generation agree before constructing `IngestFacts`.

If any step cannot prove completeness, reject capture. There is no “scan the first N and insert if absent” path.

#### 7.2 Pin and unpin

Fetch target existence plus every row with a non-nil pin ordinal. Validate unique contiguous order and construct `PinFacts`. Stored corruption fails; the operation does not perform an implicit repair commit.

#### 7.3 Revision, remove, clear, retention

- Revision fetches and decodes exactly the target item.
- Remove fetches the target's scalar summary.
- Clear fetches every ID/pin value selected by scope.
- Retention fetches every retained ID, last-copied time, and pin ordinal.

All collection-wide loads are bounded by the hard retained-item maximum. A loader never labels an incomplete result as complete.

### 8. Closed action dispatch

`SwiftDataHistory.perform` uses one exhaustive switch:

```swift
switch action {
case .capture(let raw):
    let prepared = try await ingestPreparation.prepare(raw)
    return try await authority.commitCapture(prepared)

case .placePinned(let id, let placement):
    return try await authority.commitPinnedPlacement(id, placement)

case .unpin(let id):
    return try await authority.commitUnpin(id)

case .remove(let id):
    return try await authority.commitRemove(id)

case .clear(let scope):
    return try await authority.commitClear(scope)

case .revise(let request):
    let source = try await authority.revisionPreparationSnapshot(request)
    let bundle = try await revisionPreparation.prepare(request, from: source)
    return try await authority.commitRevision(request, bundle)

case .setRetentionPolicy(let maximum):
    return try await authority.commitRetentionPolicy(maximum)
}
```

There is no generic existential, family string/tag, registry, visitor, or `as? IngestCommand` dispatch.

### 9. From Domain plan to stamped commit plan

The relevant Authority method performs:

```text
create operation-local context
→ load exact facts
→ call the action-specific pure planner
→ if unchanged: release context and return .unchanged
→ derive/stamp a StampedCommitPlan
→ prevalidate its index delta and receipt
→ execute one transaction
→ apply nonthrowing Signature Index delta
→ synchronously yield one HistoryInvalidation
→ release context
→ return .committed
```

Storage-internal stamped mutations carry absolute row values:

```swift
internal enum StampedMutation {
    case create(StoredNewItem)
    case updateOccurrence(
        itemID: HistoryItemID,
        occurrence: CopyOccurrence
    )
    case setPinOrdinal(
        itemID: HistoryItemID,
        ordinal: Int?
    )
    case appendRevision(StoredRevisionUpdate)
    case delete(
        itemID: HistoryItemID,
        reason: RetirementReason
    )
    case setRetentionPolicy(maximumUnpinnedItems: Int)
}

internal struct StoredNewItem {
    let id: HistoryItemID
    let contentVersion: ContentVersion
    let canonicalBlob: Data
    let revisionStateBlob: Data
    let canonicalSignatureBlob: Data
    let projection: ContentProjection
    let occurrence: CopyOccurrence
}

internal struct StoredRevisionUpdate {
    let itemID: HistoryItemID
    let expectedCurrentVersion: ContentVersion
    let nextVersion: ContentVersion
    let revisionStateBlob: Data
    let projection: ContentProjection
}

internal struct SignatureIndexDelta {
    let additions: [HistoryItemID: [ContentSignatureEntry]]
    let removals: Set<HistoryItemID>
}

internal struct StampedCommitPlan {
    let position: ChangePosition
    let mutations: [StampedMutation]
    let receiptOutcome: HistoryCommitOutcome
    let indexDelta: SignatureIndexDelta
}
```

Each Domain `HistoryMutation` maps to exactly one `StampedMutation`; the rename is fixed and mechanical:

| Domain `HistoryMutation` | Storage `StampedMutation` |
|---|---|
| `.create(NewHistoryItem)` | `.create(StoredNewItem)` |
| `.recordCopy(itemID:, occurrence:)` | `.updateOccurrence(itemID:, occurrence:)` |
| `.assignPin(itemID:, ordinal:)` | `.setPinOrdinal(itemID:, ordinal:)` |
| `.appendRevision(itemID:, revision:, activeRevisionID:)` | `.appendRevision(StoredRevisionUpdate)` |
| `.retire(itemID:, reason:)` | `.delete(itemID:, reason:)` |
| `.setRetentionPolicy(maximumUnpinnedItems:)` | `.setRetentionPolicy(maximumUnpinnedItems:)` (plus any emitted `.delete` victims) |

Stamping is mechanical by semantic case:

- create receives `ContentVersion.initial`, the prepared Canonical/projection, empty revision state, initial occurrence, and no pin;
- occurrence and pin mutations preserve the loaded Content Version and projections;
- append revision requires `currentVersion.successor()`, appends the complete revision, stores its active ID, and writes the prepared projection;
- delete removes the row and its Canonical signature postings;
- set retention policy writes the new `maximumUnpinnedItems` to the singleton row and emits any required `retire` victim mutations computed by `planRetention`; it preserves every item's Content Version and projections, and advances `ChangePosition` once only when the value actually changes or at least one victim retires (a same-value no-victim set returns `.unchanged` before stamping);
- the current singleton position must have a checked successor; the same successor is used for the whole plan.

The Authority never decides after planning that `.recordCopy` means “increment something” or that a pin action implies unspecified shifts. Those values are already explicit in the Domain mutation payload.

### 10. Atomic transaction

The only durable History Commit primitive is `ModelContext.transaction`:

```swift
internal enum StorageInvariant: Error {
    case positionChanged
}

try context.transaction {
    let meta = try fetchExactlyOnePositionRow(context)
    guard meta.rawValue == expectedPreviousPosition.rawValue else {
        throw StorageInvariant.positionChanged
    }

    for mutation in plan.mutations {
        try apply(mutation, in: context)
    }

    try validateFinalPinOrder(in: context)
    meta.rawValue = plan.position.rawValue
}
```

Rules:

- No `await` occurs in the closure or between fact load and closure completion.
- The executor fetches rows by `HistoryItemID`; it never passes a business ID to `registeredModel(for:)`.
- Delete fetches the actual row and calls `context.delete(row)`; it does not depend on a predicate delete seeing pending state.
- Every referenced row must exist exactly once unless the stamped case is create.
- Create IDs and revision IDs are checked for uniqueness.
- Final pin order is revalidated before closure success.
- Revision state, Content Version, and effective projections are written together.
- The singleton position is written last inside the same transaction.
- Closure failure commits nothing. There is no receipt, index delta, or invalidation.
- Closure success is the save boundary. The kernel does **not** call `save()`, `processPendingChanges()`, or a compensating `rollback()` afterward.

Apple's documented transaction behavior is a platform dependency; the scaffold gate in Part VI must confirm the exact supported-runtime behavior used by this design.

### 11. Post-commit order

After transaction success, while still isolated in `HistoryAuthority` and without suspension:

1. apply the already validated nonthrowing Signature Index delta;
2. synchronously yield `HistoryInvalidation(latestPosition:)` to registered continuations;
3. construct and return `HistoryReceipt.committed`.

Index deltas exist only for create and delete because Canonical Content never changes. Copy Coalescing and revision leave Canonical signatures untouched.

The delta is precomputed and checked before the transaction so ordinary dictionary application cannot fail after durable commit. If an internal assertion nevertheless detects index divergence, the index is marked unready; the committed state remains authoritative, observers are still invalidated, and the next capture must complete a full rebuild before deciding insert/coalesce.

A process crash after the transaction but before in-memory update loses only derived process state. Startup reconstructs the index and current position from durable rows.

### 12. Signature Index lifecycle

```swift
internal struct SignatureIndex {
    enum State {
        case unready
        case ready(generation: UInt64)
    }

    // ContentSignatureEntry → retained HistoryItemID posting set
}
```

Correctness requirements:

- Ready means every retained row contributes every Canonical signature entry exactly once.
- Startup reads all `(id, canonicalSignatureBlob)` metadata and constructs postings before declaring ready.
- An empty ready index is valid only for an empty retained store.
- Create adds all entries; delete removes all entries and empty postings.
- Every fact-load checks that candidate IDs remain retained in its serialized Authority interval.
- Fingerprints may collide; full content confirmation remains mandatory.
- Index readiness may affect capture availability, never browse/detail/paste correctness.

The index is actor-owned value state, not a second persistence authority.

### 13. Startup

`SwiftDataHistory.open` performs:

1. validate configuration and hard limits;
2. open/create the v1 `ModelContainer`;
3. enter `HistoryAuthority` and create the singleton at position 0 if this is a new store;
4. validate exactly one singleton;
5. validate retained row count does not exceed the hard bound;
6. fetch each row's business ID, nonzero Content Version, projection schema version, pin ordinal, and signature metadata;
7. require projection schema version 1 for the greenfield v1 schema;
8. decode/validate signatures and build the complete index;
9. validate the full pinned ordinal set from scalar fields;
10. publish the constructed `SwiftDataHistory` facade.

Startup does not decode Canonical/revision bytes merely to build the index. Whether the chosen SwiftData projection API truly avoids faulting those blobs is an implementation-time performance proof, not assumed prose. If the API cannot prove it, correctness remains intact but the startup performance claim must be weakened.

Corrupt durable signature or pin metadata fails open rather than enabling writes from an unproved state. v1 has no silent repair/migration path for corrupted data.

### 14. Read implementation

#### 14.1 Recent browse

Within one Authority interval:

- validate cursor/limit;
- read current position;
- fetch only scalar row projection fields;
- order pinned rows by ordinal and unpinned rows by `(lastCopiedAt DESC, id ASC)`;
- fetch at most `limit + 1` to determine continuation;
- return a value `HistoryPage` and opaque cursor.

No Canonical/revision blob is decoded.

#### 14.2 Search browse

The Authority captures a bounded `SearchCorpusSnapshot` containing position and scalar projection rows:

```swift
internal struct SearchCorpusSnapshot: Sendable {
    let position: ChangePosition
    let rows: [SearchCorpusRow]
}

internal struct SearchCorpusRow: Sendable {
    let id: HistoryItemID
    let contentVersion: ContentVersion
    let title: String
    let searchBody: String
    let typeIdentifiers: [String]
    let lastCopiedAt: Date
    let copyCount: UInt64
    let lastSource: String?
    let pinOrdinal: PinOrdinal?
}
```

`SearchWorker` evaluates exact/fuzzy/regexp over this `Sendable` snapshot and returns bounded row values. It never reads SwiftData and never uses dedup Candidate Rank.

#### 14.3 Detail and paste

Both fetch exactly one row and decode/validate its full lineage. Detail maps it to Canonical/effective/revision/occurrence DTOs. Paste maps only current Effective Content plus the current reference and lineage hint.

#### 14.4 Observation registration

`HistoryAuthority` stores `AsyncThrowingStream` continuations keyed by an internal subscription token. Registration and invalidation yield are synchronous actor operations. Cancellation removes the token. `SwiftDataHistory.observe` implements the Part IV subscribe-before-query algorithm and owns any SearchWorker task.

#### 14.5 Thumbnail source

The Authority fetches exactly one item, verifies the requested Content Version, derives Effective Content, and returns immutable source image bytes. ImageIO decode occurs only after all SwiftData objects and context have been released.

### 15. Projection rules

`ContentProjector` produces bounded values from Effective Content:

- title: first eligible textual line after normalization, otherwise a stable type-based fallback;
- search body: eligible textual representations in deterministic type order, normalized and truncated to the hard search-body bound;
- effective type identifiers: sorted unique list;
- image bytes are not decoded for title/search.

Capture projection uses initial Effective Content. Revision projection uses the prepared proposed Effective Content. Copy Coalescing, pin, unpin, clear, removal, and retention do not recompute content projection.

Projection schema changes require an explicit schema version and migration/rebuild plan. They never change Canonical Content, revisions, or Content Version by themselves; a projection-only migration is not a History Action and emits no user-visible commit.

### 16. Failure translation

At the `SwiftDataHistory` boundary:

- missing rows → `.notFound`;
- OCC mismatch → `.staleContent`;
- draft/capture/search/size/retention-policy/search-term problems → `.invalidInput` (incl. `.invalidRetentionPolicy` and `.invalidSearchTerm`);
- invalid requested anchor → `.invalidPinnedPlacement`;
- revision target absence → `.revisionNotFound`;
- cursor shape, generation, or position mismatch → `.snapshotExpired`;
- inability to rebuild the Signature Index to a proved-complete state → `.temporarilyUnavailable(.dedupIndexRebuild)` (Part V §7.1 step 1, §12);
- inability to load or prove any other action-specific complete fact → `.temporarilyUnavailable(.factProof)`;
- hard representation/byte/revision/copy-count limits → `.capacityExceeded` with the matching `CapacityKind`; a `ContentVersion`/`ChangePosition` successor overflow → `.capacityExceeded(.coherenceToken)`;
- decode/schema invariant failures or corrupt persisted values → `.persistence(.corruptStoredValue)` or `.persistence(.invariantViolation)`;
- a `ModelContext.transaction` closure failure (including the `StorageInvariant.positionChanged` guard) or any framework-level failure to durably commit the transaction → `.persistence(.transaction)`.

Platform error strings may be logged internally with privacy controls but are not used as public semantic discriminators.

### 17. Migration stance

This specification starts at `HistorySchemaV1`; it does not migrate the current repository's models.

Future changes must distinguish:

1. SwiftData schema migration for rows/columns;
2. versioned blob migration for Canonical/revision/signature payloads;
3. projection schema rebuild for derived title/search/type fields.

No future migration may invent missing active revision bytes, reinterpret an old Content Version as a new Effective Content state, reuse removed IDs, or enable capture before Signature Index completeness is restored.

### 18. Platform reference anchors

Implementation must verify assumptions against the supported SDK rather than copy pseudocode blindly:

- [ModelContext transaction](https://developer.apple.com/documentation/swiftdata/modelcontext/transaction(block:)) — closure-success transaction boundary.
- [FetchDescriptor propertiesToFetch](https://developer.apple.com/documentation/swiftdata/fetchdescriptor/propertiestofetch) — candidate scalar-projection mechanism; Part VI still requires a no-blob-decode proof.
- [ModelContext registeredModel(for:)](https://developer.apple.com/documentation/swiftdata/modelcontext/registeredmodel(for:)) — accepts `PersistentIdentifier`, which is why business-ID lookup uses a fetch.
