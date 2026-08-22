# V2-06 — Platform Grafts (P1 startup checkpoint + P2 localized search + P3 blob streaming)

> **Status (2026-07-26):** V2 design-consolidated, scaffold proof pending. This
> doc extends the v1 specification (`00`–`06`); it redefines no v1 public type,
> `HistoryAction` case, schema column, codec, invariant (D1–D19, `02` §14), or
> proof gate. v1 behavior is owned by `00`–`06`. V2-06 owns only new surface and
> the graft of three mostly-independent platform capabilities onto the v1
> architecture: **P1** persistent startup checkpoint (`06` §3 G5), **P2**
> locale-sensitive exact search (`06` §3 G7), **P3** blob-store handle/streaming
> content abstraction (`06` §3 G8). Each is admitted only after v1 reaches
> executable specification (Part VI state 2) and after its own evidence trigger
> fires (`V2-00` §3). Like v1 at consolidation time, V2-06 is
> "design-consolidated, scaffold proof pending."

## 1. Role and boundary

V2-06 answers three independent questions, each grafted without weakening a v1
load-bearing decision:

> *P1:* After the v1 executable specification passes, can a metadata-only
> startup / Signature-Index rebuild that exceeds the G5 budget (`06` §3) skip
> the rebuild when the store is provably unchanged since last open, without ever
> serving a stale or wrong index?
>
> *P2:* Can v1 exact search's "case-insensitive literal substring" (`03b` §8) be
> enhanced to locale-sensitive matching (diacritic / width / case folding) as a
> capability-gated extension, preserving the three frozen modes and v1 search
> determinism, and without a projection migration?
>
> *P3:* Can huge content representations be stored and read without
> materializing a full `Data` value on the read path, preserving the public
> `bytes: Data` surface (`03b` §9) and changing neither logical Canonical
> content nor `ContentVersion`?

The three grafts share only the V2 graft-admission protocol (`V2-00` §4) and the
M1 migration discipline (`05` §17). They touch disjoint v1 surfaces: P1 the
startup sequence (`05` §13) and the Signature Index (`05` §12); P2 the internal
search worker (`05` §14.2, `04` §7); P3 the content codecs (`05` §4) and the
read/ingest paths (`05` §6.1, §14.3). They may be admitted, proven, and shipped
independently; V2-06 records each graft's six admission records separately
(`V2-00` §4; partitioned in §7).

V2-06 owns no `HistoryAction` case, no `HistoryMutation` case, no Domain
planner, and no change to the closed `ClipboardHistory` protocol. The Domain
(`HistoryDomain`) is untouched by all three grafts: it remains pure,
Foundation-only, and unaware that a startup checkpoint, locale folding, or a
blob-store exists. Each graft's writes route through the single
`HistoryAuthority` writer (`00` §3.3) or — for P1/P3 — are bounded,
crash-safe optimizations that never enter a History Commit's transaction
closure.

### 1.1 What is shared vs partitioned

- **Shared:** §2 (platform-verification summary), §7 (graft-admission records,
  partitioned P1/P2/P3), §8 (new invariants D37–D39), §9 (M1 migration summary
  per graft), §10 (UX hooks), §11 (open questions → proof gates), §6
  (compile/dependency/isolation, the Part VI §6 analog).
- **Partitioned:** §3 (P1), §4 (P2), §5 (P3) — each self-contained
  (scope/evidence, data model, data flow, code model, fail-safe or determinism
  discipline, proof gates, migration, invariants, UX).

## 2. Platform-verification summary (MCP facts)

V2-06 makes **no concrete platform claim without an MCP-verified citation or an
assigned V2 proof gate** (`V2-00` §8). Verified facts (cited inline; full
records in `docs/v2/V2-facts.md` cycle 7 §7.3 — promoted verbatim from the
former `.tmp/v2-research/V2-06-facts.md` sidecar on 2026-08-15, closing DC-01;
the "Fact N" references below are §7.3's numbering, which the verbatim
promotion leaves unchanged):

- **P2 — Foundation locale APIs (verified).** `NSString.localizedStandardContains(_:)`
  and `NSString.localizedStandardRange(of:)` perform a **case and diacritic
  insensitive, locale-aware** search (macOS 10.11+); `localizedStandardRange`
  returns `NSRange` (UTF-16 code-unit offsets, directly mappable to v1
  `UTF16TextRange`, `03b` §8). **The default `localizedStandard*` behavior folds
  case + diacritics only — it does NOT width-fold** (the documented description
  names only "case and diacritic insensitive, locale-aware"). The lower-level
  `NSString.range(of:options:range:locale:)` (macOS 10.5+, verified) takes an
  explicit `NSString.CompareOptions` mask **and** a `Locale`, returns an
  `NSRange` (`{NSNotFound, 0}` on no match / empty term), and compares by
  Unicode canonical equivalence — this is the verified locale+options substrate
  P2 uses to deliver CJK width folding via `.widthInsensitive` (§4.1, §4.4).
  `NSString.CompareOptions` (macOS 10.0+) exposes `.caseInsensitive`,
  `.diacriticInsensitive` ("Search ignores diacritic marks"),
  `.widthInsensitive` ("ignores width differences … as occurs in East Asian
  character sets"), `.numeric`, `.forcedOrdering`, `.anchored`, `.literal`,
  `.backwards`, `.regularExpression`. Sources: Apple docs
  `foundation/nsstring/localizedstandardcontains(_:)`,
  `foundation/nsstring/localizedstandardrange(of:)`,
  `foundation/nsstring/range(of:options:range:locale:)`, and the DocC `.md`
  alternate for `foundation/nsstring/compareoptions`.
- **P3 — `FileHandle` streaming (verified).** `FileHandle.bytes` returns a
  `FileHandle.AsyncBytes` ("The file's contents, as an asynchronous sequence of
  bytes"), an `AsyncSequence` of `UInt8` supporting `.prefix(n)`,
  `.characters`, `.unicodeScalars`, `.lines` — **macOS 12.0+** (iOS 15.0+).
  Apple's `bytes` doc names `URL.resourceBytes` as an equivalent `file://`-URL
  streaming entry point. Non-deprecated synchronous primitives:
  `read(upToCount:)`, `readToEnd()`, `write(contentsOf:)`, `seek(toOffset:)`,
  `synchronize()`, `close()`. Sources: DocC `.md` alternates for
  `foundation/filehandle`, `foundation/filehandle/bytes`,
  `foundation/filehandle/asyncbytes`.
- **P3 — `.externalStorage` opacity (verified at class level; the
  load-bearing absence claims are gated — `P3-PLATFORM-1`).** SwiftData
  `Schema.Attribute.Option.externalStorage` = "Stores the property's value as
  binary data **adjacent to the model storage**" (macOS 14.0+); the
  documentation describes a storage-location *hint* only and exposes **no public
  API to obtain a file URL** for an externally-stored blob. This forces P3's
  design away from a pure read-stream over existing `.externalStorage` (§5.2).
  Source: Apple docs `swiftdata/schema/attribute/option/externalstorage`.
- **P1 — store-change detection (verified at class level; the
  load-bearing absence claims are gated — `P1-PLATFORM-1`).** CoreData's
  `NSPersistentStoreCoordinator` can "query the metadata of a specific store"
  (macOS 10.4+), but SwiftData's `ModelContainer` does not document a public
  accessor for the coordinator or any store-generation token. P1 therefore uses
  the v1-owned `ChangePosition` singleton (`05` §3.2) — one O(1) scalar read —
  as the unchanged-detector and does not depend on a CoreData generation token
  (§3.3). Source: Apple docs `coredata/nspersistentstorecoordinator`.

Open platform questions are carried as proof gates in §3.7/§4.6/§5.7
(P1-PLATFORM-1/2, P2-PLATFORM-1/2/3, P3-PLATFORM-1..5, and the P1/P2/P3 PERF
gates).

---

## 3. P1 — Persistent startup checkpoint (G5)

### 3.1 Capability scope and evidence trigger

> **Controlling DATA-11 amendment (2026-08-22).** The checkpoint reuse path
> below predates the authoritative negative-evidence rule now owned by `05`
> §12–§13. Equality of `ChangePosition` proves that no History Commit changed
> Canonical state; it does not detect at-rest corruption of the two stored
> fingerprint copies. Therefore P1.2 may not bypass the capped Canonical xxh3
> coverage pass merely because a checkpoint matches. P1 remains blocked until
> an owning amendment either preserves that validation on every hit or
> replaces it with an equally authoritative, non-hash-derived generation
> proof. Until then the current implementation always rebuilds/validates and
> no checkpoint fast path or performance claim in this section is executable.

**Historical proposed scope, blocked by the amendment above.** A durable checkpoint of the in-memory Signature Index (`05` §12),
captured at the end of `SwiftDataHistory.open`, that lets a subsequent open
**skip** the O(retained) signature-metadata fetch + decode + posting build
(`05` §13 steps 6–8) when the store is provably unchanged since the checkpoint
was written. The checkpoint stores the serialized Signature Index paired with
the `ChangePosition` at which it was captured.

**Evidence trigger (admits design work).** Lifts `06` §3 G5 ("Persistent
startup checkpoint"). Trigger: current capped Canonical-coverage / Signature
Index rebuild **p95 > 250 ms at 5,000 items on the minimum supported hardware profile**
(`V2-00` §3 P1). Until the trigger fires, P1 is design only and reserves no v1
surface. The trigger is the *admission* bar; proof gate `P1-PERF-1` shows the
graft actually clears it (the reuse path is measurably faster than rebuild).

**Out of scope.** Checkpointing anything other than the Signature Index. In
particular, P1 does **not** checkpoint the V2-01 enrichment backlog scan or the
V2-03 change journal; those are separate derivations with their own
evidence/proof gates (V2-01 `E1-PERF-7`; V2-03). P1 does not change v1 startup
correctness, the singleton, pin-order validation, projection-schema checks, or
the corruption-fails-open rule (`05` §13). It is an **optimization only**;
correctness never depends on it (D37, §8; mirrors the cache law `04` §12).

### 3.2 Data model

A new V2 singleton row, internal to `HistoryStorage`, added in `HistorySchemaV2`
(it never appears in `HistorySchemaV1`, `05` §3, frozen):

```swift
@Model
internal final class StartupCheckpointRow {
    @Attribute(.unique)
    var key: String                     // always "signature-index"

    var positionRaw: UInt64             // ChangePosition at which indexBlob was captured
    var indexCodecVersion: UInt16       // SignatureIndexBlob codec version (currently 1)
    var signatureSchemaVersion: UInt16  // the SignatureIndex structural schema (posting shape); a bump invalidates all checkpoints

    @Attribute(.externalStorage)
    var indexBlob: Data                 // versioned SignatureIndexBlobV1 (§3.3); the serialized index
}
```

Semantic mapping:

| Column | Meaning |
|---|---|
| `key` | Singleton anchor (`@Attribute(.unique)`); exactly one row, validated on open exactly as v1 validates `LastChangePositionRow` (`05` §3.2). |
| `positionRaw` | The `ChangePosition` captured **with** the index. The fast-path unchanged-detector (§3.3): `checkpoint.positionRaw == currentDurablePosition` ⟹ no History Commit since capture ⟹ Signature set identical ⟹ index reusable. |
| `indexCodecVersion` | The `SignatureIndexBlob` codec version. A bump (codec shape change) invalidates every prior checkpoint — a stale `indexCodecVersion` forces a rebuild (D37). |
| `signatureSchemaVersion` | The Signature Index *structural* schema (posting representation). A bump invalidates every prior checkpoint independently of the blob codec. |
| `indexBlob` | The serialized Signature Index (`SignatureIndexBlobV1`). `.externalStorage` is a storage hint only (`01` §10, `05` §3.1); correctness does not depend on it. |

`StartupCheckpointRow` is a **new V2 model**. It is not a v1 schema column: it
adds a table; it does not alter `HistoryItemRow` or `LastChangePositionRow`. The
`key` column is a business-ID `@Attribute(.unique)` lookup using a bounded fetch
predicate, exactly as v1 looks up `LastChangePositionRow.key` (`05` §3.2) —
never `registeredModel(for:)` (`01` §10, `05` §18). The checkpoint is decoded
**fail-closed** like every v1 codec (`05` §4): a corrupt `indexBlob` or an
unknown `indexCodecVersion`/`signatureSchemaVersion` forces a full rebuild
(D37), never a silent partial load.

#### 3.2.1 `SignatureIndexBlobV1` codec

The serialized index is an explicit versioned wire value, not synthesized
`Codable`, mirroring v1 codec discipline (`05` §4):

```swift
internal struct SignatureIndexBlobV1: Codable, Sendable {
    let formatVersion: UInt16            // exactly 1
    let signatureSchemaVersion: UInt16   // mirrors StartupCheckpointRow.signatureSchemaVersion (self-describing)
    let entries: [StoredSignaturePostingV1]
}

internal struct StoredSignaturePostingV1: Codable, Sendable {
    let typeIdentifier: String
    let fingerprint: UInt64
    let byteCount: Int
    let itemID: UUID                      // the retained HistoryItemID posting this entry
}
```

Decode reconstructs through validators and checks, exactly as v1 codecs (`05` §4):
known `formatVersion` (exactly 1); a known `signatureSchemaVersion`; bounded
`entries` count (≤ hard retained maximum, `06` §2) before any large allocation;
normalized, unique, non-empty `typeIdentifier` per entry; valid `fingerprint`
(non-zero where v1 requires it) and `byteCount` (> 0, matching v1 `02` §2.1's
no-empty-bytes Canonical-representation rule - a `byteCount == 0` posting implies
an empty-bytes representation, which is corruption, not a valid entry); unique
`(itemID, entry)` postings. Any violation is
`.persistence(.corruptStoredValue)` / `.persistence(.invariantViolation)` (`05`
§16) - a `byteCount == 0` posting forces a fail-closed rebuild per D37 instead of
being carried in the cached index. The decoder does not silently
drop entries, deduplicate, or substitute. Round-trip equivalence is a V2 proof
gate (`P1-PLATFORM-3`).

> **Naming note (R-n2).** `SignatureIndexBlobV1`/`StoredSignaturePostingV1` are
> V2-introduced; the `V1` suffix denotes the *first version of this V2 codec*,
> not a v1-owned type. v1 owns `SignatureBlobV1` for Canonical signatures (`05`
> §4) — a distinct aggregate. There is no name collision (the v1 self-review
> scan, `06` §10, is extended to confirm); the suffix-closeness is called out
> here to avoid misreading either as v1-owned.

### 3.3 Startup data flow (reuse path vs rebuild path)

Current startup (`05` §13) keeps its recipe-v2 rebuild and version fence on
both paths; P1 adds a Signature Index reuse fast path that, when it fails,
falls back to the exact current signature rebuild. `open` performs:

```text
validate configuration and hard limits                                          [v1 §13 step 1]
open/create the ModelContainer                                                   [v1 §13 step 2]
enter HistoryAuthority; create the position singleton at 0 if a new store        [v1 §13 step 3]
validate exactly one position singleton                                          [v1 §13 step 4]
bootstrap/validate the retention-expansion config singleton                      [current §13 step 5]
rebuild every projection-schema-v1 row to recipe v2 in one transaction           [current §13 step 6]
validate retained row count ≤ hard bound; fetch ID/version/projection/pin scalars [current §13 step 7]
require projection schema version 2                                              [current §13 step 8]
P1 FAST PATH (new, all inside one non-suspending Authority interval):
  fetch LastChangePositionRow.rawValue  -> currentPosition (O(1) scalar)         [v1 §13 reads the singleton]
  fetch StartupCheckpointRow by key     -> checkpoint?   (O(1) scalar + lazy blob)
  if checkpoint is absent                                    -> REBUILD (no checkpoint yet; first open after migration/corruption)
  if checkpoint.indexCodecVersion        != CURRENT         -> REBUILD
  if checkpoint.signatureSchemaVersion   != CURRENT         -> REBUILD
  if checkpoint.positionRaw              != currentPosition -> REBUILD (a History Commit advanced position; §3.4)
  else (all checks pass):
     decode checkpoint.indexBlob (SignatureIndexBlobV1; fail-closed, §3.2.1; on decode failure -> REBUILD)
     construct the in-memory SignatureIndex from the postings (no per-row signature-blob fetch/decode)
     mark SignatureIndex state .ready (the v1 State type is
     unchanged - 05 §7.1: no generation counter; freshness is
     proved by positionRaw == currentPosition above)
     -> REUSE SUCCEEDED (skip current §13 step 9 signature fetch/decode/posting-build)
P1 REBUILD PATH (== current §13 step 9, on any fast-path miss):
  fetch each row's signature metadata after the recipe-v2 fence
  decode/validate signatures and build the complete index
current §13 step 10 (validate the full pinned ordinal set from scalar fields)     [unchanged — always runs; cheap, scalar]
current §13 step 11 (RetainedBytes correspondence/scalar validation)              [unchanged — always runs]
P1 CHECKPOINT WRITE (new; only after a successful rebuild — a successful reuse
                     implies the row already exists and is current at currentPosition, so no
                     write occurs on the reuse path):
  serialize the in-memory SignatureIndex -> SignatureIndexBlobV1
  upsert StartupCheckpointRow - update the existing uniquely-keyed row,
    insert only when absent - { positionRaw: currentPosition,
    indexCodecVersion, signatureSchemaVersion, indexBlob }
    in a separate ModelContext.transaction that writes only StartupCheckpointRow
    (during startup no History Commit is open; the write advances no ChangePosition
    and yields no HistoryInvalidation; §3.6)
current §13 step 12 (publish the SwiftDataHistory facade)                         [unchanged]
```

**Why `positionRaw == currentPosition` is a sound unchanged-detector.** Every
non-empty History Commit advances `ChangePosition` exactly once in the same
transaction as its item mutations (`04` §1.1; `05` §10), and the Signature set
changes **only** on create and delete (Canonical Content is immutable, D2; Copy
Coalescing / pin / unpin / revise / retention leave Canonical signatures
untouched, `05` §11). Therefore `checkpoint.positionRaw == currentPosition`
⟹ no History Commit occurred between checkpoint capture and now ⟹ no
create/delete occurred ⟹ the retained ID set and every retained row's Canonical
signature entries are identical to the checkpointed state ⟹ the checkpointed
index is complete and current. The detector is the v1-owned `ChangePosition`
counter (monotone by D6 and collision-free by the checked-successor rule, `02`
§13; stamping vocabulary `05` §9), not a fingerprint and not a CoreData
generation token (§2; `P1-PLATFORM-1`).
Position advance is treated
**conservatively**: any advance forces a rebuild even though the advancing
commit may have been a signature-preserving coalesce or pin — fail-safe rebuild
when in doubt (D37).

**Historical fast-path target; not currently admissible.** The pre-DATA-11
rebuild's p95 cost at 5,000 items is the
per-row signature-metadata fetch and `SignatureBlobV1` decode + posting
construction (`05` §13 step 9; `06` §9 "Index rebuild is O(retained signature
metadata)"). The reuse path replaces that with one singleton read + one
checkpoint-row scalar read + one bounded `indexBlob` decode + an in-memory
posting reconstruction. It still performs current step 10 (pin-order validation from
scalars — cheap, and required for correctness independent of the index). It does
not decode Canonical or revision blobs. That is no longer sufficient for
authoritative negative evidence; the controlling amendment above blocks this
path until the owning proof changes.

**`.memory` store.** The reuse path applies to `.memory` too: an in-process
store still has a `ChangePosition` singleton and a checkpoint row. A `.memory`
store is new each process, so its first open always rebuilds and writes a
checkpoint; subsequent re-opens within the same container lifetime may reuse.
This mirrors v1 (`.memory` changes durability medium only; `05` §2).

### 3.4 Why reuse preserves v1 (correctness)

- **The reused index is provably complete.** It was complete when checkpointed
  (it was just built by the v1 rebuild path, which is the v1 completeness proof,
  `05` §12), and `positionRaw == currentPosition` proves no create/delete
  intervened. So the served index meets the same "every retained row contributes
  every Canonical signature entry exactly once" requirement (`05` §12) as a
  freshly built one.
- **Read paths are unaffected.** Signature Index readiness affects only capture
  availability, never browse/detail/paste correctness (`05` §12). A reused
  `.ready` index satisfies capture's `Require Signature Index state .ready`
  gate (`05` §7.1 step 1) exactly as a rebuilt one does.
- **Pin order is still validated.** Current step 10 runs unconditionally on both
  paths; a reused index never bypasses pin-order validation.
- **The checkpoint is not a second persistence authority.** It is an actor-owned
  cached value materialized to disk, exactly as the in-memory Signature Index is
  an actor-owned value (`05` §12). Its loss or corruption degrades to a rebuild,
  never to wrong durable state (D37; mirrors cache law `04` §12).
- **No `ChangePosition` is minted and no History Commit is entered** by the
  checkpoint write (D5/D6 preserved; §3.6).

### 3.5 Fail-safe and integrity (the D37 rule)

The checkpoint is **correctness-irrelevant**: a correct v1 startup must be
recoverable from durable rows alone, and P1 never weakens that. Formally:

- **Missing checkpoint** (first open after M1 migration, or the row was deleted)
  → rebuild. The M1 migration adds the empty table; the first open rebuilds and
  writes the first checkpoint.
- **Stale checkpoint** (`positionRaw != currentPosition`, or
  `indexCodecVersion`/`signatureSchemaVersion` mismatch) → rebuild. A stale
  checkpoint is never relabeled current.
- **Corrupt checkpoint** (`indexBlob` decode failure, unknown codec version,
  oversize/inconsistent postings) → rebuild (fail-closed decode, §3.2.1). Decode
  failure is **not** `.persistence(.corruptStoredValue)` to the caller of `open`
  unless the subsequent **rebuild** also fails: a corrupt checkpoint is an
  optimization miss, recovered transparently by rebuild. Only a corrupt *store*
  (the rebuild path failing v1 `05` §13/§4 checks) fails `open` as
  `.persistence(.corruptStoredValue)` / `.invariantViolation`, exactly as v1.
- **Threat-model boundary (P1 honesty).** P1 correctness is conditional on the
  single-writer invariant (`00` §3.3): an out-of-band edit that mutates retained
  rows or signature blobs without advancing `ChangePosition` could be served
  stale on the fast path. The single-writer boundary is the preventive control;
  P1 adds no diagnostic hash or second O(retained) audit that would duplicate
  the rebuild it exists to avoid.
- **Crash safety.** The checkpoint is written in a separate transaction after a
  successful rebuild (never on the reuse path - the row is already current)
  and before `open` returns (§3.6). A crash before the
  write leaves no checkpoint (or a stale one) → next open rebuilds. A crash
  during the write leaves either a fully committed row or none (SwiftData
  transaction atomicity, `05` §10) → next open rebuilds. No partial index is
  ever served.

### 3.6 Code model

`StartupCheckpointRow` and `SignatureIndexBlobV1` are added to `HistoryStorage`
(part of `HistorySchemaV2`). No new actor is required: the checkpoint is read and
written by `HistoryAuthority` inside `open`, exactly where v1 reads the singleton
and builds the index. New `HistoryAuthority`-internal helpers (all opening a
fresh operation-local context and releasing it before return, `05` §5):

```swift
internal extension HistoryAuthority {
    /// Read the checkpoint row's scalar fields + lazy indexBlob. O(1) singleton fetch.
    /// Returns nil if the row is absent. Does not decode indexBlob (caller decides).
    func readStartupCheckpoint() async throws -> StartupCheckpointRow?

    /// Serialize the in-memory SignatureIndex and write StartupCheckpointRow in a
    /// separate ModelContext.transaction that writes only StartupCheckpointRow.
    /// Called only after a successful REBUILD (on the reuse path the row already
    /// exists at the current position, so no write occurs). Advances no
    /// ChangePosition; yields no HistoryInvalidation.
    func writeStartupCheckpoint(
        position: ChangePosition,
        index: SignatureIndex
    ) async throws
}
```

`writeStartupCheckpoint` runs **after a successful rebuild** and **before**
`open` publishes the facade (`05` §13 step 12). It is a separate
`ModelContext.transaction` that writes only `StartupCheckpointRow`. It touches
neither `HistoryItemRow` nor `LastChangePositionRow`, advances no
`ChangePosition`, and yields no `HistoryInvalidation` (it is not a History
Commit). Because `open` is serialized inside `HistoryAuthority` and the facade is
not yet published when the checkpoint is written, no History Commit can interleave
between the position read (fast path) and the checkpoint write — the captured
`position` is identical to the `currentPosition` tested on the fast path. After
`open` returns, subsequent History Commits advance `ChangePosition`; the next
open's fast path then observes `positionRaw != currentPosition` and rebuilds.

`SwiftDataHistory` gains no new stored field (the checkpoint lives behind
`HistoryAuthority`, already a stored field, `05` §2); the public interface
(`ClipboardHistory` conformance, `open(...)` signature) is unchanged — an
additive internal extension under the V2 self-review gate (`V2-00` §8).

### 3.7 P1 proof gates

- **P1-COMPILE-1.** Swift 6 complete strict-concurrency build succeeds;
  `StartupCheckpointRow`/`SignatureIndexBlobV1` are `internal` to
  `HistoryStorage`; `SignatureIndexBlobV1` is `Sendable` (all-`let` `Sendable`
  members) because it crosses the Authority's operation-local context boundary
  into the actor; no `@unchecked Sendable` or `nonisolated(unsafe)` introduced.
- **P1-PLATFORM-1.** Confirm on the macOS 26 SDK that SwiftData exposes no
  public store-generation token / coordinator metadata; the design does not
  depend on one (the detector is `ChangePosition`).
- **P1-PLATFORM-2.** `FetchDescriptor` reads `StartupCheckpointRow` and
  `LastChangePositionRow` scalar fields on the fast path without faulting
  Canonical/revision/signature blobs (Part VI §7.5 / `05` §14 scalar-read
  isolation); `indexBlob` is decoded only after the position check passes.
- **P1-PLATFORM-3.** `SignatureIndexBlobV1` encode/decode round-trips and
  rejects every corruption class (unknown version, unknown signature schema
  version, oversize/inconsistent postings) as fail-closed → rebuild (mirrors v1
  codec proofs, Part VI §7.4).
- **P1-PERF-1.** On the minimum hardware profile at 5,000 retained items, the
  reuse-path open p95 is below the 250 ms G5 bar and measurably faster than the
  rebuild-path open p95; correctness tests (WS14 restart reconstruction, `06`
  §8) pass unchanged with the checkpoint enabled.

### 3.8 P1 migration / invariants / UX

- **Migration (M1, §9).** Layer 1 (SwiftData schema): add the
  `StartupCheckpointRow` table, purely additive (lightweight stage, no v1 row or
  column rewritten). Layers 2/3 untouched. First open after migration rebuilds
  and writes the first checkpoint.
- **Invariants (§8).** D37 (checkpoint fail-safe). D1–D19 preserved unchanged.
- **UX.** Transparent. No new UX surface; no SwiftData/Domain leakage.

---

## 4. P2 — Locale-sensitive exact search (G7)

> **Traceability note (R-m3).** Earlier drafts titled this graft "localized
> search *projection*." That name is a misnomer: P2 changes the exact-mode
> *predicate* at **query time** (§4.2); it adds no projection column and bumps
> no `projectionSchemaVersion`. It is referenced as "localized search" / "P2"
> elsewhere in this doc; both names denote the same query-time graft.

### 4.1 Capability scope and evidence trigger

**In scope.** A capability-gated enhancement of v1 **exact** search from
"case-insensitive literal substring" (`03b` §8) to **locale-sensitive**
matching, applied at **query time** against the existing v1 scalar projections.
The folding P2 delivers is partitioned by what the platform verifies (§2):

- **Case + diacritic folding — verified.** The `localizedStandard*` family
  performs a "case and diacritic insensitive, locale-aware" search (§2, Fact 1),
  and `NSString.range(of:options:range:locale:)` (macOS 10.5+, verified §2)
  delivers the same with explicit `[.caseInsensitive, .diacriticInsensitive]`.
- **Width folding for CJK locales — delivered via a verified option.** Default
  `options: []` does **not** width-fold (the verified `localizedStandard*`
  description names only case + diacritic). CJK full/half-width equivalence — a
  stated G7 trigger use case — is delivered by adding the verified
  `.widthInsensitive` member ("ignores width differences … as occurs in East
  Asian character sets", §2, Fact 3) to the option set for CJK locales. The
  option-taking, locale-taking substrate is the verified
  `NSString.range(of:options:range:locale:)`; the Swift overlay
  `localizedStandardRange(of:options:locale:)` convenience remains OPEN
  (`P2-PLATFORM-1`).

The three frozen search modes (`03b` §8) are preserved: P2 is **not** a fourth
mode; it enhances exact's predicate only, and only while the capability is
enabled.

**Out of scope (decided, §4.2).**
- **Fuzzy and regexp are unchanged.** Fuzzy lowercases its own working copy via
  locale-ignorant `.lowercased()` (`03b` §8); locale-folding Fuse's working copy
  is a deeper change to the Fuse integration with marginal benefit on a
  threshold-approximate mode, so P2 leaves fuzzy byte-for-byte v1. Regexp
  operates on `NSRegularExpression` patterns over code units; locale-folding
  would alter pattern semantics, so regexp is left byte-for-byte v1. (Decision;
  recorded.)
- **No projection change, no projection migration.** P2 evaluates locale folding
  at query time over the existing v1 `title` / `searchBody` scalar projections
  (`05` §3.1, §14.2). It does **not** add a locale-normalized projection column
  and does **not** bump `projectionSchemaVersion` — so no Part V §17 layer 3
  projection rebuild is required (deviation from a projection-time reading of
  the brief, justified in §4.2).
- **No new public search DTO.** P2 reuses `SearchPresentation`,
  `UTF16TextRange`, `HistoryRow`, `HistoryPage` verbatim (`03b` §8); matched
  ranges remain UTF-16 offsets into the returned snippet / title.

**Evidence trigger (admits design work).** Lifts `06` §3 G7. Trigger: an
approved **product requirement for locale-sensitive matching** (e.g., a user
searching `cafe` should match `café`; a user searching hiragana should match
composing-bezier and full-width variants) **plus** a migration/normalization
behavior fixed by fixtures for the supported locales (`V2-00` §3 P2). Until the
trigger fires, P2 is design only.

### 4.2 Normalization strategy — query-time, locale-aware (decision)

P2 must choose between (a) normalizing the stored `searchBody`/`title`
projection at **projection time** into a locale-tagged form, or (b) applying
locale folding at **query time**. P2 chooses **(b) query-time**, for four
reasons:

1. **Locale correctness.** Locale-sensitive equivalence is genuinely
   locale-dependent (the Turkish dotted-`i`/`İ`, German `ß`/`ss`, Scandinavian
   `å` cases). A projection-time normalization must bake in *one* locale and is
   wrong the moment the user's locale changes; P2's locale-taking substrate
   (`NSString.range(of:options:range:locale:)`, §2) applies the **current**
   locale each query. §2 verifies the `CompareOptions` members and the
   substrate's locale+options intake — it does **not** verify locale-specific
   folding rules; whether a given equivalence (e.g., `ß`↔`ss`) is actually
   delivered by a specific (locale, options) pair is fixture-locked in §4.4 and
   gated by `P2-PLATFORM-3`, not asserted from §2.
2. **No migration.** Query-time evaluation reads the existing v1 scalar
   projections unchanged; it adds no column, bumps no `projectionSchemaVersion`,
   and triggers no Part V §17 layer 3 rebuild. This is the minimum-footprint
   graft (a projection-time design would force a 5,000-item projection rebuild).
3. **v1 cost-model fit.** v1 exact already scans all bounded scalar projections
   per query (`06` §9 — "v1 search may scan all bounded scalar projections; no
   cache is added without G2 evidence"). Replacing the per-row literal-substring
   predicate with `localizedStandardContains` is the same O(retained) scan shape
   with a heavier per-row predicate; it introduces no new scan and no cache. The
   per-query cost delta is bounded by `P2-PERF-1`.
4. **Determinism preserved per locale.** The locale-folding primitives are
   deterministic for a fixed (locale, options, input) pair; v1 search determinism
   (`04` §7 — exact/fuzzy/regexp are separate algorithms with fixture-defined
   results, stable for identical inputs) is preserved **per locale**. A locale
   change is a different input context, not a search-determinism violation. This
   is distinct from D9 (`02` §14 — the dedup *winner* tie-breaker, which is
   locale-independent and preserved unchanged by P2). Both are recorded in D38
   (§8).

The escalation path, recorded but **not** taken: if `P2-PERF-1` shows
`localizedStandardContains` is too slow at 5,000 rows for the supported locales,
a future projection-time sub-design (locale-tagged normalized column + Part V
§17 layer 3 rebuild + re-normalization on locale change) is the documented
fallback. It is not part of P2.

### 4.3 Search data flow (exact, locale-enhanced)

```text
browse(.search(text:mode:.exact)) / observe(.search(...))
  -> HistoryAuthority captures SearchCorpusSnapshot(position, scalar rows)   [v1 05 §14.2; unchanged]
  -> SearchWorker evaluates the request:
       // v1 empty-term rule runs FIRST, regardless of the P2 capability flag:
       if term.isEmpty: return .recent semantics (no SearchPresentation)      [v1 03b §8; also guards the
                                                                              //  locale primitives, whose behavior
                                                                              //  on "" is not the v1 contract]
       if LocalizedSearchConfigRow.enabled == false:                          [v1-faithful path]
          exact = case-insensitive literal substring (v1 03b §8), byte-for-byte
       else (P2 enabled):
          locale  = effectiveSearchLocale()    [configured supported locale if set, else system
                                               //  locale, else fixed fallback "en"; §4.4]
          options = effectiveSearchOptions(locale)  // [.caseInsensitive, .diacriticInsensitive] baseline
                                                    //  + [.widthInsensitive] for CJK locales (§4.4)
          for each SearchCorpusRow in default order:
             // title first, only on title miss the body (v1 03b §8 precedence preserved)
             if let r = firstLocaleRange(in: title, term, locale, options):     // r: UTF16TextRange
                matchField = .title; snippet = nil; matched = r
             else if let r = firstLocaleRange(in: searchBody, term, locale, options):
                matchField = .body
                snippet, snippetRanges = applyExcerptWindow(searchBody, r, 03b §8 algorithm)
             else:
                continue   // no match for this row
             emit HistoryRow with SearchPresentation(snippet, matchedRanges: UTF-16 ranges)
          // results preserve the default row order (v1 03b §8 exact ordering) — no cross-row re-rank
  -> HistoryPage(position, rows, cursor)                                      [unchanged public types]
```

`firstLocaleRange(in:term:locale:options:)` returns the first match as a v1
`UTF16TextRange`, or nil. It is implemented against the **verified**
`NSString.range(of:options:range:locale:)` substrate (§2: returns `NSRange`,
`{NSNotFound, 0}` ⟹ no match, macOS 10.5+, compares by Unicode canonical
equivalence). The Swift overlay
`localizedStandardRange(of:options:locale:)` convenience remains OPEN
(`P2-PLATFORM-1`); if confirmed at the SDK, the call site adapts mechanically
(its `Range<Index>?` mapped to `NSRange` through the same UTF-16 translation,
`P2-PLATFORM-2`). The `options` set is the fixture-locked per-locale set from
§4.4 — baseline `[.caseInsensitive, .diacriticInsensitive]`, plus
`.widthInsensitive` for CJK locales.

**What changes, what does not.**
- The exact predicate is replaced (when P2 is enabled) by the locale-folding
  range search above. Everything else in the v1 exact pipeline — title-then-body
  precedence, first-match-wins, default row order, the `03b` §8
  excerpt-windowing algorithm, single-snippet-per-row, UTF-16 `matchedRanges` —
  is **unchanged**.
- The locale range search returns an `NSRange` (UTF-16) over the searched
  NSString. For a title match, the range maps directly into
  `HistoryRow.title`'s UTF-16 space (`snippet == nil`, `03b` §8). For a body
  match, the range is the input to the unchanged `03b` §8 excerpt algorithm,
  which produces the ≤ 322-Character `snippet` and shifts the range into the
  snippet's UTF-16 space (the leading-ellipsis shift rule). The
  Foundation→UTF16TextRange mapping is fixture-proved (`P2-PLATFORM-2`).
- Fuzzy and regexp paths in `SearchWorker` are untouched; with P2 enabled they
  remain byte-for-byte v1.
- The public search surface (`HistoryBrowseRequest`, `SearchMode`,
  `SearchPresentation`, `HistoryPage`) is unchanged.

### 4.4 Locale, options, and fixtures

```swift
internal struct LocalizedSearchLimits: Sendable, Hashable {
    // A HistoryLimits-peer fixed value, internal to HistoryStorage
    // (not a user knob and not a modification of HistoryLimits, mirroring 06 §2).
    // The supported-locale set is the design contract D38 determinism depends on;
    // it is fixed (no "e.g.", no ellipsis) and covers every locale named as a
    // motivating case in §4.2 (de: ß/ss, ja: CJK width, nb: Scandinavian å,
    // tr: dotted-i, en: baseline):
    static let supportedLocaleIdentifiers: [String] = ["de", "en", "ja", "nb", "tr"]
    static let cjkLocaleIdentifiers: Set<String>     = ["ja"]   // locales that add .widthInsensitive
    static let maxTermUTF8Bytes: Int = 4_096           // == v1 search-term bound (06 §2)
}

// Per-locale option set, fixture-locked (§4.4). The default localizedStandard*
// family folds case + diacritics ONLY (verified, §2); width folding is NOT a
// default, so CJK width equivalence is delivered by an explicit .widthInsensitive.
internal func effectiveSearchOptions(_ locale: Locale) -> NSString.CompareOptions {
    var o: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]   // verified members (§2)
    // Compare on the language code, NOT Locale.identifier: `identifier` is
    // region-inclusive (e.g. "ja-JP"), which would never match the ["ja"] CJK
    // set for a region-tagged system locale, silently disabling width folding
    // for the default system-locale path - a stated G7 trigger use case (§4.1).
    // `locale.language.languageCode?.identifier` (Locale.Language.LanguageCode,
    // macOS 13.0+; verified via the parent property page - `V2-facts.md`
    // cycle 6, fact 16; the LanguageCode struct's own page remains 404
    // (non-load-bearing), pinned by `P2-COMPILE-1`) yields the bare
    // language code ("ja") regardless of region/script tagging.
    if let lang = locale.language.languageCode?.identifier,
       LocalizedSearchLimits.cjkLocaleIdentifiers.contains(lang) {
        o.insert(.widthInsensitive)   // verified member: "ignores width differences … East Asian"
    }
    return o
}
```

- **Effective locale.** The locale used by the locale range search is the
  configured supported locale if the user has selected one, else the system
  locale, else a fixed fallback (`"en"`). It is resolved once per query (not per
  row) and held in a `Locale` value passed to every range search, so a single
  query is deterministic.
- **`CompareOptions` (the C-M1 fix).** P2 does **not** call the locale primitives
  with `options: []`. The verified `localizedStandard*` default folds case +
  diacritics only (§2); it does **not** width-fold, so `options: []` would not
  deliver the CJK full/half-width equivalence the G7 trigger names. P2 instead
  uses a fixture-locked, per-locale option set (`effectiveSearchOptions`):
  baseline `[.caseInsensitive, .diacriticInsensitive]` (mirroring the verified
  `localizedStandard*` default), plus `.widthInsensitive` for CJK locales (the
  verified member that "ignores width differences … as occurs in East Asian
  character sets", §2, Fact 3). Every option used is a verified
  `NSString.CompareOptions` member; no undocumented option is used. The option
  set travels with the locale through the verified
  `NSString.range(of:options:range:locale:)` substrate (§2); the Swift overlay
  convenience is OPEN (`P2-PLATFORM-1`).
- **Fixtures (D38, `04` §7).** Parallel V2 search fixtures pin, per supported
  locale: (a) diacritic equivalence (`cafe`↔`café` for Latin locales; `nb`
  `å`↔`a` ring-diacritic folding — the `å`↔`aa` *digraph* spelling is NOT
  claimed, it is a spelling rule, not diacritic folding, and is not delivered
  by `[.caseInsensitive, .diacriticInsensitive]` even with `locale=nb`);
  (b) CJK width equivalence (`ja`
  full-width/half-width, e.g. `Ａ`↔`A`, exercised through `.widthInsensitive`);
  (c) locale-specific case folding (`tr` dotted-`i`/`İ`; `de` `ß`↔`ss` via
  `.caseInsensitive` + `locale=de` — sharp-S is a distinct letter, not a
  diacritic mark, so this is a locale-aware case-fold, not a diacritic fold;
  gated by `P2-PLATFORM-3`); (d) the locale range →
  UTF-16 snippet-offset translation; (e) determinism (identical query + locale ⇒
  identical ranked rows and ranges); (f) the empty-term short-circuit yields
  `.recent` semantics regardless of the capability flag (§4.3); (g) the CJK-width
  option is selected on the **language code**, so a region-tagged system locale
  (`ja-JP`) with no configured supported locale selected still yields
  `.widthInsensitive` in `effectiveSearchOptions` (regression guard for the §4.4
  membership test - the region-inclusive `Locale.identifier` path is NOT taken).
  The v1 search
  fixtures (WS17, `06` §8) are re-run **with P2 disabled** and must pass
  byte-for-byte v1.

### 4.5 Code model

`LocalizedSearchConfigRow` (capability gate) and `LocalizedSearchLimits` are
added to `HistoryStorage` (part of `HistorySchemaV2`); the locale helpers are
`internal` to `HistoryStorage`. A new public protocol `LocalizedSearchHistory`
is added to `HistoryCore` (Foundation-only, reusing `HistoryItemID` verbatim,
adding no name that collides with v1):

```swift
@Model
internal final class LocalizedSearchConfigRow {
    @Attribute(.unique)
    var key: String                  // always "localized-search"
    var enabled: Bool                // capability gate; default false (v1-faithful)
    var selectedLocaleIdentifier: String?   // nil → system locale → fallback
}

public protocol LocalizedSearchHistory: Sendable {
    func localizedSearchStatus() async throws -> LocalizedSearchStatus
    func setLocalizedSearchEnabled(_ enabled: Bool) async throws
    func setLocalizedSearchLocale(_ identifier: String?) async throws   // nil clears to system locale
}

public struct LocalizedSearchStatus: Sendable, Hashable {
    public let enabled: Bool
    public let selectedLocaleIdentifier: String?   // nil → system locale
    public let supportedLocaleIdentifiers: [String]
}
```

- `enabled == false` is the **v1-faithful mode**: exact search is byte-for-byte
  v1, the `SearchWorker` exact predicate is unchanged, and the WS17 fixtures
  pass unchanged.
- `setLocalizedSearchEnabled` / `setLocalizedSearchLocale` write only the
  `LocalizedSearchConfigRow` through `HistoryAuthority`; they are **not**
  `HistoryAction`s (they do not mutate history items and do not advance
  `ChangePosition`). **Unsupported-locale rejection (producer contract):**
  `setLocalizedSearchLocale` rejects an identifier not in
  `LocalizedSearchLimits.supportedLocaleIdentifiers` at the boundary, before the
  row is written, returning `.invalidInput` (the public `HistoryFailure` channel,
  `03b` §10) — reusing `.invalidSearchTerm` (the closest existing case: the
  identifier governs the exact-search predicate, so a bad locale identifier is a
  bad search-term-input in the v1 vocabulary sense; P2 overloads this case for
  locale-identifier rejection at the config boundary; no new enum case is added.
  `V2-00` §8(h) sanctions addition only for its six *named* enums
  (`HistoryAction`, `HistoryCommitOutcome`, `CapacityKind`, `HistoryMutation`,
  `PlannedOutcome`, `StampedMutation`) — `InvalidInputReason` is not among
  them, so a `.invalidLocaleIdentifier` case would need an 8(h) amendment
  first; P2 therefore chooses overload-reuse to minimize enum surface — the
  choice is deliberate, not
  forced by a frozen-enum prohibition). **Callers disambiguate by call-site
  context: `.invalidInput(.invalidSearchTerm)` is the locale-rejection channel
  only on `setLocalizedSearchLocale` (the config setter the caller just
  invoked), whereas the same case returned from a search method
  (`browse`/`observe` `.search`, `03b` §8 / WS17) denotes an over-long or
  otherwise invalid search-term input; the two channels never share a call
  site, so the overload is unambiguous in practice.** A `nil` identifier is
  accepted (clears to the system locale).
- **Observation self-heal on predicate change (C-M5, decision (a) — preserves
  v1 coherence).** A locale/enabling change alters the *predicate* an
  `observe(.search)` stream evaluates, not the corpus. v1's observe loop (`04`
  §5) keys re-broadcast on an invalidation whose `position >` the yielded page;
  because a predicate change advances no `ChangePosition`, that channel alone
  would leave an active `observe(.search)` silently stale (the coherence
  deviation the brief flags). P2 therefore has these config writes additionally
  yield an internal **predicate-change signal** — a `HistoryInvalidation`-peer
  wake-up (internal to `HistoryStorage`, `04` §4) carrying the **current**
  `ChangePosition` (not advancing it). The `observe(.search)` consumer is
  extended (an internal extension of a v1 *internal* type, `V2-00` §2.1) to
  honor this signal as a distinct wake condition from the position-keyed
  `HistoryInvalidation`: on a predicate-change signal it discards the current
  page and re-queries under the new predicate/locale **at the current
  position** (the corpus is unchanged, so the re-queried page carries the same
  `ChangePosition`; only the predicate/locale differs). This does **not**
  advance `ChangePosition`, does **not** violate D5/D6, and preserves `04` §5's
  race-free contract for corpus changes (which still flow through the
  position-keyed path). A non-search observer (`observe(.recent)`) ignores the
  predicate-change signal — its result does not depend on the search predicate.
  No new public invalidation surface is added (`04` §4 stays internal); a
  one-shot `browse(.search)` always re-evaluates under the current predicate, so
  it needs no signal. A predicate change also expires every in-flight search
  cursor: browse's cursor validation (04 §6 rule 1) additionally requires the
  cursor's mint predicate (enabled + locale identifier) to equal the current
  one; a mismatch maps to `.snapshotExpired(current:)`, so page 2 restarts from
  page one under the new predicate instead of resuming a page-1 anchor minted
  under the old one. (The mint predicate travels in the cursor wire form - a
  format-version bump per 04 §6 - or a process-local predicate generation is
  consulted at decode.)
- `SearchWorker`'s exact predicate is a capability-gated branch (an internal
  extension of a v1 *internal* type, `05` §14.2, per `V2-00` §2.1); the disabled
  branch is byte-for-byte v1.
- `SwiftDataHistory` conforms to `LocalizedSearchHistory`; a v1 caller that holds
  `any ClipboardHistory` and ignores it behaves exactly as on v1.

### 4.6 P2 proof gates

- **P2-COMPILE-1.** Swift 6 complete strict-concurrency build succeeds;
  `LocalizedSearchConfigRow`/`LocalizedSearchLimits` are `internal` to
  `HistoryStorage`; the locale helpers are package-internal; `LocalizedSearchHistory`/
  `LocalizedSearchStatus` in `HistoryCore` import only Foundation; no
  `@unchecked Sendable` introduced.
- **P2-PLATFORM-1.** Confirm the Swift `String` overlay signature
  (`localizedStandardRange(of:options:locale:)` returning a `Range<Index>?`) on
  macOS 26. OUTCOME (stated regardless): P2's locale-folding range search is
  implemented against the **verified** `NSString.range(of:options:range:locale:)`
  substrate (§2, macOS 10.5+, returns `NSRange`, accepts `CompareOptions` +
  `Locale`) — the overlay is only a convenience. The folding behavior itself
  (case + diacritic via `.caseInsensitive`/`.diacriticInsensitive`; CJK width via
  `.widthInsensitive`) is fully verified through the `CompareOptions` members
  (§2, Fact 3).
- **P2-PLATFORM-2.** Three fixture-proved stability properties across the
  supported locales: (a) the locale range `NSRange` → `UTF16TextRange` →
  snippet-offset translation is stable (no locale-dependent index drift; `03b`
  §8 excerpt algorithm preserves UTF-16 semantics); and (b) **projection-input
  safety** — locale folding over the v1 *normalized and truncated* `title` /
  `searchBody` scalar projections (`05` §15; `06` §2: `searchBody` ≤ 256 KiB
  UTF-8) matches folding over the raw Effective Content for the supported
  locales within the projection bounds; and (c) browse cursor expiry - a
  search cursor minted under one predicate (enabled + locale identifier) and
  validated under a changed one maps to `.snapshotExpired(current:)` so page 2
  restarts from page one under the new predicate, while a cursor minted and
  validated under the same predicate survives (§4.5). P2's locale equivalence
  is **defined
  over the projection** (the value v1 search already operates on, `03b` §8); if
  a projection's normalization form (NFC/NFD) or grapheme-boundary truncation
  is shown to alter folding for any supported locale, that case is recorded as
  a fixture-locked deviation, never a silent mismatch.
- **P2-PLATFORM-3 (locale-specific case folding).** Fixture-prove that the
  verified `range(of:options:range:locale:)` substrate with `locale=de` and
  options `[.caseInsensitive, .diacriticInsensitive]` actually delivers the
  German `ß`↔`ss` equivalence named in fixture (c) (sharp-S is a distinct
  letter, not a diacritic mark, so `ß`↔`ss` is a locale-aware case-fold, not a
  diacritic fold — `.diacriticInsensitive` alone does not deliver it). The
  fixture asserts both directions (`strasse`↔`Straße`). OUTCOME (stated
  regardless): if the substrate does not deliver `ß`↔`ss` under that pair, the
  `de` case-fold row is dropped from the delivered equivalence set and recorded
  as a locale-specific deviation; the `cafe`↔`café` and `å`↔`a` diacritic folds
  are delivered by `.diacriticInsensitive` independent of this gate.
- **P2-PERF-1.** Locale-sensitive exact search p95 and correctness across the
  supported locales within the v1 search cost model (`06` §9); if exceeded, the
  documented projection-time escalation path (§4.2) is opened as a separate
  sub-design.

### 4.7 P2 migration / invariants / UX

- **Migration (M1, §9).** Layer 1 (schema): add `LocalizedSearchConfigRow`,
  additive. **Layers 2 and 3 untouched** — no blob change, **no projection
  rebuild** (P2 is query-time). First open after migration bootstraps the
  singleton `enabled == false` (v1-faithful).
- **Invariants (§8).** D38 (locale-equivalence + per-locale search determinism).
  D9 (dedup winner tie-breaker, locale-independent) preserved **unchanged**; v1
  search determinism (`04` §7) preserved **per locale**; D1–D19 unchanged.
- **UX.** A supported-locales setting + enable toggle (full surface in V2-07).
  No SwiftData/Domain leakage.

---

## 5. P3 — Blob-store handle / streaming content abstraction (G8)

### 5.1 Capability scope and evidence trigger

**In scope.** A V2 **blob-store tier** for individual content representations
whose byte count exceeds an inline threshold, storing their bytes as
**process-owned files** referenced by a versioned handle, and a streaming
**read** abstraction over those files via `FileHandle.AsyncBytes` (verified,
§2) that avoids materializing a full `Data` on the read path. The public
`PastePayload.representations: [HistoryRepresentation]` with `bytes: Data`
(`03b` §9) is **preserved** (option a): callers that want `Data` get it on
demand, with no memory regression versus v1; the memory win is delivered through
a **new public `HistoryCore` streaming protocol** (`BlobStreamingHistory`,
§5.4 / C-M2: public, not `internal` to `HistoryStorage` - V2-07 consumes
it across the target-graph boundary) for opt-in chunked consumption.

**Out of scope.**
- **Remote / network blob storage.** P3 is **local** file-handle streaming only
  (`V2-00` §3.1).
- **Changing logical Canonical/revision bytes or `ContentVersion`.** P3 changes
  the *physical storage medium* (inline `Data` ↔ process-owned blob file) behind
  a versioned blob codec. Logical content and `ContentVersion` are unchanged;
  the v1 byte limits (`06` §2) are unchanged.
- **A pure read-stream over existing `.externalStorage`.** Verified infeasible
  through public API: SwiftData `.externalStorage` is an opaque "adjacent to the
  model storage" hint with no documented file-URL accessor (§2, Fact 8). Meeting
  the G8 memory OUTCOME therefore requires the blob-store tier; this is a
  deviation from a "read-only over `.externalStorage`" aspiration, **forced** by
  the verified platform fact, recorded in Record 1/2 and carried as
  `P3-PLATFORM-1`.

**Evidence trigger (admits design work).** Lifts `06` §3 G8. Trigger: a
representative **capture- or read-path** workload **exceeds its memory
budget** (read-path evidence: peak transient hydration RSS and aggregate
resident DTO bytes under representative concurrent callers) or shows **p95
copy cost unsolvable within the bounded inline-value design** (`06` §3 G8
verbatim; the `V2-00` §3 P3 row matches). Until the trigger fires, P3 is
design only.

### 5.2 Platform finding and storage-tier decision

The brief's candidate design — "a `FileHandle`-based streaming abstraction over
existing `.externalStorage`" — was MCP-verified as **not available through
public API** on macOS 26: `Schema.Attribute.Option.externalStorage` documents
no file-URL accessor (§2, Fact 8; `01` §10 / `05` §3.1 already state the hint is
opaque). A read over `.externalStorage` therefore materializes the full `Data`
on fault, which does **not** meet the G8 memory-budget OUTCOME for near-max-size
representations (up to 64 MiB/rep, `06` §2).

P3 therefore stores large representations as **process-owned blob files**
(streamable via `FileHandle.AsyncBytes`, verified macOS 12.0+, §2) referenced by
a **versioned handle**, and migrates the content codecs from V1 to V2
(`CanonicalBlobV1 → CanonicalBlobV2`, `RevisionStateBlobV1 →
RevisionStateBlobV2`) so a representation is either inline (small) or
handle-backed (large). This is a **Part V §17 layer 2 (versioned blob)
migration**: no SwiftData schema column is added (the existing `canonicalBlob`/
`revisionStateBlob` `Data` columns now carry the V2-encoded codec, which is tiny
for large-rep items), no projection is changed, and `ContentVersion` is
unchanged. The required OUTCOME — "huge-blob reads must not materialize the full
value into a single consumer buffer; peak read-path memory within the G8 budget"
— is met regardless of the `.externalStorage` opacity finding, and the finding
itself is locked by `P3-PLATFORM-1`.

### 5.3 Data model

A new V2 admission bound, `BlobStoreLimits` (a `HistoryLimits`-peer fixed value,
`internal` to `HistoryStorage`, not a user knob and not a modification of
`HistoryLimits`, mirroring `06` §2):

| Bound | V2 value |
|---|---:|
| Inline threshold (rep byte count at/above which the rep is handle-backed) | 1 MiB |
| Blob-file read chunk size (streaming residency target, not enforced) | 256 KiB |
| Per-item blob-file count (== rep count; bounded by 06 §2's 32 reps/capture and 100 revisions/item) | derived, not a new knob |

Rules (matching `06` §2): the inline threshold is a fixed admission boundary
tested at the codec boundary, not a runtime tuning knob; all byte-count
arithmetic is checked and never wraps (`02` §13, `06` §2); the same v1
representation/capture/revision byte limits (`06` §2) apply unchanged — P3
changes the medium, not the limits.

#### 5.3.1 Versioned V2 content codecs

`CanonicalBlobV1` and `RevisionStateBlobV1` (`05` §4) are **frozen**. P3
introduces V2 codecs whose stored-representation is an inline-or-handle enum:

```swift
internal struct CanonicalBlobV2: Codable, Sendable {
    let formatVersion: UInt16       // exactly 2
    let representations: [StoredCanonicalRepresentationV2]
}

internal enum StoredCanonicalRepresentationV2: Codable, Sendable {
    case inline(typeIdentifier: String, bytes: Data, fingerprint: UInt64)   // bytes < inlineThreshold
    case handle(StoredBlobHandleV1)                                          // bytes >= inlineThreshold
}

internal struct RevisionStateBlobV2: Codable, Sendable {
    let formatVersion: UInt16       // exactly 2
    let revisions: [StoredRevisionV2]
    let activeRevisionID: UUID?
}

internal struct StoredRevisionV2: Codable, Sendable {
    let id: UUID
    let createdAt: Date
    let representations: [StoredRepresentationV2]
}

internal enum StoredRepresentationV2: Codable, Sendable {
    case inline(typeIdentifier: String, bytes: Data)
    case handle(StoredBlobHandleV1)
}

internal struct StoredBlobHandleV1: Codable, Sendable {
    let formatVersion: UInt16       // exactly 1
    let typeIdentifier: String
    let byteCount: Int              // == the blob file's exact length; checked on read
    let xxh3: UInt64                // xxh3-64 over the blob file bytes (evidence-not-identity, D7; integrity check, §5.5)
    let relativePath: String        // relative to the blob-store root; opaque, app-generated, non-user-facing
}
```

Decode reconstructs through validators and checks, exactly as v1 codecs (`05` §4):
known `formatVersion` (exactly 2 for the V2 codecs, 1 for the handle); bounded
`byteCount` (≤ the per-representation 64 MiB limit, `06` §2) before any
allocation; for `.handle`, the `relativePath` is confined to the blob-store root
(no `..`, no absolute path, no escape — verified at decode, §5.5); for `.inline`,
the same v1 normalization/uniqueness/non-empty rules. The fingerprint coverage
bidirectional check (`05` §4) is preserved: every Canonical representation —
inline or handle — has a signature entry and vice versa. Any violation is
`.persistence(.corruptStoredValue)` / `.persistence(.invariantViolation)`
(`05` §16). `SignatureBlobV1` (`05` §4) is **unchanged** — signatures
are metadata, not large-byte payloads.

> **Handle `xxh3` semantics (Lens B).** `StoredBlobHandleV1` is shared by
> Canonical reps (`StoredCanonicalRepresentationV2.handle`) and revision reps
> (`StoredRepresentationV2.handle`). The `xxh3` field means different things at
> the two call sites, matching v1's own distinction (`05` §4): for a **Canonical**
> rep the handle's `xxh3` **is** the Canonical signature fingerprint (the
> bidirectional-coverage source, `05` §4); for a **revision** rep the handle's
> `xxh3` is **read-integrity evidence only** (v1 `StoredRepresentationV1` carries
> no Canonical fingerprint, and P3 does not add one). In both cases the field is
> evidence, never identity (D7). The shared type keeps a single decode path;
> the role distinction is enforced by which codec wraps the handle.

The V2 codecs are `Sendable` (all-`let` `Sendable` members) because, like v1's
`PreparedCaptureBundle` (`05` §6.1), they cross the Authority's operation-local
context boundary into the actor.

#### 5.3.2 Blob-store layout

Blob files live under a per-store blob directory derived from the store URL
(e.g. `<storeURL>.blobs/`), outside the SwiftData store file. `relativePath` is
an app-generated, non-user-facing unique filename — a flat or sharded name
incorporating the xxh3 (as a sharding/diagnostic hint) plus a per-write
random nonce drawn from the injected ID source (`01` §4); the blob file is
created exclusively via POSIX `open(2)` with
`O_CREAT|O_EXCL` (atomic check-and-create; `FileManager.createFile`
overwrites and is NOT exclusive, `FileHandle(forWritingTo:)` does not
create - `V2-facts.md` cycle 6 fact 14) and a name collision
(`-1`/`EEXIST`) retries with a fresh nonce - uniqueness is mechanized,
not asserted — confined to the root at decode.
This is **not** content-addressing: two writes of identical bytes produce
different filenames
(different nonce), so the blob tier provides **no** blob-store-level dedup,
deliberately — dedup lives at the Canonical-signature layer (D7), and
collision-driven dedup at the blob tier would be unsound because xxh3 is
evidence-not-identity. The blob-store root is created at `open` (alongside the
v1 ModelContainer creation, `05` §13 step 2).

> **`.memory` store (Lens A).** v1's `.memory` discipline is that `.memory`
> "changes durability medium only" — an in-memory store that writes **nothing**
> durable (`05` §2). P3 preserves that exactly: for a `.memory` store, the
> inline threshold is **bypassed** — every representation stays `.inline` in the
> in-memory store and **no blob files are ever written**. This avoids the
> durability-medium change that writing multi-MiB temp blob files would
> introduce (files that survive on disk after process exit). The capture-path
> code path is the same; only the inline/handle decision is forced to `.inline`
> for `.memory`.

### 5.4 Capture and read data flow

**Capture (write path).** Large-representation blob files are written
**off the commit interval**, in `IngestPreparationActor` (`05` §6.1), exactly
where v1 fingerprints and normalizes:

```text
IngestPreparationActor.prepare(raw):                                        [v1 05 §6.1 order, unchanged]
  ... reject empty / hard-limit / invalid types; sort; reject duplicates ...
  compute xxh3-64 for every remaining representation                        [v1 step 5]
  for each representation whose byteCount >= BlobStoreLimits.inlineThreshold:
     write bytes to a new blob file under the blob-store root (fsync; §5.5)
     replace the in-memory representation with .handle(StoredBlobHandleV1{ ... })
  // representations below the threshold stay .inline(bytes) — the v1 path
  construct validated Canonical Content + signature entries                 [v1 step 6]
  project initial title/search/type summary                                 [v1 step 8]
  -> PreparedCaptureBundle carrying CanonicalBlobV2 (inline/handle mix)
```

The History Commit's transaction (`05` §10) then writes the V2-encoded
`canonicalBlob` (tiny for large-rep items) to `HistoryItemRow.canonicalBlob`.
The commit closure performs **no file I/O** — the blob files already exist on
disk before the commit, and the commit writes only the small V2 codec `Data`.
This preserves v1's "no pasteboard access / fingerprinting / projection in the
commit interval" rule (`05` §6.1): the blob-file write is preparation work,
outside the closure, like fingerprinting.

**Revision.** `RevisionPreparationActor` (`05` §6.2) applies the same
inline/handle split when preparing a revision's proposed Effective Content;
`RevisionStateBlobV2` carries the result. The two-phase OCC (`05` §6.2) is
unchanged.

**Detail / paste (read path).** `details(for:)` / `pastePayload(for:)` (`05`
§14.3) decode the V2 codec. For an `.inline` rep, v1 behavior is unchanged. For
a `.handle` rep, the Authority resolves the absolute path (root + relativePath),
verifies `byteCount`/`xxh3` lazily per the integrity policy (§5.5), and reads
the bytes. The public `PastePayload.representations` still carry `bytes: Data`
(option a): a handle-backed rep is materialized into `Data` on demand for a
caller that asks for `Data` — **no memory regression versus v1** (v1 also handed
the caller the full `Data`), and the same v1 byte limits apply.

**Streaming read (the memory win).** A new **public `HistoryCore` protocol**
exposes chunked/streamed reads so a caller that does **not** need the whole
`Data` never materializes it. Per the C-M2 decision, this protocol is **public
in `HistoryCore`** (Foundation-only — `BlobReadStream` uses only
`FileHandle`/`URL`/`Data`), not `internal` to `HistoryStorage`: v1's target
graph (`01` §8) forbids PresentationUI from importing `HistoryStorage`, and V2-07
(large-attachment preview/export, a PresentationUI feature) must consume it
across that boundary. The only Foundation-only public surface V2-07 may consume
is `HistoryCore`. Reusing `HistoryItemID`/`ContentVersion` verbatim, it adds no
name colliding with v1:

```swift
// In HistoryCore (Foundation-only public surface).
public protocol BlobStreamingHistory: Sendable {
    /// Stream a representation's bytes without materializing the full Data.
    /// Returns nil for inline reps below the streaming threshold (caller falls
    /// back to the `bytes: Data` surface). For handle-backed reps, vends
    /// FileHandle.AsyncBytes (macOS 12.0+, verified §2) bounded by
    /// BlobStoreLimits.readChunkSize.
    ///
    /// contentVersion fence: at stream-open the Authority requires the item's
    /// current ContentVersion to equal the requested one (mirroring v1 `04` §9
    /// step 2 thumbnail fence). On mismatch the call returns nil (the caller
    /// falls back to the `bytes: Data` surface) rather than streaming a stale
    /// representation; a nil return is therefore also the stale signal, not only
    /// the inline-threshold signal. Mid-stream revision/deletion is covered by
    /// the C-M3 residual (§5.5).
    func streamRepresentation(
        _ id: HistoryItemID,
        canonical: Bool,                   // true = Canonical rep, false = current Effective rep
        typeIdentifier: String,
        contentVersion: ContentVersion
    ) async throws -> BlobReadStream?
}

public struct BlobReadStream: Sendable {
    // Sendability is a required OUTCOME gated on P3-PLATFORM-4 (§5.7): Apple docs
    // do not state FileHandle.AsyncBytes: Sendable. If it is not Sendable on macOS
    // 26, bytes is vended through an actor-confined/buffered Sendable adapter
    // instead of stored directly - never @unchecked Sendable.
    public let bytes: FileHandle.AsyncBytes   // or URL.resourceBytes (§2); AsyncSequence<UInt8>
    public let byteCount: Int
    public init(bytes: FileHandle.AsyncBytes, byteCount: Int) { ... }
}
```

`BlobReadStream.bytes` is consumed with `for await byte in stream.bytes` or
`.prefix(n)`/`reduce(into:)` patterns; peak residency is bounded by the chunk
size, not the file size (`P3-PLATFORM-2`). readChunkSize is a residency
TARGET, not an enforced bound: the vended FileHandle.AsyncBytes exposes no
public chunk control. If P3-PLATFORM-2 shows its internal buffering exceeds
the target, BlobStore.openStream vends a chunked adapter (repeated
read(upToCount: readChunkSize)) instead of the raw AsyncBytes. The v1 public
surface
(`PastePayload.representations: [HistoryRepresentation]`, `bytes: Data`) is
**unchanged** — a v1 caller that holds `any ClipboardHistory` and ignores
`BlobStreamingHistory` behaves exactly as on v1. `SwiftDataHistory` conforms to
`BlobStreamingHistory` additively. V2-07 consumes this protocol (no public DTO
change beyond the protocol itself); §6 and the P3 Record note the one new public
`HistoryCore` surface.

### 5.5 Blob-store integrity, GC, and crash safety

- **Path confinement (security).** `StoredBlobHandleV1.relativePath` is verified
  at decode to be confined to the blob-store root: no absolute path, no `..`
  traversal, no symlink escape. A handle whose resolved absolute path escapes
  the root is `.persistence(.corruptStoredValue)` (`05` §16). The blob-store
  root is app-owned; no user-controlled path is accepted.
- **Integrity (evidence-not-identity, D7) and the streaming integrity window
  (C-M3).** `StoredBlobHandleV1.xxh3` is evidence, never identity (D7, `02`
  §2.2). xxh3 is a **whole-file** hash, so it cannot be evaluated until every
  byte has been consumed; the prior "verify xxh3 lazily for streaming
  first-chunk" phrasing was incoherent and is dropped. Read-time integrity is:
  (i) the file's `byteCount` is checked exactly up-front (`stat` against the
  handle's `byteCount`, fail-closed on mismatch — this catches *length-changing*
  corruption before any byte is vended); (ii) xxh3 is verified over the full
  contents. The two read paths differ in **when** (ii) completes:
  - **Detail / paste (full materialization).** All bytes are read into `Data`
    before return, so xxh3 is checked **eagerly**; a mismatch (length-preserving
    or not) throws `.persistence(.corruptStoredValue)` before the caller sees
    any byte. Same strength as v1.
  - **Streaming (`BlobStreamingHistory`).** `byteCount` is checked up-front, but
    xxh3 is computable only at **stream end**. A **length-preserving** bit-flip
    in the blob file therefore evades detection until the entire stream has been
    consumed; a streaming consumer **may receive wrong bytes before the xxh3
    mismatch fires** at stream end, at which point the consumed iterator throws
    `.persistence(.corruptStoredValue)` — **fail-closed after the fact**. This
    streaming integrity window is strictly weaker than detail/paste and is the
    documented residual. The `contentVersion` fence (§5.4) is checked at
    **stream-open**, so a revision observable at open time returns nil rather
    than streaming a stale rep. A revision/deletion that lands **mid-stream**
    (after open, before the iterator completes) is not fence-caught. Under POSIX
    semantics, however, the orphan sweep `unlink`s the blob file while
    `BlobReadStream`'s `FileHandle.AsyncBytes` sequence still holds the
    underlying `FileHandle` (and its descriptor) open for the iteration;
    `unlink` preserves the inode until the last descriptor closes, so on the
    plain unlink-during-stream path the iterator **completes with the
    pre-revision bytes** (no throw). (POSIX-documented, not Apple-doc:
    `V2-facts.md` cycle 6 fact 15; the P3-PLATFORM-2/5 gates remain
    load-bearing for the Foundation iterator layer) The
    fail-closed-after-the-fact residual above therefore applies to
    **length-preserving bit-flip corruption** and to
    any platform path that re-validates the handle or re-opens the file
    mid-stream — **not** to the plain unlink-during-stream case. If
    `P3-PLATFORM-2`/`P3-PLATFORM-5` were to demonstrate a throw on the plain
    unlink path, the residual would be re-scoped to include it. If a consumer requires end-to-end byte-identity *before
    any byte is vended*, it must either (a) full-materialize via the `Data`
    surface (eager xxh3, sacrificing bounded-memory for that read) or (b) accept
    the documented residual. P3 does not add a full pre-pass hash to the
    streaming path (it would defeat bounded-memory, the G8 OUTCOME). xxh3 is the
  v1 fingerprint primitive (`01` §4); reuse keeps P3 on the v1 evidence
  discipline.
- **Orphan blob files (decoupled cleanup).** Blob-file reclamation is
  **decoupled** from the v1 delete mutation, exactly as V2-01 decouples
  enrichment-row cleanup (V2-01 §6.5): the v1 retirement `HistoryMutation.retire`
  (`02` §7) stays byte-for-byte unchanged — it deletes `HistoryItemRow` and
  advances `ChangePosition` only. Blob files referenced only by the retired row
  become orphans. A bounded `sweepOrphanedBlobFiles()` Authority pass derives
  the live blob-handle set by scanning all retained rows' V2 codecs (O(retained),
  bounded by `06` §2; background, every Nth operation and on open) and deletes
  blob files not in the live set (the in-flight set is also excluded, so a blob
  file written but not yet committed is never swept - C-M6 below). Because the
  live-set scan is O(retained) and
  background, an inactive user's orphaned blob files linger until the next app
  launch (the open sweep) — the security record states this retention window
  honestly (Record 6). The **open sweep is deferred past the G5-critical startup
  path** (it runs after the facade is published, not inside `open`'s startup
  latency), so it does not stack on P1's 250 ms startup budget (`P3-PERF-1`); its
  amortized cost is bounded as a background tax (`P3-PERF-1`). A blob file
  referenced by no row is unrecoverable content (its row is gone); deleting it
  leaks no logical history.
- **In-flight blob handles (the capture/sweep race, C-M6).** Unlike V2-01
  enrichment rows (which are SwiftData rows written through `HistoryAuthority`,
  with no out-of-Authority window), a P3 blob file is written by
  `IngestPreparationActor` via `BlobStore` **before** the History Commit's
  transaction writes the referencing V2 codec row (`05` §6.1, §5.4). The
  live-handle set is derived from **committed** rows only, so a blob file in
  this written-but-not-yet-committed window is not in the live set; a sweep
  running in that window would delete the in-flight file and produce a
  committed row with a dangling handle that fails `.corruptStoredValue` at
  read. `BlobStore` therefore tracks an **in-flight set**:
  `write(bytes:typeIdentifier:)` registers the new `relativePath` in the
  in-flight set, and `HistoryAuthority` confirms the commit by calling
  `BlobStore.commitHandle(relativePath:)` (after the History Commit's
  transaction commits the referencing codec row), which moves the path to the
  durable-tracked set. `sweepOrphans(liveHandles:)` excludes both the
  `liveHandles` set AND the in-flight set - an in-flight file is never swept.
  An in-flight handle whose commit never arrives (the capture aborts after the
  blob write, or the process crashes before `commitHandle`) is reaped by a
  bounded age-out sweep of the in-flight set so the in-flight set cannot grow
  unboundedly. Because SwiftData transaction latency is not bounded under disk
  pressure/contention, the reap is **commit-aware**: it reaps only in-flight
  paths whose owning capture/revision has demonstrably aborted or rolled back
  (the Authority records an abort/rollback outcome for that preparation), not
  paths that have merely aged past a fixed interval. Where a non-aborted commit
  is still genuinely in flight, a conservatively large grace interval is used;
  the residual slow-commit + age-out race (a real, non-aborted commit outliving
  the grace interval) is a **fail-closed data-loss residual for the affected
  representation** — the committed row's next read throws
  `.persistence(.corruptStoredValue)` (D2/D39: never wrong bytes), recorded as
  a boundary here rather than presented as a sound bound on commit latency. A WS20-style concurrency-harness proof (`P3-PLATFORM-5`, §5.7)
  drives a capture/sweep interleaving - a sweep triggered while
  `IngestPreparation` has written a blob file but before the capture's History
  Commit runs - asserting the in-flight file is not deleted and the committed
  item reads back correctly.
- **Crash safety.** A blob file written by `IngestPreparation` before a commit
  that then **fails/aborts** becomes an in-flight file held by `BlobStore` (age-reaped later, §5.5 C-M6) — no correctness
  impact (the row was never committed). A blob file written and committed, then
  later corrupted/deleted on disk, fails closed at read (`.corruptStoredValue`),
  mirroring v1's corruption-fails-open rule for the *store* (`05` §13) — but a
  missing blob file is recoverable only if a revision/Canonical copy exists; if
  the sole copy is gone, the item is corrupt (never silently substituted, D2).
  The blob-store is a physical medium; its loss degrades to a typed persistence
  failure, never to wrong bytes (D39).
- **Durability boundary (C-M4).** P3 trades SwiftData-atomic blob storage
  (`.externalStorage`, whose sidecar write is atomic with the row transaction
  inside the SQLite store file set) for **app-managed sidecar files** under
  `<storeURL>.blobs/` that are *outside* SwiftData's transaction control and are
  written by a separate, earlier `IngestPreparation`/`BlobStore` file write.
  This is a durability-regression side effect of meeting the G8 memory OUTCOME,
  recorded honestly: (i) **backup / restore / sync MUST capture `<storeURL>.blobs/`
  alongside the SwiftData store** — an operation that captures the store but
  misses `.blobs/` produces items whose handle-backed representations decode but
  fail `.corruptStoredValue` at read, where v1 (inline/`.externalStorage`) would
  have survived; (ii) **single-blob-file loss degrades the item** to
  `.corruptStoredValue` for the affected representation (D2: never silently
  substituted); (iii) **no inline fallback exists for handle-backed
  representations after migration** — once a representation is migrated to a
  handle (§5.8 eager migration), the inline copy is gone and a lost blob file is
  unrecoverable unless a revision/Canonical copy survives. This boundary is
  recorded in Record 6; it is not a memory regression (the `Data` surface has no
  memory regression vs v1, §5.4) but a durability-medium change.
- **Equivalence (D39).** A handle-backed representation is byte-identical to the
  inline `Data` it replaces: streaming and full materialization produce the same
  bytes; the inline↔handle choice is governed solely by the inline threshold and
  is invisible to logical content, `ContentVersion`, the Signature Index, dedup
  (which uses Canonical signatures, not storage medium), and the byte limits.

### 5.6 Code model

A new `BlobStore` actor (`internal` to `HistoryStorage`) owns blob-file I/O:

```swift
internal actor BlobStore {
    private let rootURL: URL                 // blob-store root; created at open
    private var inFlight: Set<String> = []   // written-but-not-yet-committed relativePaths; §5.5 C-M6
    // Owns file I/O; creates FileHandle.AsyncBytes streams; performs orphan sweeps.
    // Sendable (actor). Holds no @Model / ModelContext; never opens a writable
    // ModelContext (all row writes go through HistoryAuthority, preserving 00 §3.3).
    func write(bytes: Data, typeIdentifier: String) async throws -> StoredBlobHandleV1
    func commitHandle(relativePath: String) async throws                  // HistoryAuthority calls after the commit; §5.5 C-M6
    func openStream(_ handle: StoredBlobHandleV1) async throws -> BlobReadStream
    func materialize(_ handle: StoredBlobHandleV1) async throws -> Data   // for the Data surface
    func sweepOrphans(liveHandles: Set<String>) async throws              // bounded; excludes inFlight too; §5.5
}
```

`SwiftDataHistory` gains a `BlobStore` stored field (an `actor`, so the derived
`Sendable` conformance is preserved, `01` §6). Each admitted graft appends its
own actor fields — there is no single global count while grafts compose, and
v1's "five actor stored fields" (`05` §2 / `01` §6) is superseded by the M1
field ledger; P3's own contribution is one `BlobStore` field;
the change is acknowledged here under the V2 self-review gate (`V2-00` §8), not
a silent edit to those v1 statements — `BlobStore` is an `actor`, so each field
remains `Sendable` and the derived conformance holds. `IngestPreparationActor`
and `RevisionPreparationActor` gain a `BlobStore` reference for large-rep writes;
`HistoryAuthority` gains `streamRepresentation`/`sweepOrphanedBlobFiles`/
`commitHandle` helpers (all opening a fresh operation-local context, `05` §5;
`commitHandle` is called after a History Commit commits the referencing codec
row, confirming the blob file is no longer in-flight, §5.5 C-M6).

**Public-surface placement (C-M2).** `BlobStreamingHistory` and `BlobReadStream`
are `public` in **`HistoryCore`** (Foundation-only), not `internal` to
`HistoryStorage`. The `BlobStore` actor stays `internal` to `HistoryStorage`;
`HistoryAuthority.streamRepresentation` is the bridge that satisfies the public
protocol by opening a `BlobStore.openStream` against a decoded handle, without
exposing `BlobStore`/`StoredBlobHandleV1`/`relativePath` across the target
boundary. The source gate (`01` §9) is unchanged: P3 uses only Foundation
(`FileHandle`, `URL`, `Data`); it adds no framework import; `HistoryCore` still
imports only Foundation. The closed `HistoryAction` switch (`05` §8) is
unchanged.

### 5.7 P3 proof gates

- **P3-COMPILE-1.** Swift 6 complete strict-concurrency build succeeds;
  `BlobStore` is an `actor` (Sendable); V2 codecs and `StoredBlobHandleV1`/
  `BlobReadStream` are `Sendable` (all-`let` `Sendable` members); no
  `@unchecked Sendable`/`nonisolated(unsafe)` introduced; `FileHandle.AsyncBytes`
  crosses no isolation boundary improperly. (`BlobReadStream: Sendable` is gated
  on `P3-PLATFORM-4` - asserted there as a required OUTCOME, not as a bare
  platform fact, because Apple docs do not state `FileHandle.AsyncBytes:
  Sendable`.)
- **P3-PLATFORM-1.** Confirm on macOS 26 that no public SwiftData API yields a
  file URL for an `.externalStorage` blob; the blob-store-tier design is taken
  regardless (§5.2).
- **P3-PLATFORM-2.** Prove `FileHandle.AsyncBytes` over a process-owned blob
  file gives bounded-memory streaming — peak residency bounded by
  `BlobStoreLimits.readChunkSize`, not by file size, for a near-64 MiB blob
  (§2, Fact 6; the async iterator does not internally buffer the whole file).
  If the measured peak exceeds `readChunkSize` (internal buffering above
  target), §5.4's chunked adapter (repeated `read(upToCount: readChunkSize)`)
  is vended instead and residency is re-measured against the target - the
  gate's outcome is bounded-by-chunk by construction (raw sequence or
  adapter), not by the raw sequence alone.
- **P3-PLATFORM-3.** `CanonicalBlobV2`/`RevisionStateBlobV2`/`StoredBlobHandleV1`
  encode/decode round-trip and reject every corruption class (unknown version,
  oversize byteCount, path-escape relativePath, missing/invalid fingerprint) as
  `.persistence(.corruptStoredValue)` / `.invariantViolation` (`05` §16),
  mirroring v1 codec proofs (Part VI §7.4). Confirm the bidirectional
  fingerprint/signature coverage check (`05` §4) holds for handle-backed reps.
- **P3-PLATFORM-4.** **Required OUTCOME:** `BlobReadStream` is `Sendable` so it
  can cross the `HistoryStorage -> PresentationUI` boundary (C-M2) without
  `@unchecked Sendable` (banned by `01` §8 / `V2-00` §2.2). `BlobReadStream`'s
  sole load-bearing stored property is `FileHandle.AsyncBytes`; Apple's docs
  document `FileHandle.AsyncBytes` as a struct on macOS 12.0+ (`§2`, verified)
  but do **not** state `Sendable` conformance (it wraps a non-Sendable
  `FileHandle` class), so per `V2-00` §5 the OUTCOME - not the unverified
  platform property - is what V2 commits to. The gate confirms, on macOS 26,
  one of: (a) `FileHandle.AsyncBytes` is `Sendable` (MCP-verified or
  compile-proven), in which case `BlobReadStream: Sendable` synthesizes via
  all-`let` members as written; or (b) `FileHandle.AsyncBytes` is **not**
  `Sendable`, in which case `BlobReadStream` is redesigned to wrap the
  `AsyncBytes` in an actor-confined or buffered `Sendable` adapter (vend the
  `AsyncSequence<UInt8>` through an accessor that hands out a non-Sendable
  sequence confined to the caller's actor, or a buffered `AsyncIterator`-backed
  `Sendable` sequence) - never `@unchecked Sendable`. Either path keeps the v1
  public surface (`BlobStreamingHistory.streamRepresentation -> BlobReadStream?`,
  `bytes: FileHandle.AsyncBytes` consumer pattern, §5.4) intact or
  behavior-preserving; the adapter choice is recorded here if (b) is taken.
  `P3-COMPILE-1`'s `BlobReadStream: Sendable` claim is **gated on this proof**,
  not asserted as bare fact.
- **P3-PLATFORM-5 (capture/sweep race, C-M6).** A WS20-style concurrency-harness
  test drives a capture/sweep interleaving: a sweep is triggered while
  `IngestPreparation` has written a blob file but before the capture's History
  Commit runs. The test asserts (a) the in-flight blob file is not deleted (it
  is in `BlobStore`'s in-flight set, excluded from `sweepOrphans`, §5.5), and
  (b) after the commit completes and `commitHandle` moves the path to the
  durable-tracked set, the committed item reads back correctly via both the
  `Data` surface and the streaming surface. A second case asserts an aborted
  capture (blob written, commit never runs) leaves the in-flight file to be
  age-reaped after the grace interval without affecting any committed item.
- **P3-PERF-1.** Peak capture-path and read-path memory within the G8 budget for
  a near-max-size representation workload; p95 copy cost not inflated by the
  blob-file write (the write is off-commit, §5.4); streamed-read peak residency
  bounded by the chunk size. The O(retained) orphan sweep's amortized per-
  operation cost and its open-time cost are bounded; the open sweep is deferred
  past the G5-critical startup path so it does not inflate P1's 250 ms startup
  budget (`P1-PERF-1`).

### 5.8 P3 migration / invariants / UX

- **Migration (M1, §9) — eager (M3 decision).** **Layer 2 (versioned blob)**
  only: `CanonicalBlobV1 → CanonicalBlobV2`, `RevisionStateBlobV1 →
  RevisionStateBlobV2`, performed **eagerly at M1 time**: every item's V1 blobs
  are read, representations ≥ the inline threshold are spooled to blob files,
  and the V2 codec is written — for **all** rows, once. No SwiftData schema
  column is added (layer 1 untouched); no projection is changed (layer 3
  untouched); `ContentVersion` is unchanged. The migration never invents missing
  bytes or reinterprets an old `ContentVersion` (`05` §17). P3 commits to eager
  migration (not lazy) because a lazy path would require the read side to
  dispatch on `formatVersion` and decode **either** `CanonicalBlobV1` **or**
  `CanonicalBlobV2` — and that dual-decode *is* P3's read surface (the §5.3.1
  validators), not an M1-plan detail; eager migration keeps the read path V2-only
  (§5.3.1 as specified) and makes "no inline fallback post-migration" literally
  true. Cost: an O(retained) row rewrite + large-rep spool at M1, bounded by
  `06` §2 (≤ 5,000 items, ≤ 64 MiB/rep), recorded in the M1 plan. **This is a
  one-time, first-launch cost distinct from the steady-state reuse-path open
  latency `P1-PERF-1` profiles** (`P1-PERF-1`'s 250 ms bar is about P1's
  checkpoint reuse path on an already-V2 store, not M1 migration of a v1
  store). The eager migration stage runs inside the M1 custom migration stage
  during `open` (synchronous), so for a large-rep store it can materially
  extend first-launch time; the M1 plan therefore records an explicit duration
  bound (or a `P3-PERF` measurement) for M1 migration on a worst-case large-rep
  store (≤ 5,000 items × (≤128 MiB Canonical + 256 MiB revisions) reachable
  worst case, `06` §2) so the G5 startup budget and
  first-launch UX are not silently inflated by the eager spool. The frozen V1
  decoders remain available only as the migration's *input*, not as a read-side
  fallback.
- **Durability / no inline fallback (C-M4).** After eager migration a
  handle-backed representation has **no inline copy**; a lost blob file is
  unrecoverable for that representation (fails `.corruptStoredValue` at read)
  unless a revision/Canonical copy survives. Backup/restore/sync must capture
  `<storeURL>.blobs/` alongside the store (§5.5 durability boundary). This is
  the documented consequence of the G8 memory OUTCOME.
- **Invariants (§8).** D39 (streaming-equivalence). D2/D4/D5/D7/D8 preserved
  unchanged (Canonical immutability, append-only revisions, precise
  ContentVersion, fingerprint-is-evidence, complete candidates).
- **UX.** Transparent for the `Data` surface (no public change). The streaming
  surface is a **public `HistoryCore` protocol** (`BlobStreamingHistory`, C-M2);
  V2-07 consumes it for large-attachment preview/export. No SwiftData/Domain
  leakage.

---

## 6. Compile, dependency, and isolation proofs (Part VI §6 analog)

- **P1/P2/P3 storage internals, two public `HistoryCore` protocols.** P1 has no
  public surface. P2 and P3 each add **one public `HistoryCore` protocol** —
  `LocalizedSearchHistory` (P2) and `BlobStreamingHistory` (P3, promoted per
  C-M2 so V2-07 in PresentationUI can consume it across the `01` §8 target
  boundary) — plus the public `LocalizedSearchStatus`/`BlobReadStream` DTOs. All
  are Foundation-only, reuse v1 vocabulary verbatim, and add no name colliding
  with v1 (`V2-00` §6). Everything else (`StartupCheckpointRow`,
  `SignatureIndexBlobV1`, `LocalizedSearchConfigRow`, `LocalizedSearchLimits`,
  V2 codecs, `StoredBlobHandleV1`, `BlobStore`) is `internal` to `HistoryStorage`.
- **Imports.** P1/P2/P3 add **no framework import**: they use only Foundation
  (`FileHandle`, `URL`, `Data`, `Locale`,
  `NSString.range(of:options:range:locale:)`, `String.CompareOptions`).
  The source gate (`01` §9) is unchanged; no
  `SwiftData` import appears outside `HistoryStorage`; `HistoryCore` still
  imports only Foundation.
- **Isolation.** `BlobStore` is an `actor`; P1/P2 add no new actor (they live
  behind `HistoryAuthority`). No `@unchecked Sendable`, no
  `nonisolated(unsafe)`, no `.shared`/`.current` service locator, no second
  writer, no public SwiftData/Domain leakage (`01` §8, `06` §6). All new values
  crossing an isolation boundary (`SignatureIndexBlobV1`, V2 codecs,
  `StoredBlobHandleV1`, `BlobReadStream`) are `Sendable` via all-`let` `Sendable`
  members.
- **Single write authority (`00` §3.3) — P3 blob-file medium disclosed (R-M1).**
  v1's single-writer rule is **`ModelContext`-scoped**: it forbids a writable
  `ModelContext` (and hence any `HistoryItemRow`/singleton mutation) outside
  `HistoryAuthority`. P3's blob files are a **different medium** — ordinary
  process-owned files written by `IngestPreparationActor`/`RevisionPreparationActor`
  via the `BlobStore` actor during preparation (`05` §6.1/§6.2), with **no
  `ModelContext`, no `HistoryItemRow` mutation, and no `ChangePosition` advance**.
  This is **not** a v1 "second writer" violation: no row is written outside the
  Authority. The blob bytes are **commit-coupled** to a History Commit through
  the small V2 codec row (`canonicalBlob`/`revisionStateBlob`) that the commit's
  transaction writes inside the Authority — the codec row references the
  already-on-disk handle, so a committed item always points at a real blob file,
  and an aborted commit leaves only an in-flight blob file later age-reaped by
  `BlobStore` (§5.5 C-M6). The P1 checkpoint
  write and the P3 orphan sweep likewise go through `HistoryAuthority` in
  separate transactions; no path creates a writable `ModelContext` outside the
  Authority.
- **No History Commit intrusion.** P1's checkpoint write and P3's blob-file
  write occur outside any History Commit's transaction closure (P1 after a
  rebuild, never on the reuse path, before `open` returns; P3 in
  preparation, before the commit).
  No History Commit's transaction is altered; `ChangePosition` advances only on
  real History Commits (D5/D6).
- **No `HistoryAction` / `HistoryMutation` / Domain change.** All three grafts
  leave the closed action switch (`05` §8), the mutation/stamping map (`05` §9),
  and the pure Domain (`HistoryDomain`) untouched.

---

## 7. Graft-admission records (`V2-00` §4) — partitioned P1 / P2 / P3

### 7.1 P1 — persistent startup checkpoint

**Record 1 — Lifted exclusion + evidence trigger.** Lifts `06` §3 G5. Trigger:
current capped Canonical-coverage / Signature-Index rebuild p95 > 250 ms at
5,000 items on the minimum supported hardware profile, plus the controlling
DATA-11 amendment (`V2-00` §3 P1).

**Record 2 — Invariant impact.** D1–D19 preserved unchanged. The
`ChangePosition`-based unchanged-detector reuses D5/D6 (precise monotone tokens)
without weakening them. **Extended** with D37 (§8). No D1–D19 weakened:
correctness never depends on the checkpoint; a corrupt/missing/stale/codec-mismatched
checkpoint forces a rebuild (D37).

**Record 3 — V2 proof gates.** P1-COMPILE-1, P1-PLATFORM-1/2/3, P1-PERF-1 (§3.7).

**Record 4 — Cache-law compliance.** The checkpoint **is** a cache of the
Signature Index. The Part IV §12 law is restated for P1: for the same durable
retained-signature state, checkpoint-hit (reuse), checkpoint-miss (rebuild),
eviction (deletion), disabled checkpoint (absent row), and process restart
produce a semantically identical Signature Index and identical capture
availability; only startup latency differs. The cache key is the v1
`ChangePosition` (+ the codec/schema versions); a stale/evicted checkpoint
degrades to a rebuild, **never** to a wrong or incomplete index. The fast path
is the position-equality check; the law's "semantically identical values"
follows because position-equality ⟹ identical Signature set ⟹ identical index
(§3.3). **Fixture coverage (honestly scoped):** WS14 (restart reconstruction,
`06` §8) passes unchanged with the checkpoint enabled — this exercises restart
only. A **dedicated reuse-vs-rebuild equivalence fixture** (asserting reuse-path
and rebuild-path yield identical served Signature Indexes and identical capture
availability for the same durable state across all five cache-law dimensions —
hit/miss/eviction/disabled/restart) is added under `P1-PERF-1`/`P1-PLATFORM-3`;
WS14 alone does not prove the full cache law.

**Record 5 — Migration impact.** Layer 1 (SwiftData schema): add the
`StartupCheckpointRow` table (additive, lightweight). Layers 2/3 untouched.
First open after migration rebuilds and writes the first checkpoint. P1 adds no
projection rebuild beyond the current §13 recipe-v2 step and changes no
`ContentVersion`; no capture is enabled before Signature Index completeness
(the reuse path serves a proved-complete index or rebuilds, §3.4).

**Record 6 — Security boundary.** P1 is **not external-facing**. The checkpoint
is internal; no TCC/sandbox/entitlement impact. P1 correctness is conditional
on v1's single-writer invariant (`00` §3.3): an out-of-band edit that mutates
retained rows or signature blobs without advancing `ChangePosition` could be
served stale on the fast path. P1 intentionally adds no diagnostic hash or
duplicate O(retained) audit; the single-writer boundary remains the preventive
control.

### 7.2 P2 — locale-sensitive exact search

**Record 1 — Lifted exclusion + evidence trigger.** Lifts `06` §3 G7. Trigger:
approved product requirement for locale-sensitive matching + fixtures defining
normalization/ordering for the supported locales (`V2-00` §3 P2).

**Record 2 — Invariant impact.** D1–D19 preserved unchanged. D9 (`02` §14, the
dedup *winner* tie-breaker, locale-independent) is preserved **unchanged**; v1
search determinism (`04` §7) is preserved **per locale** — a locale change is a
distinct input context, not a search-determinism violation. **Extended** with
D38 (§8). No D1–D19 weakened: with P2 disabled, exact search is byte-for-byte v1
(the capability gate is the boundary); with P2 enabled, exact's predicate is
locale-folding (case + diacritic for all supported locales; width for CJK via
`.widthInsensitive`, §4.4) but its ordering, precedence, excerpt, and UTF-16
range contracts are unchanged. **Observation contract (C-M5):** P2 preserves
v1's `04` §5 race-free observation — locale/enabling changes yield an internal
predicate-change signal so `observe(.search)` re-broadcasts under the new
predicate without advancing `ChangePosition` (§4.5); no coherence deviation is
taken.

**Record 3 — V2 proof gates.** P2-COMPILE-1, P2-PLATFORM-1/2/3, P2-PERF-1 (§4.6).

**Record 4 — Cache-law compliance.** P2 is **not a cache** (query-time
evaluation, no stored result cache). N/A; the v1 "no search-result cache without
G2" rule (`06` §9) is respected — P2 adds no cache.

**Record 5 — Migration impact.** Layer 1 (schema): add `LocalizedSearchConfigRow`
(additive). **Layers 2 and 3 untouched — no projection rebuild** (P2 is
query-time over existing projections, §4.2). No blob change, no `ContentVersion`
change. First open bootstraps the singleton `enabled == false` (v1-faithful).

**Record 6 — Security boundary.** P2 is **not external-facing**. No TCC/
sandbox/entitlement impact. Locale handling uses Foundation's on-device
locale APIs; no locale data leaves the process.

### 7.3 P3 — blob-store handle / streaming content abstraction

**Record 1 — Lifted exclusion + evidence trigger.** Lifts `06` §3 G8. Trigger:
a representative capture- or read-path workload exceeds its memory budget or
shows p95 copy cost unsolvable within the bounded inline-value design (`06`
§3 G8 verbatim). The
verified `.externalStorage` opacity finding (§2, Fact 8) is recorded as the
reason the graft takes the blob-store-tier form rather than a pure read-stream
over `.externalStorage`.

**Record 2 — Invariant impact.** D1–D19 preserved unchanged. In particular:
- **D2 (Canonical immutability):** P3 changes the physical medium of Canonical
  bytes (inline `Data` ↔ blob file), never the logical bytes; Canonical is still
  never overwritten.
- **D5 (precise ContentVersion):** P3 mints no `ContentVersion`; the
  inline↔handle choice is storage-only.
- **D7 (fingerprint-is-evidence):** `StoredBlobHandleV1.xxh3` is evidence, never
  identity; read-time integrity uses exact `byteCount` + evidence xxh3.
- **D8 (complete candidates):** dedup uses Canonical signatures, which are
  medium-independent; candidate completeness is unchanged.
**Extended** with D39 (§8). No D1–D19 weakened.

**Record 3 — V2 proof gates.** P3-COMPILE-1, P3-PLATFORM-1/2/3/4/5, P3-PERF-1 (§5.7).

**Record 4 — Cache-law compliance.** P3 is **not a cache** — the blob-store is
the authoritative physical medium for large reps (the V2 codec is the source of
truth, not a derived cache of an inline `Data`). The streaming read is a
read-side abstraction over the authoritative blob file, governed by D39
(byte-identical). N/A as a cache law; D39 is the equivalence discipline.

**Record 5 — Migration impact.** **Layer 2 (versioned blob)** only
(`CanonicalBlobV1 → V2`, `RevisionStateBlobV1 → V2`), byte-exact-preserving
(large reps spooled to blob files). Layer 1 untouched (no schema column added —
the existing `Data` columns carry the V2 codec). Layer 3 untouched (no
projection change). `ContentVersion` unchanged; no invented bytes, no
reinterpreted `ContentVersion`, no reused IDs; capture is not enabled before
Signature Index / change-journal completeness (the migration touches content
codecs only, not the index or journal).

**Record 6 — Security/durability boundary.** P3 is **not external-facing**
(local file-handle streaming only, `V2-00` §3.1). Trust boundary: the blob-store
root is app-owned; `relativePath` is path-confined at decode (§5.5); no
user-controlled path is accepted. No additional TCC permission expected (blob
files live beside the app-owned SwiftData store, within the app's container).
Orphan-blob-file retention window: cleanup is decoupled and commit-driven, so an
inactive user's removed-item blob files linger until the next app launch's open
sweep (mirroring V2-01 §6.5) — `remove` does not promptly delete the physical
bytes of a removed large representation until the sweep.

Additional P3 boundary disclosures:
- **New public surface (C-M2).** P3 adds one public `HistoryCore` protocol
  (`BlobStreamingHistory`) and one public `HistoryCore` DTO (`BlobReadStream`),
  Foundation-only, so V2-07 (PresentationUI) can consume large-attachment
  streaming across the `01` §8 target boundary. `BlobStore`, the V2 codecs, and
  `StoredBlobHandleV1` stay `internal` to `HistoryStorage`; the public protocol
  never exposes `relativePath` or the handle struct.
- **Durability boundary (C-M4).** P3 trades SwiftData-atomic blob storage
  (`.externalStorage`) for app-managed sidecar files under `<storeURL>.blobs/`
  outside SwiftData's transaction control. Backup/restore/sync MUST capture
  `.blobs/` alongside the store; an operation that misses it produces items
  whose handle-backed reps fail `.corruptStoredValue` at read where v1 survived.
  Single-blob-file loss degrades the item (D2, never silently substituted).
  After eager migration (§5.8) there is **no inline fallback** for handle-backed
  reps — a lost blob file is unrecoverable unless a revision/Canonical copy
  survives. This is the documented consequence of the G8 memory OUTCOME.
- **Streaming integrity residual (C-M3).** xxh3 is a whole-file hash; the
  streaming path checks `byteCount` up-front but verifies xxh3 only at stream
  end. A length-preserving corruption is therefore detected only after a
  streaming consumer has received wrong bytes (the iterator throws
  `.corruptStoredValue` at stream end — fail-closed after the fact). Consumers
  needing byte-identity before any byte is vended use the `Data` surface (eager
  xxh3) instead. This residual is weaker than detail/paste and is documented,
  not hidden.

---

## 8. New invariants (D37–D39)

D1–D19 (`02` §14) and D20–D36 (V2-01..V2-05) are reaffirmed unchanged. V2-06
extends the set with:

- **D37 (P1 — checkpoint fail-safe).** A corrupt, missing, stale, or
  codec/schema-mismatched `StartupCheckpointRow` forces a full Signature Index
  rebuild; the checkpointed index is **never** served when the durable
  `ChangePosition` has advanced or the checkpoint is ill-formed. Correctness
  never depends on the checkpoint — it is an optimization whose loss or
  corruption degrades to a rebuild, never to a wrong or stale Signature Index.
  (The fast-path unchanged-detector is the v1 `ChangePosition` counter; a
  rebuild is the conservative outcome on any advance.)

- **D38 (P2 — locale-equivalence + per-locale search determinism).** When
  localized search is enabled, exact-mode matching yields the same logical
  results regardless of case and diacritic presentation within a fixed locale
  (verified `localizedStandard*` default behavior, §2), and additionally
  regardless of width presentation for CJK locales (delivered via the verified
  `.widthInsensitive` option in the fixture-locked per-locale option set, §4.4).
  v1 search determinism (`04` §7) is preserved **per locale** — a locale change
  is a distinct input context, not a search-determinism violation. D9 (`02` §14,
  the dedup winner tie-breaker) is locale-independent and preserved unchanged.
  When localized search is disabled, exact is byte-for-byte v1.

- **D39 (P3 — streaming-equivalence).** A blob-handle-backed representation is
  byte-identical to the inline `Data` value it replaces; streaming and full
  materialization produce identical bytes. P3 changes the physical storage
  medium (inline `Data` ↔ process-owned blob file) behind a versioned blob
  codec; it mints no `ContentVersion`, changes no logical Canonical/revision
  bytes, and the v1 byte limits (`06` §2) are unchanged.

No D1–D19 is weakened. The V2 self-review scan (`V2-00` §8) is extended to
include `StartupCheckpointRow`, `SignatureIndexBlobV1`,
`LocalizedSearchConfigRow`, `LocalizedSearchHistory`/`LocalizedSearchStatus`,
`CanonicalBlobV2`, `RevisionStateBlobV2`, `StoredBlobHandleV1`, `BlobStore`,
`BlobReadStream`, `BlobStreamingHistory`, and `BlobStoreLimits` — none collides
with v1 vocabulary.

---

## 9. Migration (M1) — summary per graft

| Graft | Layer 1 (schema) | Layer 2 (blob) | Layer 3 (projection) | ContentVersion |
|---|---|---|---|---|
| **P1** | Add `StartupCheckpointRow` (additive). | None. | None. | Unchanged. |
| **P2** | Add `LocalizedSearchConfigRow` (additive). | None. | **None** (query-time; no rebuild). | Unchanged. |
| **P3** | None (no column added). | `CanonicalBlobV1→V2`, `RevisionStateBlobV1→V2` (byte-exact; **eager** at M1 — every row rewritten, large reps spooled to blob files; no read-side V1 fallback, M3). | None. | Unchanged. |

All three migrations are additive or byte-exact-preserving. None invents
missing active-revision bytes, reinterprets an old `ContentVersion`, reuses
removed IDs, or enables writes before Signature Index / change-journal
completeness is restored (`05` §17). The three grafts may migrate independently
because they touch disjoint surfaces; `HistorySchemaV2` carries all new tables
(`StartupCheckpointRow`, `LocalizedSearchConfigRow`) and the V2 codecs, and the
M1 plan orders the stages so a v1 store opens under the combined V2 plan with v1
rows untouched except the P3 blob-codec rewrite (layer 2).

---

## 10. UX hooks (full surface in V2-07; state contract here)

- **P2.** A supported-locales setting and an enable toggle, built only from
  `LocalizedSearchStatus` (a `HistoryCore` DTO) on the main actor. No
  SwiftData/Domain leakage. An active `observe(.search)` stream **self-heals**
  on toggle/locale change: the predicate-change signal (C-M5, §4.5) re-broadcasts
  the current page under the new predicate/locale without advancing
  `ChangePosition`, so the UI need not imperatively re-browse (a one-shot
  `browse(.search)` always reflects the current predicate on its next call).
- **P1, P3.** Transparent. No new UX surface. P3's streaming path is a **public
  `HistoryCore` protocol** (`BlobStreamingHistory`, C-M2); a V2-07
  large-attachment preview/export feature consumes it across the `01` §8 target
  boundary (the new public surface is the protocol + `BlobReadStream` DTO).

---

## 11. Open questions carried into proof gates

Every open platform question is assigned a proof gate; the doc states the
required OUTCOME in each case so the design is correct regardless of the
unverified detail.

- **OPEN 1 / `P1-PLATFORM-1`** — SwiftData hides the CoreData coordinator /
  generation token. OUTCOME (stated regardless): P1's unchanged-detector is the
  v1 `ChangePosition`; the checkpoint is a self-managed row; the design depends
  on no CoreData generation token.
- **OPEN 2 / `P1-PLATFORM-2`** — scalar read isolation for the checkpoint +
  position rows (no blob faulting on the fast path).
- **OPEN 3 / `P2-PLATFORM-1`** — Swift `String` overlay
  `localizedStandardRange(of:options:locale:)` signature on macOS 26. OUTCOME
  (stated regardless): P2's locale-folding range search is implemented against
  the **verified** `NSString.range(of:options:range:locale:)` substrate (§2,
  macOS 10.5+, returns `NSRange`); the Swift overlay is only a convenience. If
  the overlay is confirmed, the call site adapts mechanically; if not, P2 uses
  the verified NSString bridge directly. The folding behavior (case + diacritic
  + `.widthInsensitive`) is fully verified via the `CompareOptions` members.
- **OPEN 4 / `P3-PLATFORM-1`** — `.externalStorage` exposes no public file URL.
  OUTCOME (stated regardless): P3 is the blob-store-tier design, not a
  read-stream over `.externalStorage`.
- **OPEN 5 / `P3-PLATFORM-2`** — `FileHandle.AsyncBytes` bounded-memory
  streaming (peak residency ≤ chunk size, not file size).
- **OPEN 6 / `P2-PLATFORM-2`** — locale range `NSRange` → UTF-16 snippet-offset
  translation stability across locales, **and** projection-input safety for
  locale folding over v1's normalized+truncated projections (both fixture-proved).
- **OPEN 7 / `P1-PERF-1`, `P2-PERF-1`, `P3-PERF-1`** — the G5 / G7 / G8 triggers
  restated as proofs the grafts clear their admission bars.
