# V2-02 - Retention Expansion (R1 age + R2 byte + R3 revision retention)

> **Status (2026-07-23):** design-consolidated; scaffold proof pending. This doc
> extends the v1 specification (`00`–`06`) by **addition only**. v1 owns v1
> retention behavior; V2-02 owns the three new user-facing retention dimensions
> and their graft onto the v1 planner/facts/commit seam. It redefines no v1
> public type, `HistoryAction` case, `HistoryMutation` case, `PlannedOutcome`
> case, `CapacityKind` case, schema column, codec, or proof gate; no D1–D19
> invariant is weakened or redefined — D4 and D19 alone are explicitly
> *extended* (D4's append-only list property is extended by D23's pruning
> of inactive revisions; D19 is narrowed to the count dimension by D24,
> Record 2; sanctioned `V2-00` §8(e)/(g)). New V2 cases are added to
> closed v1 enums only as the sanctioned
> "owned exhaustive-switch change" (`V2-00` §6.5; `03a` §1). Like v1 and V2-01 at
> consolidation time, V2-02 is "design-consolidated, scaffold proof pending."

## 1. Role and boundary

V2-02 answers one question:

> *How are age-based item retention (R1), total-storage-byte item retention
> (R2), and automatic revision retention (R3) grafted onto the v1 retention
> planner and commit seam without weakening D2, D6, D13, D14, D19, or the
> one-`ChangePosition`-per-commit rule?*

v1 retention is one user dimension — maximum unpinned History Item count —
enforced in the primary History Commit by the pure `planCapture` /
`planRetention` planners over a `CompleteRetentionInventory` of
`RetainedItemSummary { id, lastCopiedAt, pinOrdinal }` (`02` §5.5, §12). `02` §12
states explicitly: *"Age, total-byte, and automatic revision-retention policies
are outside v1."* V2-02 lifts that exclusion for three product-deferred
capabilities (`06` §4; `V2-00` §3 R1/R2/R3).

V2-02 is **not a second retention system**. It extends the *same* planner /
fact / commit / stamping seam v1 uses:

- **R1 (age)** and **R2 (total storage bytes)** add **new victim-selection
  dimensions** to item retention. They reuse the v1 `HistoryMutation.retire(
  itemID:, .retention)` case and `RetirementReason.retention` (`02` §7) — no new
  item-retirement mutation is introduced. R1 needs no new fact data (it reads
  the v1 `lastCopiedAt` already in the retention inventory); R2 adds a per-item
  byte summary.
- **R3 (automatic revision retention)** adds a **new mutation kind** —
  pruning inactive revisions — because v1 revisions are append-only (`02` §2.5
  rules 5 and 8, D4) and v1 has no mutation that removes a revision. R3 is the only
  dimension that touches revision lineage.
- The count dimension (`maximumUnpinnedItems`) is **untouched**: it remains set
  by the v1 `HistoryAction.setRetentionPolicy(maximumUnpinnedItems:)` case,
  stored on the v1 `LastChangePositionRow` singleton, and enforced by the v1
  `planCapture` / `planRetention`. V2-02 never redefines it.

Every V2-02 retention retirement and revision prune is a **History Commit**:
it advances `ChangePosition` exactly once (D6), runs in the same `ModelContext.
transaction` as any primary mutation (`02` §12 one-History-Commit rule; D14's
projected-state inclusion is preserved, §4), and yields the standard
`HistoryInvalidation` (v1 observation is unchanged). V2-02 introduces **no new
actor** and **no cache**; it is planner/facts/commit-surface only.

## 2. Capability scope

### 2.1 In scope (R1 / R2 / R3)

- **R1 — age-based item retention.** A user maximum age: items whose
  `lastCopiedAt` is older than `(commit reference time − maxAge)` are retired,
  oldest-first, in the same History Commit that admits them. Pinned items are
  exempt (D13); the primary inserted/coalesced/revised item is never a victim
  (D14).
- **R2 — total-storage-byte item retention.** A user maximum total retained
  byte budget: when the projected retained set exceeds `maxTotalBytes`, oldest
  eligible unpinned items are retired until the budget is restored (or the
  action fails with a typed capacity failure, mirroring v1's count capacity
  failure, §8). Per-item bytes are a **content-byte measure** - Canonical
  representation bytes plus revision content bytes (§3.2) - that deterministically
  approximates the durable footprint. `title`/`searchBody` projections,
  fingerprints, type-identifier strings, Codable framing, `formatVersion`/
  `activeRevisionID` overhead, and `.externalStorage` block overhead are excluded
  by design (so on-disk usage exceeds the budgeted figure); R2 budgets content
  bytes, not raw SQLite/SwiftData page usage.
- **R3 — automatic revision retention.** Per-item user thresholds
  (`maxRevisionsPerItem`, `maxRevisionBytesPerItem`) at or below (≤) the v1 hard
  safety bounds (`06` §2: 100 revisions / 256 MiB; a threshold equal to the hard
  bound is permitted by §8.3 but makes R3 a no-op for that dimension, since the
  hard bound already enforces it). When a revision append or a policy
  change pushes an item past a threshold, the **oldest inactive revisions** are
  pruned in the same History Commit. The active revision is never pruned (D3
  preserved); Canonical Content and ContentVersion are never changed by pruning
  (D2, D5 preserved).

### 2.2 Out of scope (remains post-V2)

- **Cross-item revision consolidation** (merging revision histories of distinct
  items). R3 prunes *within* one item's lineage only.
- **Revision retention that prunes the active revision** or reorders the
  revision list. R3 removes only inactive revisions, oldest-first; the active
  revision and append order of survivors are unchanged.
- **Soft / best-effort retention** that leaves the store over budget. R1/R2/R3
  are all atomic: a commit either restores the bound (or threshold) or fails
  with a typed capacity / policy failure (§8), exactly as v1 count retention.
  R3 specifically is restore-or-fail, never best-effort-over-threshold: if the
  prune relation is unsatisfiable on revise (the post-append active revision
  alone exceeds `maxRevisionBytesPerItem`, §8.3), the revise fails with a typed
  capacity failure rather than leaving the item over threshold.
- **A second writer, a background reaper, or a wall-clock retention sweep.**
  All V2-02 retention runs synchronously inside a History Commit through
  `HistoryAuthority` (decision §16; `00` §3.3). There is no async retention
  worker (contrast V2-01's `EnrichmentWorker`, which is a derivation, not a
  writer). **DEC-RET-AGE (resolved): age retention is event-triggered.** An
  eligible row can remain past its age threshold until an R1 trigger named in
  §7 (`.capture` or `.setRetentionPolicies`) runs; that trigger evaluates the
  complete admitted state in the same commit. The rejected alternative,
  wall-clock expiry, would require a new writer/scheduler plus explicit
  startup, sleep/wake, clock-change, and failure semantics. V2-02 does not
  imply "delete at the instant the wall clock crosses the threshold," and
  Settings must not describe it that way.
- **Changing the v1 hard safety bounds** (`06` §2). R3 thresholds are bounded
  *by* the hard bounds; they do not replace them. A revision append still
  fails `.capacityExceeded(.revisionCount)` / `.revisionBytes` if it would
  exceed the hard bound on the post-prune post-append state (§5.4).
- **CloudKit / multi-device retention sync.** Local retention only
  (`V2-00` §3.1).

### 2.3 Evidence triggers (admit design work)

Per `V2-00` §3, R1/R2/R3 admit design work on an **approved product
requirement** (`06` §4 lists "Age-based or storage-byte user retention" and
"Automatic revision retention" as product-deferred). No performance evidence
trigger is required to *design* V2-02 (unlike J1/C1/G-grafts), because V2-02
introduces no cache and no new durable derivation whose cost must be bounded
before admission; its performance gates (Record 3) bound the expansion pass
on its capture and policy-sweep paths; the revise-path expansion (§4.3)
reuses the same O(retained) scalar sweep and is measured in RET-PERF-1.

## 3. Retention expansion data model

All V2-02 Domain declarations are `package` in `HistoryDomain`, mirroring v1's
`RetentionPolicy` / `RetentionFacts` placement (`02` §5.5). They import only
Foundation and `HistoryCore` (`02` §1); they are pure values and functions with
no actor, clock, UUID/Date generation, or async.

### 3.1 Public policy value (HistoryCore)

A new public value in `HistoryCore` (Foundation-only; a "capability-gated
extension of an existing module," `V2-00` §2.1). It carries the three V2
dimensions; each is optional (`nil` = disabled):

```swift
public struct HistoryRetentionPolicies: Sendable, Hashable {
    public let age: AgeRetention?          // R1; nil = no age policy
    public let storage: StorageRetention?   // R2; nil = no byte policy
    public let revisions: RevisionRetention? // R3; nil = no revision policy

    public init(
        age: AgeRetention?,
        storage: StorageRetention?,
        revisions: RevisionRetention?
    ) {
        self.age = age
        self.storage = storage
        // Construction-time normalization (§3.1 prose): a `RevisionRetention`
        // with both thresholds nil is R3-disabled, so it is collapsed to nil
        // before storage - the public value never carries an "enabled but
        // no-op" R3 state at construction.
        self.revisions = (revisions?.maxRevisionsPerItem == nil
            && revisions?.maxRevisionBytesPerItem == nil) ? nil : revisions
    }
}

public struct AgeRetention: Sendable, Hashable {
    public let maxAge: TimeInterval        // seconds; retire items older than (now - maxAge)
    public init(maxAge: TimeInterval) { self.maxAge = maxAge }
}

public struct StorageRetention: Sendable, Hashable {
    public let maxTotalBytes: Int          // retire oldest until retained bytes <= maxTotalBytes
    public init(maxTotalBytes: Int) { self.maxTotalBytes = maxTotalBytes }
}

public struct RevisionRetention: Sendable, Hashable {
    public let maxRevisionsPerItem: Int?   // prune oldest inactive beyond N (nil = no count limit)
    public let maxRevisionBytesPerItem: Int? // prune oldest inactive until under M (nil = no byte limit)
    public init(maxRevisionsPerItem: Int?, maxRevisionBytesPerItem: Int?) {
        self.maxRevisionsPerItem = maxRevisionsPerItem
        self.maxRevisionBytesPerItem = maxRevisionBytesPerItem
    }
}
```

`HistoryRetentionPolicies` is distinct from v1's package `RetentionPolicy`
(`02` §5.5, which carries only `maximumUnpinnedItems`); it adds no name that
collides with v1 vocabulary (`V2-00` §9). The count dimension is intentionally
**absent** — it stays on v1 `RetentionPolicy` / `.setRetentionPolicy`, so a v1
caller that ignores V2-02 surface behaves exactly as on v1 (`V2-00` §2.1).

A `RevisionRetention` with **both** thresholds `nil` is normalized to
`revisions == nil` (R3 disabled for that dimension) **at
`HistoryRetentionPolicies.init` construction** - the initializer collapses a
both-nil `RevisionRetention` to `nil` before storing it, so the public value
never carries an "enabled but no-op" R3 state at construction (not merely at
the `.setRetentionPolicies` boundary). An enabled R3 dimension therefore always
carries at least one non-nil threshold by construction; the
`revisionPolicyEnabled` field on `RetentionExpansionConfigRow` (§3.3) is the
persisted equivalent of `revisions != nil`, written only after this
construction-time normalization.

### 3.2 Domain policy mirror and expansion facts

The Domain planners take the public `HistoryRetentionPolicies` directly (v1
planners likewise take public types such as `HistoryItemID`, `PinnedPlacement`,
`02` §8). The expansion facts extend v1's `CompleteRetentionInventory`
(`02` §5.5) with the byte and revision summaries R2/R3 require:

```swift
package struct RetentionExpansionItemSummary: Sendable, Hashable {
    package let id: HistoryItemID
    package let lastCopiedAt: Date          // R1 reads this (already in v1 RetainedItemSummary)
    package let pinOrdinal: PinOrdinal?
    package let canonicalBytes: Int          // R2: Canonical content bytes (sum of StoredSignatureEntryV1.byteCount over SignatureBlobV1.entries, 05 §4); sourced from the RetainedBytesRow scalar projection (§3.3) on the planning path, not decoded per-plan
    package let revisionCount: Int           // R3: count of stored revisions; sourced from RetainedBytesRow
    package let revisionBytes: Int           // R3: revision content bytes (sum of stored-revision representation bytes); sourced from RetainedBytesRow; commensurate with the v1 256 MiB hard-bound measure (§5.4)
}

package struct CompleteRetentionExpansionInventory: Sendable {
    package let items: [RetentionExpansionItemSummary]
}

package struct RetentionExpansionFacts: Sendable {
    package let inventory: CompleteRetentionExpansionInventory
    package let currentPolicies: HistoryRetentionPolicies   // persisted V2 policies
}
```

Construction guarantees (mirroring v1 `IngestFacts` / `RetentionFacts`,
`02` §5.1, §5.5):

- `inventory.items` contains every retained item exactly once, projected to the
  post-primary state the enclosing commit will leave (D14: latest-state
  retention). For capture this is post-insert/post-coalesce and post-count-
  retirement; for `.setRetentionPolicies` it is the current retained set. For
  existing items the byte/revision scalars are read from `RetainedBytesRow`
  (§3.3b); the planning path never blocks on a not-yet-stamped row. The
  primary item is sourced by lane, mirroring v1's insert/coalesce split
  (`02` §9.3/§9.5):
  - **Insert lane.** The primary is new, so its `RetainedBytesRow` does not
    yet exist; its bytes (`canonicalBytes` from the in-memory `SignatureBlobV1`
    being written; `revisionCount = 0` and `revisionBytes = 0` - a new item has
    no revisions, `02` §2.5 rule 3 / `05` §3.1: `activeRevisionID == nil` and an
    empty revision list, so there is no "initial revision") are taken in-memory
    from the capture blob being written, and the row is created at stamping
    (§6.3).
  - **Coalesce lane.** The winner is an *existing* item: coalesce preserves
    its ID, Canonical Content, `ContentVersion`, revision list, active
    revision, and pin ordinal unchanged (`02` §9.5 - the winner receives only
    one `.recordCopy`/`.updateOccurrence` stamping, `05` §9). Its
    `RetainedBytesRow` therefore already exists and is **unchanged** by the
    coalesce; the planning path reads its scalar exactly as for any other
    existing item. The incoming capture blob is *not* the winner's retained
    bytes (in the Canonical lane it may be a strict subset, `canonicalContains`
    being set-containment not equality, `02` §9.2; in the Lineage lane it is
    the hinted item's Effective Content, which differs from Canonical when an
    active revision exists), so it must not be substituted for the winner's
    `RetainedBytesRow` scalars - doing so would undercount the primary's
    retained bytes and could leave the store over budget (§2.2 atomicity).
- `canonicalBytes` equals the sum of `StoredSignatureEntryV1.byteCount` over
  `SignatureBlobV1.entries` (`05` §4: `SignatureBlobV1.entries:
  [StoredSignatureEntryV1]`, `StoredSignatureEntryV1.byteCount: Int`), taken
  from the inline
  signature blob (`canonicalSignatureBlob` is not `.externalStorage`, `05` §3.1).
  It is a **signature-envelope byte count**: obtaining it decodes the
  `SignatureBlobV1` structural envelope (to read `byteCount`), **not** Canonical
  Content (the pasteboard bytes themselves are never materialized for this
  count). On the planning path it is read from the `RetainedBytesRow` scalar
  projection (`canonicalBytes` column, §3.3), stamped in the same transaction
  as the signature blob and therefore already holding this value — the planner
  decodes no envelope per plan.
- `revisionCount` / `revisionBytes` are the stored revision summary for the
  item; `revisionBytes` is **revision content bytes** (the sum of stored-revision
  representation bytes), commensurate with `canonicalBytes` (both content bytes)
  and with the v1 per-item-revision-byte hard-bound measure (§5.4), so the
  per-item sum is a coherent content-byte footprint. They are read from the
  `RetainedBytesRow` scalar projection (`revisionCount`/`revisionBytes`
  columns, §3.3), stamped in the same transaction as the `revisionStateBlob` it
  summarizes — the planning path reads scalar columns and decodes no
  `revisionStateBlob` per plan. (The `RetainedBytesRow` projection is the
  committed resolution to `RET-PLATFORM-2`; its coherence law and migration are
  recorded in Records 4/5.) The facts are **complete** before planning (D8); an
  incomplete load fails `.temporarilyUnavailable(.factProof)` (`05` §16), never
  a partial plan.
- **Post-R3-prune projection (revise and setRetentionPolicies paths).** Whenever
  R3 prunes any item — the revised item on a revision append, or each
  threshold-exceeding item on `.setRetentionPolicies` — that item's
  `revisionBytes`/`revisionCount` in the R2 inventory are computed over the
  **post-prune** state: `loadedRevisions \ removedRevisionIDs` (and `+
  [appendedRevision]` on the revise path). The Authority composes R3 first —
  planning the prune set over each pruned item's loaded lineage — then projects
  the inventory's `revisionBytes`/`revisionCount` to that post-prune state, then
  runs R1+R2 over the **projected post-prune** inventory. This is **one
  Authority interval** (R3 planned over loaded lineages, then R2's byte total
  projected from the post-R3 inventory — both before the single transaction),
  not two independent storage fact-loads and not a planner-derived R2 input
  disguised as a storage read: the R2 inventory is a stated post-R3 projection
  of the loaded facts, composed in-commit. R2 therefore never credits
  soon-to-be-pruned revision bytes and never retires an item whose post-prune
  bytes satisfy the budget (`RET-PRUNE-2`, Record 3). The prune set is a planner
  output, not a durable-state read; the `RetainedBytesRow` columns for pruned
  items are restamped to the post-prune value in the same transaction as the
  `.pruneRevisions`/`.appendRevision` write (§6.3).
- Failure to establish any guarantee is a Storage fact-loading failure mapped to
  `HistoryFailure.temporarilyUnavailable(.factProof)` (`05` §16). The Domain
  planner is never invoked with a partial expansion fact. This `.factProof`
  mapping covers only the **fetch mechanism itself** failing (a transient
  SwiftData read that could not complete); a **missing `RetainedBytesRow` for an
  existing item** is not a fact-load failure but **corruption** - row existence
  is a migration invariant (`RET-PLATFORM-1b(a)`, Record 3; backfilled once and
  maintained 1:1 with `HistoryItemRow` thereafter, §3.3b/Record 5) - so it fails
  closed `.persistence(.invariantViolation)`, never `.temporarilyUnavailable`
  and never a zero-byte read. (The `.factProof`-vs-`.invariantViolation` split
  is stated identically in `RET-PLATFORM-1b(d)`.)

### 3.3 RetentionExpansionConfigRow (V2 schema, additive)

A new `@Model` singleton stores the persisted V2 policies. It is internal to
`HistoryStorage` and **does not modify any v1 model**: no column is added to
`HistoryItemRow` or `LastChangePositionRow` (the v1 count policy remains on
`LastChangePositionRow.maximumUnpinnedItems`, `05` §3.2). This mirrors V2-01's
`EnrichmentConfigRow` (`V2-01` §3.5) and the v1 `LastChangePositionRow` singleton
pattern (`05` §3.2):

```swift
@Model
internal final class RetentionExpansionConfigRow {
    @Attribute(.unique)
    var key: String                 // always "retention-expansion"

    // R1
    var agePolicyEnabled: Bool
    var ageMaxSeconds: Double       // TimeInterval

    // R2
    var storagePolicyEnabled: Bool
    var storageMaxBytes: Int        // Int64 on macOS; holds the 5,000 x 384
                                    // MiB worst case (≤128 MiB Canonical —
                                    // the `06` §2 capture-admission ceiling —
                                    // plus the 256 MiB revision bound, `06` §2)

    // R3
    var revisionPolicyEnabled: Bool
    var revisionMaxCount: Int?      // nil = no count limit
    var revisionMaxBytes: Int?     // nil = no byte limit

    var configSchemaVersion: UInt16 // 1 for V2-02
}
```

Apple documents only that `.unique` "Ensures the property's value is
unique across all models of the same type"; conflict behavior is
undocumented, so V2-02 relies on the single-writer Authority (no
concurrent inserts) rather than on defined conflict semantics.

The first shipped V2 schema is named by actual ship order (DC-03, decided
2026-08-15: **incremental shipping** — each release's schema contains only the
grafts admitted in that release, and immutable version numbers follow the
shipping order, `V2-roadmap` §3). Under the first-release admission (M1 +
V2-02 only), **`HistorySchemaV2` = the frozen v1 models plus
`RetentionExpansionConfigRow` (§3.3) and `RetainedBytesRow` (§3.3b)** — it
carries the V2-02 models only; every later admitted table-owning graft
receives the next immutable version (`HistorySchemaV3`, ...), never an edit of
an already-shipped schema. (V2-01's consolidated-era statement that
`HistorySchemaV2` includes `EnrichmentRow`/`EnrichmentConfigRow` is superseded
by this ship-order rule and is corrected in `V2-01` §3.2 when that graft is
admitted.)

**Stage topology (DC-02, closed 2026-08-15).** The `HistorySchemaV1 →
HistorySchemaV2` hop both adds the two models and backfills the
`RetainedBytesRow` projection, so the hop is **one `MigrationStage.custom(
fromVersion: HistorySchemaV1.self, toVersion: HistorySchemaV2.self,
willMigrate:, didMigrate:)` stage**: the schema ADD is expressed by the two
versioned schemas themselves (purely additive; no v1 row or column is
rewritten), and the projection backfill runs in the stage's `didMigrate`
closure — after the hop's schema change, with the new models writable —
completing inside `SwiftDataHistory.open` before it returns. The documented
rule this follows: a hop needing code beyond schema description takes a single
custom stage whose `willMigrate`/`didMigrate` closures bracket the hop's
schema change (`MigrationStage.custom`, macOS 14.0+, present on macOS 26;
`V2-facts.md` cycle-2 facts), while `MigrationStage.lightweight` is the tool
for purely-additive hops that need no data transform (WWDC2025/291 uses custom
stages for data hops and lightweight only for the additive-subclass hop).
Splitting one hop into a lightweight schema-add stage **plus** a custom
backfill stage over the same version pair is **not a documented pattern** — no
Apple documentation or session shows or sanctions two stages on one from/to
pair — and is rejected; the earlier two-stage wording of this paragraph and of
Record 5 is retracted. Custom-stage failure semantics are undocumented, so the
backfill is **idempotent by construction** (every row recomputed from the
blobs; never a resumed partial write), and `RET-PLATFORM-1b` proves
interruption/restart/retry behavior on the macOS runner rather than assuming
it. The `RetentionExpansionConfigRow` singleton is created at `open` (below),
not by the migration. `RetainedBytesRow` is 1:1 with `HistoryItemRow` and
shares its lifecycle (deleted by an explicit step in the V2-extended `.delete`
stamping, not by a `@Relationship` on `HistoryItemRow` - §3.3b), so a migrated
v1 store has no rows until the backfill; the backfill is what populates them.
A migrated v1 store has no `RetentionExpansionConfigRow`; `SwiftDataHistory.open`
creates it with all policies disabled (`agePolicyEnabled == false`, etc.), so a
migrated store starts v1-faithful (no V2 retention active) — mirroring
V2-01's disabled-by-default `EnrichmentConfigRow` (`V2-01` §3.5).

**`configSchemaVersion` contract (fail-closed).** The `configSchemaVersion`
field follows the same codec discipline as a `RevisionStateBlobV1`/
`SignatureBlobV1` `formatVersion` (`05` §4): `SwiftDataHistory.open` validates
`configSchemaVersion == 1` on the fetched singleton. A row with an unknown
`configSchemaVersion` (forward-incompatible), or an out-of-range / contradictory
field combination (e.g. `revisionPolicyEnabled == true` with both
`revisionMaxCount`/`revisionMaxBytes` nil), fails closed as
`.persistence(.corruptStoredValue)` / `.persistence(.invariantViolation)` rather
than being silently treated as disabled (`05` §4 exhaustive-decode discipline).
A future config-schema bump (e.g. a fourth retention dimension) is a reviewed
migration that bumps `configSchemaVersion` and adds a lightweight/custom
migration stage per Record 5; it is not a runtime-resumable value. An absent row
(the migrated-v1 case) is the only "create with defaults" path, not a version
mismatch.

**Incremental shipping (DC-03, decided 2026-08-15).** Shipping is
incremental: each release's schema contains only the grafts admitted in that
release, and immutable schema version numbers follow the actual shipping
order (`V2-roadmap` §3). The first release (M1 + V2-02) therefore ships the
single `V1 → V2` custom hop above — schema add plus projection backfill in one
`MigrationStage.custom` stage (Record 5; `RET-PLATFORM-1/1b`). A later release
admitting another table-owning graft (e.g. V2-01 enrichment once its triggers
land) ships the **next** migration (`HistorySchemaV2 → HistorySchemaV3`),
appended to the ordered `SchemaMigrationPlan` (`V2-facts.md` cycle-2
`SchemaMigrationPlan` fact) as its own single stage for that hop — a
lightweight stage if the hop is purely additive (enrichment adds no projection
backfill), a custom stage if it needs a data transform — never a modification
of the already-shipped `HistorySchemaV2`. The `HistorySchemaV1:
VersionedSchema` retrofit that every table-adding graft depends on is owned by
**M1** (`V2-roadmap` §3, the migration-foundation prerequisite), not by any
part graft, so no shipping order creates a cross-graft dependency. Record 5
records both shapes.

### 3.3b RetainedBytesRow (V2 byte projection, additive)

A second new `@Model` carries the **per-item byte projection** that R2/R3 planning reads as a scalar, so the planning path decodes no `revisionStateBlob` or `SignatureBlobV1` envelope per plan (`RET-PLATFORM-2`). It is internal to `HistoryStorage` and, like `RetentionExpansionConfigRow`, **does not modify any v1 model**: no column is added to `HistoryItemRow` (`05` §3.1 has no size column; the v1 schema is frozen). It is a **content-byte projection** of the same kind as v1's `title`/`searchBody` projections (`05` §15) - a durable derived value stamped in the same `ModelContext.transaction` as the blob it summarizes, never a cache (Record 4) and never a new blob codec (§3.4):

```swift
@Model
internal final class RetainedBytesRow {
    // One row per retained HistoryItemRow (same lifecycle). Deleted by an
    // explicit step in the V2-extended `.delete` stamping (05 §9), NOT by a
    // @Relationship on HistoryItemRow - no v1 model gains a relationship
    // (05 §3.1 HistoryItemRow has none; the v1 schema is frozen). Mirror of
    // V2-03 §4.1's no-@Relationship choice, for the opposite lifecycle goal
    // (V2-03 keeps its row; V2-02 deletes its row with the item).
    @Attribute(.unique)
    var itemID: UUID               // HistoryItemID.rawValue; 1:1 with
                                   // HistoryItemRow (v1 business IDs are
                                   // UUID-backed, `03a` §2 — DC-04 resolved
                                   // to UUID, matching V2-01 §3.3)

    var canonicalBytes: Int        // sum of StoredSignatureEntryV1.byteCount (05 §4)
    var revisionCount: Int         // count of stored revisions
    var revisionBytes: Int         // sum of stored-revision representation bytes
    var bytesSchemaVersion: UInt16 // 1 for V2-02 (projection-coherence fence)
}
```

Apple documents only that `.unique` "Ensures the property's value is
unique across all models of the same type"; conflict behavior is
undocumented, so V2-02 relies on the single-writer Authority (no
concurrent inserts) rather than on defined conflict semantics.

**Projection-coherence (governed by `05` §15, not a new D-invariant).** `RetainedBytesRow` is a v1-style projection: its three scalar fields are recomputed and stamped in the **same `ModelContext.transaction`** as the blob write that changes them - at capture-**insert** (new item: `canonicalBytes` stamped from the signature postings; `revisionCount == 0` and `revisionBytes == 0` — a v1 insert carries an **empty revision list** with `activeRevisionID == nil`, `02` §2 / `05` §3.1, so there is no first revision until the first revise; DC-04 wording fix 2026-08-15), at coalesce (no blob changes → the row is present but **unchanged**; coalesce mutates only occurrence fields, `02` §2), at revise (appended revision and/or R3 prune: `revisionCount`/`revisionBytes` updated to the post-prune post-append value), and at `.setRetentionPolicies` R3 prune (restamped to the post-prune value, §3.2/§6.3). It is therefore never silently stale relative to the durable blob: a transaction either commits both the blob and its projection or neither (`05` §10 atomicity). This restates the v1 projection discipline (`05` §15 - "Projection schema changes require an explicit schema version and migration/rebuild plan") for the byte projection; no new D20+ invariant is minted, because (a) the coherence law already exists in v1 (`05` §15) and (b) the V2 invariant registry (`V2-roadmap` §14) allocates D25–D28 to V2-03 and D29–D31 to V2-04, so V2-02 (D23–D24) cannot mint a new byte-projection D-number without colliding. The `bytesSchemaVersion` field is the projection-coherence fence (analogous to a blob `formatVersion`): a row whose `bytesSchemaVersion` is unknown, or whose scalars are inconsistent with the item's actual blob, fails closed as `.persistence(.corruptStoredValue)` / `.persistence(.invariantViolation)` (`05` §4/§16) - it is never silently used as a stale byte fact. The inconsistency cross-check is a **bounded single-item decode piggybacked only when an item's blob is already being decoded** - i.e. on (a) the migration backfill (`RET-PLATFORM-1b`, Record 5) and (b) the R3-sweep decode for items whose `RetainedBytesRow` scalar exceeds a threshold (`RET-PERF-2`: "only for items exceeding the threshold, typically few"). It is **never a separate decode on the per-commit R2 planning path**: that path reads the scalar columns and decodes no `revisionStateBlob`/`SignatureBlobV1` envelope (`RET-PLATFORM-2`), so an R2-only-active commit (no R3 sweep to piggyback on) triggers **zero** blob decodes - the cross-check does not run there and the zero-decode `RET-PLATFORM-2`/`RET-PERF-3` guarantees are preserved. Migration backfills the row once (Record 5).

**Why this differs from `RetentionExpansionConfigRow`'s `configSchemaVersion`.** `RetentionExpansionConfigRow` is a *singleton config* row whose field combinations must be validated as a unit (e.g. `revisionPolicyEnabled` with both thresholds nil); `configSchemaVersion` fences that unit. `RetainedBytesRow`'s `bytesSchemaVersion` fences each *per-item projection* against its own blob. v1's `LastChangePositionRow` singleton (`05` §3.2) carries no version field because it has no hand-rolled decode and no contradictory-field-combination surface; both V2-02 singletons/projections add a version field precisely because they introduce a fail-closed decode/combination discipline v1's singletons did not need.

### 3.4 No new codec

V2-02 introduces **no new blob codec**. R1/R2 item retirement reuses the v1
`.delete` stamping and **extends it** with a same-transaction `RetainedBytesRow`
deletion (§3.3b/Record 5): the v1 `.delete(itemID:, reason:)` removes the
`HistoryItemRow` and its signature postings (`05` §9), and the V2 extension
also removes the 1:1 `RetainedBytesRow` in the same `ModelContext.transaction`
(by an explicit stamping step, not a `@Relationship`). R3 revision pruning
rewrites the existing `revisionStateBlob` column
of `HistoryItemRow` with a **shorter `RevisionStateBlobV1`** (`formatVersion ==
1`, fewer revisions, same `activeRevisionID`) — the v1 `RevisionStateBlobV1`
codec (`05` §4) encodes and decodes it unchanged. A future revision-codec bump
would add `RevisionStateBlobV2` and a rebuild, exactly as v1 projection schema
changes rebuild (`05` §15); V2-02 does not do this.

## 4. Retention expansion pipeline (data flow)

V2-02 adds an **expansion pass** that composes with the v1 plan for three
actions. The pass is pure Domain planning; the composition (merging mutations
into one plan, one `ChangePosition`) is Storage-internal stamping, mirroring v1's
Domain-plans / Storage-stamps split (`05` §9).

### 4.1 Composition principle

> Any History Action that adds retained bytes or items is followed, when one or
> more V2-02 policies are active, by a retention-expansion pass over the
> **projected post-primary state**. The primary mutation and all
> expansion retirements/prunes are **one `MutationPlan`** with **one
> `ChangePosition`** (D6). If no V2-02 policy is active, the pass is a no-op and
> the action's public behavior and v1 rows are exactly v1's (DC-04: not
> byte-identical durable state — the `RetainedBytesRow` projection is
> mandatorily maintained 1:1 even while every policy is disabled, §3.3b).

The expansion pass never re-runs v1 victim selection; it consumes the v1 plan's
already-decided victims (for capture, the count-based retirees) as input so it
never double-retires or conflicts. Within the expansion pass, R1 and R2 victim
selection is a **single deduplicated union pass**: R1 victims are removed from
the projected byte total before R2 selects (so an aged item also likely among
the oldest-bytes is not double-counted); `retirements` contains no duplicate
`HistoryItemID`; the pure function's postcondition guarantees itemID-uniqueness.

### 4.2 Capture (insert / coalesce) — R1 + R2

```text
Authority.commitCapture:
  load v1 IngestFacts + RetentionFacts (count)            [05 §7.1]
  planCapture(capture, facts, retention: countPolicy, hardMax)  [02 §8]  -> v1Plan
  if neither R1 nor R2 active:  stamp+transact v1Plan exactly as v1  [05 §9]
    (R3 never fires on capture, §7: capture does not grow any item's
     revisions. So an R3-only config - R1==nil && storage==nil && revisions
     != nil - takes the v1 path with NO expansion-fact load and NO
     planItemRetentionExpansion call, preserving the RET-PERF-1/RET-PERF-3
     budget for the R1/R2-active case only.)
  else:
    load RetentionExpansionFacts over the projected post-primary inventory
      (post-insert/coalesce, post-count-retirement; excluding count-plan victims)
    planItemRetentionExpansion(inventory, policies, protected, now) -> expansion
    merge: final mutations = v1Plan.mutations + expansion.retirements
           outcome           = v1Plan.outcome (inserted/coalesced)
    stamp one ChangePosition; transact; index delta = v1 delta + retirements
```

- **R1** selects items with `lastCopiedAt < (now − age.maxAge)` and retires them
  oldest-first (v1 eviction order: `lastCopiedAt ascending, id ascending`,
  `02` §12). R1 reuses the `lastCopiedAt` already in the inventory — **no new
  fact data** beyond the v1 retention summary (R1 is the cheapest dimension).
- **R2** retires oldest eligible unpinned items until projected total retained,
  in the same v1 eviction order as R1 (`lastCopiedAt ascending, id ascending`,
  `02` §12) for determinism (D16; D9 governs dedup-winner ties, not retirement)
  bytes ≤ `storage.maxTotalBytes`. Per-item bytes come from the expansion
  inventory (§3.2). If `pinned bytes + primary bytes > maxTotalBytes`, capture
  fails `.capacityExceeded(.storageBytes)` (§8) — the R2 analog of v1's
  `.capacityExceeded(.retainedItems)` (`02` §12). The R2 byte-total summation
  (per-item `canonicalBytes + revisionBytes` over the projected inventory,
  compared to `maxTotalBytes`) is a new byte-count calculation and uses
  **checked arithmetic** per the global v1 rule `06` §2 ("No arithmetic
  counter or byte-count calculation may wrap"); overflow - impossible within
  the `Int64` / 5,000 × 384 MiB worst case but enforced defensively - fails
  closed as `.persistence(.invariantViolation)`, never wraps (mirroring the
  `02` §13 checked-arithmetic discipline for counters).
- `protected` = pinned items ∪ {primary} ∪ count-plan victims. The primary is
  never a victim (plan invariant 7, `02` §7; `02` §12); D14 supplies only the
  latest-state projection guarantee that victim selection sees the post-primary
  state. Pinned items are never retired (D13).
- **R1-then-R2 composition.** Within `planItemRetentionExpansion`, R1 selects
  aged victims **first** and adds them to an internal removed/protected set; R2
  then computes retained bytes over the **post-R1** inventory (R1 victims excluded
  from both the byte total and candidate selection), so R2 never over-retires by
  crediting soon-to-be-R1-retired bytes. `retirements` = R1 victims ∪ R2 victims
  (deduped, oldest-first), a deterministic function of (inventory, policies,
  protected, now) (D16). For `.setRetentionPolicies` (no primary, no
  count-victims) `protected` = pinned items only.
- `now` is the capture's `observedAt` (already a Domain input, `02` §4
  `PreparedCapture.observedAt`) — R1 needs no new clock for capture.
  **DEC-CAPTURE-CLOCK (resolved; DC-28, accepted 2026-08-15):** capture age
  selection uses that admitted finite observation fact, not a second
  Authority `StorageClock.now()` sample. This keeps the age comparison and
  the same capture's monotone occurrence/recency planning on one time fact.
  The rejected Authority-admitted-time alternative would make one capture's
  R1 decision and persisted occurrence use different clocks; the rejected
  finite-skew clamp has no product-defined tolerance and would silently
  rewrite an otherwise valid observation. `StorageClock` remains the owner
  of Storage-minted timestamps and of R1 time for the policy-sweep lane that
  has no capture observation (§6.4); it is not a substitute capture fact.
  `observedAt` is
  finiteness-checked at preparation (`03a` §4: NaN/±∞ is
  `.invalidInput(.invalidTimestamp)` before fingerprinting) but is **not**
  clamped for the R1 comparison — a finite, far-future-dated `observedAt`
  makes `now − maxAge` large and can retire every unpinned item in one
  commit. The exposure is accepted and recorded rather than clamped: it is
  symmetric to the user's clock simply being wrong, and v1's
  persisted-`lastCopiedAt` `max()` clamp (`PlannersCapture`, `02` §4) governs
  persisted recency, not R1's reference time. Recorded again in §8.3.

### 4.3 Revise (append revision) — R2 + R3

```text
Authority.commitRevision (V2 path):
  PHASE 1 - V2-extended revision preparation (05 §6.2):
    RevisionPreparationSnapshot(item, current version)            [05 §6.2]
    reject immediately if request.expected is already stale       [02 §11 step 1]
    RevisionPreparationActor resolves proposed Effective Content  [05 §6.2]
    if R3 active for this item's thresholds:
      speculativePruneSet = planRevisionRetentionExpansion(
        snapshot.revisions, target: .revise(appended: proposedRevision),
        policies)            (pure, D16; §5.1)
      if unsatisfiable (post-prune active alone exceeds maxRevisionBytesPerItem):
        fail .capacityExceeded(.revisionBytes)                   [§8.3 revise-path]
    validate hard limits on the POST-prune POST-append lineage    [02 §11 step 4]
      (100 revisions / 256 MiB, 06 §2) - R3 prunes first so the
      hard-bound check sees the post-prune post-append state (§5.4)
  PHASE 2 - commit:
    reload RevisionFacts; v1 planRevision(...) -> v1Plan (.appendRevision)  [02 §11]
    Domain rechecks expected version + prepared.basedOn (OCC)    [02 §11; 05 §6.2]
    recompute pruneSet over reloaded lineage (== speculativePruneSet by D16
      when only a coalescing/lineage-preserving commit interleaved, 02 §11)
    if R2 active:
      load RetentionExpansionFacts over projected post-revision inventory,
        with the revised item's revisionBytes/revisionCount projected to
        (reloaded \ pruneSet) + [appendedRevision] (§3.2 post-R3-prune projection)
      planItemRetentionExpansion(inventory, policies.replacingAge(with: nil),
        protected, now) -> expansion (R2-only, §4.2; R1 structurally skipped
        on revise: a revision does not change lastCopiedAt, §7)
    merge: final mutations = v1Plan.mutations + .pruneRevisions(item, pruneSet)
                         + expansion.retirements
         outcome = v1Plan.outcome (revised)
    stamp one ChangePosition; transact (compose-with-append stamping, §6.3)
```

The prune **mutation** is computed once, in the commit path (phase 2), over the
second-phase reloaded `RevisionFacts`. Preparation (phase 1) only *speculatively*
recomputes the same prune set (pure, D16) to validate the post-prune post-append
hard bound and reject early - it produces no mutation and performs no pruning
itself. The two agree whenever only a coalescing/lineage-preserving commit
interleaved between phases (the same condition under which v1's two-phase OCC
preserves a prepared proposal, `02` §11 / `05` §6.2). A content-changing
interleaving revision rejects the proposal at the second OCC check before any
prune mutation is built.

- **Phase-2 policy re-read.** Phase 2 re-reads the **current**
  `RetentionExpansionConfigRow` policies (not a phase-1-cached copy), so an
  interleaving `.setRetentionPolicies` that *changed* the R3 thresholds between
  phases is respected: the phase-2 prune set is computed against the
  post-interleave thresholds. An interleaving `.setRetentionPolicies` R3-prune
  on the *same item* is neither coalescing nor content-changing (it preserves
  `ContentVersion`, so the `02` §11 step-1 OCC check passes, but it *removes*
  inactive revisions, changing the list the prune set is computed over): in
  that case `speculativePruneSet` need not equal the committed set, but the
  committed set is still correct because it is recomputed over the reloaded
  (post-interleave-prune) lineage in phase 2, and the active revision survives
  (D3; `RET-CONCUR-1` third case, Record 3).

- **DEC-REVERT-RACE (resolved, accepted 2026-08-28):** a revert-to-revision
  proposal carries the bytes resolved from the **phase-1 snapshot**; phase 2
  rechecks only the `02` §11 OCC contract and never re-verifies the target
  revision's existence in the reloaded lineage. An interleaving
  `.setRetentionPolicies` R3 prune that removed the target preserves
  `ContentVersion` (D5), so the revert still commits and mints a NEW revision
  from the cached bytes — it never repoints or resurrects a revision ID
  (`02` §11; D1/D4, `02` §14). The rejected phase-2-existence alternative
  (fail `.revisionNotFound` at commit when the target is gone) would add a
  failure mode the ContentVersion-keyed OCC contract cannot express and would
  make a revert's outcome depend on retention interleavings that change no
  OCC-visible fact. Recorded exposure: a revert may re-append bytes R3 just
  removed, and a pruned target whose cached bytes equal current Effective
  Content lands as the `02` §11 step-5 `.unchanged` no-op — callers must not
  read a committed revert as proof the target still exists in lineage. Target
  absence remains a preparation-time check only (`05` §6.2,
  `.revisionNotFound`).

- **R3 on revise** prunes the item's oldest inactive revisions so the
  post-append revision count/bytes respect the user thresholds. It reuses the
  revision lineage already loaded in `RevisionFacts` (`02` §5.3; `05` §7.3
  "Revision fetches and decodes exactly the target item") — **no extra revision
  decode for the revised item** (R3 on revise is free of new I/O).
- **R2 on revise** handles the case where the appended revision grows total
  retained bytes past the budget; it retires oldest *other* eligible items
  (never the revised item — it is the primary, plan invariant 7, `02` §7; `02` §12; D14 supplies only the latest-state projection).
- The prune set and the append are applied together in stamping (§6.3) so the
  hard-bound check sees the post-prune post-append state (§5.4).
- **R3-unsatisfiable on revise.** If the appended (now-active) revision's bytes
  alone exceed `maxRevisionBytesPerItem`, R3 cannot prune it (D3), so the
  threshold is unsatisfiable at commit time (satisfiable when the policy was set;
  unsatisfiable after the large revision append). The revise fails atomically
  with `.capacityExceeded(.revisionBytes)` (the v1 hard-bound failure producer
  for revision bytes, `03b` §10), and commits nothing - no over-threshold state
  is left (§2.2 atomicity). The count dimension is always satisfiable on revise
  (pruning to the new active alone yields count = 1 ≤ `maxRevisions` for any
  `maxRevisions ≥ 1`); only the byte dimension can be unsatisfiable on revise.

### 4.4 setRetentionPolicies — full R1 + R2 + R3 sweep

```text
Authority.commitRetentionPolicies(newPolicies):
  load RetentionExpansionFacts over current retained set + currentPolicies
    (RetainedBytesRow scalars; no blob decode on the planning path)
  PHASE A - R3 first (compose R3-then-R2, mirroring the revise path §4.3/§3.2):
    if R3 active: for each item whose revisionCount/bytes exceed the NEW R3
      thresholds (detected from RetainedBytesRow scalars, no decode):
        load that item's revision lineage (bounded; only exceeding items)
        planRevisionRetentionExpansion(revisions, target: .setRetentionPolicies(activeRevisionID:),
          policies) -> pruneSet
    project the inventory's revisionBytes/revisionCount to the post-R3-prune
      state (subtract each exceeding item's pruned-revision bytes/count)
  PHASE B - R1 + R2 over the PROJECTED POST-PRUNE inventory:
    planItemRetentionExpansion(projectedPostPruneInventory, policies,
      protected = pinned items only, now) -> R1 + R2 retirements
      (R2 sees post-prune bytes; it never retires an item whose post-prune
       bytes satisfy the budget, RET-PRUNE-2)
  PHASE C - unsatisfiable-R3 veto (DC-27, decided 2026-08-15 option (a); runs
    AFTER PHASE-B selection):
    if any item that SURVIVES the PHASE-B retirements has a post-prune active
      revision alone exceeding maxRevisionBytesPerItem: fail
      .invalidInput(.invalidRetentionPolicy)  (atomicity, below)
  if no retirement and no prune and newPolicies == currentPolicies: return .unchanged
  merge: mutations = retirements + per-item .pruneRevisions
                  + .setRetentionPolicies(newPolicies)   (declared §5.6; stamps the
                    RetentionExpansionConfigRow singleton, §6.3; the stamping
                    composer drops .pruneRevisions for items R2 retires, since
                    retirement subsumes the prune, §6.3 retire-subsumes-prune)
         outcome   = .retentionPoliciesSet(retiredItems:, prunedRevisions:)
  stamp one ChangePosition; transact (writes RetentionExpansionConfigRow +
    RetainedBytesRow restamp for pruned items + item changes)
```

- **R3-then-R2 composition (correctness).** This path mirrors the revise path
  (§3.2/§4.3): R3 prune sets are computed FIRST over each exceeding item's
  loaded lineage, the inventory is projected to the post-prune state, and only
  THEN does R1+R2 victim selection run over the projected inventory. R2
  therefore never credits soon-to-be-pruned revision bytes and never retires an
  item whose post-R3-prune bytes already satisfy `maxTotalBytes` (`RET-PRUNE-2`,
  Record 3). Ordering R1+R2 before R3 (the prior draft) would credit an item
  the full un-pruned `revisionBytes` for a lineage R3 is about to shrink, and
  could retire an item whose post-prune bytes fit the budget - silent data
  loss beyond what the policy requires, violating D14/D24 (projected effect of
  the `.setRetentionPolicies` commit includes the R3 prunes). The composition is
  one Authority interval, not two independent storage loads (§3.2).

- This is the R1/R2/R3 analog of v1 `.setRetentionPolicy` (WS21, `06` §8):
  lowering a threshold retires/prunes in the same History Commit; setting the
  already-persisted value when state already satisfies it is `.unchanged` (no
  commit, no `ChangePosition` advance, no invalidation). The policy value itself
  is persisted by an **explicit** `HistoryMutation.setRetentionPolicies` mutation
  stamped to a `StampedMutation.setRetentionPolicies` (§5.3/§6.3), mirroring how
  v1 persists `maximumUnpinnedItems` via `.setRetentionPolicy` (`05` §9; `02`
  §13 stamping table) - never as an outcome-inferred side effect of
  `.retentionPoliciesSet` (D18, `02` §14).
- **Atomicity.** The whole `.setRetentionPolicies` action is all-or-nothing,
  mirroring v1 capacity-failure atomicity (`02` §12): if any item's post-prune
  active revision **alone** exceeds the new `maxRevisionBytesPerItem` (an
  unsatisfiable per-item R3 threshold, §8.3), the **entire** action fails
  `.invalidInput(.invalidRetentionPolicy)` - no policy is persisted and no
  retirement/prune is applied. **Veto scope (DC-27, decided 2026-08-15,
  option (a)):** the unsatisfiable-R3 veto runs **after** PHASE-B R1/R2
  selection (PHASE C above) and applies only to items that **survive** that
  retirement — an unpinned heavy item does not block a combined
  threshold-lowering that R2 satisfies by retiring it, because retirement
  deletes the item and its revisions in the same atomic commit
  (retire-subsumes-prune, §6.3), so its active revision no longer constrains
  the post-commit state. A user therefore cannot set
  `maxRevisionBytesPerItem` below the largest post-prune active-revision byte
  count **among items that survive the same commit's R1/R2 retirement**. (The
  pre-DC-27 whole-store veto — failing PHASE A on any exceeding item before
  R1/R2 selection — was over-broad: it rejected the action on items the same
  commit was about to delete.)
- `now` for R1 has no caller-supplied `observedAt` (`.setRetentionPolicies`
  carries none). The Authority supplies `now` from a Storage-side clock read
  with a test-injectable seam (§6.4); the Domain planner remains pure (receives
  `now: Date`, mints none, `02` §1).
- R3's full sweep decodes revision blobs **only for items exceeding the
  threshold** (bounded; typically few), not for all retained items. Exceedance
  is detected from the `RetainedBytesRow` scalar projection (§3.3b), so the
  scalar sweep over the inventory is O(retained) with no blob decode; only the
  exceeding items' lineages are decoded (Record 3, `RET-PERF-2`).

### 4.5 Why this preserves v1

- **Single write authority (`00` §3.3):** every retirement/prune is a
  `HistoryMutation` applied by `HistoryAuthority` in one `ModelContext.
  transaction`. No second writer; no external path.
- **One `ChangePosition` per plan (D6):** the merge produces one `MutationPlan`;
  the Authority stamps one checked successor of the singleton position and
  reuses it for every mutation (`02` §13). The v1 stamping contract (`05` §9) is
  extended, not replaced.
- **Latest-state retention (D14):** the expansion facts are loaded over the
  projected post-primary inventory, so victim selection sees the commit's
  effect, not a stale snapshot.
- **Pin-protected (D13) / retention floor (D19 - EXTENDED, not preserved):**
  pinned items and the primary are in `protected`; R1/R2 never retire them. D19
  is **reclassified as EXTENDED** in Record 2 (per `V2-00` §4 record 2 / §8(e): a
  D1–D19 invariant is either preserved-unchanged or explicitly extended with a
  stated new invariant). D19's literal universal claim - "only the global
  hard retained-item bound can force a capacity failure" - is **narrowed to
  the count dimension** by the new D24 (§11): the count policy alone never forces a
  capacity failure, and only the hard retained-item bound forces a *count*
  capacity failure (the count floor >=1 unpinned is unchanged). R2's
  `.storageBytes` capacity failure is a **new, orthogonal byte-budget failure
  producer** governed by D24 - it is NOT the hard retained-item bound, and is
  structurally unsatisfiable when pinned + primary bytes are irreducible (pinned
  items cannot be retired, D13; the primary cannot be retired, D14), so it
  hard-fails only when no eligible (unpinned, non-primary) victim can restore the
  bound - mirroring `06` §2's general capacity rule. D19's *count* guarantee
  is preserved unchanged; only its universal "only the hard bound" scope is
  narrowed (extended, not weakened). This narrowing is recorded as an explicit
  extension in Record 2, not an undebated "preservation."
  **Cross-doc reconciliation (R-M1, resolved).** `V2-00` §5 decision 17 has been
  amended to read "(D6, D13, D14) apply unchanged; D19's count-dimension guarantee
  applies unchanged, with D24 (V2-02) extending the capacity-failure surface to an
  orthogonal byte-budget dimension (`.storageBytes`)," and `V2-00` §8(g) rules
  that D19's narrowing-to-count is a sanctioned "explicit extension" (not a
  forbidden "weakening") - the count guarantee is preserved, the byte-budget
  failure is an orthogonal new producer. V2-02 reconciles its own §4.5/Record
  2/D24 wording to that EXTENDED classification. The ruling does not block
  V2-02's scaffold proof, which discharges D19-as-extended via
  `RET-PRUNE-1`/`RET-PRUNE-2` (Record 3).
- **Canonical immutability (D2) / precise tokens (D5):** R3 prunes only
  inactive revisions; it never touches Canonical Content and never mints or
  advances `ContentVersion` (the enclosing append does, exactly as v1). R1/R2
  retire items; retirement never mutates content.

## 5. R3 — revision pruning model

R3 is the delicate dimension because v1 revisions are append-only (D4) and the
active revision's bytes must always be present (D3). This section states the
prune relation, the hard-bound interaction, and the safety invariant (D23,
§11).

### 5.1 Prune relation

Given an item's ordered revision list `R = [r0, r1, …, r_{n−1}]` (append order,
`02` §2.5 rule 1) with active revision `ra = R[k]`, and an R3 policy
`(maxRevisions, maxRevisionBytes)`:

- A revision is **prunable** iff it is **inactive** (`r.id != ra.id`) — the
  active revision is never prunable. The thresholds `maxRevisions`
  and `maxRevisionBytes` bound the **full retained revision set, active
  included** (the active revision is always within the budget); `count(R)` and
  `bytes(R)` count the active revision, not inactive-only.
- The **prune set** is the shortest append-order prefix of inactive
  revisions whose removal makes `count(R \ pruneSet) ≤ maxRevisions` and
  `bytes(R \ pruneSet) ≤ maxRevisionBytes`, selecting in **append order**
  (oldest inactive first). Append order over inactive revisions is a total order
  with no ties: revision IDs are unique within an item (`02` §2.5 rule 2) and the
  list is totally ordered by append order (`02` §2.5 rule 1), so no ID tie-breaker
  is required (D9 determinism holds from append order alone; the v1
  `lastCopiedAt ascending, id ascending` eviction tie-break, `02` §12,
  applies to *item* retirement, not to within-item revision order).
- The active revision `ra` is always retained. After pruning, `activeRevisionID`
  still names exactly one present revision (D3 preserved).

### 5.2 What pruning never does

- Never removes the active revision (D3).
- Never changes a surviving revision's content or ID (D4: revisions remain
  immutable in content).
- Never changes Canonical Content (D2), Effective Content, `ContentVersion`
  (D5), title/search projections (pruning inactive revisions does not change
  Effective Content or its projection, `05` §15), or the Signature Index
  (signatures are Canonical, `05` §3.1; revisions do not contribute postings).
- Never reorders surviving revisions (append order preserved).
- Never leaves `activeRevisionID` naming an absent revision, and never leaves a
  non-empty list with a nil active ID (D3).

### 5.3 Mutation and stamping

R3 pruning is a new `HistoryMutation` case (additive to the v1 package enum,
`02` §7):

```swift
case pruneRevisions(
    itemID: HistoryItemID,
    removedRevisionIDs: [RevisionID]
)
```

`removedRevisionIDs` is non-empty (a no-op prune returns `.unchanged` before
planning, mirroring v1's same-content revision no-op, `02` §11 step 5). The
Authority stamps it to a new `StampedMutation` (additive to `05` §9):

```swift
case pruneRevisions(
    itemID: HistoryItemID,
    revisionStateBlob: Data                     // rewritten RevisionStateBlobV1 (fewer revisions, same active)
)
```

The stamped `revisionStateBlob` is the v1 `RevisionStateBlobV1` re-encoded with
the pruned list removed (`formatVersion == 1`, same `activeRevisionID`). The
prune carries **no per-item `ContentVersion` field**: it does not advance
`ContentVersion` (R3 alone advances none; the enclosing append does on revise,
exactly as v1), and it has no caller OCC token of its own. For the prune-only
case (`.setRetentionPolicies`) the protection is the serialized Authority
interval (no suspension between fact load and commit, `05` §11) plus the
singleton `StorageInvariant.positionChanged` guard (`05` §10) - exactly the
protection v1 `.setRetentionPolicy` relies on (`05` §9), which also carries no
per-item version. For the revise+R3 case, the enclosing `.appendRevision` already
carries the two-phase `ContentVersion` OCC recheck (`02` §11 step 1; `05` §6.2:
a content-changing interleaving revision advances `ContentVersion` and the
second check rejects); the prune is folded into the append's stamping (§6.3) and
inherits that protection. A prior draft carried an `expectedCurrentVersion`
field documented as "a recorded defensive value, not an independent gate"; it
is **dropped** here because an unchecked gate-looking payload is a D18 smell
(`02` §14), and the position guard already suffices. R3 pruning does **not**
re-derive Effective Content or re-project title/search (neither changes).

### 5.4 Hard-bound interaction (the ordering rule)

v1 enforces the per-item revision-count/byte **hard** bounds during revision
*preparation* (`02` §11 step 4: "Storage has already enforced … per-item
revision-count/byte hard limits during preparation" - the preparation phase
that performs the check is `05` §6.2; `06` §2: 100 revisions /
256 MiB). A naive composition would let preparation reject an append at the hard
bound before R3 pruning can bring the item below it. V2-02 therefore revises
the **revision-preparation path** (a capability-gated extension of `05` §6.2,
not a change to the hard-bound value or its rejection semantics):

> When R3 is active for an item, the V2 revision-preparation path computes the
> prune set **before** the hard-bound check, so the check sees the
> **post-prune post-append** state. The hard bound (100 / 256 MiB) remains the
> safety net and still rejects a revision append whose post-prune post-append
> state exceeds it (`05` §6.2; `02` §11 step 4). R3 never relaxes the hard
> bound; it only prunes below the user threshold first.

**Byte-measure commensurability (assumption, gated by `RET-PLATFORM-4`).** R3's
`revisionBytes` (the `RetainedBytesRow.revisionBytes` scalar and the in-memory
post-prune post-append computation on the preparation path) is defined as the
sum of stored-revision representation bytes, excluding Codable framing,
`formatVersion`/`activeRevisionID` overhead, and `.externalStorage` block
overhead (§2.1/§3.2). The v1 per-item-revision-byte hard bound (`06` §2: 256
MiB, enforced during preparation, `05` §6.2) is stated as "Total revision bytes
per History Item | 256 MiB"; v1 (`06` §2 / `05` §6.2) does **not** explicitly
define that hard bound's byte measure. V2-02 therefore *assumes* the v1
hard-bound measure is the same representation-byte measure R3 prunes to. Under
that assumption, the preparation-path hard-bound check computes the post-prune
post-append bytes from the same measure R3 prunes to, so
`post-prune representation-bytes <= maxRevisionBytesPerItem` implies the
post-prune post-append state also satisfies the 256 MiB hard bound (because
`maxRevisionBytesPerItem <= 256 MiB` is enforced at the policy boundary, §8.3),
and a user threshold set well below 256 MiB cannot produce a spurious
`.capacityExceeded(.revisionBytes)` from the hard bound. If the v1 scaffold
instead measures the hard bound *inclusive* of Codable framing/envelope
overhead, the preparation-path hard-bound check must use the v1 measure for
that comparison (the hard-bound check is v1's, not R3's), and a user threshold
near 256 MiB *could* produce a spurious `.capacityExceeded(.revisionBytes)`
from the hard bound - but the hard-bound safety net still prevents any wrong
durable state in either case (an over-bound append is rejected, never
admitted). Measure identity is assigned to **`RET-PLATFORM-4`** (Record 3):
the scaffold must verify the v1 revision-byte hard-bound measure equals R3's
`revisionBytes` representation-byte measure on macOS 26; if it does not, the
preparation-path hard-bound comparison uses the v1 measure and the spurious-
failure note above applies.

Concretely: an item at 50 revisions with R3 `maxRevisions = 50` appending the
51st prunes the oldest inactive to hold 50 (post-append), never reaching the
hard bound of 100. An item at 100 revisions (hard bound) with R3 disabled
appending the 101st is rejected `.capacityExceeded(.revisionCount)` exactly as
v1 — R3 being disabled means no prune occurs before the hard-bound check.

### 5.5 R3 on `.setRetentionPolicies` (no append)

When R3 fires from a policy change (not a revision append), there is no
`.appendRevision` in the plan; only `.pruneRevisions` per exceeding item. The
stamping writes each pruned `revisionStateBlob` preserving the item's
`ContentVersion` (R3 alone advances no `ContentVersion`; the commit advances
`ChangePosition` once for the whole plan, D6).

### 5.6 Policy-persisting mutation and stamping

The persisted V2 policy value is written by an **explicit** `HistoryMutation`
(additive to the v1 package enum, `02` §7), mirroring how v1 persists
`maximumUnpinnedItems` via `HistoryMutation.setRetentionPolicy` (`02` §7; `05`
§9; `02` §13 stamping table "preserve every item version / commit advances once
when the value changes or victims retire"):

```swift
case setRetentionPolicies(HistoryRetentionPolicies)
```

The Authority stamps it to a new `StampedMutation` (additive to `05` §9):

```swift
case setRetentionPolicies(
    policies: HistoryRetentionPolicies          // the new persisted value
)
```

The stamping carries **no `expectedCurrentPosition` field**, mirroring v1's
`StampedMutation.setRetentionPolicy(maximumUnpinnedItems:)` (`05` §9, which
carries no position field) and V2-02's own `.pruneRevisions` stamping (§5.3).
Concurrency for the policy write is the plan-level singleton
`StorageInvariant.positionChanged` guard (`05` §10, checked inside the
`ModelContext.transaction` closure for every mutation), exactly the guard v1
`.setRetentionPolicy` relies on (`05` §9). An unchecked position-looking
payload would be the same D18 smell §5.3 rejected for `expectedCurrentVersion`
("an unchecked gate-looking payload is a D18 smell," `02` §14); the plan-level
guard already suffices, so no per-case position field is carried.

The stamping writes the `RetentionExpansionConfigRow` singleton fields
(`agePolicyEnabled`/`ageMaxSeconds`, `storagePolicyEnabled`/`storageMaxBytes`,
`revisionPolicyEnabled`/`revisionMaxCount`/`revisionMaxBytes`, normalized per
§3.1's both-nil rule; `configSchemaVersion` left at 1), **preserves every item's
`ContentVersion` and projections** (no item row is touched), and advances
`ChangePosition` **exactly once when the policy value actually changes or victims
retire** - a plan that sets the already-persisted value with state already
satisfying it is `.unchanged` (no stamp, no advance), exactly as v1
`.setRetentionPolicy` (`02` §12 / §13). Performing this write as an
outcome-inferred side effect of `.retentionPoliciesSet` would violate D18 (`02`
§14); the explicit payload is why it does not. This is the policy-write analog of
v1 `.setRetentionPolicy`; it carries no revision/blob rewrite (unlike
`.pruneRevisions`).

## 6. Code model

### 6.1 Module and target placement

- **Public surface** (`HistoryRetentionPolicies`, `AgeRetention`,
  `StorageRetention`, `RevisionRetention`,
  `HistoryRetentionConfiguration`, `ClipboardHistory.retentionConfiguration()`,
  and the new `HistoryAction` / `HistoryCommitOutcome` / `CapacityKind` cases)
  is added to `HistoryCore` as a
  V2-scoped section, Foundation-only (`01` §8). These types reuse v1 vocabulary
  (`HistoryItemID`, `RevisionID`, `TimeInterval`) verbatim and add no colliding
  name. Adding cases to closed v1 public enums is the sanctioned V2 extension
  ("new public cases … are added," `V2-00` §2.1; "an owned exhaustive-switch
  change," `V2-00` §6.5).
- **Domain planning** (`RetentionExpansionItemSummary`,
  `CompleteRetentionExpansionInventory`, `RetentionExpansionFacts`, the
  `RetentionExpansionPlan` result, the `planItemRetentionExpansion` /
  `planRevisionRetentionExpansion` functions, and the new
  `HistoryMutation.pruneRevisions` / `HistoryMutation.setRetentionPolicies` /
  `PlannedOutcome.retentionPoliciesSet` cases) is added to `HistoryDomain` as new
  package types/functions. No v1 Domain type or function signature is modified;
  `planCapture` / `planRetention` / `planRevision` are unchanged (R1/R2/R3
  compose around them, §4).
- **Storage** (`RetentionExpansionConfigRow` and `RetainedBytesRow`, the
  V2 capture/revise/setRetentionPolicies composition in `HistoryAuthority`, the
  new `StampedMutation.pruneRevisions` / `StampedMutation.setRetentionPolicies`
  stamping (including `RetainedBytesRow` restamp), the clock seam) is added to
  `HistoryStorage`. No new framework import is required (V2-02 uses only
  Foundation + the SwiftData already imported in `HistoryStorage`, `01` §8);
  the import gate (`01` §9) is **unchanged** (contrast V2-01, which added
  `Vision`/`PDFKit`).

### 6.2 No new actor; isolation unchanged

V2-02 adds **no new `actor`** and **no new stored field** on `SwiftDataHistory`
(contrast V2-01's `EnrichmentWorker`/`EnrichmentScheduler`, `V2-01` §6.1). All
expansion planning is pure Domain (no state); all stamping/transaction work is
on `HistoryAuthority`, the existing sole writer. `SwiftDataHistory: Sendable`
remains derived without `@unchecked Sendable` (`01` §6); `SwiftDataHistory`'s
field set (`05` §2) is unchanged. No `@Model`, `ModelContext`, or
`PersistentIdentifier` crosses an actor boundary (`01` §6 boundary rule); the
expansion facts are immutable `Sendable` values loaded inside one Authority
interval and released before return (`05` §5).

### 6.3 Stamping composition (prune + append)

When a plan contains both `.appendRevision` and `.pruneRevisions` for the same
item (the revise + R3 case, §4.3), the stamping applies them **together** in
one `revisionStateBlob` write:

```text
finalRevisionStateBlob = encode( RevisionStateBlobV1(
    formatVersion: 1,
    revisions: (loadedRevisions \ removedRevisionIDs) + [appendedRevision],
    activeRevisionID: appendedRevision.id ))
```

The v1 `.appendRevision` stamping rule (`05` §9) is unchanged in meaning
("append this revision, make it active"); the V2 extension is that the loaded
revision list it builds from has the pruned IDs removed first. This is one
blob write, one `ContentVersion` successor (the append), one `ChangePosition`
for the whole plan (D6). For `.setRetentionPolicies` (prune with no append),
the stamping writes the pruned blob directly, preserving `ContentVersion`, and
restamps the pruned item's `RetainedBytesRow` (`revisionCount`/`revisionBytes`
updated to the post-prune value) in the same transaction (§3.3b). On capture,
the new item's `RetainedBytesRow` is created with its bytes; on revise, the
revised item's row is restamped to the post-prune post-append value. Every blob
write that changes byte facts is accompanied by its `RetainedBytesRow` restamp in
the same `ModelContext.transaction` (projection coherence, `05` §15).

**Coalesce does not restamp `RetainedBytesRow`.** A coalesce stamps only
`.updateOccurrence` (v1 `05` §9: "occurrence and pin mutations preserve the
loaded Content Version and projections"); the winner's ID, Canonical Content,
`ContentVersion`, revision list, and active revision are unchanged (`02`
§9.5). Because no byte-changing blob write occurs on coalesce, no
`RetainedBytesRow` restamp is emitted - the winner's existing row (read on
the planning path, §3.2 coalesce lane) is already correct and is left
untouched. This is the byte-projection analog of v1's "occurrence mutations
preserve projections" rule.

The mechanical `HistoryMutation → StampedMutation` table (`05` §9) gains two (the second, `.setRetentionPolicies` -> `.setRetentionPolicies(policies:)`, is declared in §5.6; it writes the `RetentionExpansionConfigRow` singleton and preserves every item `ContentVersion`). The first
row: `.pruneRevisions(itemID:, removedRevisionIDs:)` → `.pruneRevisions(
itemID:, revisionStateBlob:)` (no per-item version field, §5.3). This per-case row
applies **only when no `.appendRevision` is present in the plan for that item**
(the `.setRetentionPolicies` case, §5.5). When a Domain plan contains both
`.appendRevision` and `.pruneRevisions` for the same item (the revise + R3
case), the stamping stage emits **exactly one** `StampedMutation` -
`.appendRevision(StoredRevisionUpdate)` whose `revisionStateBlob` is the
combined pruned+appended blob (the prune set applied first) and whose version
is `expectedCurrentVersion` -> `nextVersion` - and consumes the
`.pruneRevisions` Domain mutation **without emitting a separate stamped write**,
so no second `revisionStateBlob` / `contentVersionRaw` write occurs. The
executor never applies two blob writes to one item in one transaction (v1
`05` §10 applies `plan.mutations` sequentially, but the compose rule collapses
the two Domain mutations into one StampedMutation at stamp-emission time, before
the executor sees them). The compose-with-append
rule above is the only non-per-case stamping rule V2-02 adds; it is specified
here, not inferred from an outcome label (preserves D18). It is an explicit,
conditional extension of v1 `05` §9's 1:1 `HistoryMutation` -> `StampedMutation`
mapping: prune-alone -> its own `.pruneRevisions` StampedMutation row;
prune+append-for-same-item -> folded into the append's single blob write (both
payloads are explicit in the `MutationPlan`, so D18 holds without outcome-label
inference). The compose rule's exhaustive-switch coverage is verified by `RET-COMPILE-2`;
its **stamp-emission discipline** - exactly one `StampedMutation` emitted for
the revised item, the `.pruneRevisions` Domain mutation producing no separate
stamped write, and exactly one `revisionStateBlob`/`contentVersionRaw` write -
is verified by `RET-STAMP-1` (Record 3), which is distinct from both switch
coverage (`RET-COMPILE-2`) and the composed-blob round-trip integrity
(`RET-PLATFORM-3b`).

**Retire-subsumes-prune composition (`.setRetentionPolicies` only).** When a
`.setRetentionPolicies` plan retires an item (R1/R2, §4.4 PHASE B) for which R3
had also planned a `.pruneRevisions` (PHASE A), the stamping composer **drops**
that item's `.pruneRevisions`: retirement deletes the `HistoryItemRow` and all
its revisions (v1 `.delete` stamping, `05` §9), so a separate prune write is
redundant and would fetch a deleted row, violating the v1 `05` §10 row-existence
rule (every referenced row must exist exactly once unless the stamped case is
create). This is the retire+prune-for-same-item analog of the compose-with-
append rule above, an explicit composition step (specified, not inferred;
preserves D18): the composer filters the per-item `.pruneRevisions` to those
whose `itemID` is **not** in `retirements` before emitting `StampedMutation`s.
Consequently `prunedRevisions` in the `.retentionPoliciesSet` receipt counts
only revisions pruned for **surviving** (non-retired) items (§8.1). The
retire+prune stamping discipline (no `.pruneRevisions` `StampedMutation` emitted
for a retired item; no fetch-of-deleted-row) is verified by `RET-STAMP-2`
(Record 3), distinct from `RET-STAMP-1` (the revise+R3 compose-with-append case).

### 6.4 Storage-side clock seam (R1 reference time)

R1 needs a reference `now`. For capture, `now = observedAt` (the capture input).
For `.setRetentionPolicies` (no caller-supplied time), the Authority reads
`now` on the Storage side and passes it to the pure planner as `now: Date`. The
Domain mints no `Date()` (`02` §1). `.setRetentionPolicies` R1 introduces a
**new** test-injectable Storage-side clock seam (absent in v1 for this path:
v1's only time source is the caller-supplied capture `observedAt`, `02` §4
`PreparedCapture.observedAt`; `.setRetentionPolicies` carries no `observedAt`).
The seam reuses the existing Storage-side time source that mints revision
`createdAt` (`02` §4 `PreparedRevision.createdAt`; the persisted
`ContentRevision.createdAt` is `02` §2.5; the Domain also
receives as a value and never mints): a `Sendable` clock witness (a
`() -> Date` closure or equivalent `StorageClock` protocol) injected into
`HistoryAuthority` at `open` - not a `@Model`/`@unchecked` field, not a stored
mutable on `SwiftDataHistory`, not a `.shared`/`.current` service locator -
defaulting to `Date.now` in production and injectable in tests, so
`setRetentionPolicies` age tests are deterministic. The Domain remains pure
(receives `now: Date`, mints none). The clock read occurs inside the serialized
Authority interval before fact load; it does not suspend
(`05` §11 "without suspension"). `now` is captured once per commit and reused
for all R1 comparisons in that commit.

**Injection mechanism (public-surface preservation).** The clock is an `internal` `StorageClock` protocol parameter on `HistoryAuthority`'s `internal` initializer (internal to `HistoryStorage`); production wires `{ Date.now }` and tests inject a fixed `Date` via the `@testable` `HistoryAuthority` initializer. It is **not** a parameter on the v1 public `SwiftDataHistory.open` / `ClipboardHistory` seam: `SwiftDataHistory.open` internally constructs the `HistoryAuthority` with `{ Date.now }`, so no composition-root carrier is needed and the v1 public open/init signature is unchanged (no v1 public type is redefined - the same extension-by-addition posture as the new enum cases, §8.2; no `.shared`/`.current` locator). The v1 `open(configuration: HistoryConfiguration)` public signature, where `HistoryConfiguration` is the public v1 struct with fields `persistence` and `initialMaximumUnpinnedItems` (`05` §2), takes no clock parameter and gains none; the clock never rides on `HistoryConfiguration` (which is frozen v1). Tests inject via the `@testable` `HistoryAuthority` init only. Confirmation that the v1 `open`/`HistoryConfiguration` public signature is byte-for-byte unchanged is assigned to `RET-COMPILE-1` (Record 3).

### 6.5 Domain planner signatures

```swift
package struct RetentionExpansionPlan: Sendable {
    package let retirements: [HistoryMutation]      // .retire(itemID:, .retention); deduplicated
    package let retiredItems: Int
    // R3 revision prunes are NOT in this plan: planRevisionRetentionExpansion
    // returns [RevisionID] per item; the Storage composer builds .pruneRevisions
    // mutations from those results (§4.4). R1+R2 retirements are a single
    // deduplicated union pass: R1 victims are removed from the projected byte
    // total before R2 selects; `retirements` contains no duplicate HistoryItemID.
}

// R1 + R2 over a projected item inventory.
package func planItemRetentionExpansion(
    inventory: CompleteRetentionExpansionInventory,
    policies: HistoryRetentionPolicies,
    protected: Set<HistoryItemID>,   // pinned ∪ {primary} ∪ already-retired-by-count
    now: Date
) -> RetentionExpansionPlan

// R3 for one item's revision lineage (already loaded); returns the prune set.
// `revisions` is the pre-append loaded lineage. The `target` enum makes the
// two callers type-mutually-exclusive (avoids passing an inconsistent
// activeRevisionID + appendedRevision pair): `.setRetentionPolicies(active)`
// fires from a policy change (no append; the active is `active`);
// `.revise(appended)` fires from a revision append (the effective list is
// `revisions + [appended]` and the active is `appended.id`). The returned prune
// set is computed over the effective post-append list and is guaranteed not to
// contain the effective active id.
package enum RevisionExpansionTarget: Sendable {
    case setRetentionPolicies(activeRevisionID: RevisionID?)
    case revise(appended: ContentRevision)
}
package func planRevisionRetentionExpansion(
    revisions: [ContentRevision],
    target: RevisionExpansionTarget,
    policies: HistoryRetentionPolicies
) -> [RevisionID]                          // oldest inactive IDs to prune; never contains active
```

Both are pure (D16): identical inputs produce identical plans. They throw no
`DomainRejection` (retirement/pruning is deterministic victim selection). An
unsatisfiable R2 budget is detected by Storage, not by the planner: the
**pre-plan feasibility check** (`pinned + primary bytes > maxTotalBytes`, §4.2)
fails `.capacityExceeded(.storageBytes)` before any R2 retirement is planned, so
no maximal-doomed retirement plan is ever built; the `.setRetentionPolicies`
boundary equivalent (pinned bytes alone exceed `maxTotalBytes`) is rejected as
`.invalidInput(.invalidRetentionPolicy)` at the boundary (§8.3). This asymmetry
with v1 count capacity is justified: v1 count capacity is a hard safety bound
known to the Domain planner (`02` §12 `DomainRejection.capacityExceeded`), while
R2 byte feasibility depends on Storage-loaded byte facts, hence Storage-level
detection. `planRevisionRetentionExpansion` never returns the active revision
ID and never returns more IDs than inactive revisions present; an unsatisfiable
R3 prune (post-append active alone exceeds `maxRevisionBytesPerItem`) is detected
on the V2-extended preparation path and fails `.capacityExceeded(.revisionBytes)`
(§4.3/§8.3), not returned as a partial prune set.

## 7. Trigger model

| Action | Fires | Why |
|---|---|---|
| `.capture` (insert/coalesce) | R1, R2 | Adds/updates an item in the retained set; age and total bytes may now exceed thresholds. R3 does **not** fire (capture does not grow any item's revisions). |
| `.revise` (append revision) | R2, R3 | A revision append grows that item's revision count/bytes (R3) and total retained bytes (R2). R1 does not fire (a revision does not change `lastCopiedAt`). |
| `.setRetentionPolicies` | R1, R2, R3 | Lowering any threshold retires/prunes to satisfy the new policy in one commit (analog of v1 WS21 for count). |
| `.setRetentionPolicy` (v1 count) | none (V2-02) | Count enforcement is v1; it does not trigger V2-02 expansion. (A count retirement removes items, which trivially reduces bytes/age exposure, but V2-02 does not *re-evaluate* on the count action — the next capture/revise/setRetentionPolicies will.) |
| `.placePinned` / `.unpin` / `.remove` / `.clear` | none | These do not add retained bytes/items; v1 semantics are unchanged. (`.remove`/`.clear` reduce exposure; no expansion needed; `.unpin` — `DEC-UNPIN-SWEEP` below.) |

When no V2-02 policy is active (`age == nil && storage == nil && revisions ==
nil`, or `RetentionExpansionConfigRow` all-disabled), every action's public
behavior and v1 rows/columns are exactly v1's: no expansion facts are loaded,
no expansion planner runs, no `.pruneRevisions` is emitted. (DC-04: the
durable store is not byte-identical to a pre-V2-02 store — the
`RetainedBytesRow` projection is maintained 1:1 even while disabled, §3.3b.)
This is the V2 self-review property that a v1 caller ignoring V2-02 sees v1
behavior (`V2-00` §2.1).

**Intentional cross-dimension asymmetry (B11).** `.setRetentionPolicy` (v1
count) does **not** re-evaluate R2/R3, even though lowering the count retires
items and could leave the store over the R2 byte budget (if the retired items
were not the byte-heaviest) until the next V2-triggering action. This is
intentional: V2-02 evaluates R1/R2/R3 only on the actions that *add* retained
bytes/items (capture/revise) or *lower a V2 threshold* (setRetentionPolicies),
mirroring v1's per-action retention model (a count action enforces count only).
A user who lowers count and stops copying sees no R2 restoration; the recovery
is to issue a `.setRetentionPolicies` (which sweeps R1/R2/R3) or copy again. This is a stated semantic, not an oversight.

**DEC-UNPIN-SWEEP (resolved, accepted 2026-08-28):** `.unpin` is not a
retention trigger and carries no grace window. The unpin commit performs only
the pinned-lane shift (`02` §10): it loads no retention/expansion facts and
retires nothing, so a store may legitimately hold more unpinned items than
`maximumUnpinnedItems` — and stay over the R2 budget or past the R1 age
threshold — until the next trigger named in §7 (`.capture`,
`.setRetentionPolicies`) or the v1 count trigger (`.setRetentionPolicy`)
evaluates the complete admitted state; the posture is the same
event-triggered contract as DEC-RET-AGE (§2.2). A just-unpinned item keeps
its original `lastCopiedAt` and is immediately a fully eligible victim in the
deterministic oldest-first order (D16). The rejected sweep-on-unpin
alternative would turn a user unpin gesture into a destructive retention
commit (potentially deleting the just-unpinned item itself) and force the
unpin lane onto the full-inventory fact path the COUNT work removes; the
rejected protection-window alternative has no product-defined window and
silently re-orders D16 victim selection. Settings/help must describe count
and age enforcement as event-triggered (the `ageEnforcementExplanation`
wording extended to the count lane, §12), never as continuously held
invariants.

## 8. Public surface and code interaction

### 8.1 New public cases (additive)

```swift
// HistoryCore — HistoryAction (03a §5): new case; v1 .setRetentionPolicy unchanged
public enum HistoryAction: Sendable {
    case capture(ClipboardCapture)
    case placePinned(HistoryItemID, at: PinnedPlacement)
    case unpin(HistoryItemID)
    case remove(HistoryItemID)
    case clear(ClearScope)
    case revise(RevisionRequest)
    case setRetentionPolicy(maximumUnpinnedItems: Int)   // v1, unchanged
    case setRetentionPolicies(HistoryRetentionPolicies)  // V2-02 (new)
}

// HistoryCore — HistoryCommitOutcome (03a §6): new case; v1 .retentionPolicySet unchanged
public enum HistoryCommitOutcome: Sendable {
    case inserted(HistoryItemReference)
    case coalesced(HistoryItemReference)
    case placedPinned(HistoryItemID)
    case unpinned(HistoryItemID)
    case removed(count: Int)
    case cleared(count: Int)
    case revised(HistoryItemReference)
    case retentionPolicySet(removedCount: Int)            // v1 count, unchanged
    case retentionPoliciesSet(retiredItems: Int, prunedRevisions: Int)  // V2-02 (new)
}

// HistoryCore — CapacityKind (03b §10): new case; v1 cases unchanged
public enum CapacityKind: Sendable, Equatable {
    case retainedItems
    case revisionCount
    case revisionBytes
    case copyCount
    case thumbnailBytes   // v1 (03b §10; restored — an earlier draft of
                          // this list omitted it)
    case coherenceToken
    case storageBytes     // V2-02 (new): R2 budget unsatisfiable
}
```

Receipt mapping: `.retentionPoliciesSet(retiredItems:prunedRevisions:)` is the
public `HistoryCommitOutcome` mapped from the package
`PlannedOutcome.retentionPoliciesSet(retiredItems:prunedRevisions:)` (new,
additive to `02` §7), exactly as v1 `.retentionPolicySet(removedCount:)` maps
from `PlannedOutcome.retentionPolicySet(removedCount:)`. `retiredItems` counts
retired *items* (R1/R2); `prunedRevisions` counts pruned *revisions* (R3) — the
two are reported separately so a caller can distinguish item retirement from
revision pruning. `prunedRevisions` counts only revisions pruned for
**surviving** (non-retired) items: revisions of an item that the same
`.setRetentionPolicies` commit also retires are deleted by retirement (v1
`.delete` stamping, `05` §9), not pruned, so they are not counted (the stamping
composer drops the redundant `.pruneRevisions` for retired items, §6.3;
verified by `RET-STAMP-2`).

### 8.1a Configured-policy read (`DEC-RET-READ`, resolved public)

The existing `ClipboardHistory` interface gains one purpose-specific read:

```swift
public struct HistoryRetentionConfiguration: Sendable, Hashable {
    public let maximumUnpinnedItems: Int
    public let policies: HistoryRetentionPolicies
}

public protocol ClipboardHistory: Sendable {
    func retentionConfiguration(
    ) async throws -> HistoryRetentionConfiguration
}
```

One serialized Authority interval loads and validates the persisted v1 count
singleton and V2-02 expansion singleton, then returns them as one immutable
value. This is the configured state a later `.setRetentionPolicy` and
`.setRetentionPolicies` compare against. It is not live retained-byte usage,
does not expose `ChangePosition`, SwiftData identity, projections, or an OCC
token, and never substitutes defaults for missing/corrupt durable state.

This extension is intentionally public because the state belongs to the deep
History module, not to ClipyApp or PresentationUI. A companion protocol or
app-internal closure would split one durable concern across two interfaces and
force composition to know storage semantics. Adding a protocol requirement is
an owned Swift source-compatibility break for conformers, although ordinary v1
callers that do not invoke it are unaffected. Every repository conformer and
the HistoryCore symbol snapshot are compile/check gates. No protocol default
implementation may fabricate a new-store value. `OPEN-2` remains open only for
the distinct current/live retained-byte usage read.

### 8.2 Exhaustive-switch impact (owned change)

Per `V2-00` §6.5 / `03a` §1, adding cases is an owned exhaustive-switch change
across Core/Domain/Storage/tests. The compile-enforced switches that must
handle the new cases (proof gate `RET-COMPILE-2`):

- `HistoryAction` switch in `SwiftDataHistory.perform` (`05` §8): gains
  `case .setRetentionPolicies(let policies): return try await
  authority.commitRetentionPolicies(policies)`.
- `HistoryCommitOutcome` switches (receipt construction / UI mapping).
- `HistoryMutation` switch in the stamping (`05` §9): gains
  `case .pruneRevisions(itemID:, removedRevisionIDs:)` and
  `case .setRetentionPolicies(HistoryRetentionPolicies)` (§5.6).
- `StampedMutation` switch in the transaction executor (`05` §10): gains the
  prune blob write, the `.setRetentionPolicies` config-row write (§5.6), and the
  compose-with-append rule (§6.3).
- `PlannedOutcome` switch (receipt mapping, `02` §7).
- `CapacityKind` switches (failure consumers).
- All v1 walking-skeleton and invariant tests that switch over these enums
  (`06` §7–§8; the D1–D19 invariant suites, `02` §14).

A v1 caller holding `any ClipboardHistory` and ignoring V2-02 is unaffected:
the new `HistoryAction` case is never sent by v1 code, and the new
`HistoryCommitOutcome`/`CapacityKind` cases are only produced by the new action
or by expansion of capture/revise (which is a no-op when V2-02 policies are
disabled, §7). `SwiftDataHistory` conforms to the same `ClipboardHistory`; no
new protocol is needed (contrast V2-01's `EnrichmentHistory`, which was a
distinct concern; retention policy setting *is* a History Action, so it extends
the closed action seam, `V2-00` §6.5).

**Enum-case addition to frozen v1 public enums (recorded dependency, not a
blocking OPEN).** V2-02 adds new cases to three frozen v1 *public* enums
(`HistoryAction`, `HistoryCommitOutcome`, `CapacityKind`) and three v1
*package* enums (`HistoryMutation`, `PlannedOutcome`, `StampedMutation`). This
is sanctioned extension-by-addition per `V2-00` §2.1 ("new public cases are
added") and §6.5 ("an owned exhaustive-switch change"): SE-0192 makes imported
enums non-exhaustive only under library evolution (Apple SDK modules); in
ordinary builds every enum is frozen, so adding a case can break any
exhaustive switch - v1's cross-module switches included. `RET-COMPILE-2` must
therefore compile v1 callers over the extended enums, not just same-module
switches. No existing v1 case is redefined (meanings are
preserved); only additions are made. The ABSOLUTE RULE's enumeration of
"`HistoryAction` case" alongside "v1 public type" as things V2 "never
redefines" is read as forbidding *redefinition* of an existing case's
meaning, not *addition* of a new case - consistent with `V2-00` §2.1's
addition posture. A confirmatory ruling is **no longer pending**: `V2-00` §8(h) issues it
(extension-by-addition is sanctioned, not a redefinition of an existing case's
meaning, iff it does not break existing exhaustive switches — and since
ordinary-build enums are frozen (fact 22), cross-module v1 switches are
compiled by `RET-COMPILE-2`, not silently spared; the contingency
fallback below applies if it is ever reversed). It does not block V2-02's
scaffold proof, which discharges switch completeness via `RET-COMPILE-2`.

**Contingency fallback (disfavored; records a capture-time semantic gap,
R-m2).** Were the ruling instead "forbidden," V2-02 would redesign its surface
to avoid new public enum cases: reuse v1 `.retentionPolicySet(removedCount:)`
and a distinct protocol (mirroring V2-01's `EnrichmentHistory`), and map R2's
unsatisfiable case to `.invalidInput(.invalidRetentionPolicy)`. This fallback is
disfavored because it loses `CapacityKind.storageBytes` and with it the ability
to distinguish, *at capture time*, a structurally-unsatisfiable byte budget
(pinned + primary bytes irreducible) from an invalid *policy*: at capture time
the policy is valid (it was accepted at `.setRetentionPolicies`); it is the
state that is unsatisfiable, so `.invalidInput(.invalidRetentionPolicy)` would
mislabel a state failure as a policy failure. The new-case surface (preferred)
keeps the typed `.capacityExceeded(.storageBytes)` at capture (§8.3). The
fallback is a contingency only, not an open blocker.

### 8.3 Failure translation (extends `05` §16)

- An out-of-range / inconsistent `HistoryRetentionPolicies` →
  `.invalidInput(.invalidRetentionPolicy)` at the `HistoryStorage` boundary
  (reuses the v1 case, `03b` §10; no new `InvalidInputReason`). Bounds (new rows
  in `06` §2 style, all enforced at the boundary; user thresholds are always
  at or below the `06` §2 hard bounds):
  - R1 `maxAge`: `1 s <= maxAge <= 3,650 d` (10 years; a practical upper bound;
    a value above it is rejected as a misconfigured sentinel, not an "enabled
    but never fires" state - `agePolicyEnabled` already gates firing).
  - R2 `maxTotalBytes`: `1 <= maxTotalBytes <= 5,000 x 384 MiB` (the
    worst-case store footprint: 5,000 items x (≤128 MiB Canonical + 256 MiB
    revisions), `06` §2); a budget above the worst case is rejected as
    meaningless.
    `storagePolicyEnabled` gates firing.
  - R3 `maxRevisionsPerItem`: `1 <= maxRevisionsPerItem <= 100` (the active
    revision must survive, so `>= 1`; `<= 100` is the `06` §2 hard bound).
  - R3 `maxRevisionBytesPerItem`: `1 <= maxRevisionBytesPerItem <= 256 MiB`
    (the `06` §2 per-item-revision-byte hard bound; an R3 threshold above the
    hard bound is meaningless because the hard bound already rejects).
  Reject `maxAge <= 0`, `maxTotalBytes <= 0`, `maxRevisionsPerItem < 1` or
  `> 100`, `maxRevisionBytesPerItem <= 0` or `> 256 MiB`, and any
  above-the-upper-bound value, as `.invalidInput(.invalidRetentionPolicy)`.
  R3 requires `maxRevisionsPerItem >= 1` because at least the active revision
  must survive.
- **Finiteness (DC-21, closed 2026-08-15).** `maxAge` is a `TimeInterval`
  (`Double`); out-of-range comparisons alone cannot catch `NaN` (every
  comparison with `NaN` is false). The boundary therefore requires
  `maxAge.isFinite` explicitly: `NaN`, `.infinity`, and `-.infinity` are
  rejected as `.invalidInput(.invalidRetentionPolicy)`. Symmetrically, a
  **persisted** non-finite `ageMaxSeconds` on the
  `RetentionExpansionConfigRow` fails closed at config load as
  `.persistence(.corruptStoredValue)` (the `05` §4 exhaustive-decode
  discipline applied to the config singleton), never silently treated as a
  disabled or infinite policy.
- R2 budget unsatisfiable (`pinned + primary bytes > maxTotalBytes`) ->
  `.capacityExceeded(.storageBytes)` (new `CapacityKind`, §8.1). At
  `.setRetentionPolicies`, if the current pinned items' bytes alone exceed
  `maxTotalBytes`, the budget is immediately unsatisfiable (pinned items cannot
  be retired, D13), so the policy is rejected as
  `.invalidInput(.invalidRetentionPolicy)` at the boundary. A budget that
  becomes unsatisfiable later (user pins more items after setting the policy)
  surfaces as `.capacityExceeded(.storageBytes)` at capture/revise time; the
  user recovery is to unpin items or raise the budget. This hard-fail is
  justified because a byte budget, unlike a count policy, is structurally
  unsatisfiable when pinned + primary bytes are irreducible (D13 for pinned;
  plan invariant 7 / `02` §12 for the primary; D14 for the latest-state
  projection), so it is
  a hard constraint analogous to the hard retained-item bound, not a soft user
  policy (§4.5, D24).
- R3 prune cannot satisfy the threshold because the active revision alone
  exceeds `maxRevisionBytesPerItem` (the active revision cannot be pruned, §5.2;
  D3) -> the policy is unsatisfiable for that item; this is rejected at the
  **policy-set** boundary as `.invalidInput(.invalidRetentionPolicy)`. It never
  silently leaves the item over threshold. *(DC-27 scope: at
  `.setRetentionPolicies` this veto applies only to items that survive the
  same commit's R1/R2 retirement — retirement subsumes the prune and deletes
  the item's revisions with it, §4.4 PHASE C.)* Every valid `maxRevisionsPerItem >= 1`
  is count-satisfiable (pruning to active-only yields count = 1 <= threshold), so
  R3 count thresholds never produce unsatisfiability; only the byte threshold
  can. The same unsatisfiable condition discovered at **revise time** (the
  appended now-active revision alone exceeds `maxRevisionBytesPerItem`,
  satisfiable when set, unsatisfiable after the large append) fails the revise
  atomically as `.capacityExceeded(.revisionBytes)` (§4.3 R3-unsatisfiable on
  revise); the revise commits nothing.
- Expansion fact-load failure → `.temporarilyUnavailable(.factProof)` (v1 case,
  `05` §16); a corrupt `revisionStateBlob` encountered during R3 →
  `.persistence(.corruptStoredValue)` / `.invariantViolation` (v1 codec checks,
  `05` §4).
- A `ModelContext.transaction` closure failure during the merged commit →
  `.persistence(.transaction)` (v1 producer, `05` §16). Closure failure commits
  nothing — no partial retirement/prune (atomicity, `05` §10).
- **Recorded exposure (DC-28, accepted 2026-08-15, severity LOW).** A finite,
  far-future-dated capture `observedAt` (finiteness-checked at preparation per
  `03a` §4, but not clamped for R1) makes `now − maxAge` large enough to
  retire every unpinned item in one commit. Accepted rather than clamped —
  symmetric to the user's clock being wrong; v1's persisted-`lastCopiedAt`
  `max()` clamp governs persisted recency, not R1's reference time (§4.2).

## 9. Security boundaries

V2-02 is **not external-facing** (no X1 boundary; it is not an audited external
write, X2, `V2-05`). Its security record:

- **Trust boundary:** the process boundary; no external/network input. Policies
  are set by the local user via the v1 `ClipboardHistory` seam.
- **Deletion is atomic and prompt (contrast V2-01).** R1/R2 retirement deletes
  `HistoryItemRow` rows **in the retirement History Commit** (`05` §10); R3
  pruning rewrites `revisionStateBlob` **in the same commit**. There is no
  orphan/decoupled-cleanup window (contrast V2-01's `EnrichmentRow` orphan
  sweep, `V2-01` §6.5): a `remove`/retire/prune is durably complete when the
  receipt returns. `RET-SECURITY-1` confirms this.
- **Content-sensitivity reduction.** R1/R2/R3 are *data-minimization* controls:
  they retire items and prune revisions, reducing retained sensitive content.
  This is a privacy-positive direction (no new searchable exposure, contrast
  V2-01's OCR-text amplification, `V2-01` §9). Pruned revisions are gone
  durably (no tombstone, `02` §3.3 "removal is absence"); a backup of the store
  taken before pruning retains them, which is a backup/restore property outside
  V2-02's scope (honest note, not a gate).
- **TCC/sandbox/entitlement:** none. Retention is purely internal mutation of
  already-retained, in-process data. No new permission, privacy-usage string,
  or entitlement (`00` §5: state the outcome; no gate needed beyond
  `RET-SECURITY-1`).
- **Audit:** not an audited external write; it produces no `OperationRecord`
  (X2, V2-05). It is internal policy state.
- **Crash safety.** A crash mid-commit commits nothing (`05` §10); a crash
  after commit but before in-memory index update loses only derived process
  state (the Signature Index rebuilds from durable rows on startup, `05` §11).
  R3's pruned `revisionStateBlob` is durable on commit; restart sees the pruned
  list. No wrong durable state.

## 10. Graft-admission records (`V2-00` §4)

### Record 1 - Lifted exclusion + evidence trigger

- **R1** lifts `00` §2 Excluded ("Age- or byte-policy history retention. v1
  uses an item-count policy plus hard safety bounds") and `02` §12 ("Age,
  total-byte, and automatic revision-retention policies are outside v1") and
  `06` §4 ("Age-based or storage-byte user retention"). Evidence trigger:
  approved product requirement (`V2-00` §3).
- **R2** lifts the same `00` §2 / `02` §12 / `06` §4 exclusion (byte policy).
  Same trigger.
- **R3** lifts `00` §2 Excluded (automatic revision retention) and `02` §12
  ("...automatic revision-retention policies are outside v1") and `06` §4
  ("Automatic revision retention"). Evidence trigger: approved product
  requirement (`V2-00` §3).

No performance evidence trigger is required to admit *design* (§2.3); the
performance gates (Record 3) bound the expansion pass, not admission.

**Admission record (2026-08-15).** The product owner approved the V2-02
product requirement, admitting R1 + R2 + R3 into the first V2 release (M1 +
V2-02) as **one three-dimensional policy value with independently
disable-able dimensions** (DC-23 option A: the `HistoryRetentionPolicies`
struct ships whole; each dimension is independently `nil`-disabled; the
§7 trigger matrix, public surface, schema defaults, and UX switches follow
this document as written, with no slice trimming). Recording per `V2-00` §3 /
`V2-roadmap` §2 Step V2-2: this written approval is the durable trigger
evidence for all three dimensions; no performance trigger applies. **OPEN-2
(current retained bytes) is NOT admitted** in this release: no public
retained-bytes read is added, and the R.7/UX.4 surfaces show policies and
receipts only (`V2-roadmap` §4 DC-08 retention clause, decided 2026-08-15).

### Record 2 - Invariant impact

D1–D3 and D5–D18 are **preserved unchanged**; **D4 and D19 are EXTENDED**
(not preserved), per `V2-00` §4 record 2 / §8(e) ("a D1–D19 invariant is
either preserved-unchanged or explicitly extended with a stated new
invariant"). D4's append-only revision list is extended by D23's pruning of
inactive revisions (D23 bullet below); D19's universal scope is narrowed to
the count dimension by D24, with the count-dimension guarantee preserved
unchanged (D19 bullet below; §4.5). The `RetainedBytesRow` projection
(§3.3b) introduces **no new D-invariant**: its coherence is governed by the
v1 projection discipline `05` §15 (restated in Record 4), and the V2
invariant registry (`V2-roadmap` §14) allocates D25–D28 to V2-03 and
D29–D31 to V2-04, so
V2-02 (D23–D24) mints no byte-projection D-number. In particular:

- **D1 (Stable identity):** preserved unchanged - V2-02 reuses v1
  `.retire(itemID:, .retention)` / `.delete(itemID:, reason:)` stamping (`02`
  §7; `05` §9) for item retirement and prunes only *inactive* revisions within
  an item's lineage; no item ID is redirected, reused, or consolidated, and no
  revision ID is resurrected within an item (`02` §3.3 removal-is-absence;
  `05` §9 delete removes the row and its signature postings). Item-ID
  non-reuse and revision-ID non-reuse hold exactly as v1.
- **D2 (Canonical immutability):** R1/R2/R3 never touch Canonical Content. R3
  prunes inactive revisions only; Canonical is the ingest-lineage root
  (`02` §2.3), untouched by revision pruning.
- **D3 (complete active lineage):** R3 never prunes the active revision; after
  pruning, `activeRevisionID` still names exactly one present revision and a
  non-empty list keeps a non-nil active ID. The pruned `revisionStateBlob`
  passes every `05` §4 decode check (`RET-PLATFORM-3`).
- **D4 (append-only meaningful revision):** preserved *for appends* — a
  replace/revert still appends only when Effective Content changes, and
  surviving revisions' content is immutable. R3 *removes* inactive revisions
  for retention, which is a new operation governed by D23 (§11) that extends
  D4 without weakening it: D4's guarantee is about not mutating prior revision
  *content* and not appending without a content change; R3 does neither.
- **D5 (precise ContentVersion):** R3 pruning mints no `ContentVersion`; only
  the enclosing append does (exactly as v1). R1/R2 retirement preserves every
  survivor's `ContentVersion`.
- **D6 (one global commit position):** the merge (§4) produces one `MutationPlan`;
  the Authority stamps one checked `ChangePosition` successor for the whole
  plan (`02` §13).
- **D8 (complete facts):** the expansion planner receives complete per-item
  byte/revision summaries (`RetentionExpansionFacts`); an incomplete load fails
  before planning (§3.2).
- **D13 (pin-protected retention):** pinned items are in `protected`; R1/R2
  never retire them.
- **D14 (latest-state retention):** expansion facts are loaded over the
  projected post-primary inventory.
- **D16 (pure planning):** the expansion planners are pure; identical inputs
  yield identical plans.
- **D18 (semantic-plan completeness):** the prune/retire payloads are explicit
  in the `HistoryMutation`; Storage applies them mechanically (the one
  compose-with-append stamping rule, §6.3, is specified, not inferred).
- **`05` §6.2 revision-preparation path (conditionally EXTENDED):** when R3
  is active for an item, the V2 revision-preparation path computes the prune set
  *before* the per-item hard-bound check so the check sees the post-prune
  post-append state (§5.4). The hard-bound value (100 revisions / 256 MiB, `06`
  §2) and its rejection semantics are unchanged; when R3 is disabled, the
  preparation path is byte-for-byte v1 (no prune, hard bound rejects at 101).
  This is a capability-gated conditional extension of the v1 internal path,
  recorded here so the graft-admission inventory is complete (cited §5.4).
  **Policy-sourcing mechanism (names how R3 policies reach the off-Authority
  preparation actor).** The v1 `RevisionPreparationSnapshot` (`05` §6.2) carries
  only `canonical`, `revisions`, `activeRevisionID`, `contentVersion` — no
  policies — and that v1 value is left byte-for-byte unchanged. The
  `HistoryAuthority` reads the current `RetentionExpansionConfigRow` R3 policies
  in the **same serialized Authority interval** that captures the snapshot
  (before/around handing the snapshot to the `RevisionPreparationActor`) and
  threads them as a **sibling V2 input** to the V2-extended preparation call
  (the `if R3 active for this item's thresholds` guard and the `policies`
  operand of `planRevisionRetentionExpansion(snapshot.revisions, target:,
  policies)` in §4.3 PHASE 1 both read this sibling input); the off-Authority
  preparation actor performs no durable-state read of its own. This is
  extension-by-addition (a new sibling input), not a modification of the v1
  `RevisionPreparationSnapshot` value; phase 2 re-reads the current policies
  independently (§4.3 "Phase-2 policy re-read").
- **D19 (retention floor - EXTENDED, not preserved):** D19's literal universal
  claim ("only the global hard retained-item bound can force a capacity
  failure") is **narrowed to the count dimension** by the new D24 (§11): the
  count policy alone never forces a capacity failure, and only the hard
  retained-item bound forces a *count* capacity failure (`02` §12); the count
  floor (>=1 unpinned) is unchanged. R2's `.storageBytes` capacity failure is a
  **new, orthogonal byte-budget failure producer** governed by D24 (§11) - it
  is NOT the hard retained-item bound, and fires only when pinned + primary
  bytes exceed `maxTotalBytes` and no eligible (unpinned, non-primary) victim can
  restore the bound (mirroring `06` §2's general capacity rule). D19's
  *count-dimension* guarantee is preserved unchanged; only its universal "only
  the hard bound" scope is narrowed by D24. This is an **explicit extension**
  (D24 adds the orthogonal byte-budget failure), classified EXTENDED here and in
  §4.5 - not an undebated "preservation." `V2-00` §8(g) rules that this narrowing is a sanctioned "explicit extension"
  (not a forbidden "weakening") - the count guarantee is preserved, the byte-budget
  failure is orthogonal (§4.5 R-M1, resolved); it does not block V2-02's scaffold
  proof.

V2-02 **extends** the invariant set with **D23–D24** (§11). Of D1–D19, D1–D18 are preserved unchanged and **D19 is EXTENDED** (narrowed to count by D24, count guarantee preserved); none is weakened. `RetainedBytesRow` (§3.3b) adds no D-invariant (coherence via `05` §15).

### Record 3 - V2 proof gates

The analog of Part VI §6 (compile), §7 (schema/platform), §9 (performance) on
macOS 26. Gates use the `RET-` prefix (retention) to avoid confusion with the
R1/R2/R3 capability IDs and the deleted "R0/R1/R2 as shipped tiers" token
(`06` §10; §11 self-review note).

- **RET-COMPILE-1 (compile/dependency).** Swift 6 complete strict-concurrency
  build succeeds with the new `HistoryCore` types (Foundation-only), the new
  `HistoryDomain` pure planners (no I/O/actor/clock/UUID/Date-generation/
  async), and the new `HistoryStorage` composition/stamping. No new framework
  import; the import gate (`01` §9) is unchanged. No `@unchecked Sendable` or
  `nonisolated(unsafe)`; `SwiftDataHistory: Sendable` remains derived (no new
  actor/field, §6.2).
- **RET-COMPILE-2 (exhaustive-switch completeness).** Every switch over
  `HistoryAction`, `HistoryCommitOutcome`, `HistoryMutation`,
  `StampedMutation`, `PlannedOutcome`, and `CapacityKind` handles the new cases
  (§8.2); compile-enforced.
- **RET-READ-1A (configured-state persistence and consumption).** Through the
  public seam, set a non-default count plus literal `90,001 s` / `1,048,577 B`
  policy values, release the first store owner, reopen, and read one exact
  `HistoryRetentionConfiguration`. Reapplying both returned values is
  `.unchanged`, with no position or retained-row change. The Presentation
  consumer performs one read, edits only revision count, and emits a policy
  action preserving every untouched awkward-unit literal. A late read cannot
  replace a newer count or policy field. This does not prove localization,
  hosted controls, or live retained-byte usage.
- **RET-PLATFORM-1 (schema migration).** `RetentionExpansionConfigRow` (§3.3)
  and `RetainedBytesRow` (§3.3b) are additive to `HistorySchemaV2`; the
  `HistorySchemaV1 → HistorySchemaV2` hop is the **single
  `MigrationStage.custom` stage** of §3.3 (DC-02: the hop both adds the models
  and backfills the projection, so it takes one custom stage whose `didMigrate`
  performs the backfill; a lightweight+custom stage pair over one version pair
  is not a documented SwiftData pattern — `V2-facts.md` cycle-2 facts,
  WWDC2025/291). v1 rows, `LastChangePositionRow`, the Signature Index, and the
  singleton position are untouched; a migrated v1 store starts with V2-02
  disabled (`RetentionExpansionConfigRow` created at `open`, §3.3). Reuses the
  **M1-owned** `HistorySchemaV1: VersionedSchema` retrofit (`V2-roadmap` §3
  [M1 is the migration-foundation prerequisite for every table-adding graft],
  recorded in `V2-01` §10 `E1-PLATFORM-1`). Because M1 is a prerequisite to
  every table-adding graft, no shipping order creates a cross-graft dependency:
  the retrofit is owned by M1 in every ordering, so V2-02 never depends on
  V2-01 having already shipped it.
- **RET-PLATFORM-1b (RetainedBytesRow projection-rebuild migration).**
  `RetainedBytesRow` is a projection (§3.3b), so the single custom hop's
  `didMigrate` closure (DC-02, §3.3) is the projection-rebuild backfill
  (Part V §17 layer 3; `05` §15/§17) that, for each existing `HistoryItemRow`
  (<= 5,000), decodes its `canonicalSignatureBlob` and `revisionStateBlob` once
  and writes the `RetainedBytesRow` row (`canonicalBytes`/`revisionCount`/
  `revisionBytes`, `bytesSchemaVersion == 1`). The gate verifies: (a) every
  retained item has a 1:1 `RetainedBytesRow` after migration AND every
  `RetainedBytesRow` names a retained item (checked both directions; an orphan
  cannot arise through stamping - §3.3b deletes it in the same transaction as
  the item - and is `.persistence(.invariantViolation)` corruption if found);
  (b) each scalar equals the
  recomputed-from-blob value (no backfill skips/incorrect bytes); (c) no v1
  blob/`ContentVersion`/ID is mutated; (d) the backfill runs as the single
  custom hop's `didMigrate` step inside `SwiftDataHistory.open` (Part V §17
  layer 3), so it completes before `open` returns and therefore before any
  capture can be issued; the default-disabled `RetentionExpansionConfigRow`
  (§3.3) means R2/R3 do not fire on the first captures regardless, so V2-02
  gates nothing about the v1 capture action (a v1 caller ignoring V2-02 sees v1
  capture behavior, `V2-00` §2.1). (e) the backfill is **idempotent by
  construction** — every row is recomputed from the blobs, never a resumed
  partial write — and because SwiftData's custom-stage failure semantics are
  undocumented, this gate must prove on the macOS runner that an interrupted
  migration (process death mid-backfill) leaves the store openable and that the
  re-run reproduces exactly the (a)/(b) invariants, rather than assuming
  engine-level interruption atomicity. *(Measured 2026-08-16, run
  31955551834's fixture: the engine provides NO interruption atomicity —
  the schema version is stamped before the `didMigrate` data commits, so
  the "re-run" is owned by `open`'s step-7 missing-rows recovery, per
  Record 5's Interruption-recovery clause; the fixture proves the
  recovered outcome on the runner.)* A `RetainedBytesRow` for an existing item
  absent **post-open** (i.e. after `open` has returned) is corruption - row
  existence is the migration invariant (a) - so it fails closed
  `.persistence(.invariantViolation)`; the `.temporarilyUnavailable(.factProof)`
  mapping in §3.2 is reserved for the **fetch mechanism itself** failing, never
  for a missing row, and a zero is never read.
- **RET-PLATFORM-2 (byte-count fact loading - RESOLVED by `RetainedBytesRow`).**
  The retention planning path obtains complete per-item byte summaries by
  reading the `RetainedBytesRow` scalar projection (`canonicalBytes` /
  `revisionCount` / `revisionBytes`, §3.3b) - it decodes no
  `revisionStateBlob` and no `SignatureBlobV1` envelope on the planning path.
  The justification for the projection (rather than on-demand decode) is that
  **no documented SwiftData API yields an `.externalStorage` blob's byte length
  or revision count without materializing its content** (`V2-facts.md` cycle 4:
  `fetch` hydrates; `fetchCount` returns row counts, not bytes;
  `fetchIdentifiers` returns identifiers only; `propertiesToFetch` fetches
  attribute *values* and faults non-fetched attributes on access; `enumerate`
  hydrates per model). `RetainedBytesRow` is the committed resolution: it is
  stamped in the same transaction as the blob it summarizes (`05` §15
  projection discipline, Record 4) and backfilled once at migration (Record 5).
  A bounded per-item decode of the external `revisionStateBlob` remains the
  mechanism only for (a) the migration backfill (`RET-PLATFORM-1b`) and (b) the
  per-item coherence cross-check **piggybacked on the R3-sweep decode for items
  whose scalar exceeds a threshold** (`RET-PERF-2`) - never as a separate decode
  on the per-commit R2 planning path (§3.3b). Consequently an **R2-only-active**
  commit (no R3 sweep to piggyback on) triggers **zero** blob decodes: the
  planning path reads scalar columns only, preserving this gate's no-decode
  claim and `RET-PERF-3`'s zero-decode capture budget.
- **RET-PLATFORM-3 (R3 blob rewrite integrity).** A pruned
  `RevisionStateBlobV1` (fewer revisions, same `activeRevisionID`,
  `formatVersion == 1`) round-trips and passes every `05` §4 decode check
  (unique revision IDs, active ID names a present revision, non-empty list ↔
  non-nil active ID, normalized content) — D3 holds after pruning. Mirrors v1
  Part VI §7.4 (codec round trip + corruption rejection).
- **RET-PLATFORM-3b (composed prune+append blob integrity).** A *composed*
  `RevisionStateBlobV1` - one whose `revisions = (loaded \ removedRevisionIDs) +
  [appendedRevision]` and `activeRevisionID = appendedRevision.id` (the revise+R3
  stamping shape, §6.3) - is a distinct blob shape from both a v1 append and a
  prune-only blob. It must round-trip and pass every `05` §4 decode check
  (unique revision IDs; `activeRevisionID` names exactly one present revision,
  namely the appended one; non-empty list with non-nil active; normalized
  content) so D3/D5 hold after the fused write, and no intermediate inconsistent
  `revisionStateBlob` is ever durable. This is a **distinct** scaffold proof
  from RET-PLATFORM-3 (which covers the prune-only shape) and from RET-COMPILE-2
  (which verifies switch coverage, not blob-integrity); it is not folded into the
  compile/security gates because the compose rule is a correctness-critical
  non-mechanical stamping. Mirrors v1 Part VI §7.4 for the composed
  transformation.
- **RET-PLATFORM-4 (R3 byte-measure commensurability with the v1 hard bound).**
  v1 (`06` §2: "Total revision bytes per History Item | 256 MiB"; `05` §6.2
  preparation-path enforcement) does **not** explicitly define the hard bound's
  byte measure. This gate verifies, on the macOS 26 scaffold, that the v1
  per-item-revision-byte hard-bound measure is **identical** to R3's
  `revisionBytes` representation-byte measure (sum of stored-revision
  representation bytes, excluding Codable framing, `formatVersion`/
  `activeRevisionID` overhead, and `.externalStorage` block overhead, §2.1/§3.2).
  If identical, the §5.4 commensurability holds and a user threshold below
  256 MiB cannot produce a spurious `.capacityExceeded(.revisionBytes)` from
  the hard bound. If the v1 scaffold measures the hard bound *inclusive* of
  framing/envelope overhead, the gate records that divergence and the
  preparation-path hard-bound comparison must use the v1 measure (the
  hard-bound check is v1's, not R3's); in that case a user threshold near
  256 MiB could produce a spurious `.capacityExceeded(.revisionBytes)`, and
  the doc's §5.4 spurious-failure caveat applies. The hard-bound safety net
  prevents wrong durable state in either case (an over-bound append is
  rejected, never admitted). Distinct from `RET-PLATFORM-3`/`-3b` (blob
  round-trip) and `RET-PRUNE-1` (prune-relation correctness): this gate
  verifies *measure identity*, not blob or algorithm correctness.
- **RET-PRUNE-1 (R3 prune-relation algorithm correctness - Domain proof).**
  Fixture and property tests over `planRevisionRetentionExpansion` asserting, for
  both `target` cases (`.setRetentionPolicies(active:)` and `.revise(appended:)`)
  and for count-only / byte-only / both-threshold policies: (a) the prune set is
  the **shortest append-order prefix** of inactive revisions that satisfies
  both thresholds on the effective list (minimal under the
  oldest-inactive-first selection of (b), not minimum-cardinality);
  (b) selection is **oldest-inactive-first** (append order, `02`
  §2.5 rule 1); (c) the **active** revision is never in the prune set; (d) both
  thresholds are satisfied post-prune (count and bytes); (e) the post-prune list
  is **D3-valid** (a non-nil `activeRevisionID` names exactly one present
  revision; a non-empty list keeps a non-nil active ID); (f) the empty-list /
  `activeRevisionID == nil` (Canonical-only) item yields an empty prune set; (g)
  the returned ID count never exceeds the inactive count. This is distinct from
  `RET-PLATFORM-3`/`-3b` (blob round-trip) and `D16` (purity, not correctness).
- **RET-PRUNE-2 (R3-then-R2 composition - no over-retire).** A proof
  asserting that on `.setRetentionPolicies` (and on revise), R2 never retires an
  item whose **post-R3-prune** bytes already satisfy `maxTotalBytes`: the
  inventory R2 selects over is the projected post-prune state (§3.2/§4.4), so an
  item whose revision bytes R3 prunes below the per-item threshold is credited
  the reduced bytes, never the un-pruned bytes. Fixture: two unpinned items
  A(prunable to fit) + B(fits) under a budget both satisfy post-prune must yield
  zero R2 retirements. Discharges D14/D24 for the composition.
- **RET-SELECT-1 (R1/R2 victim-selection correctness - Domain proof).**
  Fixture and property tests over `planItemRetentionExpansion`,
  for age-only / byte-only / both-active policies and the
  `.setRetentionPolicies` sweep shape (`protected` = pinned only,
  §4.4): (a) R1's boundary is strict (`lastCopiedAt < now -
  maxAge`) and victims retire oldest-first in the v1 eviction order
  (`lastCopiedAt` ascending, `id` ascending, §4.2); (b) R2 retires
  oldest eligible unpinned items only until projected retained
  bytes <= `maxTotalBytes`, never further, after the pre-plan
  feasibility check (§4.2); (c) no protected item is ever selected
  (pinned/primary/count-victims, §4.2); (d) `retirements` is the
  deduplicated R1 ∪ R2 union - no duplicate `HistoryItemID`, R1
  victims excluded from R2's byte total (§4.1/§6.5); (e) a
  satisfying state yields no retirement and, with
  `newPolicies == currentPolicies`, the `.unchanged` outcome
  (§4.4/§5.6). Distinct from `RET-PRUNE-1/-2` (R3 planner and
  composition) and `RET-CONCUR-1` (interleaving); discharges the
  R1 selection prose that motivates the §6.4 clock seam.
- **RET-CONCUR-1 (two-phase R3 speculative-vs-commit prune-set agreement).** A
  deterministic harness (mirroring v1 WS20 for revision OCC interleaving)
  driving the revise two-phase path (§4.3): (1) a coalescing / lineage-
  preserving interleave between phase 1 and phase 2 asserts
  `speculativePruneSet == committed pruneSet` and the fused compose-with-append
  blob is built from **phase-2** (reloaded) facts; (2) a content-changing
  revision interleave asserts the revise rejects `.staleContent` at the second
  OCC check with **no** `.pruneRevisions` mutation emitted and **no**
  `revisionStateBlob` write (no stale prune applied to a different lineage);
  (3) an interleaving `.setRetentionPolicies` R3-prune on the **same item**
  (which preserves `ContentVersion` so the `02` §11 step-1 OCC check passes,
  but removes inactive revisions, changing the list the prune set is computed
  over) asserts the committed prune set is correct for the **reloaded
  post-interleave-prune lineage** (not necessarily equal to
  `speculativePruneSet`), no stale prune is applied, phase 2 uses the
  **re-read** current `RetentionExpansionConfigRow` policies (not phase-1-
  cached) so an interleaving threshold change is respected, and the active
  revision survives (D3). Discharges the concurrency claim currently resting
  on §4.3 prose, including the phase-2 policy re-read (§4.3).
- **RET-STAMP-1 (compose-with-append no-double-write stamping).** A stamping-
  stage test asserting that for a revise+R3 plan, the stamping stage emits
  **exactly one** `StampedMutation` for the revised item (`.appendRevision` with
  the combined pruned+appended blob), the `.pruneRevisions` Domain mutation
  produces **no separate** `StampedMutation`, and the executor applies exactly
  one `revisionStateBlob` write and one `contentVersionRaw` successor in the
  transaction. Distinct from `RET-COMPILE-2` (switch coverage) and
  `RET-PLATFORM-3b` (blob round-trip); verifies the §6.3 emission discipline.
- **RET-STAMP-2 (retire-subsumes-prune no-double-write stamping).** A stamping-
  stage test for the `.setRetentionPolicies` path asserting that when an item is
  both R1/R2-retired and R3-prune-planned in the same commit, the stamping
  composer emits **no** `.pruneRevisions` `StampedMutation` for that item (the
  `.retire`/`.delete` removes the `HistoryItemRow` and all its revisions, `05`
  §9), so the executor never fetches/rewrites a deleted row (no violation of the
  v1 `05` §10 row-existence rule: every referenced row must exist exactly once
  unless the stamped case is create). The test also asserts `prunedRevisions` in
  the `.retentionPoliciesSet` receipt counts only revisions pruned for surviving
  (non-retired) items. Distinct from `RET-STAMP-1` (the revise+R3
  compose-with-append case); this gate covers the retire+prune-for-same-item
  case (§6.3 retire-subsumes-prune).
- **RET-PERF-1 (expansion capture overhead).** When R1/R2 are active, the
  expansion pass over the projected inventory (<= 5,000 items, `06` §2) is
  bounded. R1 reuses `lastCopiedAt` (no new read); R2 byte-summary loading is a
  **scalar read** of `RetainedBytesRow` (§3.3b) - no `revisionStateBlob`
  decode on the planning path (`RET-PLATFORM-2` resolved). The new capture-path
  cost is the `RetainedBytesRow` create for the inserted/coalesced item (bytes
  already in memory at capture) plus the O(retained) scalar sweep, not a blob
  decode. Capture commit interval still excludes pasteboard access,
  fingerprinting, rich-text projection, and image decode (`06` §9); the
  expansion pass is planning work, not decode of the primary's content. The
  same scalar-read bound and measurement cover the revise-path expansion
  when R2 is active (§4.3): RetainedBytesRow fetch + O(retained) sweep + the
  revised item's row restamp; revise p95 with R2 active and near-5,000 items
  is measured alongside capture p95 in this gate.

- **RET-PERF-2 (setRetentionPolicies sweep).** The R3 full-sweep on
  `.setRetentionPolicies` decodes revision blobs **only for items exceeding the
  threshold** (bounded; typically few), not all retained items; the R1/R2
  scalar sweep over the inventory is O(retained). Exceedance is detected from
  the `RetainedBytesRow` scalar projection (§3.3b), so the scalar sweep decodes
  nothing; only the exceeding items' lineages are decoded for the R3 prune set
  (and their `RetainedBytesRow` rows restamped post-prune). Bounded by 5,000
  items.

- **RET-PERF-3 (capture-path cost with R2 active, restated against
  `RetainedBytesRow`).** `RetainedBytesRow` is the committed baseline (§3.3b),
  so the capture planning path decodes **zero** external `revisionStateBlob`s
  for R2; it reads scalar columns. The gate now verifies the scalar-read
  planning path (RetainedBytesRow fetch + O(retained) sweep + the inserted
  item's row create) keeps capture p95 with R2 active and near-5,000 items
  within the agreed capture-commit-interval budget (`06` §9). The prior
  worst-case 5,000-blob decode is eliminated by the projection; the
  projection's own per-commit restamp cost (one row write per blob-changing
  commit) is bounded and part of this gate's measurement. `RET-PERF-3` no
  longer names `RetainedBytesRow` as a future remedy - it is the adopted
  design.


- **RET-SECURITY-1 (deletion atomicity).** R1/R2 retirement and R3 pruning are
  atomic in-commit (one `ModelContext.transaction`, `05` §10): a receipt means
  the deletion is durable; closure failure commits nothing. No
  orphan/decoupled-cleanup window (§9). Confirm on the macOS 26 runner.

### Record 4 - Cache-law compliance

V2-02 introduces **no cache**. The Part IV §12 cache law ("for the same
authoritative source state and request, cache hit, cache miss, eviction,
disabled cache, and process restart produce semantically identical values and
failures") is **inapplicable**: there is no read cache and no materialization
cache (contrast V2-01's enrichment derivation, `V2-01` §10 Record 4, which
substituted a derivation-fence law). V2-02 retention state is authoritative
durable state written through `HistoryAuthority`, read exactly as v1 reads
durable state. No cache law is restated because none applies; this is recorded,
not hidden.

**Projection-coherence (the `RetainedBytesRow` projection).** `RetainedBytesRow`
(§3.3b) is a **derived content-byte projection** - a durable projection of
the same kind as v1's `title`/`searchBody` projections (`05` §15), not a cache.
It is governed by the v1 **projection discipline** (`05` §15), restated here:
`RetainedBytesRow`'s `canonicalBytes`/`revisionCount`/`revisionBytes` are
recomputed and stamped in the **same `ModelContext.transaction`** as the blob
write that changes them (capture/revise/R3-prune), so a transaction commits both
the blob and its projection or neither (`05` §10 atomicity); it is **never
silently stale** relative to the durable blob. A projection-schema change (e.g.
a `bytesSchemaVersion` bump) is an explicit schema version + migration/rebuild
(`05` §15; Record 5), not a runtime-resumable value. No new D-invariant is
minted for this (the law already exists in `05` §15; the V2 registry
(`V2-roadmap` §14) allocates
D25–D28/D29–D31 to V2-03/V2-04, so V2-02 mints none).

### Record 5 - Migration impact (Part V §17 three layers)

- **Schema layer (SwiftData migration):** add `RetentionExpansionConfigRow`
  (§3.3) and `RetainedBytesRow` (§3.3b) to `HistorySchemaV2` (additive; no v1
  model gains a column - the v1 count policy stays on
  `LastChangePositionRow.maximumUnpinnedItems`, `05` §3.2; `HistoryItemRow`
  gains no size column). No v1 model gains a **relationship** either:
  `RetainedBytesRow` is deleted by an **explicit step in the V2-extended
  `.delete` stamping** (`05` §9 - when `.delete(itemID:, reason:)` removes the
  `HistoryItemRow` and its signature postings, the V2 extension also removes
  the 1:1 `RetainedBytesRow`), not by a `@Relationship(... onDelete: .cascade)`
  on `HistoryItemRow` (which would touch the frozen v1 model, `05` §3.1 - the
  mirror of V2-03 §4.1's no-`@Relationship` choice, for the opposite lifecycle
  goal: V2-03 keeps its row on item deletion; V2-02 deletes its row with the
  item). The `HistorySchemaV1 → HistorySchemaV2` hop is the **single
  `MigrationStage.custom` stage** of §3.3 (DC-02, closed 2026-08-15;
  `RET-PLATFORM-1`): the schema ADD is expressed by the two versioned schemas
  (purely additive, no v1 row or column rewritten) and the hop's `didMigrate`
  performs the projection backfill — a lightweight+custom stage pair over one
  version pair is not a documented SwiftData pattern and is not used. The
  custom-stage closures run on a context the SwiftData migration machinery
  owns; this is the **sole sanctioned pre-Authority writer**, confined to the
  migration hop during container construction inside `SwiftDataHistory.open`
  (an explicit, recorded exception to the Authority-only writable-context rule,
  `05` §2, owned by M1). **Data bootstrap (not
  migration):** migration adds schema and backfills the projection, not config;
  `SwiftDataHistory.open` creates the `RetentionExpansionConfigRow` singleton
  (all policies disabled) if absent (§3.3), mirroring v1 `LastChangePositionRow`
  creation (`05` §13 step 3) and V2-01's `EnrichmentConfigRow` (`V2-01` §3.5),
  so a migrated v1 store starts v1-faithful (no V2 retention active).
  `RetainedBytesRow` rows are NOT bootstrapped at `open`; they are backfilled
  by the projection layer below.
- **Blob layer (versioned blob migration):** **no new codec.** R3 rewrites
  `RevisionStateBlobV1` (`formatVersion == 1`, shorter list, same active) — the
  v1 codec (`05` §4) encodes/decodes it unchanged; no v1 blob is reinterpreted
  and no `ContentVersion` is reinterpreted. R1/R2 use the v1 `.delete` stamping.
  A future revision-codec bump would add `RevisionStateBlobV2` and a rebuild
  (`05` §15); V2-02 does not.
- **Projection layer (rebuild):** `RetainedBytesRow` is a content-byte
  projection (§3.3b), so its adoption requires a one-time projection-REBUILD
  backfill, executed as the single custom hop's `didMigrate` step (DC-02, §3.3;
  Part V §17 layer 3; `05` §15/§17; `RET-PLATFORM-1b`). For each existing
  `HistoryItemRow` (<=
  5,000, `06` §2), the stage decodes its `canonicalSignatureBlob` (envelope
  only, no Canonical content), its `revisionStateBlob` once, **and its
  `canonicalBlob` once** — the revision codec's `05` §4 containment check
  requires the item's Canonical type set, so the full Canonical decode is a
  required input, not an optimization miss; it is a bounded one-time
  migration cost (≤ 128 MiB per item, sequential, `06` §2) and is never
  repeated on the per-commit planning path (`RET-PLATFORM-2`). *(Wording
  aligned to the M1.4 implementation, 2026-08-15: the original
  "envelope only, no Canonical content" phrase applies to the signature
  decode alone.)* The stage then writes the 1:1
  **Interruption recovery (added 2026-08-16 from the measured platform
  fact, CI run 31955551834):** SwiftData stamps the store's schema
  version before (or independently of) the custom stage's data work
  committing — a process death mid-backfill leaves a version-V2 store
  with missing `RetainedBytesRow` rows, and the stage never re-runs on
  re-open. The engine provides no interruption atomicity, so `open`
  owns the recovery: the total open order's step-7 validation first
  detects the missing-rows direction (orphans, duplicates, and version
  mismatches still fail closed immediately — they are not a producible
  interruption shape) and re-runs the idempotent full-recompute backfill
  ONCE on the Authority-owned startup context, then validates strictly.
  Recovery is exactly the "re-run reproduces (a)/(b)" outcome
  `RET-PLATFORM-1b(e)` requires; it never invents bytes
  (`V2-00` §5 decision 18) and adds no writer. A missing row discovered
  at `open` is therefore the recoverable interruption shape **by
  design**; a missing row observed through any post-open path remains
  corruption (the projection lifecycle maintains 1:1 after `open`
  returns).
  `RetainedBytesRow` (`canonicalBytes`/`revisionCount`/`revisionBytes`,
  `bytesSchemaVersion == 1`). The backfill is idempotent by construction —
  every row recomputed from the blobs, never a resumed partial write — because
  custom-stage failure semantics are undocumented (§3.3). Title/search
  projections are unaffected: R3
  pruning does not change Effective Content or its title/search projection
  (`05` §15); retirement removes rows (no projection change to survivors). The
  backfill does not invent missing active-revision bytes, reinterpret an old
  `ContentVersion`, reuse removed IDs, or enable capture before Signature Index
  / change-journal completeness is restored (`V2-00` §5 decision 18); the
  backfill completes as that `didMigrate` step inside `SwiftDataHistory.open`
  before `open` returns (so before any capture can be issued), and the
  default-disabled `RetentionExpansionConfigRow` means R2/R3 do not fire on the
  first captures regardless - V2-02 gates nothing about the v1 capture action.
  A missing row on the planning path fails closed
  `.persistence(.invariantViolation)` (§3.3b). R3 pruning
  itself removes revision IDs durably in the same commit (revision IDs are
  unique within an item, `02` §2.5 rule 2; a pruned ID is never resurrected -
  a later revision mints a new ID, mirroring item-ID non-reuse, `02` §3.3).

### Record 6 - Security boundary

V2-02 is **not external-facing** (no X1 boundary). Its security record is §9:
internal policy mutation; atomic prompt deletion (no orphan window); data-
minimization direction; no TCC/entitlement; no `OperationRecord`. The one
honest note: a store backup taken before a prune retains the pruned revisions
(a backup/restore property, not a V2-02 gate).

## 11. New invariants D23–D24 (extend `02` §14)

- **D23 Revision-pruning safety (extends D4).** R3 retention pruning removes
  only **inactive** revisions, oldest-first. It never removes the active
  revision, never changes a surviving revision's content or ID, never reorders
  survivors, and never changes Canonical Content, Effective Content,
  `ContentVersion`, title/search projections, or Signature Index postings. After
  pruning, the revision list remains D3-valid (a non-nil `activeRevisionID`
  names exactly one present revision; a non-empty list keeps a non-nil active
  ID). A pruned revision ID is never resurrected within the item. *(Extends D4's
  append-only/immutability guarantee to permit retention pruning of inactive
  revisions without weakening content immutability or the active-lineage
  invariant. Restates `V2-00` §5 decision 17 for R3.)*

- **D24 Expanded-retention completeness, victim safety, single commit, and D19
  rescoping (restates D6/D8/D13/D14; extends D19).** V2-02 keeps this as a
  single new invariant (the V2 registry (`V2-roadmap` §14) allocates D25–D28
  to V2-03 and
  D29–D31 to V2-04, so V2-02 mints only D23/D24); its four sub-claims are
  stated separately
  for testability:
  - *(a) Completeness + single commit (extends D6/D8/D14).* When one or more
    V2-02 policies are active, the expansion planner receives a **complete**
    per-item byte/revision summary (`RetentionExpansionFacts`, sourced from the
    `RetainedBytesRow` projection, §3.3b) over the **projected post-primary /
    post-R3-prune** state (D8, D14); victim selection (R1/R2) and revision
    pruning (R3) are merged with the primary mutation into **one** `MutationPlan`
    that advances `ChangePosition` **exactly once** (D6).
  - *(b) Victim safety (extends D13/D14).* R1/R2 never retire a pinned item
    (D13) or the primary (D14); R3 never prunes the active revision (D3, D23).
  - *(c) R2 byte-budget failure (orthogonal producer).* R2's
    `.storageBytes` capacity failure occurs only when pinned + primary bytes
    exceed `maxTotalBytes` and no eligible (unpinned, non-primary) victim can
    restore the bound (mirroring `06` §2's general capacity rule). It never
    retires a pinned item or the primary, and is structurally unsatisfiable only
    when pinned + primary bytes are irreducible (D13 for pinned; plan invariant
    7 / `02` §12 for the primary; D14 for the latest-state projection).
  - *(d) D19 rescoping (explicit narrowing, not a clause buried in (c)).* D19's
    universal claim ("only the global hard retained-item bound can force a
    capacity failure") is **narrowed to the count dimension** by D24: only the
    hard retained-item bound forces a *count* capacity failure, and the count
    policy alone never forces one (count floor >=1 unpinned unchanged). The
    byte-budget failure in (c) is a **new, orthogonal** producer, NOT the hard
    retained-item bound. D19's count guarantee is preserved unchanged; only its
    universal scope is narrowed. This is the explicit extension classified in
    Record 2 / §4.5 (§4.5 R-M1 resolved by `V2-00` §8(g)), not an
    undebated "preservation."
  When no V2-02 policy is active, D24 is vacuous and public behavior is
  exactly v1's (the durable `RetainedBytesRow` projection is still maintained,
  §3.3b; DC-04). *(Restates `V2-00` §5 decision 17 and §6.5 single-commit composition as
  invariants; sub-claim (d) records the D19 rescoping decision 17 (amended) now
  states explicitly.)*

These extend D1–D19: D1–D3 and D5–D18 are preserved unchanged; **D4 is
EXTENDED** (by D23, which permits retention pruning of inactive revisions)
and **D19 is EXTENDED** (narrowed to count by D24 sub-claim (d), count
guarantee preserved); none is weakened, and `RetainedBytesRow` adds no
D-invariant (coherence via `05` §15). The v1 self-review gate (`06` §10) and the V2 self-review gate
(`V2-00` §8) both apply: a mechanical scan confirms no v1 public type / schema
column / codec / invariant is redefined, and that every V2-02 type introduced —
`HistoryRetentionPolicies`, `AgeRetention`, `StorageRetention`,
`RevisionRetention`, `RetentionExpansionItemSummary`,
`CompleteRetentionExpansionInventory`, `RetentionExpansionFacts`,
`RetentionExpansionPlan`, `RetentionExpansionConfigRow`, `RetainedBytesRow`
(§3.3b), `RevisionExpansionTarget` (§6.5), the new
`HistoryAction.setRetentionPolicies` / `HistoryCommitOutcome.retentionPoliciesSet`
/ `HistoryMutation.pruneRevisions` / `HistoryMutation.setRetentionPolicies` /
`PlannedOutcome.retentionPoliciesSet` / `StampedMutation.pruneRevisions` /
`StampedMutation.setRetentionPolicies` / `CapacityKind.storageBytes` cases, and the
`planItemRetentionExpansion` / `planRevisionRetentionExpansion` functions —
does not collide with v1 names. The deleted-vocabulary scan (`06` §10, which mechanically scans `docs/`
including `docs/v2/`, per `V2-01` §11) lists **"R0 / R1 / R2 as shipped
tiers"** as a single phrase entry (a deleted generic-materialization-tier
concept, `04` §11; `V2-00` §3.1), not bare `R1`/`R2`/`R3` tokens. A scan for
that *phrase* matches it only where it is quoted in explicit rejection/history
statements (this note, and `06` §10 itself), which `06` §10 exempts. The bare
R1/R2/R3 tokens in this doc are **V2 retention capability IDs** per `V2-00` §3
(the graft-row IDs) and V2-02 dimension labels; they are not the deleted phrase
and do not match it. The V2 self-review scan therefore **passes without a
carve-out or rename**: this is a non-blocking clarity note, not an OPEN
blocker. (`V2-00` §8(i) records this ruling: bare R1/R2/R3 tokens are sanctioned
V2 retention capability IDs distinct from the deleted phrase "R0 / R1 / R2 as
shipped tiers" (`06` §10) and need no carve-out, so the scan passes without
one.) This differs from V2-01's `SourceStamp` treatment only in posture, not
in scan outcome: V2-01 **renamed** a colliding bare token (`SourceStamp` -
`EnrichmentSourceFingerprint`) because `SourceStamp` is itself a listed deleted
token; V2-02's R1/R2/R3 are not listed tokens (the listed item is the phrase),
so no rename is scan-required. A rename to AGE/BYTE/REV remains an available
clarity improvement but is not a gate.

## 12. UX interaction hooks (deferred detail to V2-07)

V2-02 provides the data hooks V2-07 (UX) consumes; it owns no SwiftUI:

- **Retention settings.** Three controls bound to `.setRetentionPolicies`: an
  age field (R1), a storage-byte budget field (R2), and per-item revision
  count/byte fields (R3). Disabling a dimension sends `nil`. The count control
  remains bound to the v1 `.setRetentionPolicy` (separate action). All rendered
  on the main actor from `HistoryCore` DTOs only (`V2-00` §6.6).
- **Configured read posture (`DEC-RET-READ`).**
  `retentionConfiguration()` returns the persisted v1 count plus the exact
  V2-02 policy bundle from one Authority interval (§8.1a). The Settings panel
  renders this state, never caller-held defaults. `HistoryConfiguration`
  remains frozen v1 (`persistence` / `initialMaximumUnpinnedItems` only,
  `05` §2; §6.4): startup configuration and durable configured-policy read are
  separate concerns. Live/current retained-byte usage remains excluded by
  OPEN-2.
- **Receipt feedback.** A `.retentionPoliciesSet(retiredItems:prunedRevisions:)`
  receipt can surface "N items retired, M older revisions pruned" to the user
  (transparent data-minimization feedback). A `.capacityExceeded(.storageBytes)`
  failure surfaces "storage budget too low for pinned items" guidance. Capture
  (R1/R2) and revise (R2/R3) fold their retirements/prunes into the primary
  receipt (`.inserted`/`.coalesced`/`.revised`), which carries no retired/pruned
  count - consistent with v1 (which also does not report count-retirements on
  capture). Those side-effects are observable to the user only via the
  `.recent`/`.search` snapshot (retired items absent) and `details(for:)` (fewer
  revisions), not via the capture/revise receipt; only `.setRetentionPolicies`
  surfaces `retiredItems`/`prunedRevisions` (§8.1).
- **Observation.** Retention retirements/prunes advance `ChangePosition` and
  yield the standard `HistoryInvalidation`, so an active `observe(.recent)` /
  `observe(.search)` reflects them via v1 snapshot replacement (`04` §5) — no
  new observation machinery. R3 pruning changes `HistoryDetails.revisions`
  (fewer revisions) on the next `details(for:)` read; no live revision-list
  observation is added. Pruning-only commits still advance `ChangePosition` by
  design (D6), so every `observe(.recent)`/`observe(.search)` subscriber
  re-fetches even though pruning inactive revisions does not change the
  recent/search snapshot (title, searchBody, effectiveTypeIdentifiers are
  unchanged, §5.2); this spurious invalidation is accepted (v1's
  position-keyed snapshot replacement cannot distinguish content-irrelevant
  commits from content-changing ones) and is a perf/UX cost of a
  `.setRetentionPolicies` that prunes across many items.
- **Accessibility / localization.** Retention setting labels and receipt
  feedback are localizable; byte/age thresholds use locale-appropriate number
  formatting (P2, V2-06, for locale-sensitive formatting).

## 12b. Interaction with sibling V2 grafts

- **V2-01 (enrichment):** R1/R2 retirement of an item orphans its
  `EnrichmentRow` exactly as v1 `.retire` does (`V2-01` §6.5) — V2-02 changes
  nothing about enrichment cleanup; the enrichment orphan sweep handles it.
  R3 pruning does not orphan enrichment rows (the item survives; only inactive
  revisions are pruned, and enrichment fences on `ContentVersion`/source
  fingerprint, which R3 does not change).
- **V2-03 (change journal):** retention retirements/prunes are History Commits
  that advance `ChangePosition`; they appear in the durable change journal as
  commits. V2-02 defines no journal kind itself; **V2-03 owns the journal
  surface** and assigns R3 prunes a distinct kind (`retireRevision`, the
  `.pruneRevisions`-alone mutation) and R1/R2 item retirements the `retire`
  kind, with a tie-break (`retire` wins when a single `.setRetentionPolicies`
  commit does both). V2-02 owns the mutations (`.pruneRevisions`,
  `.setRetentionPolicies`); V2-03 owns their journal-kind mapping - the two
  docs cross-reference each other so the journal-kind surface is unambiguous
  (reciprocal back-reference recorded for V2-03).
- **V2-06 (platform grafts):** R2 byte-summary loading on startup is a new
  non-metadata startup cost only if a startup-time retention sweep is added
  (V2-02 does no startup sweep — retention fires on capture/revise/
  setRetentionPolicies, not at startup). No G5/P1 interaction unless a future
  startup retention sweep is introduced.

## 13. Platform reference anchors

Implementation must verify against the macOS 26 SDK rather than copy pseudocode
(`05` §18, `00` §5):

- [MigrationStage.lightweight(fromVersion:toVersion:)](https://developer.apple.com/documentation/swiftdata/migrationstage/lightweight(fromversion:toversion:)) — additive schema migration (macOS 14.0+; present on macOS 26). Re-verified this cycle; both arguments are `VersionedSchema`-conforming types (`V2-facts.md` cycle-3).
- [MigrationStage.custom(fromVersion:toVersion:willMigrate:didMigrate:)](https://developer.apple.com/documentation/swiftdata/migrationstage/custom(fromversion:toversion:willmigrate:didmigrate:))
  — the data-transform sibling; since DC-02 (2026-08-15) the entire
  `HistorySchemaV1 → HistorySchemaV2` hop is **one custom stage** (schema add +
  `RetainedBytesRow` projection rebuild in its `didMigrate`, §3.3,
  `RET-PLATFORM-1/1b`, M1.4 — before
  `open` returns, never inventing bytes); `lightweight` remains the tool for
  purely-additive hops only (a later graft's hop, §3.3 incremental shipping).
  Referenced for completeness.
- [ModelContainer](https://developer.apple.com/documentation/swiftdata/modelcontainer) — automatic (lightweight) migration of additive schema preserves existing persisted data (`V2-facts.md` cycle-2 fact; behavioral prose confirming v1 rows survive the V2-02 hop).
- [FetchDescriptor propertiesToFetch](https://developer.apple.com/documentation/swiftdata/fetchdescriptor/propertiestofetch) - attribute-subset fetch mechanism (fetches whole attribute *values* for specified key paths, lazily faults the rest on access); **cannot** project an `.externalStorage` blob's byte length without materializing its content (`V2-facts.md` cycle 4: REFUTED as a size-without-content mechanism). This REFUTED result is the justification for adopting the `RetainedBytesRow` scalar projection (§3.3b) rather than an on-demand size fetch: the planning path reads the scalar column and decodes no blob (`RET-PLATFORM-2` resolved).
- Foundation `Date` / `TimeInterval` — R1 age arithmetic (`observedAt`, `now − maxAge`); v1 already uses `Date`/`TimeInterval` throughout (`02` §3.1). No macOS-26-specific API.
