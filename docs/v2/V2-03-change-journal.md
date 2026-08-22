# V2-03 - Change Journal & Reconnect (J1 durable History Change Record + reconnect cursor + collection cache)

> **Status (2026-07-25):** V2 design-consolidated, scaffold proof pending. This
> doc extends the v1 specification (`00`–`06`) by **addition only**.
> v1 owns v1 read/observation behavior; V2-03 owns the durable History Change
> Record (HCR) journal, the reconnect cursor, and the G2 collection cache, grafted
> onto the v1 commit seam. It redefines no v1 public type, `HistoryAction` case,
> `HistoryMutation` case, `StampedMutation` case, `PlannedOutcome` case, schema
> column, codec, invariant (D1–D19, `02` §14), or proof gate. The frozen v1
> `HistoryFailure` enum is **untouched** (V2-03 introduces a sibling
> `ReconnectFailure`, see §6.3). Like v1 and V2-01/V2-02 at consolidation time,
> V2-03 is "design-consolidated, scaffold proof pending."

## 1. Role and boundary

V2-03 answers one question:

> *How is a durable, crash-consistent record of every History Commit - plus an
> expiry-bounded reconnect cursor and a coherence-lawful collection cache -
> grafted onto the v1 single-writer commit kernel without weakening a single v1
> load-bearing decision, the v1 transient invalidation contract, or D1–D19?*

J1 (`V2-00` §3) bundles three deliverables onto one substrate:

1. **Durable append-only History Change Record (HCR) journal.** A new V2 table;
   each record is one row per History Commit, written **atomically with its item
   mutations in the same `ModelContext.transaction`** (`05` §10) by the sole
   writer `HistoryAuthority` (`00` §3.3). It is the *completeness mechanism* a
   collection cache may depend on (`04` §12: "Any future collection cache
> requires a durable change journal or another proved completeness mechanism; the
> transient v1 invalidation stream is insufficient").
2. **Reconnect cursor.** An opaque, expiry-bounded, `Codable` token a consumer
   persists and presents to ask "changes since cursor." Replay is **provably
   complete or the cursor is rejected** (D26) — never partial/incorrect.
3. **Collection cache (the G2 cache).** An in-memory list/search result cache
   (`V2-00` §6.2 "Caches: sit between Authority reads and the caller") whose
   invalidation is driven by the HCR stream and which obeys the Part IV §12
> cache law.

V2-03 owns:

- the HCR data model (a new V2 `HistoryChangeRecordRow` table, a versioned
  `AffectedItemsBlobV1` codec, a new public `JournalEntryKind` enum, and a
  `JournalConfigRow` singleton, all internal to `HistoryStorage` except the
  public reconnect DTOs);
- the HCR append path (a capability-gated extension of the v1 stamping +
  transaction stages, `05` §9/§10);
- the `ChangeJournal` reader (a new internal `actor`) and the `ReconnectCursor` /
  `ReconnectBatch` / `HistoryChangeRecord` public DTOs;
- the `CollectionCache` (a new internal `actor`) and its HCR-driven invalidation;
- journal retention/compaction, crash-consistency, and startup validation;
- the six graft-admission records (`V2-00` §4), V2 proof gates, migration
  impact, and new invariants **D25–D28**.

V2-03 owns no `HistoryAction` case, no `HistoryMutation` case, no
`StampedMutation` case, no `PlannedOutcome` case, and no change to the closed
`ClipboardHistory` protocol or to the v1 `HistoryFailure` enum. The Domain
(`HistoryDomain`) is untouched by the journal: it remains pure, Foundation-only,
and unaware that a journal exists.

### 1.1 What V2-03 is NOT

- **Not a replacement for v1 live observation.** v1 live observation stays
  snapshot-replacement using the process-local transient `HistoryInvalidation`
  (`04` §4–§5). The journal adds **durable** reconnect (cross-restart resume)
  and the **completeness mechanism** for the collection cache; it does not enter
  the v1 observer's wake predicate (D28, §16).
- **Not multi-device sync.** The journal is **local** durability + reconnect
  only (`V2-00` §3.1 excludes CloudKit / multi-device sync).
- **Not an audit log.** The HCR records the *fact* and *kind* of each History
  Commit for reconnect/cache completeness, not the *provenance* of an external
  write. The audited external-write record is X2's `OperationRecord` (V2-05); the
  HCR does not replace it (`04` §4 separates "audit identity" from the
  invalidation signal, which the HCR likewise does not carry).
- **Not a reconstruction of past changes.** Migration starts the journal EMPTY
  (Record 5); past changes are not backfilled. Reconnect covers only
  post-migration, post-cursor changes.

### 1.2 What V2-03 explicitly lifts

J1 (`V2-00` §3) lifts two pieces of machinery v1 deliberately left **absent** and
records that absence as a graft trigger: (a) the durable Change Cursor /
`changes(since:)` reconnect surface (`04` §11 "Durable Change Cursor / reconnect"
is out of v1 scope), and (b) the collection cache (`06` §3 G2, deferred). V2-03
is the graft that supplies both. The HCR is the substrate that makes the
collection cache's invalidation provably complete (`04` §12) and that gives
reconnect a durable, ordered delta source; neither exists in v1. This is stated
honestly here rather than implied: a v1 reader finds no `changes(since:)`, no
durable journal, and no collection cache, by design.

## 2. Capability scope

### 2.1 In scope (J1)

- Appending exactly one HCR row per non-empty History Commit (insert / coalesce /
  pin / unpin / remove / clearAll / clearUnpinned / revise / retire / policySet /
  retireRevision), inside the same `ModelContext.transaction` as the item
  mutations, advancing no second `ChangePosition` (the HCR's journal `sequence`
  is *equal to* the commit's `ChangePosition`, §4.3).
- A reconnect reader that, given a `ReconnectCursor`, returns the ordered
  `[HistoryChangeRecord]` whose `sequence` exceeds the cursor, plus a successor
  cursor, or rejects the cursor with a typed failure (D26).
- A collection cache for `browse(.recent)` / `browse(.search)` results, keyed by
  (normalized query shape, `ChangePosition`, materializer schema version),
  invalidated by the HCR stream, obeying `04` §12 (D27).
- Journal retention/compaction that never breaks a live cursor (a cursor whose
  records were compacted is rejected as expired, D26).
- A durable `JournalConfigRow` singleton carrying retention bounds, the
  generation counter, and the materializer schema version.

### 2.2 Out of scope (remains post-V2)

- **Multi-process direct writers / CloudKit sync** (`V2-00` §3.1). The HCR is
  local; a second process opening its own `ModelContainer` against the same store
  is excluded. The HCR records only commits made through this process's
  `HistoryAuthority`.
- **Incremental delta-application in the collection cache.** The cache is
  invalidated by the HCR stream and refetches authoritative state on miss; it
  does not synthesize new pages by applying HCR deltas to cached pages. That
  finer-grained incremental maintenance is a future optimization gated by
  `J1-PERF-3`; the cache law (`04` §12) is satisfied by provably-complete
  invalidation + refetch-on-miss (Record 4).
- **Backfill of pre-migration history.** The journal starts empty at M1
  migration (Record 5).
- **A durable collection cache.** The collection cache is in-memory; restart
  empties it (cache law: restart produces semantically identical values, only
  latency differs). Only the HCR is durable.
- **Enrichment-derived change records.** V2-01 enrichment writes (`V2-01` §6.4
  `persistEnrichment`, `setEnrichmentEnabled`) are **not** History Commits — they
  advance no `ChangePosition` (`V2-01` §4.1) — so they produce **no** HCR record.
  The HCR records only History Commits.

### 2.3 Evidence triggers (admit design work)

Per `V2-00` §3, J1 admits design work when **either**:

- the **G2 performance trigger** fires: at the hard retained bound (5,000 items,
  `06` §2), recent/search p95 exceeds 50 ms **or** Authority queue wait p95
  exceeds 20 ms under the agreed workload (`06` §3 G2); **or**
- an **approved reconnect product requirement** is recorded (e.g., a
  "recently removed" surface or a background consumer resuming across restart).

Until one trigger fires, V2-03 is design only and reserves no v1 surface.

## 3. Decision: custom append-only HCR vs SwiftData native History

The brief's pivotal question: Core Data exposes `NSPersistentHistoryChangeRequest`;
does SwiftData expose an equivalent usable as the journal? **Yes — SwiftData
ships a native History API** (`V2-facts.md` cycle 7 §7.1, facts 1–4): `HistoryDescriptor<T>`
(fetch criteria + sort), `protocol HistoryTransaction : Hashable, Identifiable,
Sendable` (a chronological transaction grouping `HistoryInsert`/`HistoryUpdate`/
`HistoryDelete` changes), and an opaque `HistoryToken: Comparable & Codable` (the
resumable cursor). All are **macOS 15.0+** (present on macOS 26). The article
*"Fetching and filtering time-based model changes"* confirms SwiftData History
meets the brief's **minimum** criteria (a)–(d):

- (a) per-commit ordered records — "The data store organizes changes as a series
  of chronological transactions";
- (b) atomicity with item mutations — "Transactions group together one or more
  changes that occur on a specific boundary — such as when a model context
  writes pending changes to the store" (the save boundary is the commit boundary);
- (c) a resumable cursor — "Tokens are opaque objects that conform to the
  `Comparable` and `Codable` protocols, enabling you to store the most recent
  token on-disk";
- (d) macOS 26 availability — macOS 15.0+.

**Decision: V2-03 uses a custom append-only HCR table, NOT SwiftData native
History.** SwiftData History meets the minimum bar (a)–(d), so this is not a
default-by-absence choice; the custom HCR is chosen because native History is
**insufficient for V2-03's specific contract**, for six reasons:

1. **Closed vs open write stream (D26).** V2-03's reconnect-completeness
   invariant (D26) requires a **provably closed** stream: every record corresponds
   to exactly one `HistoryAuthority` History Commit, and the replay is complete
   or rejected. SwiftData History records **every** store write — explicitly,
   "changes made by another process such as a Widget or App Intent" (article).
   It is an **open, heterogeneous** stream whose own article states "results will
   likely contain
   transactions, and changes within those transactions, that are unrelated to the
   current view or task." A reconnect consumer would have to *filter* and
   *reconstruct* completeness from an open stream — exactly the fragile path D26
   forbids. The custom HCR, appended **only** inside the Authority transaction,
   is closed by construction: one row per History Commit, nothing else.
2. **Semantic kind vs row-level diff.** The collection cache invalidator and the
   reconnect consumer need the **Domain-semantic** event (insert / coalesce /
   pin / remove / revise / retire / …) plus the affected `HistoryItemID` set.
   SwiftData History carries **row-level diffs** (`HistoryInsert`/`Update`/`Delete`
   on `HistoryItemRow` columns), exposing the storage schema and coupling any
   consumer to it (a future projection-column rename would silently change the
   stream's shape). Decoding semantic kind from row diffs would couple the cache
   to `HistoryStorage` internals, against the no-leakage principle (`00` §3.4).
   The custom HCR carries `JournalEntryKind` + `affectedItemIDs` in
   `HistoryCore` vocabulary, decoupled from the storage schema.
3. **Cursor-expiry failure semantics (D26 reject path).** V2-03 requires a typed
   reject when a cursor is expired/compacted/generation-mismatched. SwiftData
   History's behavior on `fetch(historyDescriptor)` against a token whose
   transactions were compacted (predicate-deleted) is **undocumented** — the
   article does not say whether it returns empty, throws, or silently advances
   (`V2-facts.md` cycle 7 §7.1, OPEN 1). v1 (`00` §5) requires: where a platform behavior is
   not guaranteed, state the required outcome and assign an implementation-time
   proof rather than assume. The custom HCR **owns** the reject path and emits a
   typed `ReconnectFailure.tokenExpired` deterministically (§7).
4. **Scope mismatch.** SwiftData History's documented primary use case is
   multi-process / Widget / App-Intent change detection — i.e., the X1/V2-05
   external-write problem. V2-03 (`V2-00` §3.1) **explicitly excludes**
   multi-process direct writers for V2. Using a multi-process-aware primitive
   for a deliberately single-writer-scoped graft imports semantics tuned for an
   excluded scope.
5. **Retention control.** V2-03's compaction must "never break a live cursor"
   (§9): a cursor whose floor was compacted is rejected, and the floor is
   app-controlled. SwiftData History retention is a separate predicate-delete
   API surface whose interaction with app cursor liveness is undocumented. The
   custom HCR gives full, provable control over the liveness floor.
6. **Migration cleanliness.** The custom HCR is a new V2 table added by the same
   lightweight migration V2-01/V2-02 already use (Record 5); the "journal starts
   empty post-migration" property is trivially true for a new table. SwiftData
   History is a store-level capability whose enablement point and retroactive
   coverage are store-wide concerns.

The SwiftData History API is recorded as VERIFIED (`V2-facts.md` cycle 7 §7.1, facts 1–4)
and remains a candidate for **future** grafts whose scope matches it (e.g., a
post-V2 multi-process writer, or V2-05 X1 if a Widget extension ever writes
directly). V2-03 makes no concrete platform claim about native History beyond
its verified existence and the documented open-stream/token-expiry gaps; those
gaps are the reason for the custom HCR, not an unsubstantiated assertion
(`00` §5).

**Why not also avoid SwiftData for the HCR's atomicity?** The custom HCR's
crash-consistency (D25) rests on `ModelContext.transaction(block:)` writing the
HCR row and the item mutations in one atomic closure. That primitive is VERIFIED
(`V2-facts.md` cycle 7 §7.1, fact 5; cycles 3–4 of `V2-facts.md`): `func transaction(block:
() throws -> Void) throws` — "Runs the provided closure, and once it finishes,
writes any pending inserts, changes, and deletes to the persistent storage"
(macOS 14.0+). v1 already relies on this exact primitive as its sole commit
boundary (`05` §10); V2-03 appends one more insert in the same closure, so D25
inherits v1's evidence rather than introducing a new platform dependency.

## 4. History Change Record data model

All declarations in this section are `internal` to `HistoryStorage` unless
explicitly noted as a public `HistoryCore` type. HCR types are part of
`HistorySchemaV2` (the consolidated V2 schema introduced by V2-01 and extended
by V2-02); they never appear in `HistorySchemaV1` (`05` §3, frozen).

### 4.1 HistoryChangeRecordRow (V2 schema)

```swift
@Model
internal final class HistoryChangeRecordRow {
    @Attribute(.unique)
    var sequence: UInt64              // journal monotone position; == the commit's
                                     // ChangePosition (D25); one row per History Commit

    var changePositionRaw: UInt64     // == sequence by D25 (equal-by-construction);
                                     // carried as the explicit cross-reference to
                                     // LastChangePositionRow.rawValue (05 §3.2).
                                     // Defensive duplicate of `sequence` for the §9.1
                                     // startup invariant check.

    var changeKindRaw: Int16          // JournalEntryKind raw value (internal);
                                     // :Int16 raw representable (§4.2); 0 is
                                     // reserved unset/invalid so a zeroed Int16
                                     // fails closed on decode
    var affectedItemsBlob: Data       // AffectedItemsBlobV1 (§4.4); versioned codec,
                                     // 05 §4 discipline; empty only when the kind is
                                     // self-describing (.clearAll / .clearUnpinned /
                                     // .policySet)

    var createdAt: Date               // Storage-clock commit timestamp (§6.4); the
                                     // first durable per-commit timestamp in the
                                     // architecture (Record 6)
}
```

**No per-row `materializerVersion` column.** The materializer version is carried
by `JournalConfigRow.materializerVersion` (the source of truth, §4.6), by the
`ReconnectCursor` (the cursor-mint snapshot, §6.1), and by the
`CollectionCacheKey` (§7.2). A materializer bump advances `JournalConfigRow.
materializerVersion` **and** `JournalConfigRow.generation` together (§4.6),
which expires every live cursor (D26) **before** any record minted under the new
version could be replayed against a consumer keyed to the old version. A mid-
replay materializer change is therefore impossible by construction (the cursor
is rejected at the bump). A per-row column would have no consumer and is omitted
to avoid dead schema; this mirrors the v1 discipline of not storing derivable
redundancy (`05` §3.2 stores only what the singleton must own).

`HistoryChangeRecordRow` is a new V2 model. It is **not** a v1 schema column: it
adds a table; it does not alter `HistoryItemRow` or `LastChangePositionRow`. It
references items **by value** (`HistoryItemID` inside `affectedItemsBlob`), not by
a SwiftData `@Relationship`, mirroring `EnrichmentRow.itemID` (`V2-01` §3.2) — so
item retirement does not cascade-delete the HCR row, and `itemID` non-reuse
(plan invariant 9, `02` §7; D1 stable identity, `02` §14; `05` §17 migration
stance — none of which is `02` §12, which is retention/capacity, not non-reuse)
keeps historical references meaningful. Lookups use a bounded
`FetchDescriptor` predicate on `sequence` (`05` §5 fetch-predicate discipline;
`#Predicate { $0.sequence > cursor.sequence }`, `V2-facts.md` cycle 7 §7.1, fact 7), never
`registeredModel(for:)` (`05` §18).

**Two decode paths, one policy: fail-closed.** The HCR is a derivation off the
commit path, but it is also the **completeness mechanism** the collection cache
depends on (`04` §12), so its integrity is load-bearing, not best-effort. A
corrupt `affectedItemsBlob` (unknown version, oversize/unbounded array,
malformed UUID), an **unknown `changeKindRaw`** (forward-incompatible enum raw
value, mirroring `05` §4 exhaustive-decode discipline and the
`configSchemaVersion` contract in §4.6), or a `changePositionRaw != sequence`
divergence is `.persistence(.corruptStoredValue)` /
`.persistence(.invariantViolation)` (`05` §16), mirroring v1 codec discipline
(`05` §4). There is no "silent skip" path: a corrupt HCR row breaks the journal's
completeness, so the journal is marked unready and reconnects fail closed
`.temporarilyUnavailable` until the journal is rebased (§9).

### 4.2 JournalEntryKind (public DTO)

A new public enum in `HistoryCore` (Foundation-only). It is the lossy, codec-
friendly discriminator of the commit's semantic event, distinct from the richer
`HistoryCommitOutcome` (which carries associated values like
`HistoryItemReference`). The mapping from a commit's `StampedMutation` set
(plus the originating action's scope where the mutation set is scope-less) to
`JournalEntryKind` is mechanical and total (§5.2):

```swift
public enum JournalEntryKind: Int16, Sendable, Hashable, Codable {
    case insert = 1         // .inserted outcome
    case coalesce = 2       // .coalesced
    case pin = 3            // .placedPinned
    case unpin = 4          // .unpinned
    case remove = 5         // .removed (user .remove)
    case clearAll = 6       // .clear(.all)
    case clearUnpinned = 7  // .clear(.unpinned)
    case revise = 8         // .revised (append revision, incl. V2-02 compose-with-prune)
    case retire = 9         // item retirement via retention (v1 count or V2-02 R1/R2)
    case policySet = 10     // .retentionPolicySet (v1 count) / .retentionPoliciesSet (V2-02),
                            //   value-only change with no victims (§5.2 C2-M8)
    case retireRevision = 11  // V2-02 R3 inactive-revision prune (.pruneRevisions)
}
```

The type is `RawRepresentable` as `Int16` (n4): the on-disk wire value is the
raw `Int16`, so the codec is the raw-value `Codable` derivation (no separate
encode/decode logic), and `changeKindRaw` (`§4.1`) is exactly `kind.rawValue`.
Raw values start at 1; **0 is reserved unset/invalid** so a zero-initialized
`Int16` column decodes to no case and fails closed. The raw-value map is
versioned by `configSchemaVersion` (`§4.6`): a future case addition is a
`configSchemaVersion` bump (the fail-closed rule below means an older binary
reading a newer raw value rejects it, exactly as `05` §4 exhaustive-decode
discipline governs forward-incompatible enum raw values). An **unknown
`changeKindRaw`** (forward-incompatible raw value) fails closed at decode
(`.persistence(.corruptStoredValue)`, §4.1) — it is never silently coerced to a
default case.

**The raw values are a storage encoding, not an API contract.** The `Int16`
raw type exists so `changeKindRaw` (§4.1) is a plain stored column with a
fail-closed, zero-reserved decode; it is not an interchange format. Every
v1 public enum in `HistoryCore` is raw-free (`HistoryAction`,
`HistoryCommitOutcome`, `HistoryFailure`, ...); `JournalEntryKind` is the
first raw-typed public enum, so callers must not persist, hash, or branch
on `rawValue` - the public contract is the case set, versioned by
`configSchemaVersion` (§4.6). Its raw-value `Codable` synthesis encodes
the wire value; treat those bytes as storage-owned, not app-owned.

**Why `.clear` is split into `.clearAll` / `.clearUnpinned` rather than one
`.clear` kind.** A single `.clear` collapses the clear scope (`.all` vs
`.unpinned`) and forces `affectedItemIDs` to be empty (enumerating up to 5,000
IDs is wasteful, §4.4). A reconnect consumer could then not distinguish a
full clear from a clear-unpinned, nor reconstruct the removed-item set without
re-browsing authoritative state. Splitting the kind carries the scope in the
discriminator (the kind **is** the scope), so a consumer reading
`.clearUnpinned` knows pinned items survived and only unpinned items were
removed, and `.clearAll` knows the history was emptied. Both keep
`affectedItemIDs` empty (self-describing scope via kind). This preserves the
§3 reason 2 contract (semantic kind decoupled from storage schema) and the §13
"recently removed" surface fidelity. (The scope is read from the originating
`HistoryAction.clear(scope)`, not from the scope-less `RetirementReason.clear`
/ `PlannedOutcome.cleared(count:)` — see §5.2.)

**Naming.** The type is `JournalEntryKind` (not `HistoryChangeKind`) by
pre-emptive choice (n5): the deleted-vocabulary token is the *phrase*
"ChangeKind-driven bump" (`06` §10), a deleted live-observation bump mechanism.
`JournalEntryKind` shares no stem with that deleted phrase, so it needs no
`V2-00` §8 carve-out and V2-03's self-review consolidation is unconditional
(§16). This is the same pre-emptive-rename posture V2-01 took for `SourceStamp`
(`V2-01` §11).

### 4.3 Sequence ↔ ChangePosition identity (D25)

The HCR's `sequence` is assigned the commit's `ChangePosition` value, and
`changePositionRaw` carries the same value redundantly. They are **equal by
D25**:

> After every History Commit, exactly one `HistoryChangeRecordRow` exists with
> `sequence == changePositionRaw == the commit's ChangePosition`. The journal's
> `max(sequence) == LastChangePositionRow.rawValue`. A crash never leaves a
> partial HCR entry (D25).

Carrying both columns is deliberate, not redundant data quality:

- `sequence` is the journal's monotone fetch key (`#Predicate { $0.sequence >
  cursor.sequence }`, ordered ascending). Naming it `sequence` (not
  `changePosition`) decouples the journal's reader surface from the singleton's
  vocabulary — a future evolution to multiple HCR rows per commit (finer
  granularity) could let `sequence` advance independently of `ChangePosition`
  without a rename.
- `changePositionRaw` is the explicit cross-reference to
  `LastChangePositionRow.rawValue` (`05` §3.2) used by the startup
  crash-consistency check (§9): `max(HCR.changePositionRaw) ==
  LastChangePositionRow.rawValue`. A divergence is `.invariantViolation`
  (journal rebase, §9), never silently accepted.

The 1:1 (one HCR row per `ChangePosition`) is a design choice, not a constraint:
it makes D25 trivially crash-consistent (the row is appended in the same
transaction that writes the singleton position) and keeps the journal's memory
footprint exactly one row per commit. A commit carrying multiple semantic
changes (e.g., capture + retention retirement, `V2-02` §4.2) still produces
**one** HCR row: the `changeKind` is the **primary** change (the outcome family
of the commit), and `affectedItemIDs` is the **union** of every `HistoryItemID`
touched by any `StampedMutation` in the plan (the primary, the retirees, the
pruned revisions' owning item, etc.). Finer-grained per-mutation journaling is a
future option, not taken in V2-03.

**Primary-kind-only contract (consumer obligation).** Because one row carries
only the primary kind, a reconnect consumer that needs per-mutation fidelity
(e.g., to distinguish the captured item from the retired items in a capture +
retire commit) **must cross-reference `affectedItemIDs` against its own mirror
of authoritative state**: the row tells the consumer *which* items were touched
by the commit (the union) and the primary semantic event, but not which touched
item played which secondary role. This is the honest contract for a one-row-per-
commit journal and is consistent with §3 reason 2 (semantic kind decoupled from
storage schema): the consumer gets Domain vocabulary (kinds + `HistoryItemID`
sets), never row-level storage diffs. A consumer unable to cross-reference (no
mirror) treats the row conservatively as "membership/content may have changed
for all `affectedItemIDs`" and refetches — exactly the cache's conservative floor
(§7.3).

### 4.4 AffectedItemsBlobV1 codec

The affected-item list is persisted through an explicit versioned wire value,
not synthesized `Codable`, mirroring the v1 codec discipline (`05` §4):

```swift
internal struct AffectedItemsBlobV1: Codable, Sendable {
    let formatVersion: UInt16    // exactly 1
    let itemIDs: [UUID]          // HistoryItemID.rawValue; bounded by JournalLimits
                                 // (§4.5); empty only when changeKind is
                                 // self-describing (.clearAll / .clearUnpinned /
                                 // .policySet)
}
```

Decode reconstructs through validators and checks, exactly as v1 codecs (`05` §4):

- known `formatVersion` (exactly 1);
- `itemIDs` count ≤ `JournalLimits.maxAffectedItemsPerRecord` (§4.5) before any
  large allocation;
- each element is a valid `UUID` (the codec does not synthesize `HistoryItemID`
  meaning; it stores raw `UUID`s the reader re-wraps);
- `itemIDs` is non-empty **unless** the record's `changeKindRaw` encodes a
  self-describing kind: `.clearAll` / `.clearUnpinned` (the kind conveys the
  scope; enumerating up to 5,000 UUIDs would be wasteful) or `.policySet` (a
  retention-policy *value* change that retires no items is self-describing via
  the kind — the policy value lives in `RetentionExpansionConfigRow` for V2-02
  rules (`V2-02` §3.3) / the v1 count-policy storage for the v1 count, never in
  the HCR or `JournalConfigRow`, neither of which carries a policy field; under
  the symmetric §5.2 rule a policy change that *does* retire items is recorded
  `.retire` with those victim IDs, so `.policySet` is by construction victim-
  free). For every other `changeKind`, an empty `itemIDs` is corruption
  (`.invariantViolation`).

Any violation is `.persistence(.corruptStoredValue)` /
`.persistence(.invariantViolation)` (`05` §16). The decoder does not silently
drop IDs, reset to a default, or substitute.

`AffectedItemsBlobV1` is a wire codec, like the v1 blobs (`CanonicalBlobV1`
etc., `05` §4): it is encoded to `Data` for storage and decoded back within
`HistoryStorage`'s isolation. The blob itself **does not cross an actor
boundary** — the `HistoryChangeRecord` DTO (§6.3) and the
`HistoryChangeRecordPayload` (§5.2) carry the **decoded** `[HistoryItemID]`
array (a `Sendable` value type), not the blob. The `Codable` conformance is the
load-bearing one (the encode/decode discipline above). The type is also
`Sendable` (all stored properties are `let` of `Sendable` types, so the
conformance is derived without `@unchecked Sendable`) as harmless future-proofing
in case a future evolution moves the encoded blob across isolation; this mirrors
V2-01's `EnrichmentBlobV1` (`V2-01` §3.3) without claiming a crossing that does
not exist (review-minor-5).

### 4.5 JournalLimits (admission bounds)

A new V2 admission bound, `JournalLimits` (a `HistoryLimits`-peer fixed value,
`internal` to `HistoryStorage`; evaluated and checked by `HistoryStorage`, not a
user retention knob and not a modification of `HistoryLimits`, mirroring `06` §2
and V2-01's `EnrichmentLimits`):

| Bound | V2 value |
|---|---:|
| `maxAffectedItemsPerRecord` | 5,000 (the hard retained maximum, `06` §2; bounds multi-retirement ID unions — `.clearAll`/`.clearUnpinned` rows carry no IDs, §4.4) |
| `maxJournalRecordCount` (compaction cap) | 10,000 |
| `maxJournalAgeSeconds` (compaction cap) | 604,800 (7 days) |
| `maxJournalBytes` (whole-journal **payload-bytes** cap; C3-n3) | 80 MiB (an APPROXIMATION of journal footprint, not the literal on-disk size: it bounds the sum of `affectedItemsBlob.count + fixedRowOverhead` over all rows — payload bytes only, tracked by the `JournalConfigRow.journalBytes` counter, §4.5/§4.6. The ACTUAL SQLite footprint is LARGER (per-row B-tree node headers, index pages for `@Attribute(.unique) sequence` + the `key` index, WAL frames); `fixedRowOverhead` is a fixed per-row byte allowance that approximates the row-header share but does NOT model index/WAL overhead. The cap is therefore a payload-bytes trigger that forces an earlier compaction when per-record payloads are large — a `.clearAll`/`.clearUnpinned` row carries no IDs, but a multi-retire row can approach `maxAffectedItemsPerRecord` × 16 B ≈ 80 KiB, so without the cap the payload-byte sum could reach 10,000 × 80 KiB ≈ 800 MiB; the actual SQLite footprint at that point would be higher still) |
| `compactionCadenceCommits` (trim every N-th commit) | 50 |
| `maxReconnectBatchSize` (per-call fetch limit) | 500 (the `journalChanges(since:)` `fetchLimit`, §6.2; bounds a single reconnect call independently of the journal cap so a stale cursor at `sequence == 0` cannot unspool all 10,000 rows in one call; the caller paginates via `nextCursor` until `isCaughtUp`) |

Rules (matching `06` §2):

- All byte/count arithmetic is checked; overflow fails closed and never wraps
  (`06` §2, `02` §13).
- `maxJournalRecordCount`, `maxJournalAgeSeconds`, and `maxJournalBytes` are
  alternative compaction triggers (whichever fires first); they bound journal
  footprint independently of history retention (V2-02). Journal retention is
  **separate** from item retention: trimming HCR rows never retires items, and
  retiring items never auto-trims the journal (§9). The byte bound is tracked by
  a **running `JournalConfigRow.journalBytes` counter** (C2-m3), not by scanning
  blobs at the compaction pass: the append closure increments it by
  `affectedItemsBlob.count + fixedRowOverhead` (O(1) per commit, the blob's
  encoded length known at encode time — no blob-content materialization), and the
  compaction pass subtracts the deleted rows' contributions (it knows which rows
  it deletes). Evaluating the byte trigger is therefore an O(1) compare against
  the counter, avoiding a per-pass O(rows) blob scan that would otherwise
  serialize on the Authority and blow the 20 ms queue p95 (`J1-PERF-5`); the
  counter is the byte-trigger input, and `J1-PERF-5` budgets the compaction pass
  cost net of this.
- `maxReconnectBatchSize` is a **read** bound (per-call `fetchLimit`), not a
  compaction trigger; it bounds a single `changes(since:)` call's work and
  forces pagination (D26 is stated at the protocol level — the union of batches
  via `nextCursor` until `isCaughtUp` is complete-or-rejected; contiguous-prefix
  batching is not "partial replay," §16).
- These are admission bounds, not runtime user knobs; the advanced-settings UX
  exposure (§13) reads/writes `JournalConfigRow` fields but clamps to these
  bounds at the boundary.

### 4.6 JournalConfigRow (singleton)

A new `@Model` singleton stores the durable journal configuration. It is
internal to `HistoryStorage` and **does not modify any v1 model** (no column is
added to `HistoryItemRow` or `LastChangePositionRow`). It mirrors V2-01's
`EnrichmentConfigRow` (`V2-01` §3.5), V2-02's `RetentionExpansionConfigRow`
(`V2-02` §3.3), and the v1 `LastChangePositionRow` singleton pattern (`05` §3.2):

```swift
@Model
internal final class JournalConfigRow {
    @Attribute(.unique)
    var key: String                       // always "change-journal"

    var cacheEnabled: Bool                // G2 collection-cache gate; default
                                          // false (enabled only when J1 is
                                          // admitted on recorded G2 evidence —
                                          // DC-10; a reconnect-only admission
                                          // stays cache-off)
    var maxJournalAgeSeconds: Double      // TimeInterval; clamped to JournalLimits
    var maxJournalRecordCount: Int        // clamped to JournalLimits

    var generation: UInt32                // bumps on schema migration, materializer
                                          // version bump, or journal rebase (§9);
                                          // expires every live cursor (D26).
                                          // Bumped via checked arithmetic (02 §13):
                                          // overflow fails closed; never wraps.
    var materializerVersion: UInt16       // search/projection materializer schema
                                          // version; bumps invalidate cache + cursors.
                                          // Overflow discipline (C3-m7): set by
                                          // ABSOLUTE value via
                                          // bumpMaterializerVersion(to:) (§10.3),
                                          // NOT incremented — the compiled-in
                                          // materializer version is a compile-time
                                          // constant, so the open-path compare-and-
                                          // set has no runtime overflow. A caller-
                                          // computed successor (none in V2-03's
                                          // paths, but reserved for future use) uses
                                          // checked arithmetic per 02 §13 (overflow
                                          // fails closed, never wraps).
    var compactionFloor: UInt64           // min surviving sequence after the last
                                          // compaction pass (§8); a cursor whose
                                          // sequence < compactionFloor is rejected
                                          // .tokenExpired BEFORE the range fetch
                                          // (D26, §6.2). 0 when no compaction has run.
    var journalBytes: UInt64              // running whole-journal byte counter (C2-m3,
                                          // §4.5): += (blob.count + fixedRowOverhead)
                                          // per append, -= deleted rows' contributions
                                          // on compaction. Checked arithmetic (02 §13);
                                          // the O(1) byte-trigger input.
    var storeInstance: UUID               // store-instance discriminator minted once
                                          // at first open (§4.6 bootstrap); persisted.
                                          // A ReconnectCursor whose storeInstance
                                          // differs is rejected .storeMismatch (D26,
                                          // M2): prevents a cursor minted against
                                          // store-A being replayed against store-B
                                          // (store recreate, cross-store
                                          // backup restore, multi-profile); a
                                          // same-store backup restore is caught
                                          // by reject step 5b, §6.2 — the
                                          // durable analogue of v1's
                                          // process-instance marker on
                                          // `HistoryPageCursor` (`04` §6 —
                                          // process-scoped, explicitly not a
                                          // schema hash).
    var configSchemaVersion: UInt16       // 1 for V2-03
}
```

`generation` is the cursor-expiry marker: a `ReconnectCursor` whose `generation`
differs from the current `JournalConfigRow.generation` is rejected
`.generationMismatch` (D26), because the journal's shape changed under the cursor
(schema migration, materializer bump, or rebase). `materializerVersion` is the
collection-cache key element (`04` §12 requires "a structural materializer
schema version"): a bump evicts every cache entry and expires every cursor whose
`materializerVersion` differs. Both bump together on a materializer change (the
materializer version is the finer signal; `generation` is the coarser
schema/rebase signal — a V2 schema migration that does not touch the materializer
bumps `generation` only).

`compactionFloor` is the D26 reject substrate for compacted cursors. It is
persisted (not recomputed at read time) so the reject decision is deterministic
and does not depend on a contiguous-range assumption (which the migrated-store
initial gap — §1.1, Record 5 — and rebase break). The compaction pass (§8) sets
`compactionFloor` to the compaction delete boundary `X` (every row with
`sequence <= X` was deleted; surviving rows have `sequence > X`). The reject test
is `cursor.sequence < compactionFloor`: a cursor at exactly `compactionFloor`
requests rows with `sequence > compactionFloor`, which all survived, so it is
valid; a cursor below `compactionFloor` requests at least one row that was
compacted away and is rejected `.tokenExpired(currentAnchor:)` **before** the
range fetch runs (§6.2) — never a silent partial replay. `compactionFloor`
advances monotonically (a compaction pass never un-deletes rows); it is reset to
0 only by a rebase (§9.2), which expires every cursor via `generation` regardless.

`storeInstance` is minted once (`UUID()`) at the first `open` that bootstraps the
singleton and never changes for the life of that store file. It is the durable
analogue of v1's per-process `HistoryPageCursor` process-instance marker
(`04` §6): because `ReconnectCursor` is **cross-restart** (persisted by a
consumer across process launches), a process-local marker would be useless (it
changes every launch); a durable per-store UUID survives restart but differs
across distinct store files. A cursor minted against store-A, presented to
store-B after a store recreate / backup restore / profile switch, is rejected
`.storeMismatch` rather than silently replayed as a complete-but-wrong stream.

**`configSchemaVersion` contract (fail-closed).** `SwiftDataHistory.open`
validates `configSchemaVersion == 1` on the fetched singleton. An unknown
`configSchemaVersion` (forward-incompatible) or an out-of-range field combination
(e.g., `maxJournalAgeSeconds <= 0`, `maxJournalRecordCount <= 0`) fails closed as
`.persistence(.corruptStoredValue)` / `.persistence(.invariantViolation)` rather
than being silently reset (`05` §4 exhaustive-decode discipline; mirrors V2-02
`RetentionExpansionConfigRow`, `V2-02` §3.3). An absent row (the migrated-v1
case) is the only "create with defaults" path, not a version mismatch.

**Singleton bootstrap at open (total order).** `SwiftDataHistory.open` performs
the V2-03 steps in a fixed total order, after the v1 position-singleton (`05` §13
step 3) and the V2-01 `EnrichmentConfigRow` / V2-02 `RetentionExpansionConfigRow`
singletons, and before the facade is published:

1. fetch the `JournalConfigRow` singleton (`key == "change-journal"`); validate
   exactly-one or zero;
2. **if absent (migrated v1 store):** create exactly one row with defaults
   (`cacheEnabled == false` until recorded G2 evidence — DC-10;
    `generation == 1`, `materializerVersion == 1`,
   `compactionFloor == 0`, `storeInstance == UUID()` minted here,
   `configSchemaVersion == 1`, bounds clamped to `JournalLimits`);
3. **if present:** validate `configSchemaVersion == 1` and field ranges (fail-
   closed above); read `storeInstance` (never re-minted on an existing row);
4. **materializer-version detection (upgrade + downgrade, C2-m10):** compare
   `JournalConfigRow.materializerVersion` against the compiled-in materializer
   version. **Upgrade** (stored < compiled): `bumpMaterializerVersion(to:)`
   (§10.3) in its own transaction before the facade is published, so no caller
   can observe a journal whose `materializerVersion` disagrees with the running
   binary. **Downgrade** (stored > compiled — an older binary opening a store
   last written by a newer binary): **fail-closed refuse** — `open` does not
   publish the facade and surfaces a "store written by a newer version" error
   (`.persistence(.invariantViolation)`), because an older binary cannot
   guarantee it materializes projections identically to the version that wrote
   them, and silently serving a known-higher materializer version would violate
   D27 (the cache key's `materializerVersion` would not match the projections
   the binary actually produces). There is no read-only tolerate-known-higher
   path; the user must open the store with a binary at least as new. (This is a
   pure design policy, not a SwiftData-guaranteed behavior; it needs no proof
   gate beyond `J1-PLATFORM-2`, which confirms the full §4.6 bootstrap total
   order (steps 1-7) - including this materializer-version detection and the
   `configSchemaVersion` validation - runs before the facade is published.)
5. **mandatory startup compaction pass (§8, trigger (b)):** run one compaction
   pass against the bootstrapped `JournalConfigRow`. It follows singleton
   bootstrap + materializer detection because it reads `compactionFloor`,
   `generation`, and the clamped bounds (all set in steps 1-4); it deletes
   too-old/too-many `HistoryChangeRecordRow`s and persists the resulting
   `compactionFloor` in the same transaction. Compaction preserves
   `max(sequence)` (the §8 `deleteFloor` cap keeps the head row alive), so it
   does not change the D25 result either way — but §9.1 explicitly orders it
   before the D25 check, and §8 lists this pass as a mandatory trigger;
6. **D25 startup invariant check** (§9.1): `max(HCR.sequence) ==
   LastChangePositionRow.rawValue`, else journal rebase (§9.2);
7. end of the V2-03 module segment of the single open order (`05` §13
   steps 1-12, publication at step 12, composed per roadmap M1.3): the
   `ChangeJournal` reader and `CollectionCache` see the validated,
   consistent config - the facade itself is published once, after every
   admitted module's segment.

This total order makes the open-path dependencies explicit: the singleton exists
before the step-5 startup compaction pass (which reads `compactionFloor`,
`generation`, and the clamped bounds) and before the step-6 invariant check
(which also needs `compactionFloor` and `generation`), and the invariant check
runs before the facade is published (no caller observes an inconsistent
journal). This step applies to the `.memory` store path too.

**HCR is always-on; the cache is gated.** Once V2-03 ships, the HCR append is
part of every History Commit (one O(1) row insert, `J1-PERF-1`). There is no
"journal disabled" mode: the journal is the substrate both deliverables need,
and an extra row per commit is invisible to callers. The **collection cache** is
the gated part: `cacheEnabled == false` makes reads byte-for-byte v1 (the cache
is bypassed; the HCR still appends, but nothing consults it for reads). This is
the cache-law disabled-path (Record 4).

## 5. HCR append path (data flow)

The HCR append is a capability-gated extension of the v1 stamping + transaction
stages (`05` §9/§10). It is **not** a new `HistoryMutation` case, **not** a new
`StampedMutation` case, and **not** a new `HistoryAction`. The v1 stamping table
(`05` §9: 1:1 `HistoryMutation` → `StampedMutation`) is **unchanged**; V2-03
adds one derived field to `StampedCommitPlan` and one insert step to the
transaction closure.

### 5.1 Where the append runs

```text
Authority commit kernel (05 §9 / §10), V2-03-extended:
  create operation-local context
  -> load exact facts
  -> call the action-specific pure planner
  -> if .unchanged: release context and return .unchanged   (NO HCR row; no commit)
  -> derive/stamp a StampedCommitPlan  (05 §9)
       V2-03 extension: stamping also derives
         hcrAppend: HistoryChangeRecordPayload           (§5.2, derived from
                                                          plan.position +
                                                          plan.mutations +
                                                          the originating action's
                                                          ClearScope — see §5.2)
  -> prevalidate index delta, receipt, AND hcrAppend
  -> execute one ModelContext.transaction (05 §10):
       V2-03 extension (one new line inside the closure):
         for mutation in plan.mutations { try apply(mutation, in: context) }   // v1
         try validateFinalPinOrder(in: context)                                  // v1
         try appendHistoryChangeRow(plan.hcrAppend, in: context)                 // V2-03
         meta.rawValue = plan.position.rawValue                                  // v1, written last
  -> apply nonthrowing Signature Index delta        (05 §11 step 1, unchanged)
  -> synchronously yield HistoryInvalidation         (05 §11 step 2, unchanged)
  -> construct and return HistoryReceipt.committed   (05 §11 step 3, unchanged)
```

Every `05` §10 transaction rule is preserved:

- **No `await`** in the closure or between fact load and closure completion
  (`05` §10). `appendHistoryChangeRow` is synchronous (non-suspending); it
  may throw (codec encode), which aborts the whole commit per `05` §10 — the
  same fail-closed behavior as v1's own commit-path codec encodes; it
  performs no I/O beyond the insert SwiftData already performs for the item
  mutations.
- **Closure failure commits nothing** — neither item mutations, nor the singleton
  position, nor the HCR row (`05` §10). D25 holds: a crash mid-closure leaves no
  partial HCR entry, because the HCR row and the singleton position share the
  same atomic save boundary.
- **The singleton position is written last** (`05` §10). The HCR row is appended
  *before* the singleton write (carrying `plan.position.rawValue`, which equals
  the to-be-written singleton value); order within the closure does not affect
  atomicity.
- **Closure success is the save boundary**; the kernel does not call `save()`,
  `processPendingChanges()`, or a compensating `rollback()` afterward (`05` §10).

The HCR append adds **no second writer** and **no new context**: it runs inside
the Authority's existing operation-local transaction. Single-writer is preserved
(`00` §3.3); D22 (V2-01) and its V2-03 analogue D28-isolation hold.

### 5.2 HistoryChangeRecordPayload and the stamping derivation

```swift
internal struct HistoryChangeRecordPayload: Sendable {
    let sequence: UInt64                    // == plan.position.rawValue
    let changePositionRaw: UInt64           // == plan.position.rawValue (D25)
    let changeKind: JournalEntryKind
    let affectedItemIDs: [HistoryItemID]    // union over plan.mutations; sorted,
                                            // deduplicated (deterministic total
                                            // order: HistoryItemID raw bytes
                                            // ascending — chosen for stable
                                            // encoding, independent of D9's
                                            // dedup-winner tie-break and 02 §12's
                                            // eviction order; C3-n1)
    let createdAt: Date                     // Storage clock (§6.4)
}
```

(The payload carries no `materializerVersion`: that value lives on
`JournalConfigRow` and the `ReconnectCursor`, and a materializer bump expires
every cursor before any new-version record is minted — §4.1 "No per-row
`materializerVersion` column.")

`StampedCommitPlan` (`05` §9) gains one field:

```swift
internal struct StampedCommitPlan {
    let position: ChangePosition
    let mutations: [StampedMutation]
    let receiptOutcome: HistoryCommitOutcome
    let indexDelta: SignatureIndexDelta
    let hcrAppend: HistoryChangeRecordPayload   // V2-03 (new field)
}
```

This is a **private stored-field addition** to a v1 internal struct, exactly as
V2-02 extended the v1 internal `StampedMutation` enum with new cases
(`V2-02` §6.3) and V2-01 extended `SwiftDataHistory`'s field set
(`V2-01` §6.1). It is an additive, behavior-preserving extension under the V2
self-review gate (`V2-00` §8); the public `ClipboardHistory` interface is
unchanged.

**Derivation is mechanical and total** over explicit stamped data. The stamping
stage already has `plan.position` and `plan.mutations`; V2-03 threads one
additional input — the originating action's `ClearScope` — into the stamping
stage for the clear case (see "Clear-scope input" below):

- `sequence` / `changePositionRaw` ← `plan.position.rawValue`.
- `changeKind` ← `primaryChangeKind(of: plan.mutations, outcome:
  plan.receiptOutcome, actionScope:)`. This is a **deterministic function over
  explicit stamped data** — the outcome associated values, the mutation-set
  composition, the selected primary `StampedMutation`'s payload, and (for the
  scope-less clear) the originating action's `ClearScope` — never an inference of
  hidden Domain behavior. D18 (`02` §14 "Storage applies explicit mutation
  payloads and never infers hidden domain behavior from outcome labels") is
  honored by TWO complementary rules (C3-m5):
  - **(a) Item-designating outcomes designate their primary directly.** The v1
    `HistoryCommitOutcome` associated values differ by family (`03a` §6): three
    outcomes carry the item by reference — `.inserted(HistoryItemReference)` /
    `.coalesced(HistoryItemReference)` / `.revised(HistoryItemReference)` — and
    their associated `HistoryItemReference` designates the primary
    `StampedMutation`; two pin outcomes carry a bare `HistoryItemID` —
    `.placedPinned(HistoryItemID)` / `.unpinned(HistoryItemID)` — and designate
    the primary via that `HistoryItemID`; and `.removed(count: Int)` carries only
    a count with no item identity, so its primary is designated by the selected
    `.delete` payload itself (the outcome's count carries no designator). In
    every case the selected primary `StampedMutation`'s payload spells the kind
    (the legitimate use of the label).
  - **(b) Policy outcomes and multi-effect plans use the explicit
    membership-outranks-revision tie-break.** `.retentionPolicySet(removedCount:)`
    / `.retentionPoliciesSet(...)` carry a count or composite, not a mutation
    reference, so the outcome does NOT designate a primary; and a plan
    rule (a) does not resolve (no item-designating outcome associated
    value) falls to the tie-break. Rule (a) always governs when it
    applies - including revise+R2 (the `.revised` reference designates
    the primary `.appendRevision`; the retires fold into
    `affectedItemIDs`, exactly as the capture-then-retire fold below). In
    both cases the primary is chosen by the
    **membership-outranks-revision rule** over the mutation set, a three-tier
    ranking: a membership-affecting mutation (`.create` / `.delete(.retention)` /
    `.delete(.userRemoval)` / `.setPinOrdinal`) outranks a value-only-policy
    mutation (`.setRetentionPolicy` / `.setRetentionPolicies` with no victims),
    which in turn outranks a revision-only mutation (`.appendRevision` /
    `.pruneRevisions`) - i.e. membership-affecting > value-only-policy >
    revision-only - and the winning payload spells the kind. This is what
    makes the v1 `.setRetentionPolicy`-with-victims, V2-02 R1/R2-retire, and the
    R1/R2+R3 mixed rows all resolve to `.retire` deterministically (a
    membership-affecting `.delete(.retention)` outranks both the value-only
    policy mutation and the revision-only `.pruneRevisions`), while a no-victim
    `.setRetentionPolicy` alone resolves to `.policySet` (value-only-policy
    outranks revision-only, and there is no membership-affecting mutation to
    win).
  With one explicit scope exception: for the scope-less clear, the payload
  (`StampedMutation.delete` with scope-less `RetirementReason.clear`) cannot
  distinguish `.clearAll` from `.clearUnpinned`, so the action's `ClearScope`
  spells the kind there (m4 — "the payload spells the kind" is qualified to "the
  payload spells the kind for scope-carrying mutations; the action scope spells
  it for the scope-less clear"). The mapping is fixed:

  | Commit's primary `StampedMutation` (selected by `receiptOutcome`) + action scope | `JournalEntryKind` | `affectedItemIDs` |
  |---|---|---|
  | `.create` | `.insert` | created item (+ retirees, §4.3 union) |
  | `.updateOccurrence` (no `.create`) | `.coalesce` | coalesced winner (+ losers, retirees) |
  | `.setPinOrdinal` (assign, ordinal non-nil) | `.pin` | pinned item |
  | `.setPinOrdinal` (clear, ordinal nil) | `.unpin` | unpinned item |
  | `.delete` with `RetirementReason.userRemoval` | `.remove` | removed items |
  | `.delete` with scope-less `.clear`, originating `HistoryAction.clear(.all)` | `.clearAll` | empty (self-describing scope) |
  | `.delete` with scope-less `.clear`, originating `HistoryAction.clear(.unpinned)` | `.clearUnpinned` | empty (self-describing scope) |
  | `.delete` with `.retention` (v1 count) | `.retire` | retired items |
  | `.appendRevision` (with or without V2-02 compose-with-prune) | `.revise` | revised item (+ prune-owning items) |
  | `.appendRevision` + `.delete(.retention)` (V2-02 revise with R2 retire, with or without `.pruneRevisions`) | `.revise` | revised item (+ retired-item IDs, prune-owning items) — rule (a): the `.revised` reference designates the primary; retires fold, like the capture-then-retire fold |
  | `.pruneRevisions` alone (V2-02 `.setRetentionPolicies` R3-only) | `.retireRevision` | prune-owning items |
  | `.setRetentionPolicy` (v1), value change, **no** victim retired | `.policySet` | empty (self-describing; C2-M8 symmetry) |
  | `.setRetentionPolicy` (v1), **with** victims retired | `.retire` | retired-item IDs (C2-M8: retire is the membership-affecting primary; symmetric with V2-02 R1/R2) |
  | `.setRetentionPolicies` (V2-02, value changed, no prune, no retire) | `.policySet` | empty (self-describing; M4) |
  | `.setRetentionPolicies` (V2-02, with R1/R2 retire, no R3) | `.retire` | retired-item IDs (retire wins as membership-affecting primary) |
  | `.setRetentionPolicies` (V2-02, with R3 prune, no R1/R2) | `.retireRevision` | prune-owning-item IDs |
  | `.setRetentionPolicies` (V2-02, with **both** R1/R2 retire **and** R3 prune) | `.retire` | **tie-break: `.retire` wins as primary** (membership-affecting outranks revision-only); `affectedItemIDs` = union of retired-item IDs **and** prune-owning-item IDs (the consumer cross-references per §4.3 to separate them; both sets are touched by the commit) |

  **Policy-kind symmetry (C2-M8).** The v1 `.setRetentionPolicy` and V2-02
  `.setRetentionPolicies` rows now follow ONE rule: a policy change that retires
  items is `.retire` (membership-affecting primary, victims in `affectedItemIDs`);
  `.policySet` is reserved for the no-victim value-only change (empty
  `affectedItemIDs`, self-describing). This removes the prior asymmetry where v1
  policy-with-victims mapped to `.policySet` while V2-02 policy-with-victims
  mapped to `.retire`.

  For multi-distinct-kind plans (e.g., capture + V2-02 retention retire, which
  stamps `.create` + `.delete(.retention)` + possibly `.pruneRevisions`), the
  **primary** is the outcome family: a capture-then-retire plan yields
  `.insert` (the capture is the primary action; the retire is a side effect
  folded into `affectedItemIDs`). V2-02 capture/revise expansion already
  produces a primary outcome (`.inserted`/`.coalesced`/`.revised`,
  `V2-02` §4.2/§4.3) — the HCR `changeKind` mirrors that primary. The rule is
  unambiguous because the plan's `receiptOutcome` already designates the primary
  mutation; the HCR switches on the selected mutation (and the action scope for
  clear) only to *spell* the kind, not to *decide* the primary.

- `affectedItemIDs` ← the union of every `HistoryItemID` named by any
  `StampedMutation` in the plan (the created item, the coalesced winner, the
  pinned/unpinned item, every retired item, every revised item, every
  prune-owning item), deduplicated and sorted by `HistoryItemID` raw bytes
  ascending (a deterministic total order chosen for stable encoding — NOT D9's
  dedup-winner tie-break and NOT `02` §12's eviction order; those govern
  different decisions; C3-n1). Bounded by
  `JournalLimits.maxAffectedItemsPerRecord`: if the union exceeds the cap,
  the encoder keeps the smallest `HistoryItemID`s (raw bytes ascending,
  deterministic) and drops the rest - `affectedItemIDs` is best-effort
  (the §4.3 consumer obligation), never a completeness claim; the
  decoder's count-≤-cap check (§4.4) remains the invariant. The bound is
  reachable: a capture at the 5,000-item hard cap under a count-1 policy
  retires 5,000 and creates 1 (union 5,001). Empty only for the
  self-describing kinds (`.clearAll` / `.clearUnpinned` / `.policySet`),
  per the §4.4 codec rule.
- `createdAt` ← the Storage clock seam (§6.4), read inside the serialized
  interval.

**Clear-scope input (C2-M1).** The stamping inputs `plan.position` + `plan.
mutations` **cannot** by themselves distinguish `.clearAll` from `.clearUnpinned`:
v1 `RetirementReason.clear` is **scope-less** (`02` §7 `case clear` — no
associated value), and `PlannedOutcome.cleared(count: Int)` is likewise scope-less
(`02` §7). The `.all` / `.unpinned` distinction enters the Domain only as the
planner input `planClear(scope: ClearScope)` (`02` §7) sourced from the
originating `HistoryAction.clear(ClearScope)` (`03a` §5) — it never reaches the
stamped `StampedMutation`/`RetirementReason`/`StampedCommitPlan`. V2-03 therefore
threads the originating action's `ClearScope` into the stamping stage as a
documented additional input (available in the `05` §8 dispatch context, which
sees the `HistoryAction` before invoking the package planner; this is a read of
dispatch context, **not** a modification of `StampedMutation`,
`RetirementReason`, `PlannedOutcome`, or `StampedCommitPlan`, so no v1 type is
redefined). This is the one place the "payload spells the kind" discipline is
qualified by an action-scope input; it is called out here so the derivation
inputs match reality (V2-WS-J1-1 asserts `.clear(.all)` → `.clearAll` and
`.clear(.unpinned)` → `.clearUnpinned`).

### 5.3 Why this preserves v1

- **The commit interval is unchanged in shape.** No `await` is added; the
  transaction closure gains one non-suspending insert. The post-commit order
  (`05` §11) is unchanged: the HCR append occurs *inside* the transaction (before
  closure success), not in the post-commit phase, so it adds nothing to the
  invalidation/receipt steps.
- **One `ChangePosition` per plan (D6) is unchanged.** The HCR row carries
  `plan.position.rawValue`; it does **not** advance the singleton, does not mint
  a `ContentVersion`, and does not enter the Domain. The Domain remains pure and
  unaware of the journal (preserves D16, D17).
- **D18 (semantic-plan completeness) is preserved.** `changeKind` is derived
  from explicit stamped data — the `StampedMutation` payloads, the outcome
  associated values, and (for the scope-less clear only) the originating action's
  `ClearScope` (§5.2 clear-scope input) — not inferred from the
  `receiptOutcome` label. The label designates the primary; the payloads (and the
  action scope for clear) spell the kind. No hidden Domain behavior is inferred.
- **Single-writer (`00` §3.3) is preserved.** The HCR is written only inside the
  Authority transaction; no second writer, no external path, no new context
  creator.
- **The HCR is a derivation off the commit path; its loss degrades, never
  corrupts.** A failed/absent HCR append fails the whole transaction (closure
  failure commits nothing, `05` §10); a corrupt journal is rebuilt (rebased,
  §9), expiring live cursors but never producing wrong durable history state
  (D25, D26).

## 6. Reconnect cursor and the ChangeJournal reader

### 6.1 ReconnectCursor (public DTO)

A new public opaque token in `HistoryCore` (Foundation-only; `Sendable`,
`Hashable`, `Codable` so a consumer can persist it):

```swift
public struct ReconnectCursor: Sendable, Hashable, Codable {
    let sequence: UInt64               // == ChangePosition of the last replayed commit
    let generation: UInt32             // JournalConfigRow.generation at cursor mint
    let materializerVersion: UInt16    // materializer version at cursor mint
    let storeInstance: UUID            // JournalConfigRow.storeInstance at cursor mint
                                       // (M2); durable per-store discriminator

    // C3-M2: versioned-envelope discriminator. Always 1 for V2-03; a future
    // cursor-shape change bumps it (paired with a JournalConfigRow.configSchemaVersion
    // bump). Stored in the payload (not derived) so init(from:) reads the encoded
    // value and throws on a mismatch — a future-version cursor is cleanly discarded
    // via the §6.1 decode-failure path rather than mis-decoded with zeroed fields.
    let cursorSchemaVersion: UInt16    // == 1 for V2-03

    private enum CodingKeys: String, CodingKey {
        case cursorSchemaVersion, sequence, generation, materializerVersion, storeInstance
    }

    // Custom Codable (C3-M2): synthesized Codable would silently ignore an unknown
    // future key and zero-fill any added field, defeating forward-compat detection.
    // The encoder is JSONEncoder (keyed encoding, the basis for the version check);
    // PropertyListEncoder is NOT used — its unknown-key/typed-stream behavior
    // differs and is not relied on. The package-internal memberwise init sets
    // cursorSchemaVersion = 1; consumers never construct cursors (no public init).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decode(UInt16.self, forKey: .cursorSchemaVersion)
        guard v == 1 else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "unknown cursorSchemaVersion \(v)"))
        }
        cursorSchemaVersion = v
        sequence          = try c.decode(UInt64.self,    forKey: .sequence)
        generation        = try c.decode(UInt32.self,    forKey: .generation)
        materializerVersion = try c.decode(UInt16.self,  forKey: .materializerVersion)
        storeInstance     = try c.decode(UUID.self,      forKey: .storeInstance)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cursorSchemaVersion, forKey: .cursorSchemaVersion)
        try c.encode(sequence,            forKey: .sequence)
        try c.encode(generation,          forKey: .generation)
        try c.encode(materializerVersion, forKey: .materializerVersion)
        try c.encode(storeInstance,       forKey: .storeInstance)
    }
}
```

The cursor is **opaque to consumers** (no public `init`; cursors are obtained
only from `ReconnectHistory.changes(since:)` / `currentReconnectAnchor()`, §6.3);
consumers persist and round-trip the `Codable` value but never inspect or
construct its fields. The package-internal memberwise initializer is `internal`,
so the five stored fields are a private encoding contract the journal owns
end-to-end.

It is **distinct from the v1 `HistoryPageCursor`** (`04` §6, which encodes a
browse query shape + page anchor + position + **process-instance marker**
for in-session pagination). A `ReconnectCursor` encodes a journal resume point
for **cross-restart** replay. The two do not collide: `ReconnectCursor` carries
no query shape and no page anchor; it carries a journal position, two version
markers, and a **durable** store-instance UUID (whereas the v1 cursor carries a
**process-local** marker that changes every launch — appropriate for an in-
session cursor, useless for a cross-restart one). The v1
`HistoryPageCursor`'s expiry produces `HistoryFailure.snapshotExpired(current:)`
(`03b` §10, `04` §6); the `ReconnectCursor`'s expiry produces
`ReconnectFailure.tokenExpired` / `.storeMismatch` (§6.3) — **sibling** failures,
not a reuse of the v1 case (justified in §6.3).

**Decode-failure semantics (C2-n6, C3-M2).** A consumer persists the `Codable`
`ReconnectCursor` across restarts. The on-disk encoding is a **versioned
envelope** implemented by the custom `init(from:)` above: the
`cursorSchemaVersion: UInt16` discriminator is the first keyed value, paired
with `JournalConfigRow.configSchemaVersion`'s discipline; `init(from:)` throws
on any value other than 1, so a future-shape cursor (encoded by a newer binary
under a bumped schema version) is **detectable rather than mis-decoded**.
Synthesized `Codable` would have ignored the unknown discriminator and silently
zero-filled the new fields — the custom decoder closes that hole. If a
consumer's stored cursor fails to decode (corruption, an unknown
`cursorSchemaVersion`, a truncated blob, or a missing required key), the
consumer **discards it and calls `changes(since: nil)`** — i.e. full resync
from `currentReconnectAnchor()` — so D26's typed-reject contract holds across
decode failures (a non-decodable cursor is treated as no-cursor, never as a
wrong cursor that could yield a partial replay). The consumer never needs to
inspect cursor fields to recover.

### 6.2 ChangeJournal reader (internal actor)

```swift
internal actor ChangeJournal {
    private let authority: HistoryAuthority   // Sendable actor ref; all context
                                              // work delegated to the Authority
                                              // (preserves 05 §5 single-context-creator)

    // Stateless reader: cursors are caller-held opaque values. The actor's
    // isolation serializes reads off the caller's executor and gives the
    // CollectionCache a stable consumption seam (§8.3); it holds no durable
    // state and never creates a ModelContext.

    // Public-reconnect reader (ReconnectHistory): caller-held cursor.
    func changes(since cursor: ReconnectCursor?) async throws -> ReconnectBatch
    func currentReconnectAnchor() async throws -> ReconnectCursor   // caught-up cursor
                                                                    // at the current
                                                                    // ChangePosition

    // Internal position-based reader (C2-M2): used by the CollectionCache finer
    // floor (§7.3), which holds only a ChangePosition (lastSeenPosition) and has
    // no cursor fields. The Authority constructs the cursor internally from the
    // live JournalConfigRow snapshot (see below); the cache never needs to learn
    // generation/materializerVersion/storeInstance itself.
    func changes(since position: ChangePosition) async throws -> ReconnectBatch
}
```

The reader delegates every durable read to the Authority. The two readers share
ONE Authority range-read path: `Authority.journalChanges(since:)` (cursor-based)
and `Authority.journalChanges(since position:)` (position-based, C2-M2) both
open ONE operation-local read context (`05` §5) and run the **D26 reject gate
before any range fetch**, against the fetched `JournalConfigRow` singleton. The
position-based reader constructs the cursor internally: it reads the live
`JournalConfigRow` (generation, materializerVersion, storeInstance,
compactionFloor) in the same operation-local read context, mints an ephemeral
cursor `(sequence: position, generation, materializerVersion, storeInstance)`,
and runs the identical reject gate — so a position below a freshly-advanced
`compactionFloor` is rejected `.tokenExpired` exactly as a caller-held cursor
would be. **The cache does not need to track generation/materializer/storeInstance
bumps itself:** (a) a materializer bump calls `CollectionCache.flush()` directly
(`bumpMaterializerVersion`, §10.3), so the next finer-floor call starts from a
flushed cache at the new position; (b) a rebase flushes the cache and resets
`lastSeenPosition` (§9.2); (c) compaction advances `compactionFloor` without
notifying the cache, and the next position-based read rejects a too-low
`lastSeenPosition` (the cache treats `.tokenExpired` as the §7.3 contiguity-break
flush). The live `JournalConfigRow` read in the same context is therefore the
single source of truth for the reject decision.

```text
reject gate (all checks use the live JournalConfigRow read in the SAME operation-
local read context as the range fetch; fail-closed to ReconnectFailure, never a
silent partial/empty replay — D26 / J1-PLATFORM-4 / J1-PLATFORM-5):
  1. cursor == nil            -> skip to anchor: return ReconnectBatch(
                                 changes: [], nextCursor: currentReconnectAnchor(),
                                 isCaughtUp: true)   (no historical replay, §1.1)
  2. cursor.storeInstance != JournalConfigRow.storeInstance
                              -> .storeMismatch (M2: cross-store guard)
  3. cursor.generation != JournalConfigRow.generation
                              -> .generationMismatch (schema/rebase bump)
  4. cursor.materializerVersion != JournalConfigRow.materializerVersion
                              -> .materializerMismatch
  5. cursor.sequence < JournalConfigRow.compactionFloor
                              -> .tokenExpired(currentAnchor:) (C1: the cursor's
                                 requested range was compacted away; reject BEFORE
                                 the fetch — a range fetch here would silently
                                 return the contiguous post-floor tail = partial
                                 replay, exactly what D26 forbids)
  5b. cursor.sequence > currentPosition
                              -> .tokenExpired(currentAnchor:) (the cursor is
                                 from a rolled-back future of this same store
                                 instance - e.g. an older backup of the same
                                 store file was restored; the position and HCR
                                 rolled back while storeInstance persisted.
                                 Replay cannot be complete: post-restore
                                 commits reuse sequences the cursor exceeds,
                                 so the cursor is expired, never looped on)
  only after all six pass (steps 1–5 and 5b):
  6. fetch HistoryChangeRecordRow with
       #Predicate { $0.sequence > cursor.sequence }, sortBy [.sequence],
       fetchLimit == JournalLimits.maxReconnectBatchSize  (§4.5; bounds a single
       call independently of the journal cap so a stale cursor at sequence == 0
       cannot unspool all rows)
  7. build ReconnectBatch:
       currentPosition = Authority ChangePosition at fetch time (the journal HEAD;
                         NOT necessarily == nextCursor.sequence — C3-M1: mid-
                         pagination nextCursor.sequence is max(rows.sequence), the
                         resume point, which is below the head; the two are equal
                         only when isCaughtUp)
       if rows is EMPTY: isCaughtUp = (cursor.sequence == currentPosition)
                         (no rows after the cursor; the caller is caught up iff
                         the cursor is already at the head — m5)
       else: nextCursor.sequence = max(rows.sequence)
             isCaughtUp = (rows.count < maxReconnectBatchSize) AND
                          (max(rows.sequence) == currentPosition)
             else the caller paginates via nextCursor (D26 protocol-level
             completeness; contiguous-prefix chunking is not "partial replay")
  MID-PAGINATION REJECT (m5): a reject (.tokenExpired/.storeMismatch/.generation-
  Mismatch/.materializerMismatch) returned on a LATER page invalidates ALL prior
  batches accepted under that cursor — the caller MUST discard them and resync
  from currentReconnectAnchor() (the cursor is no longer a valid resume point).
  The batch contract states this: a nextCursor is a promise only until the next
  call confirms it.
```

**Single-snapshot non-suspending interval (C2-M7 / J1-PLATFORM-5).** Steps 5–7
(floor-check + range fetch + the currentPosition read for `isCaughtUp`) run in
**ONE non-suspending Authority interval** on **ONE operation-local read context**
— no `await` between the `JournalConfigRow` read, the range fetch, and the
currentPosition read, and no second read context. The currentPosition read
(step 7) is a distinct value (the journal HEAD: `LastChangePositionRow.rawValue`
or `max(HCR.sequence)`) not derivable from the bounded range fetch when `rows` is
empty, so it is a third `context.fetch` in the same interval; broadening the
interval to cover it keeps `isCaughtUp` consistent with the reject gate and the
range fetch under one snapshot. Compaction is Authority-serialized (§8, single
writer), so a `compactJournal` commit cannot interleave between the floor read,
the range fetch, and the currentPosition read within this interval; all reads
share the same snapshot. This is what prevents the partial-replay race (a
compaction raising `compactionFloor` past `cursor.sequence` and deleting rows
after the floor-check passed but before the fetch). SwiftData's multi-`fetch`
snapshot consistency on a single operation-local read context is the platform
behavior `J1-PLATFORM-5` confirms on macOS 26.

The `#Predicate { $0.sequence > cursor.sequence }` ordered by `sequence`
ascending is VERIFIED (`V2-facts.md` cycle 7 §7.1, fact 7). The compaction-floor reject
(step 5) is the custom-HCR-owned path that SwiftData native History does not
document (`V2-facts.md` cycle 7 §7.1, OPEN 1): because `compactionFloor` is **persisted**
(§4.6), the reject is deterministic and does not depend on contiguity (which the
migrated-store initial gap and rebase break). The actor never creates a
`ModelContext` (preserving the single-context-creator rule, `05` §5); like
V2-01's `EnrichmentScheduler` (`V2-01` §6.3), it only coordinates. It is a new
internal `actor` field on `SwiftDataHistory` (§10), so `SwiftDataHistory:
Sendable` remains derived without `@unchecked Sendable` (`01` §6).

### 6.3 ReconnectHistory protocol and ReconnectFailure

A new public protocol in `HistoryCore`, conformed by `SwiftDataHistory`. It is a
"distinct concern" protocol (`V2-00` §6.5), not an extension of `ClipboardHistory`
(mirrors V2-01's `EnrichmentHistory`, `V2-01` §8):

```swift
public protocol ReconnectHistory: Sendable {
    // nil cursor: begin from the current position, caught-up (no historical
    // replay - past changes are not reconstructable, Record 5). Returns an
    // initial cursor the caller persists for future incremental replays.
    //
    // MID-PAGINATION REJECT (m5): a `ReconnectFailure` returned on any page
    // invalidates ALL batches previously accepted under that cursor - the caller
    // MUST discard them and resync from `currentReconnectAnchor()` (the cursor
    // is no longer a valid resume point). A `nextCursor` is a promise only until
    // the next call confirms it; a reject on a later page retroactively voids
    // every prior `nextCursor` accepted under that cursor (§6.2 m5).
    func changes(since cursor: ReconnectCursor?) async throws -> ReconnectBatch

    // The caught-up cursor at the current ChangePosition (for initial
    // subscription or resync anchor). Equivalent by construction to
    // changes(since: nil).nextCursor (§6.2 reject-gate step 1); prefer
    // this method - it avoids the empty-batch round trip.
    func currentReconnectAnchor() async throws -> ReconnectCursor
}

/// A batch of `HistoryChangeRecord`s returned by `changes(since:)`.
///
/// **Batch contract (m5):** a `ReconnectFailure` returned on any page
/// invalidates all batches previously accepted under that cursor; the caller
/// must discard them and resync from `currentReconnectAnchor()`. A
/// `nextCursor` is a promise only until the next call confirms it - a reject on
/// a later page retroactively voids every prior `nextCursor` accepted under
/// that cursor (§6.2 m5).
///
/// Boundary: a batch that is exactly full (changes.count ==
/// maxReconnectBatchSize, §4.5) and ends at the head still reports
/// isCaughtUp == false - the caller makes one more changes(since:) call,
/// which returns an empty batch with isCaughtUp == true (§6.2 step 7).
/// "Full batch" means "possibly more", never "certainly more".
public struct ReconnectBatch: Sendable, Equatable {
    public let changes: [HistoryChangeRecord]      // ordered by sequence ascending
    public let nextCursor: ReconnectCursor          // persist and present next call
    public let currentPosition: ChangePosition      // journal head (Authority
                                                    // ChangePosition at fetch time);
                                                    // equals nextCursor.sequence
                                                    // ONLY when isCaughtUp — mid-
                                                    // pagination nextCursor.sequence
                                                    // is the resume point (max rows),
                                                    // which is below the head (C3-M1)
    public let isCaughtUp: Bool                     // §6.2 step 7; an exactly-
                                                    // full batch at the head
                                                    // reports false (boundary
                                                    // note above)
}

public struct HistoryChangeRecord: Sendable, Equatable {
    // changePosition is the commit's ChangePosition (== the internal row's
    // sequence by D25). The public DTO carries the v1 ChangePosition vocabulary
    // only; the redundant raw `sequence` field is dropped from the DTO (C3-m4) —
    // consumers use changePosition. The internal HistoryChangeRecordRow (§4.1)
    // and HistoryChangeRecordPayload (§5.2) keep both `sequence` and
    // `changePositionRaw` columns/fields for the journal's fetch key + §9.1
    // cross-check; the DTO projection collapses them to the one v1-spelled value.
    public let changePosition: ChangePosition
    public let changeKind: JournalEntryKind
    public let affectedItemIDs: [HistoryItemID]
    public let committedAt: Date
}

public enum ReconnectFailure: Error, Sendable, Equatable {
    case tokenExpired(currentAnchor: ReconnectCursor)        // cursor compacted past
                                                             // compactionFloor (§6.2 step 5)
    case storeMismatch(expected: UUID, current: UUID)        // cursor minted against a
                                                             // different store file (M2):
                                                             // store recreate, backup
                                                             // restore, profile switch
    case generationMismatch(expected: UInt32, current: UInt32)  // schema/rebase bump
    case materializerMismatch(expected: UInt16, current: UInt16)
    case temporarilyUnavailable        // journal not safely readable — the only
                                       // TRANSIENT case (C2-M6): (a) a rebase is in
                                       // flight (open-time divergence detected, §9.2,
                                       // before the facade is published, or runtime
                                       // divergence tripped a deferred rebase); OR
                                       // (b) transient storage I/O during the range
                                       // fetch (disk pressure, store locked by another
                                       // reader, SQLite-level contention) that is not
                                       // corruption. The caller retries; if a runtime
                                       // rebase cannot complete (e.g., the Authority is
                                       // wedged), the store requires a restart to run
                                       // the open-time rebase (§9.2). The four cases
                                       // above are deterministic rejects carrying a
                                       // resync anchor / expected value.
    case persistence(PersistenceFailure)  // wraps v1 PersistenceFailure (03b §10)
                                           // for storage-level failures. Reserved
                                           // (C2-M6) for genuine decode/invariant
                                           // corruption (unknown changeKindRaw,
                                           // oversize/malformed blob, divergence) — the
                                           // 05 §16 corruption-class intent. Transient
                                           // fetch I/O is .temporarilyUnavailable, NOT
                                           // this case.
}
```

**One recovery for all four deterministic rejects; mismatch payloads are
diagnostics-only.** `.storeMismatch`, `.generationMismatch`, and
`.materializerMismatch` carry `expected`/`current` scalars with no recovery
information: recovery is identical to `.tokenExpired`'s (§6.2 m5 - discard
every batch accepted under the cursor, resync from
`currentReconnectAnchor()`), and only `.tokenExpired` carries the anchor
inline. Consumers match the case for logging/diagnostics only; no recovery
path branches on `expected`/`current` (the §6.1 opacity rule: consumers
never inspect stored version fields to recover).

**Why a sibling `ReconnectFailure`, not a new `HistoryFailure` case.** The brief
asks: reuse `HistoryFailure.snapshotExpired` (`03b` §10) or add a new case?
V2-03 does **neither**: it introduces a sibling `ReconnectFailure` enum and
leaves the frozen v1 `HistoryFailure` enum untouched. Justification against
`03b` §10:

1. **Different contract, different recovery.** `HistoryFailure.snapshotExpired(current:)`
   belongs to the v1 **browse-cursor** expiry contract (`04` §6): an intervening
   commit expired a paginated browse cursor; recovery is "re-query page one."
   `ReconnectCursor` expiry has reconnect-specific recovery: "discard cached
   state, full resync from `currentAnchor`." Conflating them under one case
   misrepresents the recovery and forces consumers to disambiguate by context.
2. **Different owning seam.** `snapshotExpired` is produced by the v1
   `ClipboardHistory.browse` path (`04` §6). Reconnect is exposed via the
   **distinct** `ReconnectHistory` protocol (`V2-00` §6.5). A failure case
   carried by one protocol should not be reused to label a failure produced by a
   different protocol.
3. **Avoids the V2-02 enum-addition question.** V2-02 (`V2-02` §8.2) recorded
   the interpretive question whether enum-case **addition** to a frozen v1
   public enum is "extension by addition" (permitted) or "redefinition"
   (forbidden); `V2-00` §8(h) has since **resolved** it in favor of sanctioned
   addition. V2-03 still does not touch `HistoryFailure`. This is the safest
   V2 posture and the consistent
   one: V2-01 likewise added `EnrichmentStatus` rather than a `HistoryFailure`
   case for its distinct concern (`V2-01` §8).

`ReconnectFailure.persistence(PersistenceFailure)` **reuses the v1
`PersistenceFailure` vocabulary** (`03b` §10) by wrapping it — this is not a
redefinition (the v1 type is unchanged) but the standard Swift pattern of a
scoped error enum carrying a lower-level error category. `PersistenceFailure` is
the v1 durable-error vocabulary; reusing it for the storage-level failures that
underlie reconnect reads keeps failure semantics consistent across the v1/V2
surface.

### 6.4 Storage clock seam (reused, not added)

The HCR `createdAt` is the first durable **per-commit** timestamp in the
architecture (v1 stores only per-item `firstCopiedAt`/`lastCopiedAt` and
per-revision `createdAt`, `05` §3.1). Its source is the **same** Storage-side
clock seam V2-02 introduced for `.setRetentionPolicies` R1 (`V2-02` §6.4): a
`Sendable` clock witness (`() -> Date` closure or `RetentionClock` protocol)
injected into `HistoryAuthority` at `open`, defaulting to `Date.now` in
production and injectable in tests. **V2-03 reuses this seam; it adds no new
service-locator or injection point** (`J1-COMPILE-1` stays free of a new escape
hatch). What V2-03 does add is a **per-commit clock read where v1 did not read
the clock on that commit path**: v1 reads a clock only in *preparation*, off
the commit interval (revision `createdAt`; capture times are caller-supplied
`observedAt`), and V2-02 reads it only on
R1-carrying commits; the HCR is **always-on**, so the clock is now read on every
History Commit (pin / unpin / remove / clear / retire / policySet / revise too,
not only capture). The read is one `Date.now`-equivalent inside the serialized
Authority interval (the stamping/transaction stage, `05` §9/§10, no suspension;
the clock is captured there, not in the post-commit phase) — O(1), cheaper than
the codec encode + `context.insert` it shares the closure with — but it is an
honest new per-commit cost recorded in `J1-PERF-1`, not "free." **Wall-clock is
NOT monotonic (C3-n4):** `Date.now` can move backwards across NTP adjustments or
skew; a backwards move would make an age-bounded row appear younger than it is
and UNDER-compact (a safe direction — the row lingers, count/byte compaction
bounds still apply, and no cursor is silently broken). The clock seam is
injectable in tests for determinism; production uses `Date.now`. The value is captured
once and reused for the HCR `createdAt` (and for R1 age arithmetic when V2-02 is
active on the same commit). This keeps the Domain pure (it mints no `Date()`,
`02` §1).

## 7. Collection cache (the G2 cache)

### 7.1 What it caches, and the isolation model (M1)

An in-memory cache of `browse(.recent)` / `browse(.search)` **first-page**
results, internal to `HistoryStorage`. The cache is **first-page-only**: it
serves the page a fresh browse query produces (mirroring v1's observation scope,
`04` §6 "Observation is limited to the first page"). Continuation pages bypass
the cache and always run the v1 scalar scan — this avoids the page-offset key
collision (M8: two pages of the same query sharing a key would let a page-2 read
hit a page-1 entry, a cache-law violation; first-page-only is the simplest
correct scoping and covers the G2 hot path — recent/search first page — that the
trigger measures). The cache stores `HistoryPage`-equivalent values (scalar
`HistoryRow` projections + position + ordering anchor), never `@Model`, never
Canonical/revision blobs (preserves Part VI §7.5 scalar-read isolation).

**Isolation model: actor + async fence.** `CollectionCache` is an `actor`. The
Authority read path consults it **before** the non-suspending read interval and
**fences on `ChangePosition` inside** the interval — the single model that
reconciles §7.1/§7.5/§10.1/§10.2 (M1):

```text
Authority browse read path (05 §14), cache-extended:
  1. (outside the non-suspending interval) await cache.lookup(queryShape,
     materializerVersion) -> (page?, builtAtPosition P_build?,
     builtAtEpoch E_build?)
       - crossing to the CollectionCache actor is an `await`; it happens BEFORE
         the 05 §11 non-suspending interval, so it adds no suspension inside the
         serialized interval
  2. enter the non-suspending read interval (05 §14):
       read current ChangePosition P_current AND current corpus epoch
       E_current = Authority.enrichmentCorpusEpoch (two scalar reads,
       one interval; enrichment bumps cannot interleave inside it)
  3. FENCE: if a cached page was returned AND P_build == P_current AND
     materializerVersion == JournalConfigRow.materializerVersion AND
     E_build == E_current:
       serve the cached page (the G2 latency win; no v1 scan)
     else (no page, position advanced between the await and the fence,
           materializer bumped, or a non-commit corpus write bumped the
           epoch - V2-01 persistEnrichment/setEnrichmentEnabled, §14):
       run the v1 scalar scan (05 §14.1/§14.2), build the page at P_current
  4. (outside the interval) on a scan, await cache.insert(page, queryShape,
     P_current, E_current, materializerVersion)   // E_current captured in
     the step-2 interval: the page's corpus IS the E_current corpus.
     Capturing at insert time (post-interval) would key a page built at
     an older epoch under the newer epoch and re-open the stale race.
```

The fence (step 3) is the correctness guarantee: the Authority is the single
serialized writer, so `P_current` read inside its interval is stable for the
read; if a commit advanced the position between the `await cache.lookup` (step 1)
and the fence, the cached page (built at `P_build < P_current`) is treated as a
miss and the scan runs. The cache's **async invalidation** (§7.3, driven by the
post-commit wake) is a **latency optimization** (evict stale entries eagerly so
step 1 returns nil instead of a doomed page); it is **not** on the correctness
path, because the fence re-checks position regardless. This means the cache
never serves wrong bytes even if an invalidation is delayed or lost: the fence
catches every staleness case. (`05` §11 "without suspension" is preserved: the
two `await`s are outside the non-suspending interval; the interval itself
contains only the two scalar reads (position + corpus epoch), the fence
compare, and the optional scan.)

```swift
internal actor CollectionCache {
    private var entries: [CollectionCacheKey: CollectionCacheEntry] = [:]
    private var lastSeenPosition: ChangePosition    // drives scoped invalidation (§7.3)
    private let authority: HistoryAuthority          // for refetch-on-miss (05 §14)
    private let journal: ChangeJournal               // for scoped invalidation (J1-PERF-3)

    // All three are async: the cache is a separate actor (M1). lookup returns the
    // candidate page + its build position + its build corpus epoch so the caller
    // can fence; the fence itself runs in the Authority interval, not here.
    func lookup(_ request: NormalizedBrowseRequest, materializerVersion: UInt16)
        async -> (page: HistoryPage?, builtAt: ChangePosition?,
                  builtAtEpoch: UInt64?)
    func insert(_ page: HistoryPage, for request: NormalizedBrowseRequest,
                at position: ChangePosition, corpusEpoch: UInt64,
                materializerVersion: UInt16) async
    func invalidateDelta(to newPosition: ChangePosition) async   // §7.3 wake-driven
    func flush() async   // conservative full eviction (generation bump, rebase)
}

internal struct CollectionCacheKey: Hashable, Sendable {
    let queryShape: NormalizedQueryShape     // browse kind (recent vs search(text, mode)); page-limit; sort anchor
    let changePosition: ChangePosition       // the position the cached page was built at
    let materializerVersion: UInt16          // JournalConfigRow.materializerVersion
    let corpusEpoch: UInt64                  // non-commit corpus-write discriminator (V2-01; §7.2)
}

internal struct CollectionCacheEntry: Sendable {
    let page: HistoryPage                     // scalar projections + position + cursor
    let builtAt: Date                         // for LRU eviction
}
```

`NormalizedQueryShape` and `NormalizedBrowseRequest` are the cache's two
normalized-request types, declared with their conformances (C3-m6 — `J1-COMPILE-1`
depends on both being `Sendable`; `CollectionCacheKey: Hashable, Sendable` (above)
requires `NormalizedQueryShape: Hashable, Sendable`):

```swift
// SortAnchor captures the v1 browse sort order (04 §7:
// "every sort ends with lastCopiedAt descending and History Item ID bytes
// ascending"). v1 ships ONE fixed sort order, so for V2-03 this is a single-
// case enum carried in the cache key for forward-compatibility (a future
// user-selectable sort would add cases here, invalidating cache keys whose
// anchor differs). v1 keeps the page-resume "last-row ordering anchor" opaque
// inside `HistoryPageCursor.payload` (`Data`, 04 §6); this SortAnchor is
// the cache-key projection of the sort ORDER (not the resume position), so it is
// a value type, not the opaque cursor payload. The cache is first-page-only
// (§7.1), so no page-offset/resume dimension is needed (review-minor-2).
internal enum SortAnchor: Sendable, Hashable {
    case v1Default   // lastCopiedAt desc, then HistoryItemID raw bytes asc (04 §6)
}

internal struct NormalizedQueryShape: Hashable, Sendable {
    // The Hashable cache-key projection of a browse request: the query IDENTITY
    // (browse kind: recent vs search(text, mode); page-limit; sort anchor)
    // without the per-call position/materializer. Derived from
    // NormalizedBrowseRequest by the same 04 §6 browse-normalization the v1
    // browse cursor applies. The kind is the v1 `HistoryBrowseKind` (03a §7),
    // which carries BOTH recent-vs-search AND the `SearchMode` sub-mode
    // (exact/fuzzy/regexp) - different search algorithms for the same term MUST
    // produce distinct cache keys or a cache-law violation results (04 §12;
    // 04 §7 "exact, fuzzy, and regexp are separate algorithms"). The prior
    // separate `recent: Bool` + `mode: BrowseMode` fields were ambiguous
    // (`BrowseMode` is not a v1 type and either duplicated `recent: Bool` or
    // misnamed v1's `SearchMode`), risking a collision between search sub-modes;
    // the v1 `HistoryBrowseKind` removes the ambiguity (review-minor-2).
    let kind: HistoryBrowseKind         // 03a §7 (.recent / .search(text, mode))
    let pageLimit: Int
    let sortAnchor: SortAnchor          // v1 sort order (04 §6); cache-key projection
}

internal struct NormalizedBrowseRequest: Sendable {
    // The caller-facing fully-normalized browse request (04 §6 browse-normalization
    // applied to the inbound request). Hashable only if a future key dimension
    // needs the request itself as a key (not required by CollectionCacheKey, which
    // keys on NormalizedQueryShape); the request is the lookup/insert parameter
    // (§10.2), not a key.
    let shape: NormalizedQueryShape
    let callPosition: ChangePosition   // the live per-call position fence input
}
```

`NormalizedBrowseRequest` is the caller-facing fully-normalized `browse` request
(the `04` §6 browse-normalization applied to the inbound request — browse
kind: recent vs search(text, mode), page-limit, sort anchor); the cache derives
`NormalizedQueryShape` (the `Hashable` cache-key projection of the request: the
query identity without the per-call position/materializer) from it by the same
normalization `04` §6 applies to the v1 browse cursor. The two are 1:1 (a request
maps to exactly one shape); the split mirrors v1's separation of "the cursor's
encoded shape" from "the call's live parameters."

### 7.2 Cache key (the `04` §12 analogue)

`04` §12 requires: *"Any future item cache key must contain History Item ID, the
relevant authoritative version, complete normalized parameters, and a structural
materializer schema version."* For a **collection** cache the analogue is:

- **Query shape** (the collection analogue of "History Item ID" — it identifies
  *which* result set): the fully-normalized `browse` request (`04` §6 normalizes
  the request shape the same way the browse cursor does; browse kind: recent vs
  search(text, mode), page-limit, sort anchor). **Scope: first page only** (§7.1) — there is no
  page-offset dimension because continuation pages bypass the cache (M8).
- **`ChangePosition`** (the collection analogue of "the relevant authoritative
  version" — it identifies *at which commit* the result set was authoritative):
  the page's source position (`04` §2). This is the value the §7.1 fence compares
  against `P_current`.
- **`materializerVersion`** (the "structural materializer schema version"
  required verbatim by `04` §12): the scalar-projection + search-algorithm
  version. A bump (projection schema advance, `05` §15, or search-algorithm
  change) evicts every entry whose key carries the old version.
- **corpusEpoch** (non-commit corpus-write discriminator): an in-memory
  Authority counter bumped (checked arithmetic, 02 §13) in the same
  Authority serialization as every persistEnrichment that writes a ready
  EnrichmentRow and every setEnrichmentEnabled toggle (V2-01 §4.1/§8).
  In-memory like the cache itself: restart empties both, so it is not
  persisted. Without it a browse(.search) page cached before an
  enrichment persist is served stale indefinitely - enrichment changes
  the corpus without advancing ChangePosition (V2-01 §4.1), so
  P_build == P_current still holds and D27's never-wrong-bytes claim and
  04 §12's cache law are violated.

A cache entry is served **only** on an exact four-element match (page shape,
`changePosition`, `materializerVersion`, `corpusEpoch`) **and** after the
§7.1 fence confirms the build position is still current. A stale
(`changePosition` behind current, or `corpusEpoch` behind a non-commit corpus
write), mismatched (`materializerVersion` differs), or
post-fence-miss entry is a miss (the cache degrades to refetch, never to wrong
bytes — D27).

### 7.3 Invalidation (two floors: position-fence shipped, HCR-scoped optional)

The cache has **two invalidation floors**, one shipped and correct, one optional
and finer. Correctness rests on the **position fence** (the §7.1 step-3 fence +
the shipped floor below), **not on HCR content**; the HCR is the substrate that
enables the finer floor (`J1-PERF-3`) and reconnect (m10). The two floors are
**ALTERNATIVE wake handlers, not sequential**: on each transient wake exactly
ONE runs. When `J1-PERF-3` is OFF (shipped default), the `CollectionCache` runs
the shipped floor only — blanket-evict every entry with `changePosition < P_new`
and set `lastSeenPosition = P_new`. When `J1-PERF-3` is promoted to shipped
(C2-M3 path (a) below), it runs ONLY the finer floor — it does NOT blanket-evict;
instead it selectively invalidates by `changeKind` against the HCR rows since the
prior `lastSeenPosition`, and advances `lastSeenPosition = max(returned
sequence)`, NOT `P_new`. Running both sequentially is a contradiction: the
shipped floor evicts every entry behind `P_new` and resets `lastSeenPosition =
P_new` (the journal HEAD), leaving the finer floor no surviving entries to keep
and an empty `changes(since: lastSeenPosition)` fetch — so they are mutually
exclusive. The §7.1 position fence (it re-checks `P_build == P_current` on every
hit) is the correctness backstop in BOTH modes; the floors only differ in hit
preservation, never in correctness.

**Shipped conservative floor — position-fence invalidation (no HCR content
needed).** On each transient wake (position `P_new`), invalidate every entry
whose `changePosition < P_new`:

```text
HistoryInvalidation yielded (05 §11 step 2, transient, content-free, position P_new)
  -> CollectionCache receives the wake (a new internal invalidation consumer,
     wired exactly like v1 observer continuations, 04 §4 / 05 §14.4; the
     Authority's post-commit yield is non-blocking, V2-facts.md cycle 7 §7.1,
     fact 8)
  -> for each entry where entry.key.changePosition < P_new:
       evict (over-invalidation; the cache law permits this, only latency suffers)
  -> lastSeenPosition = P_new
```

This floor is **provably complete by construction**: every entry behind the
current position is evicted, so no stale entry can be served (and the §7.1 fence
re-confirms position on every hit regardless). It needs **only the newest
position**, which the transient wake carries — coalesced wake-ups do not matter
(the fence cares only about the latest `P_new`, not the intermediate ones). This
is a "proved completeness mechanism" in the sense of `04` §12 ("a durable change
journal **or another proved completeness mechanism**"), so the shipped cache
satisfies the cache law even without consulting the HCR. **Honest hit-rate
tradeoff (m9) + bursty-write gating (C2-M3):** because every commit invalidates
every cached entry, the shipped floor's hit rate is realized **only between
commits** (read-heavy workloads: many reads, few writes). The clipboard workload
is bursty-write (rapid captures), so the shipped floor alone may yield no latency
win — an inert cache. The G2 admission trigger (`06` §3) is workload-neutral (p95
thresholds); J1 therefore ships the cache under an explicit **read/write-ratio
re-check**: after admission, if the measured workload is bursty-write (too few
reads between commits for the shipped floor to hit), the design takes one of two
paths — (a) promote `J1-PERF-3` finer invalidation to **shipped (non-optional)**
so hits survive across commits, or (b) keep `cacheEnabled == false` (cache inert
/ bypassed, byte-for-byte v1) until a read-heavy admitting pattern is measured.
`J1-PERF-2` states this explicitly and does not claim a hit across commits under
the shipped floor; the finer floor below is what extends hits across commits.

**Optional finer floor — HCR-scoped invalidation (`J1-PERF-3`, MAY).** To keep
entries alive across commits whose `changeKind` provably cannot affect them,
the cache MAY consult the HCR. This is the only path that reads HCR content for
the cache, and it is decoupled from the wake value to avoid thrash (m3):
`lastSeenPosition` advances to `max(returned sequence)` unconditionally, and the
**flush-on-gap** fires only on a **real contiguity break**, not on the wake
value:

```text
HCR-scoped path (J1-PERF-3, optional; runs on the CollectionCache actor as an
ALTERNATIVE wake handler to the shipped floor above — NOT after it; the shipped
floor does NOT run when this floor is active):
  -> fetch changes(since: lastSeenPosition) from ChangeJournal
       (the INTERNAL POSITION-BASED reader, §6.2 C2-M2: ChangeJournal.
       changes(since position:) — the Authority mints the cursor internally from
       the live JournalConfigRow; the cache holds no cursor fields. Ordered HCR
       rows; bounded by maxReconnectBatchSize, paginated. A .tokenExpired reject
       here — lastSeenPosition fell below an advanced compactionFloor — is treated
       as the contiguity-break FLUSH below.)
  -> REAL CONTIGUITY CHECK (decoupled from the wake value P_new):
       lowest = min(returned.sequence)
       if lowest != lastSeenPosition.successor() AND lastSeenPosition != 0
          (checked successor per D5/D6, NOT raw UInt64 +1 — m7; the migrated-store
           initial gap and post-rebase reset are excepted; lastSeenPosition == 0
           means "no prior anchor," not a gap):
         FLUSH (a real contiguity break means the incremental view is
         unrecoverable from the HCR); the shipped floor did NOT run (this floor
         is the active handler), so this flush drops every entry regardless of
         changePosition (the §7.1 fence remains the correctness backstop)
       else:
         for each HCR row, scope invalidation by (changeKind, affectedItemIDs):
           .insert/.coalesce/.revise/.retire/.remove/.clearAll/.clearUnpinned/
             .policySet -> membership/content change -> invalidate entries whose
             queryShape could be affected (conservative: any matching shape)
           .pin/.unpin -> order change -> invalidate recent-list entries
             (search entries are unaffected unless the search ranks pinned-first,
              03b §8; conservative: invalidate both)
           .retireRevision -> does not change list membership or title/searchBody
             (R3 prunes inactive revisions, V2-02 §5.2); no-op for the collection
             cache (it stores list/search projections, not revision detail)
  -> lastSeenPosition = max(returned.sequence)   // unconditional; NOT P_new
```

Decoupling the gap check from the wake value (m3) is what prevents thrash: under
sustained commits, rows up to `P_newer > P_new` may arrive between the wake and
the HCR readback; judging staleness by `max(returned) != P_new` (the old rule)
would misclassify that as a gap and flush on ~every commit. Judging by the real
contiguity break (`lowest != lastSeenPosition.successor()`) flushes only when the
HCR itself has a hole, which under D25/D26 happens only at compaction (handled by
the `.tokenExpired` reject the position-based reader returns when
`lastSeenPosition < compactionFloor`, which forces a flush) or rebase (handled by
`generation` bump, which flushes). The wake value `P_new` is **timing-only** (it
tells the cache a wake arrived); it does not gate the flush.

**Why the HCR is recorded as the `04` §12 completeness mechanism even though the
shipped floor does not read it.** The position-fence floor is a proved
completeness mechanism on its own (above), so the shipped cache satisfies `04`
§12 without HCR content. The HCR is the **stronger substrate** the design bundles
because (a) it is required for reconnect regardless (deliverable 2), and (b) it
is the only mechanism that can make the finer, hit-preserving floor provably
complete (the transient stream cannot answer "what kind of change was each
commit?" — it carries only the newest position). Stating the HCR as the `04` §12
mechanism is therefore honest: it is the mechanism that makes **both** the
shipped floor (trivially, since the fence is complete) and the finer floor
(provably, since the HCR is the complete delta source) lawful, and it is the
reconnect substrate. `04` §12's "transient stream is insufficient" refers to
**delta-application** completeness (which the finer floor needs); the shipped
floor avoids needing deltas by invalidating unconditionally. (m10)

### 7.4 Cache law compliance (Record 4 restatement)

The Part IV §12 law — *"For the same authoritative source state and request,
cache hit, cache miss, eviction, disabled cache, and process restart produce
semantically identical values and failures; only latency and resource use may
differ"* — holds for the collection cache:

- **Hit:** the served page is the page that would have been produced by a miss
  at the same `(queryShape, changePosition, materializerVersion,
  corpusEpoch)`; the cache stores exactly that page (built by the v1 scan), and
  the §7.1 fence confirms
  the build position is still current before serving. Byte-identical.
- **Miss:** the v1 scan runs and populates the cache; the result is what v1
  would have returned.
- **Eviction (LRU or capacity):** an evicted entry is a miss on next read; v1
  scan re-runs. Byte-identical.
- **Disabled (`cacheEnabled == false`):** the cache is bypassed; every read runs
  the v1 scan. Byte-for-byte v1 (this is the cache-law disabled-path and the
  v1-faithful mode for callers that have not opted into the G2 graft).
- **Restart:** the cache is in-memory and starts empty; the HCR journal is
  durable but the cache does **not** replay it on restart (it simply starts
  fresh at the current position). The first read after restart is a miss
  (v1 scan); subsequent reads hit. Semantically identical to a miss; only
  latency differs.
- **Failure equivalence:** the cache never changes failure semantics. A browse
  that would return `.snapshotExpired(current:)` (`04` §6) still does — the
  cache stores only pages built at a position that was current at build time,
  and a cursor-position mismatch is detected before cache lookup (the browse
  cursor's own expiry check, `04` §6, runs first). The cache adds no failure
  path.

The cache key contains the `04` §12-mandated elements (§7.2); the HCR is its
proved-completeness mechanism (`04` §12). D27 (§16) states this as an invariant.

### 7.5 Does NOT replace live observation

The collection cache and the HCR do **not** enter the v1 observer's wake
predicate. v1 live observation stays snapshot-replacement (`04` §5): the
observer registers a continuation, queries, and on each transient
`HistoryInvalidation` (position > yielded page) re-queries authoritative state.
The collection cache is consulted **before** the Authority's non-suspending read
interval and fenced inside it (§7.1) — never *inside* the v1 observer's wake
predicate; the observer still receives fresh pages and its race-free contract
(`04` §5) is unchanged. The HCR's role is durable reconnect + the optional finer
cache-invalidation floor (`J1-PERF-3`), not live observation (D28, §16). The
shipped cache's correctness rests on the position fence + the transient wake, not
on HCR content (§7.3, m10).

## 8. Journal retention and compaction

The journal grows by one row per History Commit; without compaction it is
unbounded. V2-03 defines a compaction policy **separate from history retention**
(V2-02):

- **Trigger.** Every `JournalLimits.compactionCadenceCommits`-th commit (50),
  the Authority performs an amortized compaction pass in its own operation-local
  transaction (separate from the triggering commit's transaction — compaction is
  not in the commit closure, to keep the commit closure's work bounded and
  deterministic). Compaction **also runs on startup** and on a **wall-clock
  periodic timer** (see "wall-clock bound" below). The pass is **synchronous on
  the Authority** (it serializes on the single writer, like every other write);
  its cost is bounded by `J1-PERF-5` (m4). The commit-cadence trigger is the
  steady-state path; startup + the wall-clock timer are the wall-clock-bounding
  paths for inactive and always-running-few-commit users (C2-m8).
- **Floor (underflow-safe; C1-persisted).** The compaction predicate deletes
  `HistoryChangeRecordRow` rows with `sequence <= deleteFloor`, where the
  `deleteFloor` is computed with **clamped, checked arithmetic** (no `UInt64`
  underflow, review-minor-4):

  ```text
  ageFloor   = (no row exceeds the age bound)
                 ? 0
                 : min(maxSequenceWhere(ageSeconds > effectiveMaxJournalAgeSeconds),
                       maxSequence.predecessor())
               // ageFloor is the BOUNDARY (the highest too-old sequence = the
               // youngest too-old row), NOT the single oldest, so ALL too-old
               // rows (the low-sequence prefix {1..ageFloor}) are deleted in one
               // pass, not just row 1. HCR sequence == commit ChangePosition
               // (monotone: lower sequence = older = higher age), so the too-old
               // rows are a low-sequence prefix; maxSequenceWhere (not
               // minSequenceWhere) selects the boundary. The maxSequence.predecessor()
               // cap (checked predecessor per D5/D6, m7 - NOT raw UInt64 - 1, and
               // NOT maxSequence.successor() - 1 which == maxSequence and does NOT
               // cap below the head; fails closed to 0 when the journal is empty)
               // preserves D25: even when ALL rows are too-old (app idle > maxAge),
               // the newest row (sequence == maxSequence) always survives, so
               // deleteFloor < max(sequence) holds. Equivalently: delete all rows
               // strictly older than maxAge EXCEPT the head. 0 if no row exceeds
               // the age bound (no age-driven deletion). NOTE: a naive
               // maxSequenceWhere WITHOUT the predecessor cap would set ageFloor
               // == maxSequence when all rows are too-old, deleting the head and
               // violating D25 (§16: deleteFloor < max(sequence)).
  countFloor = (maxSequence >= effectiveMaxJournalRecordCount)
                 ? (maxSequence - effectiveMaxJournalRecordCount)
                 : 0
               // clamped: when the journal holds fewer rows than the count cap,
               // countFloor is 0 (delete nothing by the count rule); the
               // unguarded (maxSequence - cap + 1) would wrap to ~UInt64.max and
               // delete the entire journal — this clamp prevents that
  deleteFloor = max(ageFloor, countFloor)   // the more conservative (higher) bound;
               // always < maxSequence (both operands are capped below the head),
               // so D25's head-survival holds regardless of which trigger fires.
  // boundary: rows with sequence <= deleteFloor are deleted; rows with
  // sequence > deleteFloor survive. After the delete, the pass sets
  // JournalConfigRow.compactionFloor = deleteFloor (C1, persisted in the same
  // transaction), so the §6.2 step-5 reject test (cursor.sequence <
  // compactionFloor) is deterministic on the next read.
  ```

  The effective bounds (`effectiveMaxJournalAgeSeconds`,
  `effectiveMaxJournalRecordCount`) are the **user-configured `JournalConfigRow`
  values clamped to the `JournalLimits` caps** (§4.5/§4.6/§13), not the raw caps
  — reconciling §8 with §4.6 and §13 (review-minor-7). The byte bound
  (`maxJournalBytes`, §4.5) is a third trigger: if the surviving rows' total byte
  footprint exceeds it, `deleteFloor` is raised until the footprint fits (the
  oldest rows go first).
- **Never breaks a live cursor (D26).** A cursor whose `sequence` was compacted
  (`cursor.sequence < JournalConfigRow.compactionFloor`) is rejected
  `.tokenExpired(currentAnchor:)` on its next `changes(since:)` call — the
  reject runs **before** the range fetch (§6.2 step 5, C1). Compaction never
  silently serves a partial replay. Because cursors are caller-held opaque
  values, the journal cannot know the lowest live cursor ahead of time; it
  relies on the age/count floor being generous enough that live cursors
  (typically recent) survive, and on the typed reject (against the **persisted**
  `compactionFloor`) when they do not. This is the honest contract: **replay is
  complete or rejected, never partial** (D26).
- **Wall-clock bound on removal records (m5, C2-m8).** v1/V2-02 retire item
  content promptly (the deletion is in the retirement commit), but the **HCR
  record** of a removal lingers until compaction (§12). For an inactive user (no
  commits between launches), the commit-cadence trigger would not advance, so
  the removal record could linger up to the count/age cap. To bound this
  wall-clock, compaction has **three** triggers, not two: (a) the commit-cadence
  trigger (every `compactionCadenceCommits`-th commit); (b) **mandatory startup
  compaction** — every `open` runs a pass (after the §4.6 singleton bootstrap and
  before the facade is published); and (c) **a wall-clock periodic trigger** — a
  process-lifetime timer (armed at `open`) fires a compaction pass every
  `effectiveMaxJournalAgeSeconds / 2` of wall-clock while the process runs
  (bounded off the Authority queue by `J1-PERF-5`). The wall-clock timer is what
  bounds an **always-running, few-commit** menu-bar process: without it, the
  commit-cadence trigger would not advance and the count cap bounds only record
  *count*, not *age*, so removal records could linger past
  `effectiveMaxJournalAgeSeconds`. With the timer, the age bound is
  `effectiveMaxJournalAgeSeconds` (default 7 days), with a worst-case survival of
  `effectiveMaxJournalAgeSeconds + (effectiveMaxJournalAgeSeconds / 2)` (~10.5
  days default) due to the timer half-period: the timer fires every
  `effectiveMaxJournalAgeSeconds / 2`, and the predicate is strict `>` (age ==
  maxAge is NOT > maxAge, so a record at exactly the bound survives one more
  half-period). The worst-case extension for an actively-running process between
  two timer/commit triggers is thus bounded by the timer half-period plus one
  compaction pass; this is stated honestly in §12. (This bound is independent of
  the age-floor fix above, which must also be applied for the bound to hold:
  without it only the single oldest too-old row is deleted per pass and the age
  bound is silently broken.)
- **Compaction is a derivation operation.** It deletes only HCR rows and writes
  only `JournalConfigRow.compactionFloor`; it touches no `HistoryItemRow`, no
  `LastChangePositionRow`, no Signature Index, advances no `ChangePosition`, and
  mints no `ContentVersion`. Its loss/crash mid-pass commits nothing (closure
  failure, `05` §10); a partial compaction leaves extra rows (harmless — they
  are still valid HCR rows) and a possibly-stale `compactionFloor` (also
  harmless — a too-low floor only means a compacted cursor is rejected one read
  later, never a partial replay). D25 is unaffected.
- **Compaction does not advance `generation`.** Compaction preserves the
  journal's shape; it only removes old rows and advances `compactionFloor`.
  `generation` advances only on schema migration, materializer-version bump, or
  rebase (§4.6, §9.1).

## 9. Crash consistency and startup validation

### 9.1 Startup invariant check

`SwiftDataHistory.open` (`05` §13) gains one validation step after the V2-01/V2-02
singleton creation and before the facade is published:

```text
11. (V2-03) fetch max(HistoryChangeRecordRow.sequence),
    max(HistoryChangeRecordRow.changePositionRaw), and
    LastChangePositionRow.rawValue; require all three equal (D25). The
    changePositionRaw aggregate is the consumer that justifies the duplicate
    column (§4.1/§4.3, C2-m2). Its cross-check POWER IS BOUNDED (C3-m2): a
    divergence of `max(changePositionRaw)` from `max(sequence)` detects either
    the max-`sequence` row's `changePositionRaw` divergence or a
    `changePositionRaw` runaway beyond `max(sequence)` — but a MID-ROW
    `sequence != changePositionRaw` divergence below the maxima is NOT caught
    by the max-aggregate (it would need a per-row scan). The aggregate is
    therefore a cheap O(1) runaway / max-row guard, NOT a per-row invariant
    scan; a per-row scan is not budgeted in `J1-PERF-4` and is deferred to a
    future hardening if a real corruption class demands it. The
    journal-vs-singleton equality (`max(sequence) == LastChangePositionRow.
    rawValue`) is the primary D25 guard; `max(changePositionRaw)` adds a
    redundant column cross-check on the same max row.
      - EMPTY-JOURNAL BOOTSTRAP (fresh or just-migrated store): if the HCR table
        is empty, both maxes are undefined; treat this as equality with
        lastSeenPosition = LastChangePositionRow.rawValue (caught-up; the
        journal covers only post-migration changes, §1.1/Record 5). This is the
        normal first-open state, not divergence.
      - on equality (or empty bootstrap): set lastSeenPosition for the
        CollectionCache = LastChangePositionRow.rawValue (caught-up; no replay
        at startup).
      - on divergence (any pair of the three differs, or a corrupt row): the
        journal is inconsistent with durable state.
        Recovery: JOURNAL REBASE (§9.2).
```

This step runs as step 6 of the §4.6 total order (after singleton bootstrap +
materializer detection and the step-5 mandatory startup compaction pass, before
the facade is published). The `compactionFloor` read by §6.2 step 5 is therefore
already current when the first reconnect call lands.

The check is the D25 defensive guard. Under correct atomic commits it never
fires (D25); it fires only on a should-never-happen invariant violation
(corruption, a partial commit that escaped the transaction boundary, a store
edited out-of-band).

### 9.2 Journal rebase (the recovery path)

The HCR is a **derivation** off the commit path: its records past changes, and
past changes are **not reconstructable** from durable item state (Record 5: no
backfill). So the recovery from an inconsistent journal is a **rebase**, not a
reconstruction:

```text
JOURNAL REBASE (inside the Authority, at open or on detected divergence):
  -> delete all HistoryChangeRecordRow rows (the inconsistent journal)
  -> bump JournalConfigRow.generation (+1, checked arithmetic)  // expires every live
                                                               // cursor (D26)
  -> reset JournalConfigRow.compactionFloor = 0   // C1: no rows survive, so no
                                                  // floor; generation bump already
                                                  // expires every cursor regardless
  -> reset JournalConfigRow.journalBytes = 0   // the running payload-byte
                                               // counter must not outlive the
                                               // rows it summed (DC-9)
  -> leave JournalConfigRow.storeInstance unchanged  // M2: rebase does not change
                                                     // the store identity (same
                                                     // store file, restarted journal)
  -> leave LastChangePositionRow unchanged   // durable history state is authoritative
  -> set CollectionCache.lastSeenPosition = current position (caught-up, empty cache)
  -> log a journal-rebase event (internal; surfaces to UX as a "resync" notice, §13)
  -> writes remain enabled (durable history state is intact; only the journal restarted)
```

A rebase is **safe** because the HCR is a derivation: its loss degrades to
cursor-expiry (every live cursor's `generation` mismatches), never to wrong
durable history state (D25, D26). Consumers holding a pre-rebase cursor receive
`.generationMismatch` on their next `changes(since:)` and perform a full resync
from `currentReconnectAnchor()` — which is the correct, typed recovery (D26).
The collection cache starts empty (no consumer sees wrong data).

**Why automatic rebase (not fail-open).** v1 fails open on corrupt signature/pin
metadata ("fails open rather than enabling writes from an unproved state",
`05` §13) because the Signature Index is a **correctness-critical** structure
(dedup depends on it). The HCR is a **derivation**: its correctness is not on
the dedup path. Disabling writes because the journal is inconsistent would be
disproportionate — it would let a derived-structure corruption block all
captures. The rebase keeps writes enabled while honestly expiring every cursor
(the typed reject path). This is the cache-law/derivation safety direction
(decisions §14, §15; `V2-00` §6.4 "Crash safety: the change journal and caches
are derivations; their loss degrades to a miss/rebuild, never to wrong durable
state"). `J1-PLATFORM-2` confirms the rebase behavior on the macOS 26 runner.

### 9.3 `.memory` store path

The HCR + collection cache work identically in the `.memory` store (the HCR is a
SwiftData table in the in-memory store; the collection cache is in-memory either
way). The reconnect cursor in `.memory` is process-lifetime (lost on process
exit, since the store is in-memory) — acceptable, because `.memory` is the
deterministic test medium (`01` §4 / `03a` §3; `05` §2 changes the durability
medium only). The startup invariant check (§9.1) runs on `.memory` too.

## 10. Code model

### 10.1 Module and target placement

- **Public surface** (`ReconnectHistory` protocol, `ReconnectCursor`,
  `ReconnectBatch`, `HistoryChangeRecord`, `JournalEntryKind`, `ReconnectFailure`)
  is added to `HistoryCore` as a clearly V2-scoped section, Foundation-only
  (`01` §8). These types reuse v1 vocabulary (`HistoryItemID`, `ChangePosition`,
  `PersistenceFailure`) verbatim and add no name that collides with v1
  vocabulary (`V2-00` §9). Adding new types to `HistoryCore` is a
  "capability-gated extension of an existing module" (`V2-00` §2.1); no existing
  v1 `HistoryCore` type is modified, and the frozen v1 `HistoryFailure` enum is
  **not** touched (§6.3).
- **Implementation** (`HistoryChangeRecordRow`, `JournalConfigRow`,
  `AffectedItemsBlobV1`, `HistoryChangeRecordPayload`, `ChangeJournal`,
  `CollectionCache`, the stamping derivation, the transaction-closure append,
  the journal-rebase path, and the Authority read methods) is added to
  `HistoryStorage`. **No new framework import** (V2-03 uses only Foundation +
  the SwiftData already imported in `HistoryStorage`, `01` §8); the import gate
  (`01` §9) is **unchanged** (contrast V2-01, which added `Vision`/`PDFKit`).
- `SwiftDataHistory` gains a `ReconnectHistory` conformance; `ChangeJournal` and
  `CollectionCache` are stored fields of `SwiftDataHistory` (extending its actor
  field set, `05` §2). Both are `actor` types, so `SwiftDataHistory: Sendable`
  remains derived without `@unchecked Sendable` (`01` §6). This is a private
  stored-field addition to a v1 public concrete type, exactly as V2-01 added
  `EnrichmentWorker`/`EnrichmentScheduler` (`V2-01` §6.1); the public interface
  is unchanged (additive extension under the V2 self-review gate, `V2-00` §8).

### 10.2 ChangeJournal and CollectionCache actors

```swift
internal actor ChangeJournal {
    private let authority: HistoryAuthority
    func changes(since cursor: ReconnectCursor?) async throws -> ReconnectBatch
    func changes(since position: ChangePosition) async throws -> ReconnectBatch  // C2-M2:
        // internal position-based reader for the CollectionCache finer floor
        // (§7.3); the Authority mints the cursor internally from the live
        // JournalConfigRow (§6.2). Aligned stem (nit 11).
    func currentReconnectAnchor() async throws -> ReconnectCursor
}

internal actor CollectionCache {
    private var entries: [CollectionCacheKey: CollectionCacheEntry]
    private var lastSeenPosition: ChangePosition
    private let authority: HistoryAuthority
    private let journal: ChangeJournal

    // M1: all three are async (separate actor). lookup returns the candidate page
    // + its build position so the Authority read path can fence (§7.1); the fence
    // itself runs in the Authority interval, not here. Consulted BEFORE the
    // non-suspending read interval; returns nil on miss.
    func lookup(_ request: NormalizedBrowseRequest,
                materializerVersion: UInt16)
        async -> (page: HistoryPage?, builtAt: ChangePosition?,
                  builtAtEpoch: UInt64?)

    // Called by the read path (outside the interval) on miss to populate.
    func insert(_ page: HistoryPage, for request: NormalizedBrowseRequest,
                at position: ChangePosition, corpusEpoch: UInt64,
                materializerVersion: UInt16) async

    // Driven by the transient HistoryInvalidation wake (05 §11 step 2). Runs
    // exactly ONE of the two §7.3 floors (ALTERNATIVE wake handlers, not
    // sequential): when J1-PERF-3 is OFF (shipped default) the position-fence
    // floor blanket-evicts entries with changePosition < P_new and sets
    // lastSeenPosition = P_new; when J1-PERF-3 is active it runs ONLY the finer
    // floor, which calls ChangeJournal.changes(since: lastSeenPosition) — the
    // internal position-based reader (C2-M2), NOT the cursor-based reader (the
    // cache holds no cursor fields) — and sets lastSeenPosition =
    // max(returned sequence), NOT P_new.
    func invalidateDelta(to newPosition: ChangePosition) async

    func flush() async   // conservative full eviction (generation bump, rebase)
}
```

Both actors hold only `Sendable` values (`HistoryPage` is `Sendable`;
`ChangePosition`, `HistoryItemID` are v1 `Sendable` values). Neither holds
`@Model` or `ModelContext`, and **neither creates a writable `ModelContext`**:
all durable reads/writes go through `HistoryAuthority` (§10.3), preserving the
single-context-creator rule (`05` §5). The `CollectionCache` methods are `async`
because the cache is a separate actor (M1); the two `await`s the Authority read
path performs (`lookup`, `insert`) are **outside** the `05` §11 non-suspending
interval (§7.1), so they add no suspension inside the serialized read.
`invalidateDelta` is `async` because it optionally awaits
`ChangeJournal.changes(since:)` on the finer floor — but this runs on the
`CollectionCache`'s own executor. **Wake mechanism (C2-M4):** the cache is a
**new consumer of the existing transient `HistoryInvalidation` yield**
(`05` §11 step 2), wired exactly like a v1 observer continuation (`04` §4 /
`05` §14.4) — it is **not** a separate post-commit yield and **not** a cache-
private inbox. The Authority's post-commit phase is therefore literally
unchanged (`05` §11: one `HistoryInvalidation` yield, fanned to all registered
consumers including the cache); the finer-floor `await ChangeJournal.changes` is
on the cache's own executor, downstream of the wake, and adds **no** `await` to
the Authority's post-commit phase (`05` §11 "without suspension"). This keeps
the load-bearing "§11 unchanged" / D28 evidence intact. (Contrast V2-01's
`EnrichmentScheduler`, which has its own private inbox and a separate yield —
the cache deliberately does not mirror that pattern.)

### 10.3 Authority methods (single-writer preservation)

New `HistoryAuthority` methods, all opening a fresh operation-local context and
releasing it before return (`05` §5):

```swift
internal extension HistoryAuthority {
    // Read: HCR range for reconnect (read context; no mutation).
    func journalChanges(since cursor: ReconnectCursor?) async throws -> ReconnectBatch

    // Read: HCR range for the CollectionCache finer floor (C2-M2). Constructs the
    // cursor internally from the live JournalConfigRow (read in the SAME operation-
    // local read context as the range fetch) and runs the identical reject gate;
    // the cache holds no cursor fields. Single non-suspending interval (C2-M7).
    func journalChanges(since position: ChangePosition) async throws -> ReconnectBatch

    // Read: current caught-up anchor.
    func currentReconnectAnchor() async throws -> ReconnectCursor

    // Write: compaction (separate transaction; deletes only HCR rows; advances
    // JournalConfigRow.compactionFloor; §8).
    func compactJournal() async throws

    // Write: rebase (§9.2); called from open on divergence.
    func rebaseJournal() async throws

    // Write: UX-bound config changes (§13 advanced settings). Own transaction;
    // no ChangePosition, no HCR row (this is not a History Commit). Clamps the
    // supplied values to JournalLimits at the boundary (M6).
    func setJournalConfig(cacheEnabled: Bool?,
                          maxJournalAgeSeconds: Double?,
                          maxJournalRecordCount: Int?) async throws

    // Write: materializer-version bump (own transaction; no ChangePosition, no
    // HCR). Bumps JournalConfigRow.materializerVersion AND .generation together
    // (§4.6), evicting every cache entry and expiring every live cursor.
    func bumpMaterializerVersion(to newVersion: UInt16) async throws

    // Internal: append one HCR row inside the current commit transaction.
    // NOT an async method and NOT a separate transaction: it is called inline
    // inside the 05 §10 transaction closure (§5.1), sharing the commit's
    // atomic save boundary.
    func appendHistoryChangeRow(_ payload: HistoryChangeRecordPayload,
                                in context: ModelContext) throws
}
```

`setJournalConfig` and `bumpMaterializerVersion` are the **writer path for the
UX-bound `JournalConfigRow` fields** (M6): D28 requires `JournalConfigRow` writes
to go through the Authority (single-writer for journal state), and these are the
methods that fulfill it. Neither is a History Commit: neither advances
`ChangePosition`, neither appends an HCR row, and neither yields a
`HistoryInvalidation` (a config change is not a content change — though
`bumpMaterializerVersion` does call `CollectionCache.flush()` because a
materializer bump structurally invalidates every cached projection).
`bumpMaterializerVersion` is also called from the **open-time materializer-
version detection** (§4.6 total order step 4): `open` compares
`JournalConfigRow.materializerVersion` to the compiled-in version and bumps
before the facade is published if they differ, so no caller can observe a
journal whose `materializerVersion` disagrees with the running binary.

`journalChanges` / `currentReconnectAnchor` are read operations (operation-local
read context, `05` §5); they advance no `ChangePosition` and yield no
`HistoryInvalidation`. `compactJournal` / `rebaseJournal` are write operations
in their own operation-local transactions; `rebaseJournal` bumps
`JournalConfigRow.generation` (expiring live cursors). `appendHistoryChangeRow`
is the inline transaction-closure helper (§5.1); it is the **only** writer of
HCR rows on the commit path. None of these methods is part of the `HistoryAction`
dispatch (`05` §8); the closed `HistoryAction` switch is unchanged.

### 10.4 StampedCommitPlan extension and the stamping derivation

`StampedCommitPlan` gains `hcrAppend: HistoryChangeRecordPayload` (§5.2). The
stamping stage (`05` §9) derives it from `plan.position` + `plan.mutations` via
the mechanical `primaryChangeKind` mapping (§5.2 table) + the `affectedItemIDs`
union. The stamping stage already derives `indexDelta` (a projection of the
mutation set) — `hcrAppend` is an analogous derived projection. The executor
(`05` §10 transaction closure) inserts the row from `plan.hcrAppend` after
applying mutations and before the singleton position write (§5.1).

## 11. Code interaction and exhaustive-switch impact

- **`HistoryAction` switch (`05` §8):** **unchanged.** V2-03 adds no case. The
  closed enum and its exhaustive dispatch are untouched.
- **`HistoryMutation` / `PlannedOutcome` (`02` §7):** **unchanged.** The journal
  is not a Domain mutation; the Domain is unaware of the journal (preserves
  D16, D17, D18).
- **`StampedMutation` switch (`05` §9 stamping table, `05` §10 executor):**
  **unchanged.** V2-03 adds **no** `StampedMutation` case. The HCR row is
  appended by an inline transaction-closure step, not by a new stamped case.
  (Contrast V2-02, which added `.pruneRevisions`/`.setRetentionPolicies` cases;
  V2-03 deliberately avoids enum-case addition to minimize v1-internal-surface
  change.)
- **`StampedCommitPlan` struct (`05` §9):** gains one stored field
  (`hcrAppend`). This is a private stored-field extension of a v1 internal
  struct, not a public-type modification.
- **`ClipboardHistory` protocol (`03a` §3):** **unchanged.** A v1 caller that
  holds `any ClipboardHistory` and ignores `ReconnectHistory` behaves exactly as
  on v1. `SwiftDataHistory` conforms to both; `ClipyApp` casts to
  `ReconnectHistory` only when it wants V2 reconnect surface.
- **`HistoryFailure` enum (`03b` §10):** **untouched.** V2-03 introduces
  `ReconnectFailure` as a sibling (§6.3), avoiding the V2-02 enum-addition OPEN
  question entirely.
- **`SwiftDataHistory` field set (`05` §2):** extended with `ChangeJournal` and
  `CollectionCache`. Both are `actor` types, so the derived `Sendable`
  conformance is preserved (`01` §6).
- **v1 walking-skeleton tests (`06` §8):** run unchanged. The HCR append is
  additive (one extra row per commit, invisible to the public outcomes the WS
  tests assert); the collection cache is bypassed when `cacheEnabled == false`
  and is transparent (cache law) when `true`. V2-03 adds parallel V2 fixtures
  (§17). **WS13 (`06` §8 WS13 — Transaction failure) interaction (m6):** WS13
  injects failure "after row mutation but before singleton update"; V2-03 inserts
  the HCR append in that same window (after mutations, before the singleton
  write, §5.1). Because closure failure commits nothing (`05` §10, atomic), a
  failure injected either **before** or **after** the HCR append leaves no HCR
  row, no item mutation, and no singleton advance — the WS13 assertion ("unchanged
  durable rows and position") holds identically. The injection point is therefore
  not ambiguous under atomicity: V2-WS-J1-5 (§17) extends WS13 to assert **no
  HCR row** on a mid-closure failure at both injection points.

A v1 caller holding `any ClipboardHistory` and ignoring V2-03 is unaffected: the
journal appends silently, the cache is transparent, and no v1 public type or
enum case changed.

## 12. Security boundaries

V2-03 is **not external-facing** (no X1 boundary; it is not an audited external
write, X2, V2-05). Its security record:

- **Trust boundary:** the process boundary; no external/network input. The
  journal is written by the local `HistoryAuthority` only.
- **New durable metadata exposure (Record 6).** v1 durably stores per-item
  `firstCopiedAt`/`lastCopiedAt` and per-revision `createdAt` (`05` §3.1) but no
  **per-commit** timestamp or commit-level change kind. The HCR durably records,
  for every History Commit: the commit's `sequence`/`ChangePosition`, the
  `changeKind` (insert/remove/clearAll/clearUnpinned/retire/…), the
  `affectedItemIDs`, and a per-commit `createdAt`. This is a new durable
  **metadata** exposure: an
  attacker (or a backup restore) with access to the store can reconstruct a
  timed log of every clipboard-history change (when items were added, removed,
  revised, retired) for up to the journal retention window (default 7 days /
  10,000 records, §4.5). This is metadata, not content (no Canonical/revision
  bytes are in the HCR), but it is a new sensitive timeline. It is surfaced to
  UX (V2-07) as a user-visible data practice and recorded here honestly.
- **Deletion latency (contrast V2-02, align V2-01).** v1 item retirement and
  V2-02 retention retire/prune are atomic and prompt (the deletion is in the
  retirement commit, `V2-02` §9). The **HCR record** of that retirement,
  however, lingers until compaction: a `remove`/`retire` produces an HCR row
  recording the retired `itemID`(s), which persists until the age/count
  compaction floor (§8). So while the item's content is gone promptly, the
  **fact and kind** of its removal (and the affected item IDs) remain in the
  journal until compaction. Compaction has **three** triggers (§8), not only the
  commit-cadence one: (a) the commit-cadence trigger (steady-state); (b)
  **mandatory startup compaction** - every `open` runs a pass, so a user who
  launches (even without committing) advances compaction, bounding the removal
  record to ~maxAge + (inter-launch interval); (c) a **wall-clock periodic
  timer** (armed at `open`) that bounds an always-running, few-commit process to
  ~maxAge + (timer half-period). The only case where the removal record is truly
  unbounded is a store **never opened again** (process not running, no launches):
  there no compaction runs and the record lingers up to the count/age cap. The
  security record states this retention window honestly. (A user-facing "flush
  journal now" control is an advanced-settings option, §13.)
- **Content confinement.** The HCR carries no Canonical/revision bytes — only
  item IDs, kinds, positions, and a timestamp. The collection cache stores only
  scalar projections (title/searchBody/typeIdentifiers) that v1 already
  materializes for reads (`05` §14.2). No `@Model` crosses isolation (`01` §6).
- **TCC/sandbox/entitlement:** **none.** The journal is purely internal
  mutation/recording of already-retained, in-process data. No new permission,
  privacy-usage string, or entitlement (`00` §5: state the outcome; no gate
  needed beyond `J1-SECURITY-1`).
- **Audit:** the HCR is **not** an audited external write; it produces no
  `OperationRecord` (X2, V2-05). It is internal change-journal state. The
  HCR records the *fact* of a commit; X2's `OperationRecord` records the
  *provenance* of an external write — distinct concerns, both honest.
- **Crash safety.** The HCR is a derivation. Its loss/corruption degrades to a
  journal rebase (§9.2) and cursor expiry; it never produces wrong durable
  history state (decisions §14; D25, D26, D27). The collection cache is
  in-memory; its loss is a miss. Single-writer is preserved (D28).

## 13. UX interaction hooks (deferred detail to V2-07)

V2-03 provides the data hooks V2-07 (UX) consumes; it owns no SwiftUI:

- **Reconnect status / "recently removed" surface (if product-approved).** A
  main-actor view built only from `HistoryCore` DTOs (`V2-00` §6.6) consuming
  `ReconnectHistory.changes(since:)`. Observation remains snapshot-replacement
  (`04` §5): the view re-browses on an explicit user pull/re-open (no push -
  `ReconnectHistory` is pull-only, §6.3; the HCR does not enter the v1 observer
  wake path, D28), it does not subscribe to a delta stream. Because the HCR is consumed via a distinct
  protocol (`ReconnectHistory`), the v1 live observer is untouched (D28).
  **Best-effort fidelity caveat (C2-m9):** a kind-based "recently removed"
  filter sees `.remove`/`.retire`/`.clearAll`/`.clearUnpinned` rows directly, but
  a **capture + retention-retire** commit records `.insert` as the primary with
  the retired items folded into `affectedItemIDs` (§4.3 primary-kind-only
  contract) — so a pure kind filter MISSES those retirees. The surface is
  therefore best-effort unless the consumer cross-references `affectedItemIDs`
  against its own mirror of authoritative state (the §4.3 consumer obligation);
  absent a mirror, the surface should be scoped to the primary-kind rows it can
  soundly report and avoid claiming completeness over folded retirees.
- **Advanced settings.** A journal-retention window control (age / count) bound
  to `JournalConfigRow` fields, clamped to `JournalLimits` (§4.5); a
  collection-cache enable/disable toggle bound to `cacheEnabled`; and a
  "flush change journal now" control (triggers `compactJournal()` with an
  aggressive floor, expiring every cursor below the new compactionFloor; the
  head row always survives §8, so a caught-up head cursor remains valid - and
  needs no replay). All rendered on the main actor from `HistoryCore` DTOs
  only. None of these three controls is shippable as written: their writer
  path is internal (§10.3 `setJournalConfig` / `compactJournal`) and §10.1
  adds no public admin protocol. A public `JournalAdminHistory` is pending
  OPEN-5 / DC-08 (`V2-roadmap`: "Omit dependent UI if an API is not
  admitted"); `V2-07` §12 already gates them on it. Until OPEN-5 resolves,
  treat these hooks as deferred detail, not a shipped seam.
- **Resync notice.** A journal rebase (§9.2) bumps `generation` and is surfaced
  as a one-time "history resynced" notice (consumers holding old cursors get
  `.generationMismatch` and resync).
- **Accessibility / localization.** Reconnect status, settings labels, and the
  resync notice are localizable (P2, V2-06).
- **No SwiftData/Domain leakage.** All UX is built from `HistoryCore` DTOs
  (`V2-00` §6.6).

## 14. Interaction with sibling V2 grafts

- **V2-01 (enrichment):** enrichment writes (`persistEnrichment`,
  `setEnrichmentEnabled`) advance no `ChangePosition` and are not History
  Commits (`V2-01` §4.1), so they produce **no** HCR record. The HCR records
  only History Commits. Because enrichment writes change the search corpus
  without advancing ChangePosition, the collection cache carries the
  Authority's enrichmentCorpusEpoch in its key and fence (§7.1/§7.2) instead
  of relying on the position fence alone. **Wake fan-out (C2-M4):** the
  collection cache is a new consumer of the **existing** transient
  `HistoryInvalidation` yield (`05` §11
  step 2), wired like a v1 observer continuation (`04` §4) — it is **not** a
  separate post-commit yield. V2-01's `EnrichmentScheduler` inbox, by contrast,
  is a **separate** private inbox with its **own** yield (`V2-01` §6.3). The
  Authority's post-commit phase is literally unchanged (`05` §11): one
  `HistoryInvalidation` yield (now fanned to the v1 observers **and** the cache)
  plus the V2-01 enrichment-inbox yield — the cache adds a consumer, not a yield.
  V2-01's `EnrichmentRow` orphan sweep is likewise not an HCR event (it is not a
  History Commit). No collision.
- **V2-02 (retention):** retention retirements (R1/R2) and revision prunes (R3)
  **are** History Commits (`V2-02` §4) — they advance `ChangePosition` and
  produce HCR records (`changeKind == .retire` / `.retireRevision` / `.policySet`,
  §5.2). V2-02 §12b already states "retention retirements/prunes are History
  Commits that advance ChangePosition; they appear in the durable change journal
  as commits." V2-03 honors this: the stamping derivation maps V2-02 mutations
  to `JournalEntryKind` (§5.2 table). No special journal record is needed.
- **V2-04 (materialization caches):** the C1/C2/C3 thumbnail caches are
  **separate** from the collection cache. C1/C2 cache thumbnail bytes
  (`HistoryItemID` + `ContentVersion` + dimensions); the collection cache caches
  list/search results (query shape + `ChangePosition`). Different keys,
  different consumers, both obey `04` §12. No collision; the `04` §12 law is
  restated per-cache in each owning doc.
- **V2-05 (external gateway / audit):** X1 routes external writes through
  `HistoryAuthority` (`V2-00` §5 decision 16), so they are History Commits and
  produce HCR records (the HCR records the *commit*; X2's `OperationRecord`
  records the *external provenance* — distinct). The HCR does **not** replace X2.
  If a future post-V2 Widget extension writes directly (multi-process), SwiftData
  native History (§3) would be the candidate primitive — explicitly out of scope
  for V2-03 (`V2-00` §3.1).
- **V2-06 (platform grafts):** G5/P1 (persistent startup checkpoint) interacts
  with the HCR startup invariant check (§9.1): the check is a new non-metadata
  startup cost (one `fetchCount`/max-sequence fetch over the HCR table). If
  HCR-inclusive startup p95 exceeds the G5 budget (250 ms, `06` §3), P1 (V2-06)
  or an HCR-specific checkpoint is required; this is assigned `J1-PERF-4`.

## 15. Graft-admission records (`V2-00` §4)

### Record 1 — Lifted exclusion + evidence trigger

- **J1** lifts `00` §2 ("Durable History Change Record journal and reconnect
  cursor") and `06` §3 G2 ("Collection cache plus durable History Change Record
  journal"). Evidence trigger (`V2-00` §3 J1): **either** (a) at the hard
  retained bound (5,000 items), recent/search p95 > 50 ms **or** Authority queue
  wait p95 > 20 ms under the agreed workload (`06` §3 G2); **or** (b) an
  approved reconnect product requirement.

### Record 2 — Invariant impact

D1–D19 are **preserved unchanged**. In particular:

- **D2 (Canonical immutability):** the HCR is metadata (kinds, IDs, position,
  timestamp); it never touches Canonical Content. The collection cache stores
  scalar projections of Effective Content that v1 already materializes; it
  overwrites no Canonical.
- **D5/D6 (precise tokens):** the HCR mints neither `ContentVersion` nor
  `ChangePosition`; `sequence == ChangePosition` by D25 (a recording, not a
  minting). The collection cache advances no token.
- **D7 (fingerprint-is-evidence):** inapplicable to the HCR (it carries no
  fingerprints, only IDs); the collection cache fences on `ChangePosition` (a
  collision-free counter, D5), never on a hash — the cache key's
  `changePosition` is exact.
- **D8 (complete facts):** the journal is not a planning fact; the Domain
  planners receive no journal input and remain complete-fact-bounded.
- **D11/D18 (plan semantics):** the journal is not a `HistoryMutation`; the
  stamping contract is extended by one derived field (`hcrAppend`) and one
  inline transaction step, not by a new mutation case. `changeKind` is derived
  from the explicit `StampedMutation` payloads, not from the `receiptOutcome`
  label (D18 preserved, §5.2).
- **The v1 transient `HistoryInvalidation` (`04` §4) is unchanged.** The HCR is
  a **separate**, durable, content-carrying (kind + IDs) record; the transient
  invalidation remains a process-local, content-free wake-up that may coalesce.
  The collection cache consumes **both**: the transient wake (for timing) and
  the HCR stream (for completeness). v1's race-free observer (`04` §5) is
  unchanged (D28).
- **`04` §12 (cache law / completeness mechanism):** V2-03 *satisfies* it: the
  HCR is the durable change journal `04` §12 requires for a collection cache,
  and the collection cache obeys the law (Record 4, §7.4; D27).

V2-03 **extends** the invariant set with **D25–D28** (§16). No D1–D19 is
weakened.

### Record 3 — V2 proof gates

The analog of Part VI §6 (compile), §7 (schema/platform), §9 (perf) on macOS 26.
Gates use the `J1-` prefix.

- **J1-COMPILE-1 (compile/dependency).** Swift 6 complete strict-concurrency
  build succeeds with the new `HistoryCore` types (Foundation-only), the new
  `HistoryStorage` types (`HistoryChangeRecordRow`, `JournalConfigRow`,
  `AffectedItemsBlobV1`, `HistoryChangeRecordPayload`, `ChangeJournal`,
  `CollectionCache`), and the `StampedCommitPlan.hcrAppend` extension. No new
  framework import; the import gate (`01` §9) is unchanged. No `@unchecked
  Sendable` or `nonisolated(unsafe)`; `ChangeJournal`/`CollectionCache` are
  `actor` types so `SwiftDataHistory: Sendable` is derived.
- **J1-COMPILE-2 (no leakage / single-writer).** No `@Model`/`ModelContext`/
  `PersistentIdentifier` crosses an actor boundary (`01` §6). `ChangeJournal`
  and `CollectionCache` never create a writable `ModelContext`; all durable
  reads/writes go through `HistoryAuthority` (`05` §5). The HCR is appended only
  inside the Authority transaction closure (§5.1). The collection cache stores
  only `Sendable` scalar projections.
- **J1-PLATFORM-1 (transaction atomicity for HCR + mutations).** `ModelContext.transaction(block:)`
  atomically writes the HCR row, the item mutations, and the singleton position
  in one closure (`V2-facts.md` cycle 7 §7.1, fact 5; `V2-facts.md` cycles 3-4). Confirm
  on macOS 26 that appending one extra `@Model` insert in the closure preserves
  the closure-success-is-save-boundary semantics (`05` §10) — D25.
- **J1-PLATFORM-2 (custom-HCR decision + journal rebase + bootstrap total order).** The §3 decision
  (custom HCR over SwiftData native History) is design-justified; SwiftData
  History is VERIFIED to exist (`V2-facts.md` cycle 7 §7.1, facts 1-4) but insufficient for
  the closed/single-writer/semantic-kind contract. Confirm on macOS 26: (a) the
  HCR/position startup invariant check (`max(HCR.sequence) ==
  LastChangePositionRow.rawValue`) holds after normal commits and after a
  simulated crash; (b) the journal rebase (§9.2) restores a consistent
  post-divergence state with writes enabled and `generation` bumped; (c) the full
  §4.6 bootstrap total order (steps 1-7) runs before the facade is published -
  including `configSchemaVersion == 1` validation (step 3), the materializer-
  version detection (step 4: upgrade via `bumpMaterializerVersion(to:)` before
  publish; downgrade refuse surfacing `.persistence(.invariantViolation)` and NOT
  publishing the facade), and the mandatory startup compaction pass (step 5, §8
  trigger (b), run after singleton bootstrap + materializer detection and before
  the step-6 D25 check) - so no caller observes a journal whose config or
  materializer version disagrees with the running binary.
- **J1-PLATFORM-3 (FetchDescriptor range predicate).** A `FetchDescriptor<HistoryChangeRecordRow>`
  with `#Predicate { $0.sequence > cursor.sequence }` and `sortBy: [.init(\.sequence)]`
  returns the contiguous ordered range, bounded by `fetchLimit`
  (`V2-facts.md` cycle 7 §7.1, fact 7; `V2-facts.md` cycle 4). Confirm on macOS 26.
- **J1-PLATFORM-4 (cursor expiry determinism, C1 compactionFloor + M2 store).** A
  `ReconnectCursor` whose `sequence < JournalConfigRow.compactionFloor` (C1:
  compacted past the **persisted** floor), whose `storeInstance` mismatches (M2:
  cross-store), whose `generation` mismatches, or whose `materializerVersion`
  mismatches, or whose `sequence` exceeds the current position (a
  rolled-back-future cursor, §6.2 step 5b - e.g. a same-store backup
  restore), is rejected with the typed `ReconnectFailure` (§6.3) — **before**
  any range fetch, never a partial/empty replay. This is the custom-HCR-owned
  reject path that SwiftData native History does not document
  (`V2-facts.md` cycle 7 §7.1, OPEN 1). Fixture-proved (V2-WS-J1-3, §17).
- **J1-PLATFORM-5 (single-snapshot reject+fetch+head, C2-M7).** `journalChanges`
  performs the D26 reject-gate reads (the live `JournalConfigRow`: `compactionFloor`,
  `storeInstance`, `generation`, `materializerVersion`), the range `FetchDescriptor`
  fetch, AND the currentPosition (journal HEAD) read for `isCaughtUp` in **ONE
  non-suspending Authority interval** on **ONE operation-local read context**
  (`05` §5), with no `await` between them and no second read context.
  Confirm on macOS 26 that all `context.fetch` calls in the `journalChanges` interval
  (the config singleton + the HCR range + the `LastChangePositionRow`/max-sequence
  read for currentPosition) on a single operation-local read-only `ModelContext`
  return a mutually consistent snapshot unaffected by a concurrent `compactJournal`
  commit on the serialized writer (a compaction that raises `compactionFloor` past
  `cursor.sequence` and deletes rows cannot interleave between the floor read, the
  range fetch, and the currentPosition read within this interval — preventing the
  silent partial-replay race D26 forbids, and keeping `isCaughtUp` consistent with
  the gate under one snapshot). This is the custom-HCR-owned snapshot-consistency
  property SwiftData does not document for multi-`fetch` read sequences.
- **J1-PERF-1 (HCR append O(1) + per-commit clock).** The HCR append adds one
  row insert per History Commit (O(1) in retained size). It also adds one
  per-commit Storage-clock read on **every** commit path (pin/unpin/remove/clear/
  retire/policySet/revise too, not only capture), because the HCR is always-on
  (§6.4, m2); this read is O(1) and cheaper than the codec encode + insert it
  shares the closure with. Capture/revise/pin commit p95 with the HCR append +
  clock read is within the agreed commit-interval budget (`06` §9); the append
  is non-suspending and adds no `await` to the commit closure.
- **J1-PERF-2 (collection-cache hit avoids the scan — between commits).** On a
  cache hit, the G2 read returns the cached page without the v1 scalar scan; the
  §7.1 fence confirms freshness. **Honest hit-rate scope (m9) + bursty-write
  gating (C2-M3):** under the shipped position-fence floor, every commit
  invalidates every cached entry, so hits are realized **only between commits**
  (read-heavy workloads). The clipboard workload is bursty-write, so the shipped
  floor's win is conditioned on the read/write ratio: the G2 trigger's
  justification (recent/search p95 > 50 ms at the hard retained bound) must be
  re-checked against the **measured** post-admission read/write ratio, and if the
  workload is bursty-write (no win under the shipped floor), either `J1-PERF-3`
  ships (non-optional) or the cache stays `cacheEnabled == false` (inert) until a
  read-heavy pattern is measured (§7.3). Extending hits across commits requires
  the finer `J1-PERF-3` floor to ship. Cache-miss p95 ≤ v1 scan p95 + the
  cache-insert cost. The cache reads only scalar projections (no Canonical/
  revision decode, preserves Part VI §7.5).
- **J1-PERF-3 (finer invalidation scope — optional).** The shipped position-fence
  floor (§7.3, any commit invalidates entries behind the new position) is correct
  and complete on its own (correctness rests on the fence, not HCR content, m10).
  The finer `changeKind`-scoped invalidation (§7.3 second floor, reading the HCR)
  is an **optional optimization** that preserves hits across commits whose
  `changeKind` provably cannot affect a cached query shape. If shipped, prove the
  cache's `invalidateDelta` does not starve the `CollectionCache` actor or the
  Authority under sustained commit load (the post-commit wake is non-blocking,
  `V2-facts.md` cycle 7 §7.1, fact 8), and that the contiguity-break flush (§7.3) does not
  fire spuriously under sustained commits (m3).
- **J1-PERF-4 (startup-with-HCR p95).** The HCR startup invariant check (§9.1)
  plus **mandatory startup compaction** (§8, m5) are new non-metadata startup
  costs (max-sequence fetch + a compaction pass over the HCR table). Prove
  HCR-inclusive startup p95 is within budget; if it exceeds the G5 budget
  (250 ms, `06` §3), P1 (V2-06) or an HCR-specific checkpoint is required.
- **J1-PERF-5 (compaction pass cost, m4).** The compaction pass (§8) scans and
  deletes up to `maxJournalRecordCount` (10,000) + overhead rows and writes
  `JournalConfigRow.compactionFloor`, serializing on the Authority single writer
  every `compactionCadenceCommits`-th commit (50). Prove the pass does not
  extend the Authority queue p95 past the G2 trigger's 20 ms threshold (`06` §3)
  under the agreed workload; if it does, defer the pass off the commit-cadence
  trigger onto a low-priority Authority task (state the sync-vs-deferred choice
  in the implementation).
- **J1-SECURITY-1 (no new entitlement).** Confirm on macOS 26 that the HCR
  (internal SwiftData table) and the collection cache (in-memory) require no
  privacy-usage string, entitlement, or TCC permission beyond v1's.

### Record 4 — Cache-law compliance

The Part IV §12 law — *"For the same authoritative source state and request,
cache hit, cache miss, eviction, disabled cache, and process restart produce
semantically identical values and failures; only latency and resource use may
differ"* — is restated for the collection cache in §7.4 and stated as D27 (§16).
The cache satisfies `04` §12 via the **shipped position-fence floor** (§7.3), a
proved completeness mechanism independent of HCR content (every entry behind the
current position is invalidated; `04` §12's escape clause — "a durable change
journal **or another proved completeness mechanism**" — is satisfied by the
fence alone, m10). The HCR is the **canonical durable journal** `04` §12 names
— required for reconnect (deliverable 2) and the only mechanism that can make
the optional finer, hit-preserving floor (`J1-PERF-3`) provably complete — not
the sole shipped-cache lawfulness dependency. The cache key contains the
`04` §12-mandated elements plus the corpus discriminator (§7.2: query
shape + `ChangePosition` + `materializerVersion` + `corpusEpoch`); the
fence is the §7.1 three-way compare (position + materializer + epoch). A
fixture proves hit/miss/eviction/disabled/restart
equivalence (§15).

### Record 5 — Migration impact (Part V §17 three layers)

- **Schema layer (SwiftData migration):** add `HistoryChangeRecordRow` and
  `JournalConfigRow` tables to `HistorySchemaV2` (the consolidated V2 schema =
  the frozen v1 models plus V2-01's `EnrichmentRow`/`EnrichmentConfigRow` and
  V2-02's `RetentionExpansionConfigRow` and `RetainedBytesRow`, `V2-01` §3.2 /
  `V2-02` §3.3/§3.3b). The
  migration is `MigrationStage.lightweight(fromVersion: HistorySchemaV1.self,
  toVersion: HistorySchemaV2.self)` — purely additive, no v1 row or column
  rewritten (`V2-facts.md` cycles 1-3; reuses V2-01's `HistorySchemaV1:
  VersionedSchema` retrofit, `V2-01` §10 `E1-PLATFORM-1`). **Incremental
  shipping:** if V2-03 ships after V2-01/V2-02, its models are a further
  lightweight stage (`HistorySchemaV2 -> HistorySchemaV3`) in an ordered
  `SchemaMigrationPlan` (`V2-02` §3.3 incremental-shipping note), not a
  modification of an already-shipped schema. **Data bootstrap (not migration):**
  a lightweight migration adds schema, not data; `SwiftDataHistory.open` creates
  the `JournalConfigRow` singleton (`cacheEnabled == false` until recorded
  G2 evidence — DC-10; `generation == 1`,
  bounds clamped) if absent (§4.6), mirroring v1 `LastChangePositionRow` creation
  (`05` §13 step 3) and V2-01/V2-02's config singletons, so a migrated v1 store
  starts with a configured journal and an **empty HCR table**.
- **Blob layer (versioned blob migration):** `AffectedItemsBlobV1` is a new
  codec (`formatVersion == 1`). No v1 blob (`CanonicalBlobV1`,
  `RevisionStateBlobV1`, `SignatureBlobV1`, `EffectiveTypeIdentifiersBlobV1`,
  `05` §4) is reinterpreted. No `ContentVersion` is reinterpreted. A future
  affected-items codec bump would add `AffectedItemsBlobV2` and a `generation`
  bump (expiring all cursors), exactly as v1 projection schema changes rebuild
  (`05` §15).
- **Projection layer (rebuild):** the HCR is **not reconstructable** from
  durable item state (past changes are gone; no backfill). The journal therefore
  starts **empty** at migration. On a **fresh** store the first commit is
  `sequence == 1` (the singleton moves `0 → 1`, `05` §3.2). On a **migrated v1
  store** with existing history, the singleton `ChangePosition` is already `N >
  0` at migration; the first post-migration commit takes the checked successor
  `N → N+1` (D6, `05` §9), so the **first HCR row's `sequence == N+1`**, not
  `N`. The HCR therefore has a gap from 0 to `N+1` (sequences `1..N` and the
  empty-table prefix do not exist); this is **expected and not corruption** —
  the journal covers only post-migration changes, §1.1 — and the §6.2 reject
  gate's contiguity reasoning does not rely on the initial range being
  contiguous (the `compactionFloor`-based reject and the cache's position fence
  are gap-agnostic). The collection cache starts empty
  (in-memory). **Past changes are NOT reconstructable** — reconnect covers only
  post-migration changes; this limitation is stated explicitly (§1.1). No
  migration invents missing bytes, reinterprets an old `ContentVersion`, reuses
  removed IDs, or enables capture before Signature Index / journal completeness
  is restored (`V2-00` §5 decision 18). The startup invariant check (§9.1)
  guards the journal/position consistency post-migration; on a fresh migration
  it trivially holds (empty HCR, `max(sequence)` undefined → treated as
  equality with `lastSeenPosition = current position`).

### Record 6 — Security boundary

V2-03 is **not external-facing** (no X1 boundary). Its security record is §12:
internal change-journal state; new durable per-commit metadata exposure (kind +
IDs + timestamp, retained up to the journal window); removal-record deletion
latency (lingers until compaction - wall-clock-bounded for a launching or
always-running process by §8's startup + periodic triggers, unbounded only for a
store never opened again);
no TCC/entitlement; no `OperationRecord` (X2 owns external-write audit). The
collection cache is in-memory and stores only v1 scalar projections. The HCR is
a derivation; its loss degrades to a rebase + cursor expiry, never wrong durable
state.

## 16. New invariants D25–D28 (extend `02` §14)

V2-03 owns **D25–D28** — the next free numbers after V2-02's D23–D24 (V2-01 owns
D20–D22), per the global D-invariant allocation registry in `V2-roadmap` §14. (The design
brief numbered these D27–D30, skipping D25–D26; that numbering is corrected here
to avoid colliding with future V2 docs' D25–D26 claims.)

- **D25 Journal crash-consistency (extends D6).** Every non-empty History Commit
  appends exactly one `HistoryChangeRecordRow` **inside the same
  `ModelContext.transaction`** as its item mutations and the singleton position
  write (`05` §10). The row's `sequence == changePositionRaw == the commit's
  ChangePosition`. After every commit, `max(HistoryChangeRecordRow.sequence) ==
  LastChangePositionRow.rawValue`. A crash mid-closure commits no HCR entry and
  no item mutation (closure failure is the rollback boundary, `05` §10); a crash
  after closure success leaves the HCR and the singleton position durably
  consistent. **Compaction preserves the post-condition (C3-n5):** a compaction
  pass deletes only rows with `sequence <= deleteFloor` where `deleteFloor <
  max(sequence)` (the newest row always survives — `deleteFloor` is an age/count
  floor below the head), so `max(HistoryChangeRecordRow.sequence)` is unchanged
  across a compaction pass and the equality with `LastChangePositionRow.rawValue`
  still holds. The single exception is the empty-bootstrap case (§9.1): if the
  journal is empty (the fresh-store, just-migrated, or post-rebase case, §9.1 —
  compaction cannot empty the journal because the §8 `deleteFloor` cap keeps the
  head row alive), `max(sequence)` is undefined and §9.1 treats it as equality
  with `lastSeenPosition = LastChangePositionRow.rawValue` (caught-up), not
  divergence. This is also what makes a compaction BUG that
  wrongly deletes the newest row detectable: §9.1's startup invariant check
  (`max(HCR.sequence) == LastChangePositionRow.rawValue`) catches the resulting
  drop and triggers a journal rebase (§9.2). A divergence detected at startup is
  a journal rebase (§9.2), never silently accepted. *(Extends D6's one-
  `ChangePosition`-per-commit guarantee to the journal: the journal records
  exactly that commit, atomically. Restates `V2-00` §5 decision 14's crash-
  consistency clause as an invariant.)*

- **D26 Reconnect completeness-or-reject (extends D6/D7).** A `changes(since:
  cursor)` replay yields a **provably complete** ordered stream of
  `HistoryChangeRecord`s whose `sequence ∈ (cursor.sequence, currentPosition]`,
  **or** the cursor is rejected with a typed `ReconnectFailure`
  (`.tokenExpired` / `.storeMismatch` / `.generationMismatch` /
  `.materializerMismatch`). The invariant is stated at the **protocol level**
  (m12): when the range exceeds `maxReconnectBatchSize`, the caller paginates via
  `nextCursor` until `isCaughtUp`, and the **union of batches** is the complete
  stream — contiguous-prefix chunking is not "partial replay." Rejection occurs
  **before any range fetch** (§6.2 reject gate) when (a) the cursor's `sequence`
  was compacted (`cursor.sequence < JournalConfigRow.compactionFloor`, the
  **persisted** floor — C1), (b) the cursor's `storeInstance` differs from
  `JournalConfigRow.storeInstance` (M2: cross-store guard against a cursor minted
  against store-A replayed against store-B), (c) the cursor's `generation`
  differs from `JournalConfigRow.generation` (schema migration, materializer
  bump, or rebase), or (d) the cursor's `materializerVersion` differs from the
  current materializer version, or (e) the cursor's `sequence` exceeds the
  current position (a cursor from a rolled-back future of the same store
  instance - §6.2 step 5b). The journal never serves a partial or incorrect
  replay: a compacted/cross-store/version-mismatched/future cursor is
  rejected, never silently truncated or replayed against the wrong store.
  *(The completeness analogue of D7's evidence-vs-identity discipline and
  `04` §6's `.snapshotExpired` browse-cursor reject, restated for a durable
  reconnect cursor; `04` §12 requires exactly this completeness-or-reject
  for a collection cache's journal.)*

- **D27 Collection-cache law (extends D6 / `04` §12).** The collection cache
  obeys the Part IV §12 law: for the same authoritative source state and
  request, cache hit, cache miss, eviction, disabled cache (`cacheEnabled ==
  false`), and process restart produce semantically identical values and
  failures; only latency and resource use may differ. The cache key contains
  (normalized query shape, `ChangePosition`, `materializerVersion`,
  `corpusEpoch`) - the `04` §12-mandated elements
  (the collection analogues of "History Item ID, the relevant authoritative
  version, complete normalized parameters, and a structural materializer
  schema version") plus the non-commit corpus-write discriminator (§7.2).
  **Correctness rests on the §7.1 three-way fence - position
  (`P_build == P_current`) + materializer version + corpus epoch
  (`E_build == E_current`) - and the shipped position-fence invalidation
  floor, not on HCR content** (m10): the shipped floor invalidates every
  entry whose position is behind the current position (complete for History
  Commits), and the fence's epoch arm rejects every entry built before a
  non-commit corpus write (V2-01 `persistEnrichment`/`setEnrichmentEnabled`
  advance no `ChangePosition`, §14); together they are a "proved
  completeness mechanism" under `04` §12's escape clause. The HCR journal is
  the **stronger substrate** that makes the optional
  finer, hit-preserving floor (`J1-PERF-3`) provably complete and that provides
  reconnect; `04` §12's "transient stream is insufficient" applies to delta-
  application completeness (the finer floor), which the shipped floor avoids by
  invalidating unconditionally. A stale or evicted entry degrades to a miss
  (refetch), never to wrong bytes. *(Restates `04` §12 and `V2-00` §5 decision 15
  for the G2 collection cache.)*

- **D28 Journal single-writer and non-replacement of live observation (extends
  `00` §3.3 / `04` §4–§5).** Durable journal state (`HistoryChangeRecordRow`,
  `JournalConfigRow`) is written only through `HistoryAuthority` — inside the
  commit transaction for HCR appends (§5.1), and in separate Authority
  transactions for compaction (§8), rebase (§9.2), AND UX/materializer-version
  config writes (`setJournalConfig` / `bumpMaterializerVersion`, §10.3; C3-m3);
  no component outside the Authority — in particular `ChangeJournal` and
  `CollectionCache`, which only read/enqueue — creates a writable
  `ModelContext` for the journal tables. The
  journal and the collection cache do **not** replace v1's transient
  `HistoryInvalidation` for live observation: v1 live observation remains
  snapshot-replacement (`04` §5), and the observer's wake predicate
  ("invalidation position > yielded page") is unchanged. The journal adds
  durable reconnect (cross-restart resume) and is the completeness mechanism for
  the collection cache; it does not enter the live-observation path. *(Extends
  `00` §3.3 single-writer to the V2 journal tables — the V2-03 analogue of
  V2-01's D22 — and restates `V2-00` §5 decision 14's non-replacement clause.)*

These extend D1–D19; none weakens any. The v1 self-review gate (`06` §10) and
the V2 self-review gate (`V2-00` §8) both apply: a mechanical scan confirms no
v1 public type / schema column / codec / invariant / `HistoryFailure` case is
redefined, and that every V2-03 type introduced — `ReconnectHistory`,
`ReconnectCursor`, `ReconnectBatch`, `HistoryChangeRecord`, `JournalEntryKind`,
`ReconnectFailure`, `HistoryChangeRecordRow`, `JournalConfigRow`,
`AffectedItemsBlobV1`, `HistoryChangeRecordPayload`, `ChangeJournal`,
`CollectionCache`, `CollectionCacheKey`, `CollectionCacheEntry`, `SortAnchor`,
`NormalizedQueryShape`, `NormalizedBrowseRequest` (the caller-facing normalized
request from which `NormalizedQueryShape` is derived; the two are 1:1, §7.1/n3),
`JournalLimits`, and the `StampedCommitPlan.hcrAppend` field — does not collide
with v1 names. The deleted-vocabulary scan (`06` §10,
which mechanically scans `docs/` including `docs/v2/`, per `V2-01` §11) includes
"ChangeKind-driven bump", "ChangeFeed", "ChangeCursor", "StructuralChangeRecord",
"VersionMap": the V2-03 tokens `JournalEntryKind`, `HistoryChangeRecord`,
`ChangeJournal`, `ReconnectCursor` are **distinct** from these deleted tokens
(different stems / different concepts: a journal entry-kind discriminator vs a
bump-mechanism; a durable record vs a structural-change record; a reconnect
cursor vs a deleted change cursor). `JournalEntryKind` was chosen over
`HistoryChangeKind` pre-emptively (n5) so it shares no stem with the deleted
"ChangeKind-driven bump" phrase and needs no `V2-00` §8 carve-out; V2-03's self-
review consolidation is therefore **unconditional** (not dependent on a V2-00
amendment, unlike V2-02's R1/R2/R3 carve-out class). `ReconnectCursor`
deliberately avoids the deleted `ChangeCursor` token.

## 17. V2 fixtures (parallel to v1 WS)

V2-03 adds fixtures parallel to the v1 walking skeleton (`06` §8), proving the
new contract:

- **V2-WS-J1-1 (HCR append atomicity + clear-scope derivation, C2-M1).**
  Insert/coalesce/revise/remove/clearAll/clearUnpinned/pin each produce exactly
  one HCR row with `sequence == ChangePosition` and the correct `changeKind` +
  `affectedItemIDs`; a no-op (`.unchanged`) produces no row. After each,
  `max(HCR.sequence) == LastChangePositionRow.rawValue` (D25). **Clear-scope
  assertion (C2-M1):** `.clear(.all)` produces a row with `changeKind ==
  .clearAll` and `.clear(.unpinned)` produces `changeKind == .clearUnpinned` —
  proving the originating action's `ClearScope` threads through stamping into the
  kind even though `RetirementReason.clear` / `PlannedOutcome.cleared(count:)` are
  scope-less (§5.2 clear-scope input).
- **V2-WS-J1-1a (policySet with no victim, M4 + C2-M8 symmetry).** A V2-02
  `.setRetentionPolicies` that changes the policy value but retires no items and
  prunes no revisions produces a valid `.policySet` HCR row with **empty**
  `affectedItemIDs` (self-describing kind); the decoder accepts it (not
  corruption). A victim-bearing policy change — whether v1
  `.setRetentionPolicy` or V2-02 `.setRetentionPolicies` with R1/R2 — produces
  `.retire` with the victim IDs (C2-M8: the two paths are symmetric; `.policySet`
  is reserved for the no-victim value-only change).
- **V2-WS-J1-1b (encode-side cap truncation).** A plan whose affected-ID
  union exceeds `JournalLimits.maxAffectedItemsPerRecord` (capture at the
  5,000-item hard cap under a count-1 policy: union 5,001) encodes exactly
  the cap's smallest `HistoryItemID`s (raw bytes ascending), decodes under
  the §4.4 count-<=-cap check, and is byte-identical across two runs
  (deterministic truncation; best-effort per §4.3, never a completeness
  claim).
- **V2-WS-J1-2 (reconnect completeness).** Persist a `ReconnectCursor`, perform
  N commits, call `changes(since: cursor)`; assert the complete ordered stream
  of N records is returned, `nextCursor.sequence == currentPosition`, and
  `isCaughtUp == true` (D26). When N exceeds `maxReconnectBatchSize`, assert the
  caller paginates via `nextCursor` until `isCaughtUp` and the union of batches
  is the complete stream (D26 protocol-level completeness, m12).
- **V2-WS-J1-3 (cursor expiry, C1 mid-range compaction).** Compact the journal
  past a **mid-range** cursor (cursor at sequence S, compaction raises
  `JournalConfigRow.compactionFloor` to F > S); call `changes(since: cursor)`;
  assert `ReconnectFailure.tokenExpired` is returned **before** any range fetch
  (no partial post-floor tail replay — C1). Assert a cursor at exactly F is still
  valid (requests only `sequence > F`, all survived). Bump `generation`
  (simulated rebase); assert `.generationMismatch`. Bump `materializerVersion`;
  assert `.materializerMismatch`. Present a cursor whose `storeInstance` differs
  (simulated store recreate); assert `.storeMismatch` (M2). Present a cursor
  whose `sequence` exceeds the current position (simulated
  same-store backup restore: position and HCR rolled back while
  `storeInstance` persisted); assert `.tokenExpired` - never a loop over
  reused sequences (§6.2 step 5b). No partial replay in
  any case (`J1-PLATFORM-4`).
- **V2-WS-J1-4 (collection cache law + page non-collision, M8).** With
  `cacheEnabled == true` (explicitly enabled for the fixture; the bootstrap
default is off — DC-10), perform the same browse under hit/miss/eviction/
  disabled/restart; assert byte-identical `HistoryPage` values and failures
  (only latency differs) (`J1-PERF-2`, D27). **Page non-collision (M8):** assert
  a page-1 result is served from the cache on a repeated page-1 query, and a
  page-2 (continuation) query **bypasses** the cache (always scans), so a page-2
  read never hits a page-1 entry (first-page-only scope). **Fence (M1):**
  inject a commit between the cache `lookup` and the fence read; assert the
  cached page is treated as a miss (position advanced -> scan runs). **Epoch
  fence (§7.2 corpusEpoch):** in the same lookup->fence window, inject a V2-01
  `persistEnrichment`/`setEnrichmentEnabled` that bumps `corpusEpoch` without
  advancing `ChangePosition`; assert the entry misses (`E_build != E_current`)
  even though `P_build == P_current`. **Insert window (§7.1 step 4):** bump the
  epoch between interval exit and `cache.insert`; assert the next lookup
  misses - the entry is keyed at the in-interval `E_current`, now behind.
- **V2-WS-J1-5 (crash consistency, extends WS13).** Simulate a mid-closure
  failure at **both** injection points inside the transaction: (a) after item
  mutation but **before** HCR append, and (b) **after** HCR append but before the
  singleton write. Assert, for both, no HCR row, no item mutation, no position
  advance (closure failure commits nothing, D25; the WS13 injection window now
  contains the HCR append, m6). Simulate a crash after closure success; assert
  the HCR and singleton position are durably consistent on restart.
- **V2-WS-J1-6 (rebase).** Force an HCR/position divergence; assert `open`
  rebases (deletes HCR rows, bumps `generation`, resets `compactionFloor == 0`,
  leaves `storeInstance` unchanged, leaves durable history intact, writes
  enabled); a pre-rebase cursor returns `.generationMismatch` (§9.2,
  `J1-PLATFORM-2`).
- **V2-WS-J1-7 (V2-02 integration).** A V2-02 retention retire (R1/R2) and an
  R3 prune produce HCR rows with `changeKind == .retire` /
  `.retireRevision` respectively and the correct affected IDs (§14; mirrors
  V2-02 §12b). A V2-02 commit doing **both** R1/R2 retire **and** R3 prune
  produces a `.retire` primary whose `affectedItemIDs` is the union of retired-
  item IDs and prune-owning-item IDs, by the **membership-outranks-revision
  tie-break** of §5.2 rule (b) (a membership-affecting `.delete(.retention)`
  outranks a revision-only `.pruneRevisions`; C3-n2). **Revise+R2 mapping
  (§5.2 rule (a) row):** a V2-02 revise composed with R2 retire
  (`.appendRevision` + `.delete(.retention)`, with or without
  `.pruneRevisions`) produces `.revise` - the `.revised` reference
  designates the primary; retired-item and prune-owning IDs fold into
  `affectedItemIDs`, like the capture-then-retire fold.

## 18. Platform reference anchors

Implementation must verify against the macOS 26 SDK rather than copy pseudocode
(`05` §18, `00` §5):

- [ModelContext.transaction(block:)](https://developer.apple.com/documentation/swiftdata/modelcontext/transaction(block:)) — the atomic save boundary; "Runs the provided closure, and once it finishes, writes any pending inserts, changes, and deletes to the persistent storage" (macOS 14.0+; `V2-facts.md` cycle 7 §7.1, fact 5). The HCR row and the item mutations share this boundary (D25).
- [ModelContext](https://developer.apple.com/documentation/swiftdata/modelcontext) — fetch/insert/delete lifecycle; `fetch(_:)`, `fetchCount(_:)`, `delete(model:where:)` (the compaction primitive, `V2-facts.md` cycle 4).
- [FetchDescriptor](https://developer.apple.com/documentation/swiftdata/fetchdescriptor) — predicate + sort + fetchLimit; `#Predicate { $0.sequence > cursor.sequence }` range queries (macOS 14.0+; `V2-facts.md` cycle 7 §7.1, fact 7; `V2-facts.md` cycle 4).
- [HistoryDescriptor](https://developer.apple.com/documentation/swiftdata/historydescriptor) / [HistoryTransaction](https://developer.apple.com/documentation/swiftdata/historytransaction) / [HistoryToken](https://developer.apple.com/documentation/swiftdata/historytoken) — SwiftData native History (macOS 15.0+). VERIFIED to exist and meet the brief's minimum criteria (a)-(d), but **rejected** as the V2-03 journal substrate (§3): open heterogeneous multi-process-aware row-diff stream; undocumented token-expiry failure semantics. Recorded as a candidate for future post-V2 multi-process grafts (`V2-facts.md` cycle 7 §7.1, facts 1-4, OPEN 1).
- [Fetching and filtering time-based model changes](https://developer.apple.com/documentation/swiftdata/fetching-and-filtering-time-based-model-changes) — the SwiftData History article; confirms chronological transactions, atomicity at the save boundary, the `Comparable & Codable` token, and the open/heterogeneous/multi-process nature of the stream.
- [MigrationStage.lightweight(fromVersion:toVersion:)](https://developer.apple.com/documentation/swiftdata/migrationstage/lightweight(fromversion:toversion:)) / [VersionedSchema](https://developer.apple.com/documentation/swiftdata/versionedschema) — additive schema migration (macOS 14.0+; `V2-facts.md` cycles 1-3). V2-03 reuses V2-01's `HistorySchemaV1: VersionedSchema` retrofit.
- [AsyncThrowingStream.Continuation.yield(_:)](https://developer.apple.com/documentation/swift/asyncthrowingstream/continuation/yield(_:)) / [AsyncStream.Continuation.yield(_:)](https://developer.apple.com/documentation/swift/asyncstream/continuation/yield(_:)) — non-blocking yield (macOS 13.0+/iOS 13.0+; `V2-facts.md` cycles 1-2); the primitive for the collection-cache inbox wake (`V2-facts.md` cycle 7 §7.1, fact 8). Adds no `await` to the Authority post-commit phase.
- [SchemaMigrationPlan](https://developer.apple.com/documentation/swiftdata/schemamigrationplan) / [ModelContainer](https://developer.apple.com/documentation/swiftdata/modelcontainer) — ordered migration plan + automatic-migration behavioral prose (`V2-facts.md` cycle 2; incremental shipping, Record 5).

All facts above are recorded with verdicts in `docs/v2/V2-facts.md`: the
V2-03-specific facts (facts 1-9, OPEN 1-5) as cycle 7 §7.1 — promoted verbatim
2026-08-15 from the former `.tmp/v2-research/V2-03-facts.md` sidecar, closing
DC-01 — and the cross-cycle transaction-atomicity, FetchDescriptor-predicate,
non-blocking-yield, and migration primitives in cycles 1-4. This cycle verified
the SwiftData History
surface (`HistoryDescriptor`/`HistoryTransaction`/`HistoryToken`/article) and
re-cited the transaction-atomicity, FetchDescriptor-predicate, and non-blocking-
yield primitives. Where a behavior could not be MCP-fetched (SwiftData History
token-expiry failure semantics, HCR/position post-crash consistency on the
macOS 26 runtime, journal-rebase behavior), it is marked OPEN there and assigned
a V2 proof gate in §15 — V2-03 makes no concrete platform claim without either a
citation or a proof gate, exactly as v1 (`00` §5).
