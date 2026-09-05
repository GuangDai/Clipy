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
    // All six stored fields are `actor` types, so each is Sendable and the
    // Sendable conformance is derived without @unchecked Sendable.
    private let authority: HistoryAuthority
    private let ingestPreparation: IngestPreparationActor
    private let revisionPreparation: RevisionPreparationActor
    private let searchWorker: SearchWorker
    private let thumbnailService: ThumbnailService
    private let externalGateway: ExternalGateway

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

`HistoryConfiguration` selects persistent or in-memory storage and the initial retention value for a new store. An existing store uses its durable singleton value; the public retention action changes it. `open` validates the initial value against Part VI's fixed range and always uses the fixed `HistoryLimits.standard` safety profile. It throws `HistoryFailure`: `.invalidInput(.invalidRetentionPolicy)` for an out-of-range `initialMaximumUnpinnedItems`, or `.persistence(.openStore)` / `.persistence(.corruptStoredValue)` / `.persistence(.invariantViolation)` for store-open or startup-corruption failures (Part V §13). A projection-rebuild transaction or durable-commit failure is `.persistence(.transaction)` under §16's uniform transaction boundary. `.memory` changes durability medium only; it uses the same Authority, planners, codecs, and transaction path.

Internal isolation:

```text
SwiftDataHistory facade
├── IngestPreparationActor
├── RevisionPreparationActor
├── SearchWorker
├── ThumbnailService / ThumbnailWorker
├── ExternalGateway
└── HistoryAuthority
    ├── ModelContainer
    ├── SignatureIndex value
    ├── validated settings
    └── observation continuations
```

`HistoryAuthority` is the sole writer. It is also the serialization point for source snapshot capture and observer registration. It stores no `@Model` instance or `ModelContext` across operations.
`ExternalGateway` owns only process-local admission state and delegates every
durable check/audit to `HistoryAuthority`; it never creates a `ModelContext`.
X.5 stores this internal denial module only after startup succeeds. The public
connection-bound facade remains absent until X.6 completes granted dispatch.

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
| `canonicalSignatureBlob` | Durable signature metadata used with authoritative Canonical bytes to rebuild the complete Signature Index in the current hard-capped profile. |
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
- fingerprint/signature coverage is checked **bidirectionally** against Canonical representations — every Canonical representation has a signature entry and every signature entry corresponds to a Canonical representation (no orphan entries). Ordinary blob decode checks the two stored copies structurally; the current hard-capped startup/unready-index paths additionally recompute xxh3 from Canonical bytes before the index may use absence as negative evidence. D7 still requires byte-exact confirmation for every positive candidate;
- unique revision IDs and bounded full revision history within the per-item revision-count/byte bounds;
- active ID: when non-nil it is unique and names exactly one stored revision; `nil` is valid only when the revision list is empty (D3); a non-nil active ID with no matching revision, or a non-empty list with a nil active ID, is corruption;
- normalized, non-empty revision content containing only Canonical representation types;
- a valid (≥1) Content Version and valid occurrence values: finite dates,
  copy count ≥1, monotone first/last copy time, and bounded source values;
- a non-negative pin ordinal (negative is corruption);
- the `effectiveTypeIdentifiersBlob` decodes to a sorted, unique, non-empty list of type identifiers at format version 1;
- `projectionSchemaVersion` is exactly the current value (v3), and the stored `title` (≤ 1,024 UTF-8 bytes) and `searchBody` (≤ 256 KiB) obey their Part VI bounds. Tags v1/v2 are accepted only by the bounded startup rebuild below; ordinary reads never consume v1/v2 projection scalars.

Projection checks live at the scalar boundary rather than inside a blob codec:
startup validates every row's schema tag; recent browse validates the fetched
schema tag and title; search validates schema, title, and search body; full-row
hydration validates all three before reconstructing lineage. An over-bound
stored value is corruption — it is never silently truncated or repaired while
reading.

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

All production business-ID lookup uses a bounded fetch predicate on
`HistoryItemRow.id`. Exactly zero or one row is valid; duplicates are
persistence corruption even though the schema also declares uniqueness.

The package-only manual-performance fixture seam is constrained by the same
boundary. It is not reachable through `ClipboardHistory`, and it does not add
a fake or second writer. `IngestPreparationActor` prepares each raw capture;
`HistoryAuthority` encodes and commits at most 64 prepared items in one fresh
context and one `ModelContext.transaction`, applies the real Signature Index
delta, publishes invalidation, and advances `ChangePosition` once for that
non-empty batch. The disposable store is proved empty first. Within each batch,
a `Set` proves candidate IDs unique; between batches, expected position and the
complete ready Signature Index prove both non-interleaving and ID absence. That
fixture-only proof avoids a full count and one business-ID query per row while
the schema uniqueness constraint remains a transaction backstop. Inputs are
trusted to have nil lineage hints and pairwise distinct,
containment-disjoint Canonical values; an incomplete setup is discarded rather
than resumed. This setup-only path trades bounded transient space for fewer
queries and transactions; production actions continue to use the one-action
planner, durable ID lookup, and stamped commit path described below.

### 6. Preparation outside the commit interval

#### 6.1 Capture preparation

`IngestPreparationActor` converts `ClipboardCapture` into:

```swift
internal struct PreparedCaptureBundle: Sendable {
    let domain: PreparedCapture
    let projection: ContentProjection
}

internal struct ContentProjection: Sendable {
    let schemaVersion: UInt16       // projection recipe v3 = 3
    let title: String
    let searchBody: String
    let effectiveTypeIdentifiers: [String]
}
```

Fixed order:

1. Reject a pasteboard-level exclusion (`ClipboardCapture.isConcealed` or an exact match in the configured best-effort third-party transient/private/concealed/auto-generated convention-string denylist), an empty capture, a non-finite observation timestamp, or a hard-limit violation. These raw strings are not Apple framework guarantees and are not a complete inventory of producer privacy behavior. Exclusion happens before payload validation or fingerprinting and returns `.invalidInput(.excludedFromHistory)`; a NaN/infinite `observedAt` returns `.invalidInput(.invalidTimestamp)` before fingerprinting.
2. Reject invalid/oversized type identifiers and bytes. The closed public v1
   vocabulary deliberately maps empty or over-envelope type identifiers to
   `.unsupportedRepresentationType`, and empty or over-envelope payload bytes
   to the capture-input `.byteLimit` bucket.
3. Enforce whole-capture exclusion for exact matches in the configured best-effort marker denylist; never filter a marker while retaining its sibling plaintext/rich representations. V1's six third-party convention strings are `org.nspasteboard.TransientType`, `org.nspasteboard.ConcealedType`, `org.nspasteboard.AutoGeneratedType`, `com.agilebits.onepassword`, `de.petermaurer.TransientPasteboardType`, and `com.typeit4me.clipping`. A non-matching type remains an ordinary representation; this step neither infers privacy from an application name nor assigns a dedup-ignore role.
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

1. Fetch the complete scalar retention inventory once, derive the retained ID
   set from its already duplicate-checked summaries, and require Signature
   Index state `.ready` for exactly that set. If the inventory fetch is
   unavailable or over the hard bound, candidacy cannot be proved and capture
   returns `.temporarilyUnavailable(.dedupIndexRebuild)` (WS5). If the index is
   unready or its retained-ID coverage differs, attempt one complete rebuild
   from every retained row's Canonical and signature blobs within the hard
   item bound, recomputing xxh3 before absence becomes negative evidence.
2. Intersect posting sets for all incoming signature entries.
3. Fetch and fully decode every candidate ID.
4. If a lineage hint exists, fetch it separately by ID even when it is absent from the candidate intersection.
5. Use the same step-1 inventory as the complete retention fact; do not issue
   a second overlapping table scan or rebuild the retained-ID set merely to
   compare two same-interval fetches.
6. Verify candidate IDs, retained IDs, and the actor-owned index value agree before constructing `IngestFacts`.

Steps 1–6 and the subsequent plan→transaction→index-apply sequence execute in
one non-suspending `HistoryAuthority` interval. Actor isolation is therefore
the interleaving proof: a generation counter would carry no independent
correctness information and is deliberately absent.

If any step cannot prove completeness, reject capture. There is no “scan the first N and insert if absent” path.

#### 7.2 Pin and unpin

Fetch target existence plus every row with a non-nil pin ordinal. Validate unique contiguous order and construct `PinFacts`. Stored corruption fails; the operation does not perform an implicit repair commit.

#### 7.3 Revision, remove, clear, retention

- Revision fetches and decodes exactly the target item.
- Remove fetches the target's scalar summary plus the complete pinned order (the §7.2 load): removing a pinned item compacts the pinned lane in the same commit (docs/02-domain.md §10, D12).
- Clear fetches every ID/pin value selected by scope.
- v1 retention fetches every retained ID, last-copied time, and pin ordinal.
  The V2 R3 policy sweep selects exceeding items from the validated scalar
  projection, then fully hydrates only those selected lineages and requires
  exact `canonicalBytes`/`revisionCount`/`revisionBytes` equality before
  destructive planning. Non-exceeding items remain on the scalar-only path;
  their content blobs and exact projection correspondence are not inspected.

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
        case ready
    }

    // ContentSignatureEntry → retained HistoryItemID posting set
}
```

Correctness requirements:

- Ready means every retained row contributes every Canonical signature entry exactly once.
- In the current hard-capped profile, startup reads each retained row's
  Canonical bytes together with `canonicalSignatureBlob`, recomputes the
  Canonical signature entries, requires bidirectional byte-count/fingerprint
  coverage, and only then constructs postings and declares the index ready.
- An empty ready index is valid only for an empty retained store.
- Create adds all entries; delete removes all entries and empty postings.
- Every fact-load checks that candidate IDs remain retained in its serialized Authority interval.
- Fingerprints may collide; full content confirmation remains mandatory.
- Index readiness may affect capture availability, never browse/detail/paste correctness.

The index is actor-owned value state, not a second persistence authority.
Its complete value is rebuilt or mutated only inside the non-suspending
Authority interval; readiness plus retained-ID coverage is the complete
same-interval proof, rather than an otherwise unread generation counter.

### 13. Startup

`SwiftDataHistory.open` performs:

1. validate configuration and hard limits;
2. open/create the current V2 `ModelContainer` through the V1 → V2 migration plan;
3. enter `HistoryAuthority` and create the singleton at position 0 if this is a new store;
4. validate exactly one singleton;
5. bootstrap/validate the retention-expansion config singleton;
6. derive every projection-schema-v1/v2 replacement from validated Canonical/revision bytes, then stamp them as recipe v3 in one bounded transaction; an unknown tag, invalid source, or failed transaction fails open without publishing a partial rebuild;
7. validate retained row count does not exceed the hard bound and fetch each row's business ID, nonzero Content Version, current projection schema version, pin ordinal, Canonical bytes, and signature metadata;
8. require projection schema version 3;
9. decode Canonical and signature metadata, recompute Canonical signature
   entries, require bidirectional coverage, and build the complete index;
10. validate the full pinned ordinal set from scalar fields;
11. enforce the `RetainedBytesRow` 1:1 correspondence and scalar relation/version fence, including the one missing-rows-only recovery rerun;
12. publish the constructed `SwiftDataHistory` facade.

The Canonical coverage pass is a correctness-first rule for the current
hard-capped profile: a structurally valid but incomplete signature blob could
otherwise create false-negative dedup candidates. Revision bytes remain
untouched except when a legacy projection row already requires recipe rebuild.
This full Canonical pass is not an admissible U-scale design. Before the global
hard item bound can be removed, `DEC-U-SCALE-STARTUP-INDEX` must replace it with
the approved durable candidate-query/lazy-shard authority and an equally strong
negative-evidence contract; it may not retain this O(N) hydration path or add a
second truth index.

Corrupt durable signature or pin metadata fails open rather than enabling
writes from an unproved state. The explicit v1-to-v2 derived-projection rebuild
is not a silent or general repair path for corrupted data.

### 14. Read implementation

#### 14.1 Recent browse

Within one Authority interval:

- validate cursor/limit;
- read current position;
- fetch only scalar row projection fields;
- order pinned rows by ordinal and unpinned rows by `(lastCopiedAt DESC, id ASC)`;
- fetch pinned rows first. A first page materializes at most `limit + 1`
  scalar rows across both lanes. A pinned continuation uses
  `fetchOffset = anchorOrdinal`, fetches the anchor plus page and lookahead
  (at most `limit + 2`), verifies the complete anchor, then drops it; this
  preserves O(`limit`) work without accepting a malformed cursor;
- for an unpinned continuation, fetch at most `limit + 2` in the normal case:
  the inclusive date bound returns the anchor plus `limit` rows and one
  lookahead. Because the store is not trusted to sort UUID ties, a full slice
  is ordered by `(lastCopiedAt DESC, id ASC)` and re-fetched up to the hard
  retained-item bound when consumed same-date rows contaminate the slice head,
  the anchor is absent, or the true page/lookahead boundary ties;
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
Exact/regexp scans retain only the continuation anchor and at most `limit + 1`
subsequent matches. Fuzzy still scores the complete corpus, but retains only
the best `limit + 1` post-anchor matches and the matching anchor, sorting only
those candidates. This bounds evaluated-result storage; it does not replace
the full corpus snapshot or change the frozen score/date/ID ordering.

#### 14.3 Detail and paste

Both fetch exactly one row and decode/validate its full lineage. Detail maps it to Canonical/effective/revision/occurrence DTOs. Paste maps only current Effective Content plus the current reference and lineage hint.

The Settings `usage()` read joins existing validated retained-byte projections
to item-ID and pin-ordinal scalars in one operation-local context, alongside
the current position. It returns item/pinned counts and Canonical/revision
byte sums. Missing or orphan projections fail the read instead of displaying
a partial total. Content blobs are not decoded, and the read writes no state.

#### 14.4 Observation registration

`HistoryAuthority` stores `AsyncThrowingStream` continuations keyed by an internal subscription token. Registration and invalidation yield are synchronous actor operations. Cancellation removes the token. `SwiftDataHistory.observe` implements the Part IV subscribe-before-query algorithm and owns any SearchWorker task.

#### 14.5 Thumbnail source

`ThumbnailService` installs an exact-key source-to-decode task before its first suspension. The creator asks the Authority to fetch and fully hydrate exactly one item, verify the requested Content Version, derive Effective Content, and return immutable source image bytes. An existing-flight caller instead asks the Authority for a scalar-only dimension/existence/version fence before awaiting that task. ImageIO decode occurs only after all SwiftData objects and context have been released; no joiner rehydrates the content blob.

The worker aspect-fits the primary image into both requested pixel dimensions,
using its display orientation when computing the downsample limit. Neither
decoded axis exceeds the corresponding requested axis; aspect ratio is
preserved to pixel rounding, with no upscaling. The payload retains the
requested `PixelSize` as its key, even when the encoded image is smaller.

#### 14.6 Configured retention read

`HistoryAuthority.retentionConfiguration()` creates one fresh read context and,
within one non-suspending Authority interval, loads the position singleton's
validated `maximumUnpinnedItems` and the retention-expansion singleton's
validated enabled/value lanes. It returns one immutable
`HistoryRetentionConfiguration`. Disabled expansion lanes map to `nil`; dormant
placeholder columns never become configured policy. Missing, duplicate,
wrong-version, non-finite, or out-of-range singleton state fails closed through
the existing persistence taxonomy. The read performs no write, emits no
invalidation, and exposes neither current retained-byte usage nor a
`ChangePosition`/OCC token (`V2-02` §8.1a; `DEC-RET-READ`).

### 15. Projection rules

`ContentProjector` produces bounded values from Effective Content:

- title: first eligible textual line after normalization, otherwise a stable type-based fallback;
- search body: eligible textual representations in deterministic type order, normalized and truncated to the hard search-body bound;
- textual decoding is type-strict under projection recipe v3: only
  `public.utf8-plain-text` uses UTF-8. `public.utf16-plain-text` uses native
  UTF-16 (little-endian on arm64); `public.utf16-external-plain-text` uses
  external UTF-16 (big-endian without a BOM). Both honor a leading byte-order
  mark. The former misspelling `public.utf8-external-plain-text` is an unknown
  opaque identifier. `public.plain-text` has no
  declared encoding; `public.text` is abstract; RTF and HTML are structured
  formats. Those four families remain opaque and never enter title/search
  through a guessed UTF-8 decode. Malformed bytes of an exact plain type are
  skipped, never guessed through a fallback encoding;
- effective type identifiers: sorted unique list;
- image bytes are not decoded for title/search.

Capture projection uses initial Effective Content. Revision projection uses the prepared proposed Effective Content. Copy Coalescing, pin, unpin, clear, removal, and retention do not recompute content projection.

The projector constructs the joined search body directly under that hard
UTF-8 bound; it does not materialize an unbounded concatenation and truncate it
afterward. Read paths that need only a revision-summary title use the title-only
projection and do not construct a search body.
Details reuse the validated durable Effective title for the active revision's
summary; inactive revision summaries still project their own content titles.

Projection schema changes require an explicit schema version and migration/rebuild plan. They never change Canonical Content, revisions, Content Version, or Change Position by themselves; a projection-only migration is not a History Action and emits no user-visible commit.

Projection recipe v2 removed guessed text decoding. Recipe v3 corrects the
external UTF-16 identifier and the native no-BOM byte order. `HistoryItemRow` already
carries the consistency fence, so this is not a SwiftData schema change and
does not add a schema-migration stage. During `SwiftDataHistory.open`, after
singleton bootstrap and before Signature Index publication or capture, the
Authority fetches at most the hard retained-item bound plus one, accepts only
projection tags 1, 2, and 3, then derives every v1/v2 replacement from validated
Canonical/revision bytes before entering one `ModelContext.transaction` that
updates the title, search body, effective-type blob, and tag. Source decode
failure, an unknown tag, or
transaction failure leaves no partially published v3 set and fails the open.
Ordinary reads accept only v3. The rebuild preserves unknown representation
bytes even when their old guessed title/search text is removed.

Future changes to textual decoding, normalization, title, or body derivation
must increment the projection schema again and ship an explicit bounded
rebuild plan.

### 16. Failure translation

At the `SwiftDataHistory` boundary:

- missing rows → `.notFound`;
- OCC mismatch → `.staleContent`;
- draft/capture/search/size/timestamp/retention-policy/search-term problems → `.invalidInput` (incl. `.excludedFromHistory`, `.invalidTimestamp`, `.invalidRetentionPolicy`, and `.invalidSearchTerm`); excluded or non-finite-timestamp captures produce no receipt, durable commit, fingerprint, or invalidation;
- invalid requested anchor → `.invalidPinnedPlacement`;
- revision target absence → `.revisionNotFound`;
- cursor shape, generation, or position mismatch → `.snapshotExpired`;
- inability to rebuild the Signature Index to a proved-complete state → `.temporarilyUnavailable(.dedupIndexRebuild)` (Part V §7.1 step 1, §12);
- inability to load or prove any other action-specific complete fact → `.temporarilyUnavailable(.factProof)`;
- a durable transaction error whose Cocoa code is `fileWriteOutOfSpace` or whose POSIX code is `ENOSPC` (directly or in the single observed `NSUnderlyingErrorKey` wrapper) → `.temporarilyUnavailable(.insufficientDiskSpace)`; classification uses domains/codes, never localized strings;
- stamped-plan capacity admission → `.temporarilyUnavailable(.insufficientDiskSpace)`: before executing any stamped plan, the single writer refuses it — typed, with no receipt, durable commit, or invalidation — when the store volume's readable raw available-capacity fact (`volumeAvailableCapacity`) is below the plan's new external-storage payload total plus a fixed 1 MiB margin. The raw fact, not the important-usage variant, is authoritative here: the OS maintains purgeable-space accounting only on the boot volume, and the important-usage fact was observed returning zero on a dedicated mounted volume (dispatch run 32634051113, 254 MiB free, every capture refused); the raw fact matches the filesystem's own accounting on every volume and errs conservative on the boot volume, where ignoring purgeable space yields a typed, retryable refusal. The payload total counts the encoded `CanonicalBlobV1`/`RevisionStateBlobV1` bytes carried by `.create`, `.appendRevision`, and `.pruneRevisions` mutations (the wire-format byte counts Core Data externalizes, not raw clipboard bytes); plans writing no new external bytes — byte-exact copy coalescing, pin/occurrence/policy/delete-only commits — are never refused, and an unreadable capacity fact (in-memory store or unavailable resource value) leaves the path unrefused. Admission exists because the external-storage save path returns no out-of-space error at all: creating the `_EXTERNAL_DATA` interim file on a full volume raises an uncaught `NSInternalInconsistencyException` that terminates the process before this section's translation runs (Card 6B physical-ENOSPC runner evidence, 2026-08-23). An exhaustion that begins after admission passes remains that framework crash ceiling, not a typed failure;
- hard retained/revision/copy-count limits → `.capacityExceeded` with the matching `CapacityKind`; valid encoded thumbnail output over the Part VI byte envelope → `.capacityExceeded(.thumbnailBytes)`; a `ContentVersion`/`ChangePosition` successor overflow → `.capacityExceeded(.coherenceToken)`;
- an image representation that ImageIO cannot interpret or render as a thumbnail → `.thumbnailUnavailable`; this is not evidence of persisted-value corruption and does not affect byte-exact capture, detail, or paste. The selected candidate still fails without falling back to another representation;
- decode/schema invariant failures or corrupt persisted values → `.persistence(.corruptStoredValue)` or `.persistence(.invariantViolation)`;
- a PNG destination/finalization failure after source decode → `.persistence(.invariantViolation)` (encode-side invariant, never stored-value corruption);
- any other `ModelContext.transaction` closure failure (including the `StorageInvariant.positionChanged` guard) or framework-level failure to durably commit the transaction → `.persistence(.transaction)`.

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
