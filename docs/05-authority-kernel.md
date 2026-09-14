## Part V — Authority Commit Kernel

> **2026-09-07:** [V2-09](v2/V2-09-multilevel-storage.md) supersedes the
> SwiftData models, aggregate Canonical/revision persistence, context lifecycle
> and full Signature Index from the original v1 design. The replacement uses normalized
> SQLite rows and immutable blob files. File publication precedes reference
> insertion; item mutations, accounting, HCR, Gateway audit and ChangePosition
> share one SQL transaction. Failed commits preserve old History; cleanup only
> unlinks files after checking committed references. The two process-death test
> points now precede SQL COMMIT and prove complete-old recovery, not physical
> power-loss or interruption inside the COMMIT syscall.

### 1. Role

`HistoryStorage` is the only product target that imports SQLite3 and xxh3. It provides `SQLiteHistory`, the production `ClipboardHistory` adapter, and hides all persistence types.

Its responsibilities are deliberately asymmetric:

- translate raw public values into validated Domain inputs;
- load action-specific facts with proved completeness;
- invoke pure Domain planners;
- mechanically stamp semantic plans with versions and durable projections;
- apply one atomic SQLite transaction including persistent candidate postings;
- publish a process-local invalidation;
- project purpose-specific read values.

It does not duplicate dedup winner selection, Copy Occurrence folding, pin-order planning, revision semantics, or retention victim selection.

### 2. Public concrete adapter and internal actors

The public adapter is `SQLiteHistory: ClipboardHistory, Sendable`.
`SQLiteHistory.open(configuration:)` accepts `HistoryConfiguration` with
`persistence: HistoryPersistence` and `initialMaximumUnpinnedItems: Int? = 200`.
Persistence is either `.persistent(storeURL:)` or `.temporary`; both use the
same SQLite database and immutable blob implementation. A temporary directory
lives until its last owner/read finishes. A nil initial count disables count
retention; an enabled count must be positive. Existing stores retain their
persisted configuration.

The facade holds six actor references, the immutable store location and
App Intents connection identity, and the persistent-store ownership lifetime.
Its Sendable conformance is derived. Exact declarations live in
[SQLiteHistory.swift](../Sources/HistoryStorage/SQLiteHistory.swift) and
[Configuration.swift](../Sources/HistoryStorage/Configuration.swift).

```text
SQLiteHistory facade
├── IngestPreparationActor
├── RevisionPreparationActor
├── SearchWorker → request-owned SQLite read connections
├── ThumbnailService / ThumbnailWorker
├── ExternalGateway → durable work delegated to HistoryAuthority
└── HistoryAuthority
    ├── SQLiteDatabase (sole writable connection)
    ├── ImmutableBlobStore
    ├── configuration and scalar accounting
    └── observation continuations
```

Database/statement handles never cross actors. The public connection-bound
`ExternalHistoryFacade` uses this same Authority through ExternalGateway.

### 3. SQLite schema and immutable content

[SQLiteHistorySchema.swift](../Sources/HistoryStorage/SQLiteHistorySchema.swift)
owns the current SQL schema. There are no SwiftData models, ModelContainer,
ModelContext, or ten-model schema.

| Durable values | Storage |
|---|---|
| ChangePosition, count policy, retained/pinned counts and logical byte totals | `history_state` singleton |
| Item identity, ContentVersion, current content pointer, occurrence facts, pin order and exact UTF-8 projections | `history_items` |
| Per-application copy occurrences | `copy_sources` |
| Immutable Canonical/revision metadata | `contents` |
| Ordered representations, type identifiers, byte counts and candidate fingerprints | `representations` |
| Representation bytes | Exactly one of inline SQLite bytes or a UUID-named immutable blob reference |
| Age/storage/revision policy | `retention_policies` singleton |
| Search candidate postings | Contentless FTS5 `history_search`, maintained with item changes |
| Connections, grants, request audit and History Change Record journal | Current Gateway/HCR tables in the same database |

Titles/search bodies remain exact UTF-8 Data stored as SQLite BLOBs. Indexes
filter candidates; byte-exact confirmation decides equality. Item IDs and
blob UUIDs are independent identities, never content hashes.

Files are published and synchronized before SQL references commit. Removal
commits reference changes first, then bounded cleanup checks current references
before unlinking. Schema shape, content placement and startup are specified in
[V2-09 §§3–6](v2/V2-09-multilevel-storage.md); no dual writing, migration,
legacy-store reading or automatic deletion of an unreadable store is added.

### 4. Versioned storage codecs

Domain values do not gain synthesized `Codable` conformance merely for persistence. The existing explicit codecs below retain their validation contracts; aggregate Canonical/revision/signature blobs are not the current SQLite content layout (§3). Effective type identifiers and other purpose-specific encoded values still use their owning codecs:

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
- fingerprint/signature coverage is checked **bidirectionally** against Canonical representations — every Canonical representation has a signature entry and every signature entry corresponds to a Canonical representation (no orphan entries). Aggregate codec decode checks the two encoded copies structurally; current SQLite candidate reads use normalized representation rows and confirm matching content bytes. D7 still requires byte-exact confirmation for every positive candidate;
- unique revision IDs and bounded full revision history within the per-item revision-count/byte bounds;
- active ID: when non-nil it is unique and names exactly one stored revision; `nil` is valid only when the revision list is empty (D3); a non-nil active ID with no matching revision, or a non-empty list with a nil active ID, is corruption;
- normalized, non-empty revision content containing only Canonical representation types;
- a valid (≥1) Content Version and valid occurrence values: finite dates,
  copy count ≥1, monotone first/last copy time, and bounded source values;
- a non-negative pin ordinal (negative is corruption);
- the `effectiveTypeIdentifiersBlob` decodes to a sorted, unique, non-empty list of type identifiers at format version 1;
- `titleUTF8` (≤ 1,024 bytes) and `searchBodyUTF8` (≤ 256 KiB) are valid UTF-8 within their Part VI bounds. There is no projection schema tag or legacy read path.

Projection checks live at the scalar boundary rather than inside a blob codec:
recent browse validates the fetched title; search validates title and search
body; full-row hydration validates both before reconstructing lineage. An over-bound
stored value is corruption — it is never silently truncated or repaired while
reading.

Any violation is `.persistence(.corruptStoredValue)` or `.persistence(.invariantViolation)`. The decoder does not silently drop bad representations, choose a duplicate, reset to Canonical, or repair pin order locally.

Encode starts from validated Domain/stamped values and is deterministic. Round-trip equivalence is a Part VI gate.

### 5. Connection confinement

Only `HistoryAuthority` owns the writable `SQLiteDatabase` and
`ImmutableBlobStore`. Its connection persists across operations; statements
are finalized within their owning interval. No database, statement or file
handle crosses an actor boundary.

Reads that combine position and rows use one SQLite read transaction.
Commit fact loading, final position validation and SQL commit run under the
Authority's isolation. Any preparation that yields must validate its captured
position before applying a plan; there is no suspension inside a SQL
transaction. Business-ID lookup uses indexed SQL predicates.

The package-only performance fixture also uses this Authority and its real
SQL transaction path. It is not a second writer or caller-facing operation.

### 6. Preparation outside the commit interval

#### 6.1 Capture preparation

`IngestPreparationActor` converts `ClipboardCapture` into:

```swift
internal struct PreparedCaptureBundle: Sendable {
    let domain: PreparedCapture
    let projection: ContentProjection
}

internal struct ContentProjection: Sendable {
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

Read scalar accounting and query the persistent representation indexes for
the incoming signature entries. Stream candidate confirmation against exact
Canonical bytes; retain the current candidate and confirmed winner, not a
history-sized array of content. Resolve any lineage hint by indexed item ID
and confirm its current Effective Content bytes.

Check the prepared item's ID for occupancy and load the oldest eligible
unpinned prefix required by count retention. Enabled age/storage policies
load their purpose-specific facts. The complete result feeds the pure
planner; incomplete or corrupt facts reject capture without insertion.
There is no resident SignatureIndex readiness state or startup rebuild.

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

`SQLiteHistory.perform` uses one exhaustive switch:

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
enter isolated Authority interval
→ load exact facts
→ call the action-specific pure planner
→ if unchanged: return .unchanged
→ derive/stamp a StampedCommitPlan
→ validate the stamped values and receipt
→ execute one transaction
→ synchronously yield one HistoryInvalidation
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

`SQLiteDatabase.writeTransaction` is the durable commit primitive, using
SQLite BEGIN/COMMIT and ROLLBACK on failure. The Authority publishes new
immutable files before the transaction, validates the expected previous
position and any external authorization, applies typed mutations, validates
required final pin order, and commits accounting, HCR, Gateway audit and the
new ChangePosition together.

No `await` occurs inside the transaction. A failed transaction leaves the
previous History and referenced content intact, returns no committed receipt
and publishes no invalidation. Newly written unreferenced files are eligible
for bounded cleanup; old payload files are not deleted during rollback.
See [HistoryAuthority+TransactionExecution.swift](../Sources/HistoryStorage/HistoryAuthority+TransactionExecution.swift).

### 11. Post-commit order

After SQLite commit succeeds, the Authority synchronously publishes the
process-local invalidation and returns the committed receipt. Persistent
candidate postings already belong to that transaction; there is no second,
post-commit in-memory index update. Cleanup of unreferenced files is derived
work and cannot change a successful receipt.

### 12. Persistent candidate lookup

Candidate postings live in indexed SQLite representation rows. Capture queries
those rows and confirms candidates with exact bytes. Positive fingerprints
alone never establish identity, and failure to read or validate candidates
never establishes absence. No full-store resident signature/ID index,
readiness state or Canonical startup scan is constructed.

### 13. Startup

`SQLiteHistory.open` validates configuration, establishes the persistent
store's existing ownership lifetime when applicable, and opens its SQLite/blob
location. One Authority transaction creates or validates the current schema,
the History singleton and retention configuration, Gateway state and the
retained HCR suffix. The facade is published only after those owners are ready.

Startup does not hydrate all Canonical payloads, build a resident ID/signature
index or load a search corpus. Reads validate the metadata and content they
consume. Existing unreadable or unsupported stores fail without migration,
backfill, repair or automatic deletion. Temporary stores exercise the same
startup and independent read-connection path.

### 14. Read implementation

#### 14.1 Recent browse

One Authority read transaction joins ChangePosition, cursor validation and
bounded scalar page queries. Pinned items sort by ordinal; recent items sort
by last-copy date and stable UUID text. SQL keyset predicates retain complete
tie ordering without fetching a full tie group. Forward and backward cursors
remain bound to query, process and position. No Canonical/revision payload is
decoded for a page.

#### 14.2 Search browse

SearchWorker opens a request-owned SQLite read connection and transaction.
Position, candidate batches and final excerpts come from this one snapshot.
FTS5 narrows eligible exact-search candidates; fuzzy/regexp evaluation uses
bounded scalar batches and bounded result retention. Request cancellation
and deadlines release the reader. There is no full-store SearchCorpusSnapshot
or search-content cache. See
[SearchWorker+SQLite.swift](../Sources/HistoryStorage/SearchWorker+SQLite.swift)
and Part IV §1.

#### 14.3 Detail and paste

Both fetch exactly one row and decode/validate its full lineage. Detail maps it to Canonical/effective/revision/occurrence DTOs. Paste maps only current Effective Content plus the current reference and lineage hint.

The Settings `usage()` read joins existing validated retained-byte projections
to item-ID and pin-ordinal scalars in one operation-local context, alongside
the current position. It returns item/pinned counts and Canonical/revision
byte sums. Missing or orphan projections fail the read instead of displaying
a partial total. Content blobs are not decoded, and the read writes no state.

#### 14.4 Observation registration

`HistoryAuthority` stores `AsyncThrowingStream` continuations keyed by an internal subscription token. Registration and invalidation yield are synchronous actor operations. Cancellation removes the token. `SQLiteHistory.observe` implements the Part IV subscribe-before-query algorithm and owns any SearchWorker task.

#### 14.5 Thumbnail source

`ThumbnailService` installs an exact-key source-to-decode task before its first suspension. The creator asks the Authority to verify the requested Content Version from scalar fields, select the effective image representation and return its validated immutable bytes. An existing-flight caller uses the same scalar dimension/existence/version check before awaiting that task. ImageIO decode occurs after the Authority source-read interval; no joiner rereads the content.

Distinct creators wait for the preceding source-to-decode operation to finish
before loading their own source. Waiting tasks retain request identity and the
source-loading closure, not hydrated image bytes. A completion-only task tail
advances on success, no-image, and failure, and is cleared when no flights remain.

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

- title: first eligible textual line after normalization; otherwise, when no known image is present, a valid copied reference supplies its decoded filename or original URL address before the stable type-based fallback;
- search body: eligible textual representations in deterministic type order, normalized and truncated to the hard search-body bound; a reference supplying the title instead contributes its original address and non-empty decoded path, separated by a newline under the same normalization and byte bound;
- plain-text decoding is type-strict: only
  `public.utf8-plain-text` uses UTF-8. `public.utf16-plain-text` uses native
  UTF-16 (little-endian on arm64); `public.utf16-external-plain-text` uses
  external UTF-16 (big-endian without a BOM). Both honor a leading byte-order
  mark. An odd byte count is rejected as a complete malformed representation
  before Foundation decoding; a valid prefix followed by an incomplete
  UTF-16 code unit never contributes to the title or search body.
  The former misspelling `public.utf8-external-plain-text` is an unknown
  opaque identifier. `public.plain-text` has no
  declared encoding; `public.text` is abstract; RTF and HTML are structured
  formats. Those four families remain opaque and never enter title/search
  through a guessed UTF-8 decode. Malformed bytes of an exact plain type are
  skipped, never guessed through a fallback encoding;
- effective type identifiers: the unique union across all constituent items,
  globally sorted by Unicode scalar order (V2-09 §11). This metadata order
  does not reorder content: capture and paste retain item positions, and
  each item retains its own normalized representation set;
- image bytes are not decoded for title/search.

Reference metadata is parsed locally from the first exact `public.url` or
`public.file-url` representation, only after plain text supplies no title and
only when no known image is present. Its selected source is limited to 16 KiB,
strictly decoded as UTF-8 without discarding a BOM, and validated as an absolute
URL without repairing invalid characters. File references must have an absolute
path; their title is the last non-empty component of the decoded path, split
at U+002F scalar boundaries without re-decoding (or the path for an all-slash
root). Other URLs retain the original address as the title. Both contribute
the original address and non-empty decoded URL path to search. No file existence,
resource attributes, symlinks, bookmarks, or network destination is consulted.
An invalid or oversized first reference keeps the old opaque fallback rather
than selecting a later reference. A textual title that merely truncates to an
empty display prefix still owns the projection; reference metadata cannot
replace it. `projectTitle` computes the same title without assembling a corpus.

Capture projection uses initial Effective Content. Revision projection uses the prepared proposed Effective Content. Copy Coalescing, pin, unpin, clear, removal, and retention do not recompute content projection.

The projector constructs the joined search body directly under that hard
UTF-8 bound; it does not materialize an unbounded concatenation and truncate it
afterward. Read paths that need only a revision-summary title use the title-only
projection and do not construct a search body.
Details reuse the validated durable Effective title for the active revision's
summary; inactive revision summaries still project their own content titles.

The prepared projection is a value containing Strings; the transaction stores
their exact UTF-8 bytes. This avoids the observed leading-U+FEFF loss when
SwiftData materialized String columns, including body-only search content
longer than the title. Readers decode these bytes strictly without stripping
content markers. Malformed source text is skipped by the projector while its
raw representation remains retained; malformed stored projection bytes fail
the consuming read instead of being reprojected.

Earlier recipe-number and startup-rebuild sections are retired history, not
current compatibility obligations. Their useful decoding fixes remain in the
current algorithm: exact UTF-16 identifiers and byte order, rejection of odd
UTF-16 tails, and inert reference metadata. The current schema has no recipe
tag and no automatic reconstruction of old development stores. Projection
changes do not authorize rewriting Canonical/revision bytes or fabricating
`ContentVersion`/`ChangePosition` advances.

### 16. Failure translation

At the `SQLiteHistory` boundary:

- missing rows → `.notFound`;
- OCC mismatch → `.staleContent`;
- draft/capture/search/size/timestamp/retention-policy/search-term problems → `.invalidInput` (incl. `.excludedFromHistory`, `.invalidTimestamp`, `.invalidRetentionPolicy`, and `.invalidSearchTerm`); excluded or non-finite-timestamp captures produce no receipt, durable commit, fingerprint, or invalidation;
- invalid requested anchor → `.invalidPinnedPlacement`;
- revision target absence → `.revisionNotFound`;
- cursor shape, generation, or position mismatch → `.snapshotExpired`;
- inability to load or prove any other action-specific complete fact → `.temporarilyUnavailable(.factProof)`;
- a durable transaction error whose Cocoa code is `fileWriteOutOfSpace` or whose POSIX code is `ENOSPC` (directly or in the single observed `NSUnderlyingErrorKey` wrapper) → `.temporarilyUnavailable(.insufficientDiskSpace)`; classification uses domains/codes, never localized strings;
- SQLite `SQLITE_FULL`, or filesystem out-of-space errors during immutable-file publication, map to `.temporarilyUnavailable(.insufficientDiskSpace)`; corrupt SQLite pages map to `.persistence(.corruptStoredValue)`. The retired Core Data external-storage exception is not a current storage failure path;
- revision/copy-count resource limits → `.capacityExceeded` with the matching `CapacityKind`; valid encoded thumbnail output over the Part VI byte envelope → `.capacityExceeded(.thumbnailBytes)`; a `ContentVersion`/`ChangePosition` successor overflow → `.capacityExceeded(.coherenceToken)`;
- an image representation that ImageIO cannot interpret or render as a thumbnail → `.thumbnailUnavailable`; this is not evidence of persisted-value corruption and does not affect byte-exact capture, detail, or paste. The selected candidate still fails without falling back to another representation;
- decode/schema invariant failures or corrupt persisted values → `.persistence(.corruptStoredValue)` or `.persistence(.invariantViolation)`;
- a PNG destination/finalization failure after source decode → `.persistence(.invariantViolation)` (encode-side invariant, never stored-value corruption);
- any other SQLite transaction failure (including the `StorageInvariant.positionChanged` guard) or framework-level failure to durably commit the transaction → `.persistence(.transaction)`.

Platform error strings may be logged internally with privacy controls but are not used as public semantic discriminators.

### 17. Current-only storage stance

The user's 2026-09-06 direction retires historical schema compatibility for
this new project. Keep one current model set, not frozen model generations,
migration stages, legacy columns, backfills, or projection-recipe rebuilds.
Older development stores are not compatibility targets. This is not permission
for the application to silently delete or reset an unreadable store.

Current codecs still validate their declared wire versions and fail closed on
corruption. Immutable revision IDs and bytes, `ContentVersion`,
`ChangePosition`, occurrence facts, and pin order remain business invariants;
removing schema history does not remove their checks. Retired migration/recipe
sections elsewhere in the historical design archive are not instructions to
reintroduce compatibility infrastructure.

### 18. Platform assumptions

The supported macOS SDK and direct storage tests verify SQLite transaction,
snapshot, corruption and immutable-file publication behavior. The historical
SwiftData fetch/refresh API discussion does not constrain this implementation.
