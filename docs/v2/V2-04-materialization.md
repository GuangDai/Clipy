# V2-04 - Materialization Caches (C1 in-memory thumbnail + C2 disk thumbnail + C3 publish fence + S1 thumbnail source fingerprint)

> **Status (2026-07-25):** V2 design-consolidated, scaffold proof pending. This
> doc extends the v1 specification (`00`–`06`) by **addition only**. v1 owns v1
> thumbnail behavior (single-flight, version fence, "completed bytes are not
> retained"); V2-04 owns the C1 in-memory completed-thumbnail cache, the C2 disk
> thumbnail cache, the C3 publish-fence materialization lifecycle, and the
> thumbnail-purpose instantiation of S1 (`ThumbnailSourceFingerprint`), grafted
> onto the v1 `ThumbnailService`/`ThumbnailWorker` seam. It redefines no v1
> public type, `HistoryAction` case, `HistoryMutation` case, schema column,
> codec, invariant (D1–D19, `02` §14), or proof gate. The v1 thumbnail DTOs
> (`ThumbnailPayload`, `PixelSize`, `ThumbnailFormat`, `HistoryItemReference`,
> `03b` §9) are **unchanged**; the caches are transparent to every caller. Like
> v1 and V2-01/V2-02/V2-03 at consolidation time, V2-04 is "design-consolidated,
> scaffold proof pending."

## 1. Role and boundary

V2-04 answers one question:

> *After v1 thumbnail single-flight + version fence ships, how are a shared
> in-memory completed-thumbnail cache, a disk thumbnail cache, and a
> multi-state publish-fence materialization lifecycle grafted onto the v1
> thumbnail seam without weakening a single v1 load-bearing decision, the v1
> cache law (`04` §12), or D1–D19?*

V2-04 is a **transparent cache + lifecycle graft**. It changes no public
thumbnail type and no caller-observed thumbnail availability: a hit returns the
bytes a miss would have produced (cache law, `04` §12); a miss runs the v1
decode path unchanged. It retains completed thumbnail bytes that v1 deliberately
does **not** retain (`04` §9 step 7) — that retention is the G1/G3 lift
(`06` §3 G1/G3), recorded in §1.2.

V2-04 owns:

- the C1 in-memory completed-thumbnail cache (`ThumbnailCache`, a new internal
  `actor`);
- the C2 disk thumbnail cache (`DiskThumbnailCache`, a new internal `actor`
  using `NSFileCoordinator`-coordinated file I/O), its on-disk layout, the
  versioned `ThumbnailDiskBlobV1` file codec, and the `ThumbnailCacheConfigRow`
  V2 singleton;
- the C3 publish-fence materialization lifecycle (`ThumbnailPublishFence`, a new
  internal state machine owned by `ThumbnailService`);
- the thumbnail-purpose instantiation of S1 — `ThumbnailSourceFingerprint`, an
  **independent concrete** fingerprint type mirroring `V2-01`'s
  `EnrichmentSourceFingerprint` (`V2-01` §5.1) with **no shared generic**;
- the cache-key decision (source-stamp vs `ContentVersion` vs both, §3.2);
- the six graft-admission records (`V2-00` §4), V2 proof gates, migration
 impact, and new invariants **D29–D31**.

V2-04 owns no `HistoryAction` case, no `HistoryMutation` case, no Domain
planner, and no change to the closed `ClipboardHistory` protocol's thumbnail
surface. The Domain (`HistoryDomain`) is untouched by the caches: it remains
pure, Foundation-only, and unaware that caches exist.

### 1.1 What V2-04 is NOT

- **Not a generic materialization framework.** The deleted generic
  `ItemKey<Purpose>` / `OutputParams` / five-store framework (`04` §11, Part VI
  §10) is **not reintroduced** (`V2-00` §3.1). `ThumbnailSourceFingerprint` and
  `ThumbnailCacheKey` are purpose-specific (thumbnail only); they share **no**
  generic type, protocol, or store with `V2-01`'s enrichment fingerprint.
  "Per-purpose pattern" means a repeated design, never a reusable generic API
  (`V2-01` §5, `04` §11).
- **Not a redefinition of v1 thumbnail.** v1 single-flight + the version fence
  (`04` §9) are preserved unchanged; V2-04 *retains* the completed bytes that v1
  discards and *consults* that retained state before re-decoding. The v1
  fetch-time version fence (steps 2–3) runs identically; the decode
  (`ThumbnailWorker`, ImageIO) runs identically on a miss.
- **Not multi-process or external-facing.** The disk cache lives in the app's
  own container; `NSFileCoordinator` coordinates across in-process presenters
  and any future extension sharing the container, but V2-04 does not admit a
  second process opening its own `ModelContainer` (`V2-00` §3.1). No `X1`
  boundary, no `OperationRecord` (V2-05).
- **Not a durable derivation.** Unlike `V2-01` enrichment (a durable derived
  projection) and `V2-03` HCR (a durable journal), the thumbnail caches are
  **transparent caches**: their loss degrades to a miss + re-decode, never to
  wrong durable state. The disk cache is a new on-disk artifact but it stores
  only derived preview bytes, not history state.

### 1.2 What V2-04 explicitly lifts

V2-04 lifts three pieces of machinery v1 deliberately left **absent** and
records that absence as the graft substrate, exactly as `V2-03` §1.2 lifted the
durable change cursor and the collection cache:

- **Completed-thumbnail retention.** v1 states "Completed bytes are not retained
  by `HistoryStorage`" (`04` §9 step 7) and lists "one transient thumbnail
  single-flight coordinator" as the only v1 thumbnail machinery (`00` §2
  Included). G1 (`06` §3) lifts the retention absence: V2-04 retains completed
  PNG bytes in C1 (in-memory) and, when G3 fires, C2 (disk).
- **Shared / disk materialization caches.** v1 excludes "Shared or disk
  materialization caches, collection caches, generic purpose/source-stamp
  systems, and five-store materialization frameworks" (`00` §2 Excluded) and
  "Collection snapshot cache," "Generic … `SourceStamp`, `ItemKey<Purpose>`, or
  `OutputParams` frameworks," "Publish fences, reap state machines, or generic
  materialization stores" (`04` §11). G1/G3 lift the shared/disk-cache absence
  for the **thumbnail purpose only** (purpose-specific, not generic); G6 lifts
  the publish-fence absence for the **thumbnail lifecycle only**.
- **Per-purpose source stamps.** G4 (`06` §3) lifts the source-stamp absence.
  `V2-01` already instantiated S1 for the enrichment purpose
  (`EnrichmentSourceFingerprint`, `V2-01` §5); V2-04 instantiates the **same
  per-purpose pattern independently** for the thumbnail purpose
  (`ThumbnailSourceFingerprint`, §3). Neither purpose reserves the other's
  surface; there is no shared generic.

This is stated honestly here rather than implied: a v1 reader finds no retained
thumbnail bytes, no thumbnail cache, no publish fence, and no thumbnail source
stamp, by design. V2-04 is the graft that supplies them, purpose-specifically.

## 2. Capability scope

### 2.1 In scope

- **C1 (G1): in-memory completed-thumbnail cache.** Retains completed encoded
  PNG bytes keyed by `(HistoryItemID, ThumbnailSourceFingerprint, PixelSize,
  materializerSchemaVersion)` (§3.2/§5). A hit returns byte-identical bytes to a
  miss (cache law, §13 Record 4). Bounded by a memory cap with LRU eviction.
  Fenced by the v1 fetch-time version fence (`04` §9 steps 2–3) and the C3
  publish fence (§7).
- **C2 (G3): disk thumbnail cache.** Persists completed thumbnails across
  launches (the G3 cross-launch-reuse trigger). Keyed identically to C1 plus a
  `ThumbnailDiskBlobV1` file envelope (§6). File access via `NSFileCoordinator`
  (coordinated read/write, macOS 10.7+, non-`Sendable` → actor-confined,
  `V2-04-facts.md` fact 1). Crash-safe: a corrupt/missing/expired disk entry
  degrades to a miss (re-decode), NEVER wrong bytes (§6.3).
- **C3 (G6): publish-fence materialization lifecycle.** A multi-state lifecycle
  (`pending → decoding → ready → superseded → discarded`, §7) that extends v1
  single-flight + the version fence with an explicit publish-time fence,
  preventing a superseded materialization result from being *published as
  current* to a newer row state (D31; tag-and-observe — the payload is still
  returned tagged, §7.1). Preserves the v1 invariant that current bytes are
  never returned under an old reference (`04` §9).
- **S1 (G4): thumbnail source fingerprint.** `ThumbnailSourceFingerprint`
  (xxh3-64 over the selected image source bytes, §3) — the thumbnail-purpose
  instantiation of the per-purpose S1 pattern `V2-01` established. Enables the
  cache to survive revisions that advance `ContentVersion` without changing the
  image source bytes (the G4 trigger condition).
- **Config + UX hooks.** A durable `ThumbnailCacheConfigRow` V2 singleton gates
  C2 (disk cache enable/disable + size cap) and carries the materializer schema
  version; a new public `ThumbnailCacheHistory` protocol exposes the config +
  status to callers (§10), mirroring `V2-01`'s `EnrichmentHistory`.

### 2.2 Out of scope (remains post-V2)

- **A generic materialization framework** (`V2-00` §3.1, `04` §11). The caches
  are thumbnail-only; `V2-01`'s enrichment has no read cache (`V2-01` §2.2). Any
  future non-thumbnail materialization cache is a separate, cache-law-gated
  graft.
- **Multi-process / extension direct writers to the disk cache.** V2-04's disk
  cache is written only by this process's `DiskThumbnailCache` actor.
  `NSFileCoordinator` coordinates correctly if a future extension shares the
  container (fact 1), but V2-04 does not admit a second writer; a multi-writer
  cache needs its own architecture review (`V2-00` §3.1).
- **Detail/paste/list/search caching.** V2-04 caches only completed thumbnail
  bytes. The collection (list/search) cache is J1/V2-03; detail/paste are
  uncached by design (`04` §8).
- **Content-addressed blob storage / streaming.** P3 (V2-06) is a separate
  graft; the disk thumbnail cache is a flat file store, not the P3 blob-handle
  abstraction.
- **Thumbnail material re-derivation across a materializer change.** A
  materializer-version bump evicts every entry (re-decode on next access); V2-04
  does not proactively re-warm the cache. Re-warming is a future optimization.

### 2.3 Evidence triggers (admit design work)

Per `V2-00` §3, V2-04 admits design work when its triggers fire:

- **C1 (G1):** representative scrolling shows thumbnail decode p95 above 16 ms
  **and** at least 30% identical completed requests in the measurement window
  (`06` §3 G1).
- **C2 (G3):** C1 is already justified **and** measured cross-launch reuse is
  substantial **and** a structural materializer fingerprint is specified and
  fixture-proved (`06` §3 G3). G3's "structural materializer fingerprint" is the
  `materializerSchemaVersion` (§4) — the structural materializer schema version
  `04` §12 requires verbatim; `ThumbnailSourceFingerprint` (§3) is the separate
  G4 source stamp, not G3's structural fingerprint. The fixture proof is §13
  Record 4.
- **C3 (G6):** at least 20% of thumbnail work is measured as superseded or
  discarded despite cancellation and single-flight (`06` §3 G6).
- **S1 (G4):** profiling shows material thumbnail work repeatedly invalidated by
  Effective Content changes that provably leave the thumbnail purpose's source
  bytes unchanged (`06` §3 G4; `V2-00` §3).

Until the respective trigger fires, the corresponding capability is design only
and reserves no v1 surface. C1 may ship before C2 (C2 requires C1 + the G3
cross-launch evidence); S1 may ship with C1 (the stamp is the cache key); C3 may
ship with C1 (the fence gates every publish). The capabilities are
independently admissible but share the `ThumbnailSourceFingerprint` substrate,
so the natural ship order is S1+C1 → C3 → C2 (`V2-roadmap` will record the
gate-respecting order).

## 3. S1 — ThumbnailSourceFingerprint (independent concrete type)

S1 (`06` §3 G4) is the mechanism that lets the thumbnail cache survive a
revision that advanced `ContentVersion` without changing the image source bytes
the thumbnail derives from. It is the thumbnail-purpose analogue of `V2-01`'s
`EnrichmentSourceFingerprint` (`V2-01` §5), refined to the *thumbnail source
bytes*. V2-04 owns its **thumbnail instantiation**. Each purpose defines its own
independent concrete fingerprint struct — there is **no** shared generic
`SourceStamp<Purpose>` / `ItemKey<Purpose>` type, protocol, or store (`04` §11,
`06` §10, `V2-00` §3.1); "per-purpose pattern" means a repeated design, never a
reusable generic API. `V2-01` §5 already stated this independence for the
enrichment purpose; V2-04 concretizes the thumbnail purpose here.

### 3.1 Definition

```swift
internal struct ThumbnailSourceFingerprint: Sendable, Hashable {
    let rawValue: UInt64     // xxh3-64 over the selected thumbnail source
                             // representation bytes (the image bytes selected by
                             // the v1 thumbnail source pick, 05 §14.5 / 04 §9
                             // step 3)
}
```

The fingerprint is xxh3-64 over the **selected image source representation's
bytes** — the same bytes the v1 thumbnail path selects per `05` §14.5 ("derives
Effective Content, and returns immutable source image bytes") and `04` §9 step 3
("Derive Effective Content and select the supported image representation as an
immutable byte value"). It is computed inside the same non-suspending
`HistoryAuthority` interval as the version check (step 2) and Effective-Content
derivation (step 3), so the stamp and the version fence are consistent and no
commit can interleave (`04` §2). xxh3 is the v1 fingerprint primitive (`01` §4,
`05` §1); reuse — not a new hash — keeps the derivation on the v1 evidence
discipline (mirrors `V2-01` §5.1).

The stamp is computed for the **one** selected image representation only (v1
thumbnail already selects one image per item, `04` §9 step 3); there is no
per-candidate fingerprint set as in enrichment (`V2-01` §3.1), because the
thumbnail purpose has no PDF/text-layer precedence probe — the v1 selection rule
is deterministic and single-valued.

### 3.2 The cache-key decision (source-stamp vs ContentVersion vs both)

`04` §12 mandates that any future item cache key contain *"History Item ID, the
relevant authoritative version, complete normalized parameters, and a structural
materializer schema version."* V2-04's key is:

```swift
internal struct ThumbnailCacheKey: Hashable, Sendable {
    let itemID: HistoryItemID
    let sourceStamp: ThumbnailSourceFingerprint   // S1: the authoritative
                                                   // version FOR THE THUMBNAIL
                                                   // PURPOSE (the image source
                                                   // bytes' content-addressed
                                                   // identity)
    let pixels: PixelSize                          // complete normalized params
    let materializerVersion: UInt16                // structural materializer
                                                   // schema version (§4)
}
```

`ThumbnailSourceSelection` is the value the Authority's `thumbnailSource(for:pixels:)`
method (§9.4) returns — it bundles the fetch-time-verified reference, the selected
image source bytes (handed to `ThumbnailWorker`), and the composed cache key, all
materialized inside the one non-suspending `04` §9 interval:

```swift
internal struct ThumbnailSourceSelection: Sendable {
    let ref: HistoryItemReference          // the fetch-time-verified reference
                                             // (carries the CV the fence checked)
    let sourceBytes: Data                  // the selected image source bytes B
                                             // (05 §14.5 / 04 §9 step 3); handed
                                             // to ThumbnailWorker
    let cacheKey: ThumbnailCacheKey        // (itemID, sourceStamp, pixels,
                                             // materializerVersion) (§3.2)
}
```

It is `Sendable` by synthesis (all-`let` `Sendable` members:
`HistoryItemReference`, `Data`, `ThumbnailCacheKey`) and crosses the Authority
→ `ThumbnailService` isolation boundary. `thumbnailSource` returns `nil` when
the item has no supported image representation (v1 `04` §9 step 4); the caller
then returns `nil` unchanged (§7.3/§8).

**Decision: the key uses the S1 source stamp as the "relevant authoritative
version" dimension, NOT `ContentVersion`.** `ContentVersion` is retained as the
serve-time fence input (the v1 `04` §9 step-2 reference check runs unchanged)
and as entry provenance (the entry records the `ContentVersion` it was produced
under, for diagnostics and the C3 publish fence, §7), but it is **not** a key
dimension.

Justification:

1. **The G4 benefit requires stamp-keying.** A revision that changes a textual
   representation but not the image advances `ContentVersion` while leaving the
   image bytes (hence the stamp) unchanged. A `ContentVersion`-keyed cache
   misses on every such revision (key changed); a stamp-keyed cache hits (key
   unchanged). The G4 trigger admits S1 *for this benefit*; `ContentVersion`
   keying makes S1 inert, defeating the admission.
2. **"Relevant authoritative version" is purpose-relative.** For the thumbnail
   purpose, the authoritative source is the **image bytes**, whose version is
   their content-addressed stamp. Two item-states with the same image bytes
   produce the same thumbnail (materializer determinism, §4); the stamp captures
   exactly that identity. This is a faithful reading of `04` §12's "relevant"
   qualifier — the version *relevant to the thumbnail purpose* is the source
   bytes' identity, not the whole-item `ContentVersion`.
3. **The cache law holds with stamp-as-identity** (§13 Record 4). For the same
   `(itemID, sourceStamp, pixels, materializerVersion)`, the thumbnail is
   deterministic (materializer determinism), so cache hit and cache miss produce
   byte-identical bytes; only latency differs. The stamp is a stable identity
   for the thumbnail output.
4. **`ContentVersion` is the serve-time fence, not a key.** The v1 fetch-time
   fence (`04` §9 step 2) already requires the request's reference to be current
   before any source byte is selected; a stale-reference request fails there
   with `.staleContent` (`05` §16), unchanged. So the cache never serves a
   request whose reference was already stale — the fence is upstream of the
   cache lookup. `ContentVersion` in the key would be redundant with the fence
   for correctness and harmful for the S1 benefit.

**Alternatives rejected.**

- *`ContentVersion`-in-key:* zero residual, but no S1 benefit (misses on every
  revision). Rejected because G4 admits S1 for the cross-revision hit benefit.
- *Both `ContentVersion` AND stamp in-key:* collapses to `ContentVersion`-in-key
  (CV already disambiguates revisions, making the stamp dimension redundant).
  Rejected for the same reason.

**Collision honesty — a bounded, recorded EXCEPTION to decision 15 + `04` §12
(D7).** Like every v1 fingerprint, `ThumbnailSourceFingerprint.rawValue` is
**evidence, never identity** (D7, `02` §2.2, `02` §14). For the thumbnail cache,
an xxh3-64 collision between two distinct image-byte sets B1 and B2 (same stamp,
different bytes) would serve the B1-derived thumbnail for an item-state whose
image is B2 — a visually-wrong preview. **This is a genuine exception to two
load-bearing cache-law statements:** `V2-00` §5 decision 15 ("a stale or
evicted cache degrades to a miss, **never to wrong bytes**") and `04` §12
("cache hit, cache miss, eviction, disabled cache, and process restart produce
semantically identical values"). Decision 15 (amended) now scopes "never to
wrong bytes" to non-collision inputs, carving out the per-doc fingerprint-
collision residual as a bounded, transient exception (here D30); `04` §12
(v1, frozen) admits no collision carve-out as written. V2-04 takes the exception
**explicitly and recorded** (D30, §14), not by re-reading "wrong" to exclude
collisions. The exception is justified on five
grounds:

  (a) **Transient, not durable.** A collision-served wrong thumbnail is a
      process-local preview artifact. It is not durable history state, does not
      affect Canonical/revision/paste/detail bytes, and does not affect dedup
      identity or search. Eviction, restart, or a subsequent stamp-changing
      revision clears it. The actual content a user pastes is the v1
      `pastePayload` path, which never consults the thumbnail cache.
  (b) **Astronomically small, stated at the worst case.** The xxh3-64 birthday
      bound at the retained scale is ~7e-13 at ~5,000 entries (a conservative bound over V2-04's 2,048-entry
      in-memory cap, §5.3, which yields ~1e-13), ~1e-11 at the 20,000-entry disk
      cap, and ~5e-20 per independent request pair — the same primitive v1 accepts for dedup
      candidate generation (`02` §9.2) and `V2-01` accepts for enrichment.
  (c) **Materializer-determinism-boundable.** The collision can only serve
      bytes that the materializer *could* have produced from some image-byte set
      with that stamp — a valid PNG obeying the 16 MiB output bound (`06` §2),
      never malformed bytes. The wrong-bytes space is "a different valid
      thumbnail," not arbitrary bytes.
  (d) **The cost of the S1/G4 benefit.** A byte-exact fence eliminating the
      residual would require retaining the source bytes (up to a 64 MiB
      representation, `06` §2) per cache entry across isolation, or recovering
      them from the append-only revision history (D4). Both are disproportionate
      to a transient-preview residual and are not taken; the residual is the
      accepted cost of stamp-keyed cross-revision reuse (the S1 benefit, §3.2
      decision).
  (e) **V2-04 is the intentional V2 exception.** Unlike `V2-01` (`V2-01` §5.1,
      where the D7 residual sits on the *write/drain* path and the collision-
      free `ContentVersion` remains the read arbiter) and `V2-03` (`V2-03` §7.2,
      where the collision-free `ChangePosition` is the serve arbiter and the §7.1
      fence re-confirms it before serve), V2-04 has **no collision-free serve
      arbiter**: the stamp *is* the read/serve identity. A transparent read
      cache has no durable per-item row to carry a collision-free version and no
      background drain to two-layer the fence. V2-04 trades collision-freedom
      for the S1 benefit; it is the only V2 cache whose D7 residual lands on the
      user-visible read/serve path. This is a purpose-relative reinterpretation
      of `04` §12's "relevant authoritative version" (the version *relevant to
      the thumbnail purpose* is the source bytes' content-addressed identity),
      not a silent redefinition.

**V2-00 amendment (landed).** `V2-00` §5 decision 15 has been amended to scope
"never to wrong bytes" to *non-collision* inputs, with the per-doc
fingerprint-collision residual carved out as a bounded, transient,
preview-only exception (V2-01 D21, V2-04 D30). V2-04 owns its carve-out
**explicitly and recorded** as D30 (§14); it claims decision 15's "never to wrong
bytes" for non-collision inputs only (the amended scope) and records D30 as the
bounded residual against `04` §12 (v1, frozen, admits no carve-out as written).

## 4. Thumbnail materializer schema version

The `materializerVersion` is the **structural materializer schema version**
required verbatim by `04` §12: it identifies the ImageIO decode/downsample/encode
algorithm shape (downsample filter, pixel-ratio handling, PNG encoder settings,
max-pixel clamping rule). When the thumbnail materializer changes (e.g., a new
downsample filter is pinned), `materializerVersion` advances and every prior
cache entry — in-memory and on-disk — is treated as stale (re-decode on next
access). This mirrors `V2-01`'s `derivationSchemaVersion` (`V2-01` §5.2) and v1's
`projectionSchemaVersion` discipline (`05` §3.1, §15).

- **Compiled-in constant.** The running binary's materializer version is a
  compile-time `let` (currently 1). It is the value the cache key carries and
  the value compared at open against the durable singleton.
- **Durable home.** The current durable value lives on
  `ThumbnailCacheConfigRow.materializerVersion` (§6.4). A bump is an
  **absolute set** via `bumpMaterializerVersion(to:)` (`HistoryAuthority`,
  §10.3), not an increment — the compiled-in version has no runtime overflow
  (`02` §13).
- **Bump effect (lazy).** A bump advances the durable `materializerVersion` and
  flushes C1 (in-memory, §5 — empty at open for an open-time bump). C2 stale
  files are reclaimed **lazily**: the decode-time `materializerVersion` check
  (§6.2) treats a stale file as a miss + opportunistic delete on next access,
  and the background sweep (§6.5) reclaims the rest. V2-04 performs **no eager
  whole-cache scan + delete** at bump/open time (that would contradict the §6.3
  no-open-scan discipline and the no-startup-cost gate, `C2-PERF-2`/`C2-PERF-3`).
  An old-materializer thumbnail is not byte-identical to a new-materializer one
  (materializer determinism is version-scoped), so a stale file can only ever
  produce a miss — lazy reclamation is correctness-preserving.

## 5. C1 — In-memory completed-thumbnail cache

### 5.1 Data model

```swift
internal actor ThumbnailCache {
    private var entries: [ThumbnailCacheKey: ThumbnailCacheEntry] = [:]
    private var totalBytes: Int                 // running sum of encodedBytes.count
    private var lru: [ThumbnailCacheKey: (stamp: Date, seq: UInt64)]
                                                   // last-access stamp + monotonic seq;
                                                   // eviction order is (stamp, seq) so
                                                   // equal stamps break deterministically
                                                   // by access order (§5.3)
    private var lruSeq: UInt64 = 0                 // monotonic access counter; never resets;
                                                   // the deterministic LRU tie-breaker
    private let limits: ThumbnailCacheLimits    // §5.3

    // Consulted AFTER the v1 fetch-time fence (the source bytes + stamp are
    // selected in the 04 §9 non-suspending interval); the lookup itself runs on
    // this actor (an `await` outside the Authority interval, mirroring V2-03
    // CollectionCache §7.1 M1).
    func lookup(_ key: ThumbnailCacheKey) async -> Data?   // PNG bytes or nil
    func insert(_ key: ThumbnailCacheKey, png: Data) async // evict-to-cap on insert
    func flush(materializerVersion: UInt16) async          // evict every entry
                                                           // whose key version differs
    // NOTE: no invalidate(itemID:) — C1 retirement is LRU-lazy (§5.4), not
    // wake-driven; v1 HistoryInvalidation carries no itemID (05 §11 step 2).
}

internal struct ThumbnailCacheEntry: Sendable {
    let png: Data                               // the completed encoded thumbnail
    let contentVersion: ContentVersion          // provenance: the CV under which
                                                // the entry was produced. NOT a key
                                                // dimension; diagnostics/inspection
                                                // only — the C3 publish fence (§7)
                                                // re-checks the REQUEST's own
                                                // reference, not this field, so
                                                // this field is NOT on the serve
                                                // path.
    let builtAt: Date                           // build time; diagnostics. NOT the
                                                // C1 eviction key — C1 evicts by
                                                // the `lru` last-access map
                                                // (§5.3). builtAt is the durable
                                                // LRU anchor only for C2 (§6.2/
                                                // §6.5), where reads do not
                                                // rewrite the file to update
                                                // last-access.
}
```

The entry's `contentVersion` is **provenance, not a key, and not on the serve
path.** It records the `ContentVersion` verified at fetch time (`04` §9 step 2)
for diagnostics/inspection (the entry's age relative to the item's current
version). The C3 publish fence (§7) re-checks the **request's own** reference
against the item's current `ContentVersion` — it does **not** read this field —
so `contentVersion` is write-on-insert, read-only-by-diagnostics. Because the
key is `(itemID, sourceStamp, pixels, materializerVersion)`, two revisions of
the same item with the same image bytes share a key; the entry's
`contentVersion` reflects whichever revision produced (or last refreshed) the
entry.

### 5.2 Cache-law compliance (the C1 restatement)

The Part IV §12 law — *"For the same authoritative source state and request,
cache hit, cache miss, eviction, disabled cache, and process restart produce
semantically identical values and failures; only latency and resource use may
differ"* — holds for C1 with stamp-as-identity (§3.2):

- **Hit:** the served PNG is the PNG a miss would have produced at the same
  `(itemID, sourceStamp, pixels, materializerVersion)`. By materializer
  determinism (§4), ImageIO produces byte-identical output for identical source
  bytes + pixels + materializer version, so the cached PNG is byte-identical to
  a fresh decode **if** `C2-PLATFORM-3` confirms byte-determinism (§13 Record 3);
  otherwise the served PNG is *visually equivalent* (same pixels, possibly
  different encoded bytes), still cache-law-faithful for a *preview* (the cache
  serves thumbnails, not source bytes) and recorded as a second bounded
  deviation alongside the D7 residual (§3.2/§13 Record 4). The fence upstream
  (`04` §9 step 2) already verified the request's reference is current.
- **Miss:** the v1 decode path runs (`04` §9 step 6) and the result populates
  C1; the caller receives exactly what v1 would have returned.
- **Eviction (LRU or capacity):** an evicted entry is a miss on next read; v1
  decode re-runs. Byte-identical.
- **Disabled (C1 is always-on once G1 fires; there is no C1 disable toggle):**
  C1 ships only after the G1 trigger fires. If a future design adds a disable,
  the disabled path is a pure passthrough to v1 decode (byte-for-byte v1) — the
  cache-law disabled-path.
- **Restart:** C1 is in-memory and starts empty. The first read after restart
  is a miss (v1 decode); subsequent reads hit. Semantically identical to a miss;
  only latency differs. (Cross-launch reuse is C2's role, §6.)
- **Failure equivalence:** C1 adds no failure path. A thumbnail request that
  would fail `.staleContent` (stale reference at `04` §9 step 2) or return `nil`
  (no supported image representation, step 4) still does — those decisions are
  upstream of the cache lookup and unchanged.
- **The D7 residual (recorded deviation):** the only non-identical path is the
  xxh3-64 collision on the source-stamp identity (~7e-13, §3.2), which may serve
  a different valid thumbnail. This is the accepted, bounded deviation from
  *strict* semantic identity, recorded in §13 Record 4 and D30; it is transient,
  non-durable, and does not affect content/paste/detail.

### 5.3 ThumbnailCacheLimits (admission bounds)

A new V2 admission bound, `ThumbnailCacheLimits` (a `HistoryLimits`-peer fixed
value, `internal` to `HistoryStorage`; evaluated and checked by `HistoryStorage`,
not a user retention knob and not a modification of `HistoryLimits`, mirroring
`06` §2, `V2-01`'s `EnrichmentLimits`, `V2-03`'s `JournalLimits`):

| Bound | V2 value |
|---|---:|
| Max in-memory cache entries | 2,048 |
| Max in-memory cache bytes (`maxInMemoryBytes`) | 256 MiB |
| Max disk cache bytes (`maxDiskBytes`, default + clamp) | 512 MiB |
| Max disk cache entries | 20,000 |
| Single PNG encoded-output bound | 16 MiB (reused from `06` §2 "Encoded thumbnail output") |
| Thumbnail dimension per axis | 1–2,048 (reused from `06` §2; checked upstream by v1) |

Rules (matching `06` §2):

- All byte/count arithmetic is checked; overflow fails closed and never wraps
  (`06` §2, `02` §13).
- An `insert` that would exceed `maxInMemoryBytes` evicts LRU entries (oldest
  `(stamp, seq)` first — ties on `stamp` from sub-microsecond batched access break
  deterministically by the monotonic `seq`, so eviction order is reproducible)
  until the new entry fits or the cache is empty; insertion then succeeds. C1
  eviction is **bounded and amortized**: an `insert` performs at most a small
  bounded batch of LRU deletes per insert, each delete selecting the oldest entry
  by a bounded O(n) scan over the cap-bounded `lru` index (n ≤ 2,048 entries),
  never a synchronous unbounded sweep
  that could stall the actor's lookup path; budgeted by `C1-PERF-3` (§13 Record
  3). A single PNG exceeding `maxInMemoryBytes` (only possible if the 16 MiB
  output bound is raised in a future spec change) is not inserted (decoded-and-
  served-once, not cached).
- **Entry-count caps are enforced on both tiers.** C1 enforces its 2,048-entry
  cap and C2 enforces its 20,000-entry cap (§6.5): an insert that would exceed
  either count evicts oldest-first until both the byte cap *and* the entry-count
  cap are satisfied (whichever binds first triggers the pass; both are checked).
  The figure 20,000 is therefore a real bound, not advisory.
- `maxDiskBytes` is the **user-configurable** cap (clamped at the boundary to
  the `ThumbnailCacheLimits` ceiling); `maxInMemoryBytes` and the entry-count
  caps are fixed admission bounds (not user knobs), matching `V2-03` §4.5.

### 5.4 Invalidation

C1 is invalidated by two mechanisms, both correctness-preserving (over-
invalidation is safe — only latency suffers):

- **Stamp advance (lazy, by key mismatch).** There is no eager per-commit
  invalidation. When an item's image bytes change (a stamp-changing revision),
  the next request computes a new stamp → a new key → a natural miss; the old
  entry lingers until LRU-evicted. Lingering old entries are correct for any
  future item-state whose image bytes share that stamp (e.g., a revert), so
  eager invalidation would only reduce the S1 benefit.
- **Item retirement (lazy, via LRU — no eager per-item retire invalidation).**
  v1's `HistoryInvalidation` yield (`05` §11 step 2) carries only
  `latestPosition` (a position fence), **not** an `itemID` — there is no
  per-item retire signal on the post-commit stream to consume, so an eager
  `invalidate(itemID:)` has no trigger source. (Contrast `V2-03`'s
  `CollectionCache`, which is position-fence-invalidated, not per-item; C1 is
  not even position-fenced — a thumbnail request is guarded by the v1 fetch-
  time reference fence, `04` §9.) A retired item's entries are reclaimed
  **lazily by LRU** (§5.3): a lingering retired-item entry is harmless —
  `itemID` is never reused (`02` §9 step 9 / §14 D1), so it can never hit a different item —
  so delaying reclamation to the LRU path is correctness-preserving (over-
  retention is a memory cost, not a correctness cost). V2-04 therefore **adds
  no consumer** of the `HistoryInvalidation` yield for C1.
- **Materializer bump (eager, full flush).** `flush(materializerVersion:)` on a
  `bumpMaterializerVersion` (§10.3); every entry whose key's `materializerVersion`
  differs is dropped.

C1 correctness never depends on eager invalidation: the key mismatch (stamp
advance) + the v1 fetch-time fence (`04` §9 step 2) + the C3 publish fence (§7)
together ensure no wrong-bytes serve (except the D7 collision residual, §3.2).
Eager invalidation (the materializer-bump flush only) is a memory-footprint
optimization, not a correctness path (mirrors `V2-03` §7.3's position-fence
floor: correctness holds without per-item eager eviction).

## 6. C2 — Disk thumbnail cache

### 6.1 Role and isolation

`DiskThumbnailCache` is an internal `actor` that persists completed thumbnails
across launches (the G3 cross-launch-reuse trigger). It owns all file I/O for
the disk cache. **`NSFileCoordinator` is actor-confined:** `NSFileCoordinator`
is a non-`Sendable` `class` (`V2-04-facts.md` fact 1), so under Swift 6 complete
strict concurrency it must be created, used, and released entirely within the
`DiskThumbnailCache` actor — exactly as v1 confines the non-`Sendable` Fuse
matcher in `SearchWorker` (`01` §6) and `V2-01` confines `VNRecognizeTextRequest`
in `EnrichmentWorker` (`V2-01` §6.2). Apple documents that each coordinator is
"meant to be used on a per-file-operation basis" and "on a single thread only"
(fact 1); V2-04 satisfies both by the **per-operation-fresh-coordinator
discipline**: a fresh `NSFileCoordinator(filePresenter: nil)` is created at the
start of each coordinated actor method and released when the method's accessor
closure returns, so each coordinator lives entirely within one serialized
actor-method execution. The justification is per-operation freshness + the
actor's serialized method execution (which serializes those methods) — **not**
OS-thread affinity, which Swift 6 actors do not guarantee (an actor is a
serialized executor, not a pinned OS thread). No `@unchecked Sendable` /
`nonisolated(unsafe)` is introduced (`01` §8).

V2-04 does **not** register an `NSFilePresenter` for the cache directory: V2-04
admits no second writer (`V2-00` §3.1), so there is no in-process presenter to
coordinate against; `NSFileCoordinator` is used for its documented atomic-
coordination semantics (coordinated read/write that reconciles with any future
extension sharing the container) and for the coordinated-write -> atomic-rename
crash-safety pattern (§6.3), not for inter-process presenter notification. (If a
future graft admits an extension that writes the cache, that graft registers the
presenter; V2-04 states this honestly rather than assuming it.)

### 6.2 On-disk layout and ThumbnailDiskBlobV1 codec

**Location.** The disk cache lives under the app's per-user Caches directory in
a fixed subdirectory (`ThumbnailCache/`), resolved via `FileManager.url(for:in:appropriateFor:create:)`
against the user domain. This is the app's own container; no TCC permission or
privacy-usage string is expected (§12, proof gate `C2-SECURITY-1`). The location
is **independent of the SwiftData store URL** — the disk cache is not a SwiftData
artifact; deleting the store does not delete the cache and vice versa. The cache
directory is created lazily on first write.

**Sharded flat layout.** Files are named by a hex encoding of an xxh3-64 over the
`ThumbnailCacheKey` and sharded into a 2-level tree (first two hex characters as
the subdirectory) to avoid a single huge directory:

```text
< Caches >/ThumbnailCache/< shard >/< keyHash-hex >
```

Each file is a self-describing `ThumbnailDiskBlobV1` envelope. The filename hash
is a **lookup optimization only** — the authoritative key lives in the envelope
header, and decode re-validates the full key against the request (§6.3), so a
filename collision or a renamed file is detected and treated as a miss, never as
wrong bytes.

**Filename collision (write path).** Two distinct `ThumbnailCacheKey`s whose
xxh3-64 filename hashes collide (~5e-20 per pair; ~1e-11 at the 20,000-entry
disk cap, §3.2) write to the same path; the later write atomically replaces the
earlier file (§6.3), so the earlier entry is silently lost — its next access is
a miss and re-decodes. This is cache-law compliant (a miss is the law's required
fallback) and is stated honestly: the collision cost is a lost cache entry
(latency), never wrong bytes (the envelope key re-check, §6.3, catches any read
of a stale-overwritten file).

```swift
internal struct ThumbnailDiskBlobV1: Codable, Sendable {
    let formatVersion: UInt16       // exactly 1
    let itemID: UUID                 // HistoryItemID.rawValue; the key's ID
    let sourceStamp: UInt64          // ThumbnailSourceFingerprint.rawValue
    let pixelsWidth: Int             // key's PixelSize.width
    let pixelsHeight: Int            // key's PixelSize.height
    let materializerVersion: UInt16  // key's materializer version
    let contentVersionRaw: UInt64    // provenance (NOT a key dimension); the CV
                                      // under which the entry was produced
    let builtAt: Date                // wall-clock BUILD time; the durable LRU
                                      // ordering anchor for C2 + diagnostics
                                      // (content-defined, so it survives
                                      // copy/restore, unlike the filesystem
                                      // modificationDate). C2 disk eviction is
                                      // therefore oldest-BUILD-time — a wall-clock
                                      // approximation of access-LRU (disk reads
                                      // do not rewrite the file to update last-
                                      // access, unlike C1's `lru` map, §5.3).
    let checksum: UInt64             // xxh3-64 over encodedBytes (corruption
                                      // detection; evidence per D7, used only to
                                      // REJECT, never to ACCEPT)
    let encodedBytes: Data           // the completed PNG (≤ 16 MiB, 06 §2)
}
```

`ThumbnailDiskBlobV1` is declared `Sendable` explicitly because it crosses an
isolation boundary: the `DiskThumbnailCache` actor reads it from disk and the
decoded `Data` (PNG bytes) travels back to `ThumbnailService`. All stored
properties are `let` of `Sendable` types, so the conformance is derived without
`@unchecked Sendable`, mirroring `V2-01`'s `EnrichmentBlobV1` (`V2-01` §3.3).

**Decode is fail-soft-to-miss, NOT fail-closed.** This is the critical
difference from v1 SwiftData blob codecs (`05` §4) and `V2-01`'s
`EnrichmentBlobV1` (`V2-01` §3.3), which are fail-closed
(`.persistence(.corruptStoredValue)`). The disk cache is a **transparent
cache**: a corrupt/missing/expired entry is a *miss* (re-decode), never a
durability or correctness event. There is no caller-visible failure for a
corrupt cache file — the decode path falls through to a real thumbnail decode.
This is exactly the cache-law's "eviction/disabled/restart" half: loss degrades
to a miss + re-decode, the law's required outcome.

Decode validates:

- known `formatVersion` (exactly 1) — else miss;
- `pixelsWidth`/`pixelsHeight` in 1–2,048 (`06` §2) — else miss;
- `encodedBytes.count` ≤ 16 MiB (`06` §2) before any large allocation — else
  miss;
- `materializerVersion ==` the current compiled-in version — else treat as stale
  (miss + lazy delete on the next eviction pass);
- the **key re-check**: the request's `(itemID, sourceStamp, pixels,
  materializerVersion)` matches the envelope's fields — else miss (defends
  against filename collisions and renamed files);
- `checksum == xxh3(encodedBytes)` — else miss (a torn write, bit-rot, or a
  truncated file is detected and treated as a miss). Per D7 the checksum is
  evidence, not identity: a corrupted byte sequence whose xxh3 happens to
  collide with the stored checksum (~7e-13/~1e-11 at the disk cap, §3.2) would
  pass this check. Defense in depth, the PNG decoder rejects malformed bytes
  downstream, so even that residual degrades to a decode failure → miss, not to
  wrong bytes.

A file that fails any check is a miss for that request; the corrupt file is
deleted opportunistically (best-effort; deletion failure does not block the
miss). The decoder never substitutes, repairs, or returns partial bytes.

**Encode** starts from a validated `ThumbnailCacheKey` + completed PNG and is
deterministic. Round-trip equivalence is a V2 proof gate (`C2-PLATFORM-2`).

### 6.3 Crash safety and atomic write

Disk writes are crash-safe by construction:

- **Coordinated write + atomic rename.** A write proceeds as: (1) encode
  `ThumbnailDiskBlobV1`; (2) write to a temporary sibling file inside the cache
  directory under a coordinated write accessor (`NSFileCoordinator`); (3) `FileManager.replaceItem(at:withItemAt:backupItemName:options:)`
  (atomic replace) so the destination file is either the *previous* contents or
  the *complete new* contents, never a torn partial write. A crash mid-write
  leaves either the old file (if any) or no file — both are correct (a miss).
  The exact `NSFileCoordinator` coordinated-write accessor signature on macOS 26
  is assigned `C2-PLATFORM-1` (fact 1 verified the class; the specific Swift
  method spelling is OPEN, `V2-04-facts.md` OPEN 1).
- **No partial-state durability claim.** The disk cache makes no atomicity
  claim across multiple files. A crash between two `insert`s leaves whichever
  files were fully written; each is independently valid or absent. The cache
  (read path) tolerates any subset.
- **Version skew on open.** On `open`, `DiskThumbnailCache` does **not** scan
  every file (that would be an unbounded startup cost). Instead, the
  `materializerVersion` check at decode time (§6.2) lazy-deletes stale files on
  first access, and a bounded background sweep (§6.5) periodically reclaims
  stale + over-cap files. A stale file that is never re-accessed lingers until
  the sweep — harmless (it can only produce a miss when eventually read, because
  the `materializerVersion` check fails).

### 6.4 ThumbnailCacheConfigRow (V2 singleton)

A new `@Model` singleton stores the durable thumbnail-cache configuration. It is
internal to `HistoryStorage` and **does not modify any v1 model** (no column is
added to `HistoryItemRow` or `LastChangePositionRow`). It mirrors `V2-01`'s
`EnrichmentConfigRow` (`V2-01` §3.5), `V2-03`'s `JournalConfigRow` (`V2-03`
§4.6), and the v1 `LastChangePositionRow` singleton pattern (`05` §3.2):

```swift
@Model
internal final class ThumbnailCacheConfigRow {
    @Attribute(.unique)
    var key: String                       // always "thumbnail-cache"

    var diskCacheEnabled: Bool            // C2 capability gate; default false
                                          // (v1-faithful: no disk cache)
    var maxDiskBytes: Int                 // clamped to ThumbnailCacheLimits
    var materializerVersion: UInt16       // the thumbnail materializer schema
                                          // version (§4); bumped via
                                          // bumpMaterializerVersion(to:) by
                                          // ABSOLUTE value (§10.3). Overflow
                                          // discipline mirrors V2-03 §4.6.
    var configSchemaVersion: UInt16       // 1 for V2-04
}
```

`diskCacheEnabled == false` is the **v1-faithful mode**: no disk cache is
written or read; C1 (in-memory) may still be active (G1-separable from C2). With
both disabled, every thumbnail request runs the v1 decode path byte-for-byte.
The flag is written only through `HistoryAuthority` (single writer, §10.3);
toggling it is not a `HistoryAction` (it does not mutate history items and does
not advance `ChangePosition`) and therefore lives on the `ThumbnailCacheHistory`
protocol (§10), not on `HistoryAction`.

**`configSchemaVersion` contract (fail-closed).** `SwiftDataHistory.open`
validates `configSchemaVersion == 1` on the fetched singleton. An unknown
`configSchemaVersion` (forward-incompatible) or an out-of-range field combination
(e.g., `maxDiskBytes <= 0`) fails closed as
`.persistence(.corruptStoredValue)` / `.persistence(.invariantViolation)` rather
than being silently reset (`05` §4 exhaustive-decode discipline; mirrors
`V2-03` §4.6, `V2-02` §3.3). An absent row (the migrated-v1 case) is the only
"create with defaults" path.

**Singleton bootstrap at open (total order).** `SwiftDataHistory.open` performs
the V2-04 steps in a fixed total order, after the v1 position-singleton (`05` §13
step 3), the `V2-01`/`V2-02`/`V2-03` singletons, and before the facade is
published:

1. fetch the `ThumbnailCacheConfigRow` singleton (`key == "thumbnail-cache"`);
   validate exactly-one or zero;
2. **if absent (migrated v1 store):** create exactly one row with defaults
   (`diskCacheEnabled == false`, `maxDiskBytes ==` the
   `ThumbnailCacheLimits.maxDiskBytes` default, `materializerVersion ==` the
   compiled-in version, `configSchemaVersion == 1`);
3. **if present:** validate `configSchemaVersion == 1` and field ranges (fail-
   closed above);
4. **materializer-version detection (upgrade + downgrade):** compare
   `ThumbnailCacheConfigRow.materializerVersion` against the compiled-in
   materializer version. **Upgrade** (stored < compiled): `bumpMaterializerVersion(to:)`
   (§10.3) in its own transaction before the facade is published, so no caller
   can observe a cache whose `materializerVersion` disagrees with the running
   binary; C1 is empty at open (in-memory), and C2 stale files are reclaimed
   lazily (§4 bump-effect, §6.2/§6.5) — no eager whole-cache scan. **Downgrade**
   (stored > compiled — an older binary opening a cache last written by a newer
   binary): **fail-closed refuse** — `open` does not publish the facade and
   surfaces a "store written by a newer version" error
   (`.persistence(.invariantViolation)`). This refuse is **not correctness-
   required**: §6.2's decode-time `materializerVersion == compiled-in` check
   already treats every foreign-version (newer) disk file as a miss + lazy
   delete, so an older binary re-decodes fresh under its **own known**
   materializer (not an unknown one) and writes new files tagged with its
   compiled-in version - no wrong bytes in either direction, because the check
   is against the compiled-in version, not the singleton. The leave-singleton-
   as-is alternative (do not refuse; let §6.2 handle foreign-version files as
   misses) is therefore correctness-safe; it is rejected here in favor of the
   fail-closed refuse as a conservative one-way-door posture (a newer-version
   thumbnail's materialization shape is unknown to the older binary, and the
   refuse avoids serving any thumbnail whose provenance the older binary cannot
   vouch for), mirroring `V2-03` §4.6 step 4 exactly. **One-way-door
   consequence (product sign-off required):** because `materializerVersion`
   lives on the always-read `ThumbnailCacheConfigRow` singleton (not gated by
   `diskCacheEnabled`), any bump makes the store unopenable by every older
   binary — **app-wide, including users who never enabled the disk cache**. A
   thumbnail-materializer change is therefore a one-way door requiring explicit
   product sign-off per release. This consequence is recorded in §11.
5. **Disk cache directory bootstrap.** If `diskCacheEnabled`, ensure the cache
   directory exists (lazy-create); do **not** scan it at open (§6.3).
6. publish the facade.

This step applies to the `.memory` store path too — except the disk cache is
**inert** in `.memory` (no on-disk directory is used; `diskCacheEnabled` is
force-false for `.memory`, because `.memory` is for tests, `05` §2). C1
(in-memory) works identically in `.memory`.

### 6.5 Disk eviction and sweep

The disk cache is bounded by `maxDiskBytes`. Two reclamation mechanisms:

- **Insert-time cap.** An `insert` that would exceed `maxDiskBytes` or the
  20,000-entry disk cap (§5.3) triggers a bounded eviction pass: list the cache
  directory's files (a bounded `FileManager.contentsOfDirectory`, sharded so
  each shard is small), read each envelope's `builtAt` (the durable LRU ordering
  anchor, §6.2 — content-defined, so it survives copy/restore, unlike the file's
  `modificationDate` which a backup/restore can reset), and delete
  oldest-`builtAt` until **both** the byte cap and the entry-count cap are
  satisfied (whichever binds first triggers the pass; both are checked). The
  pass is bounded by the entry-count cap (`ThumbnailCacheLimits`); a single
  pass's cost is budgeted by `C2-PERF-2`.
- **Background sweep (runs independently of `diskCacheEnabled`).** A low-
  priority, cancelable periodic sweep (armed at `open`, on the
  `DiskThumbnailCache` actor's own executor) reclaims (a) stale files whose
  `materializerVersion` differs from the current (lazy delete), (b) over-cap
  files (byte and entry-count), and (c) retired-item files (oldest-`builtAt`
  LRU). **The sweep runs regardless of `diskCacheEnabled`:** a user who toggles
  the disk cache off (§10) leaves existing derived-preview files on disk (§11),
  and those files must still be reclaimed — the sweep is the mechanism.
  Additionally, **toggling `diskCacheEnabled` off triggers a best-effort final
  reclaim pass** on the actor so an opt-out user's derived previews do not
  linger until the next sweep cadence, and the cache directory's
  `URLResourceKey.isExcludedFromBackupKey` flag (`C2-SECURITY-2`) is set
  **eagerly on toggle-off** as defense in depth. The sweep cadence is wall-
  clock-bounded (unlike `V2-01`'s commit-driven orphan sweep, the disk sweep
  must run for inactive users too — the disk cache's footprint must be bounded
  regardless of commit rate or enable state). `C2-PERF-3` budgets the sweep,
  including the disabled-state reclaim.

Both mechanisms delete only cache files; they touch no SwiftData state, advance
no `ChangePosition`, and mint no `ContentVersion`. Deletion failure (file locked,
permission) is best-effort — the file lingers and is re-attempted next sweep;
the read path treats any unreadable file as a miss.

## 7. C3 — Publish-fence materialization lifecycle

### 7.1 Why C3 (the G6 trigger's value)

v1 single-flight + the fetch-time version fence (`04` §9) already ensure
correctness: a stale-reference request fails (`.staleContent`), a result is
tagged with its verified reference, and the caller applies it only if its row
still carries that reference (`04` §9 step 6). The G6 trigger
("≥ 20% of thumbnail work is superseded or discarded despite cancellation and
single-flight") measures that a substantial fraction of completed decodes are
discarded at the caller — because the item was revised mid-decode, the view
scrolled away, or a newer request superseded an in-flight one.

C3 makes the materialization lifecycle an **explicit, tracked state machine**
with a **publish-time fence**, extending (not replacing) the v1 fetch-time
fence. **C3 is a tag-and-observe design, not a delivery-prevention design:** the
v1 caller-side contract (`04` §9 step 6 — "applies it only if its row still
carries that reference") remains the sole delivery arbiter, unchanged; a
superseded result is still *returned to the caller*, tagged with its fetch-time-
verified reference, exactly as in v1. C3 does **not** stop the caller from
receiving a superseded payload — it makes the supersession *observable*. Its
incremental value over v1:

1. **Supersession observability + G6 measurement.** A result whose reference was
   superseded between fetch and publish is marked `.superseded` in the lifecycle
   table (and transitions to `.discarded`), recording *that* this produce was
   superseded — for diagnostics and for the supersession accounting that feeds
   the G6 measurement. The payload is still returned to the caller, tagged with
   the fetch-time reference (v1 contract preserved, §7.3). This is the
   capability the G6 trigger measures; without C3 the supersession is invisible
   (the caller silently discards). The G6 trigger's "wasted work" framing is
   addressed by *observability* (measuring the supersession fraction) + *cache-
   insertion hygiene* (point 2), **not** by preventing delivery — V2-04 states
   this honestly rather than claiming C3 reduces wasted caller-side apply work
   (it does not; the caller still receives and discards, as in v1).
2. **Cache-insertion hygiene.** A `.superseded` result is still inserted into
   C1/C2 (stamp-keyed insertion is safe by construction, §3.2/§7.3 — the entry
   is correct for any future request with that stamp), and the lifecycle records
   that it was a superseded produce. This is the real "wasted work" recovery: v1
   discards completed bytes (`04` §9 step 7); V2-04 retains the superseded
   decode's bytes so a revert or a same-image revision hits instead of re-
   decoding — the G1/G3 benefit delivered through the C3-tagged path.
3. **Supersession coordination (publication-right tracking).** A newer request
   for the same item that arrives mid-decode supersedes the in-flight decode's
   *publication right*; the older decode, when it completes, transitions
   `.ready → .superseded → .discarded`. The decode is **not** canceled — its
   bytes are cached (point 2) — and its payload is still returned to its caller
   tagged with its (now-superseded) reference; the v1 caller-side check decides
   whether it is applied. C3 tracks the publication right for lifecycle
   accounting, not to suppress delivery.

C3 is **not** on the correctness path for "no wrong bytes" or "no stale
delivery": the v1 fetch-time fence + the v1 caller-side reference check already
guarantee both (except the D7 residual). C3 is an **observability + cache-
hygiene lifecycle** that makes supersession measurable and retains superseded
bytes for reuse. D31 (§14) is stated accordingly: it guarantees a superseded
result is never ***published as current*** (i.e., never delivered *under a
reference it did not verify*) — which is exactly what tagging + the v1 caller-
side check already enforce; C3 makes the lifecycle explicit and tracked, it does
not change what the caller receives.

### 7.2 States and transitions

```swift
internal enum ThumbnailMaterializationState: Sendable, Hashable {
    case pending        // request accepted, source not yet fetched
    case decoding       // fetch done; decode in progress on ThumbnailWorker
                        // (single-flight-joined)
    case ready          // decode complete; PNG bytes available
    case published      // terminal: the publish fence (§7.3) confirmed the
                        // request's reference is still current; the result is
                        // delivered to the caller and inserted into C1 (and C2
                        // if enabled). Per-caller outcome (§9.2).
    case superseded     // the request's reference is no longer current, OR a
                        // newer request for the same item superseded this
                        // publication right
    case discarded      // terminal: PAYLOAD IS STILL RETURNED TO THE CALLER
                        // (tagged, NOT dropped) - the result was superseded
                        // (NOT delivered AS CURRENT); the payload was still
                        // returned to the caller tagged with its fetch-time
                        // reference per the v1 contract (04 §9 step 6, §7.3).
                        // The bytes MAY still have been inserted into C1/C2
                        // (stamp-keyed safe insertion, §7.3).
}
```

The state machine is owned by `ThumbnailService` (the v1 actor that owns the
single-flight table, `01` §6), tracking each in-flight materialization **per
call** (a per-call `ThumbnailFenceKey`, because concurrent same-key callers have
independent publish outcomes, §9.2 — not keyed by the `ThumbnailCacheKey`
alone). It is **actor-confined state** (no `@unchecked Sendable`); it holds no
`@Model`/`ModelContext`. Transitions:

```text
                    ┌──────────────────────────────────────────────────┐
                    ▼                                                  |
  request ──> pending ──> decoding ──> ready ──> published (terminal:   |
                │            │           │       result delivered;      |
                │            │           │       bytes inserted C1/C2)  |
                │            │           │                              |
                │            │           └──> superseded ──> discarded  |
                │            │                  (reference superseded   |
                │            │                   between fetch and      |
                │            │                   publish; tagged, not as |
                │            │                   current; inserted)     |
                │            └────────────────> superseded ──> discarded|
                │                               (reference superseded  |
                │                                during decode)         |
                └──────────────────────────> discarded (canceled before |
                                            decode; no bytes)           |
```

- `pending → decoding`: the v1 fetch-time interval completed (steps 2–3), the
  source bytes + stamp are in hand, and the single-flight decode is starting.
- `decoding → ready`: the decode completed; the PNG bytes are available,
  tagged with the fetch-time reference.
- `decoding → superseded`: the item was revised mid-decode such that a newer
  request now holds the publication right for that item (or the caller
  canceled). When the decode completes, the result transitions `.ready →
  .superseded` and is tagged (not *published as current*; its payload is still
  returned to the caller tagged with the superseded reference, §7.1).
- `ready → published` (terminal): the publish fence (§7.3) confirmed the
  reference is still current; the result is delivered to the caller and inserted
  into C1 (and C2 if enabled).
- `ready → superseded → discarded`: the reference was superseded between decode
  completion and the publish fence; the result is not *published as current*
  (its payload is still returned tagged) and is still inserted (stamp-keyed safe
  insertion).
- `pending → discarded` / `decoding → discarded`: caller cancellation before
  publication; no bytes are published (a canceled decode's bytes, if completed,
  are still cached — stamp-keyed safe).

**Fence-table terminal-state cleanup.** The lifecycle table entry for a call is
**reaped when the request reaches a terminal state** (`.published` or
`.discarded`): the entry is removed once that call's `thumbnail(for:pixels:)`
returns, so the table holds only *in-flight* materializations. Because the table
is keyed **per call** (concurrent same-key callers have independent outcomes,
§9.2), its steady-state size is the in-flight **call** count (UI thumbnail-
request concurrency) — ≥ the single-flight table size whenever callers join —
never the cumulative request count (no unbounded terminal accumulation, no
memory leak). D31 (§14) records this reap-on-terminal discipline.

### 7.3 The publish fence (D31)

The publish fence is the **publish-time** currency check that gates delivery to
the caller. It is the complement of the v1 **fetch-time** fence (`04` §9 step 2):

```text
ThumbnailService.thumbnail(for ref: HistoryItemReference, pixels: PixelSize):
  [fetch-time fence — v1 04 §9 steps 2–3, UNCHANGED, one non-suspending
   Authority interval]
    fetch item, verify item.contentVersion == ref.contentVersion  (else .staleContent)
    derive Effective Content, select image source bytes B (04 §9 step 3)
    [if no supported image representation: return nil — v1 04 §9 step 4,
     UNCHANGED; no cache consultation, no decode, no fence registration]
    compute sourceStamp = xxh3(B)
    build cacheKey = (ref.itemID, sourceStamp, pixels, compiledMaterializerVersion)
    build selection = ThumbnailSourceSelection(ref: ref, sourceBytes: B, cacheKey: cacheKey)
    [release all @Model + the context]
  [C3 lifecycle]
    state = .pending; register ((cacheKey, ref) -> state) in the per-call fence table (§9.2)
  [C1 lookup — outside the Authority interval, an `await`]
    cached = await thumbnailCache.lookup(cacheKey)
    if cached == nil && diskCacheEnabled:
        diskHit = await diskThumbnailCache.lookup(cacheKey)   [NSFileCoordinator read]
        if diskHit:
            await thumbnailCache.insert(cacheKey, diskHit)    [promote to C1]
            cached = diskHit
  if cached != nil:
    state = .ready
    [publish fence]
    if await publishIfCurrent(cacheKey, ref):   [§7.3]
        state = .published
        return ThumbnailPayload(item: ref, pixels: pixels, format: .png,
                                encodedBytes: cached)
    else:
        state = .superseded; state = .discarded
        return ThumbnailPayload(item: ref, pixels: pixels, format: .png,
                                encodedBytes: cached)   [delivered per v1 contract:
                                                         caller applies only if its
                                                         row still carries ref;
                                                         04 §9 step 6. The fence did
                                                         not re-publish; it tagged.]
  else:
    [single-flight join/create on cacheKey — v1 04 §9 step 5, join key
     SUBSTITUTED (reference -> stamp), §9.2]
    state = .decoding
    png = await thumbnailWorker.decode(B, pixels)   [off-Authority, ImageIO; 04 §9 step 6]
    [insert into C1/C2 — stamp-keyed safe insertion, §7.3 below]
    await thumbnailCache.insert(cacheKey, png)
    if diskCacheEnabled:
        await diskThumbnailCache.insert(cacheKey, png)   [coordinated atomic write]
    state = .ready
    [publish fence]
    if await publishIfCurrent(cacheKey, ref):
        state = .published
        return ThumbnailPayload(item: ref, pixels: pixels, format: .png, encodedBytes: png)
    else:
        state = .superseded; state = .discarded
        return ThumbnailPayload(item: ref, pixels: pixels, format: .png,
                                encodedBytes: png)   [v1 caller-side contract]
```

`publishIfCurrent(cacheKey, ref)` is the publish-time fence. It re-checks that
the request's reference `ref` is still the item's current `ContentVersion` (a
cheap scalar Authority read, single-item, non-suspending interval — mirrors the
v1 fetch-time fence's step 2 but at publish time). If the item was revised
mid-decode, `ref.contentVersion < item.contentVersion` and the fence returns
false → `.superseded`. If unchanged, the fence returns true → `.published`.

**Stamp-keyed safe insertion (why a superseded result is still cached).**
Because the cache key is `(itemID, sourceStamp, pixels, materializerVersion)`
(§3.2) and the entry's bytes are the deterministic decode of the bytes that
produced `sourceStamp`, the entry is **correct by construction for any future
request whose source bytes share that stamp**, regardless of whether the
*current* request was superseded. Inserting a superseded result does not pollute
the cache: a future request at a newer `ContentVersion` whose image bytes happen
to match (e.g., a revert) will correctly hit. This is the key consequence of
stamp-keying — insertion is unconditional on caller currency; only *publication-
as-current* is tagged (the lifecycle tag), and the payload is returned to the
caller in both branches. Delivery/application is governed by the v1 caller-side
check (`04` §9 step 6), not by C3. (Under a `ContentVersion`-keyed design, a
superseded result's insertion would key on a stale CV and could be served under
a wrong state; stamp-keying eliminates that risk. This is a second reason —
beyond the G4 benefit — to prefer stamp-keying, §3.2.)

**D31 (publish-fence no-stale-publish-as-current — lifecycle tagging).** A
superseded materialization result is never *published as current* (delivered
under a reference that is no longer the item's current `ContentVersion`); the
publish fence **tags** the result (`.published` vs `.superseded → .discarded`)
and the payload is returned to the caller in both branches. The v1 caller-side
contract (`04` §9 step 6: "applies it only if its row still carries that
reference") is the **sole delivery arbiter** (unchanged) — C3 makes supersession
observable, it does not prevent delivery. C3 makes the lifecycle explicit and
tracked; it preserves the v1 invariant and extends it with the
`.superseded`/`.discarded` states.

**Mid-decode revert (benign edge case).** If an item is revised mid-decode in a
way that advances `ContentVersion` but leaves the image bytes — hence the stamp
— unchanged (e.g., a text-representation edit on a multi-representation item),
the publish fence sees `ref.contentVersion < item.contentVersion` and tags the
result `.superseded` even though the decoded bytes are identical to the current
item's thumbnail. This is benign: the caller discards per the v1 contract, the
bytes are cached (stamp-keyed safe insertion above), and the next request (with
a current reference and the same stamp) hits C1 and is served. C3 tags
conservatively (any CV advance supersedes); it does **not** re-check the stamp
at publish time, because doing so would require a re-fetch of the source bytes
at publish — exactly the cost the stamp was designed to avoid (§3.2).

### 7.4 Relationship to the v1 fetch-time fence (not a replacement)

The two fences are complementary and both ship:

- **v1 fetch-time fence (`04` §9 step 2):** runs *before* source selection.
  Ensures the request's reference is current when source bytes are picked and
  the stamp is computed. A stale-reference request fails `.staleContent` here.
  **Unchanged by V2-04.**
- **C3 publish fence (§7.3):** runs *after* decode, before delivery. Ensures a
  result whose reference aged out during decode is not published as current.
  **New in V2-04.**

A result can pass the fetch-time fence and fail the publish fence (the item was
revised during decode). It can never fail the fetch-time fence and reach the
publish fence. The two never disagree on acceptance; the publish fence is
strictly later and stricter only about mid-decode supersession.

## 8. Data flow (the extended thumbnail pipeline)

The V2-04 thumbnail pipeline extends the v1 `04` §9 flow with cache consultation
(C1/C2) and the publish fence (C3). It branches at two points: after the
fetch-time interval (cache lookup) and after decode (publish fence). The v1
fetch-time interval and the v1 decode are **unchanged in shape**.

```text
Caller ──> ThumbnailService.thumbnail(for: ref, pixels:)
  [v1 fetch-time fence — 04 §9 steps 2–3, UNCHANGED, one non-suspending
   HistoryAuthority interval]
    Authority.thumbnailSource(for: ref, pixels):
       create operation-local context
       fetch item by HistoryItemID (05 §5 fetch-predicate discipline)
       verify item.contentVersionRaw == ref.contentVersion.rawValue   (else .staleContent)
       derive Effective Content (02 §2.6)
       select the supported image representation bytes B (04 §9 step 3; 05 §14.5)
       [if no supported image representation: return nil — 04 §9 step 4, UNCHANGED]
       compute sourceStamp = ThumbnailSourceFingerprint(rawValue: xxh3(B))
       build cacheKey = (ref.itemID, sourceStamp, pixels, compiledMaterializerVersion)
       return ThumbnailSourceSelection(ref: ref, sourceBytes: B, cacheKey: cacheKey)
       [release all @Model + context; no @Model crosses isolation]
  guard let selection else { return nil }   [v1 04 §9 step 4; no cache, no decode]
  [C3: register .pending — per-call fence key (cacheKey, ref), §9.2]
  [C1 lookup — `await` on the ThumbnailCache actor, OUTSIDE the Authority interval]
    cached = await thumbnailCache.lookup(selection.cacheKey)
    if cached == nil && ThumbnailCacheConfigRow.diskCacheEnabled:
        [C2 lookup — `await` on the DiskThumbnailCache actor, NSFileCoordinator read]
        diskHit = await diskThumbnailCache.lookup(selection.cacheKey)
        if let diskHit:
            await thumbnailCache.insert(selection.cacheKey, diskHit)   [promote]
            cached = diskHit
  if let cached:
    [C3: .ready]
    [publish fence — `await` publishIfCurrent (a scalar Authority CV re-read)]
    [C3: .published | .superseded → .discarded]
    return ThumbnailPayload(item: ref, pixels: pixels, format: .png, encodedBytes: cached)
  else:
    [v1 single-flight — 04 §9 step 5, join key SUBSTITUTED (reference -> stamp)
     to ThumbnailCacheKey, §9.2]
    join/create flight for selection.cacheKey
    [C3: .decoding]
    png = await thumbnailWorker.decode(selection.sourceBytes, pixels)
                          [off-Authority, ImageIO; 04 §9 step 6 — UNCHANGED]
    [insert — stamp-keyed safe insertion (§7.3)]
    await thumbnailCache.insert(selection.cacheKey, png)
    if ThumbnailCacheConfigRow.diskCacheEnabled:
        await diskThumbnailCache.insert(selection.cacheKey, png)
    [v1: remove the flight entry on success/failure/cancellation — 04 §9 step 7,
     EXTENDED: the bytes are RETAINED in C1/C2 (the G1/G3 lift, §1.2)]
    [C3: .ready]
    [publish fence]
    [C3: .published | .superseded → .discarded]
    return ThumbnailPayload(item: ref, pixels: pixels, format: .png, encodedBytes: png)
```

### 8.1 Why this preserves v1

- **The fetch-time interval is unchanged.** Steps 2–3 run in one non-suspending
  `HistoryAuthority` interval (`04` §9); the stamp computation adds one xxh3-64
  (the v1 primitive, `01` §4) over bytes already in hand — O(n) in the source
  byte count, no suspension, no `@Model` crossing. The v1 fence semantics (no
  commit can interleave between the version check and the Effective-Content
  derivation) are preserved. **The source fetch + stamp are paid on every
  consultation, hit or miss** (the stamp is computed from bytes that must be
  fetched inside the `04` §9 interval regardless): a C1 hit avoids the *decode*,
  not the fetch. The C1 benefit is therefore decode-avoidance, bounded by
  `C1-PERF-2`'s net end-to-end latency gate (§13 Record 3); the in-interval
  xxh3-64 cost at the 64 MiB representation ceiling (`06` §2) is budgeted by
  `C1/C2/C3-PERF-4`.
- **The decode is unchanged.** `ThumbnailWorker.decode` runs off-Authority
  (`04` §9 step 6, `05` §14.5); non-`Sendable` ImageIO objects
  (`CGImageSource`, `CGImageDestination`) are created and consumed entirely
  inside the worker actor (`01` §6). V2-04 adds no decode work, changes no
  decode parameters, and introduces no new framework import on the decode path
  (ImageIO is already imported in `HistoryStorage`, `01` §4).
- **Single-writer is preserved.** The caches are read/written on their own
  actors; they never create a `ModelContext`. The publish fence's scalar CV
  re-read goes through `HistoryAuthority` (`05` §5). No second writer, no
  external path, no new context creator (decision §15; D29, §14).
- **The cache is transparent.** A hit returns the bytes a miss would have
  produced (cache law, §5.2/§13 Record 4). The `ThumbnailPayload` returned to
  the caller is byte-identical whether the bytes came from C1, C2, or a fresh
  decode. The caller cannot observe which path served the request.
- **Post-commit order is unchanged.** V2-04 adds **no** consumer of the
  transient `HistoryInvalidation` yield (`05` §11 step 2): C1 retirement is
  LRU-lazy (§5.4), not wake-driven, so the Authority's post-commit phase is
  literally unchanged. The caches advance no `ChangePosition` and yield no
  `HistoryInvalidation` of their own. (Contrast `V2-03`'s `CollectionCache`,
  which does consume the position yield; V2-04's thumbnail cache does not.)

## 9. Code model

### 9.1 Module and target placement

- **Public surface** (`ThumbnailCacheHistory` protocol, `ThumbnailCacheStatus`)
  is added to `HistoryCore` as a clearly V2-scoped section, Foundation-only
  (`01` §8). These types reuse v1 vocabulary (`HistoryItemID`) verbatim and add
  no name that collides with v1 vocabulary (`V2-00` §9). The thumbnail *request*
  surface (`ThumbnailPayload`, `PixelSize`, `ThumbnailFormat`,
  `HistoryItemReference`, `03b` §9) is **unchanged** — V2-04 adds no thumbnail
  request type. Adding new types to `HistoryCore` is a "capability-gated
  extension of an existing module" (`V2-00` §2.1); no existing v1 `HistoryCore`
  type is modified.
- **Implementation** (`ThumbnailCache`, `DiskThumbnailCache`,
  `ThumbnailPublishFence`/the state machine on `ThumbnailService`,
  `ThumbnailCacheConfigRow`, `ThumbnailDiskBlobV1`, the cache-key types, the
  `thumbnailSource`/`bumpMaterializerVersion`/config Authority methods) is added
  to `HistoryStorage`. **No new framework import** (V2-04 uses only Foundation +
  the ImageIO + SwiftData already imported in `HistoryStorage`, `01` §4/§8); the
  import gate (`01` §9) is **unchanged** (contrast `V2-01`, which added
  `Vision`/`PDFKit`). `NSFileCoordinator` and `FileHandle` are Foundation
  (`V2-04-facts.md` facts 1, 3) — already permitted in `HistoryStorage`.
- `SwiftDataHistory` gains a `ThumbnailCacheHistory` conformance;
  `ThumbnailCache` and `DiskThumbnailCache` are stored fields of
  `SwiftDataHistory` (extending its actor field set, `05` §2). Both are `actor`
  types, so `SwiftDataHistory: Sendable` remains derived without
  `@unchecked Sendable` (`01` §6). This is a private stored-field addition to a
  v1 public concrete type, exactly as `V2-01` added
  `EnrichmentWorker`/`EnrichmentScheduler` (`V2-01` §6.1) and `V2-03` added
  `ChangeJournal`/`CollectionCache` (`V2-03` §10.1); the public interface is
  unchanged (additive extension under the V2 self-review gate, `V2-00` §8).

### 9.2 ThumbnailService (v1 actor, extended)

`ThumbnailService` remains the single-flight coordinator (`01` §6). V2-04
extends it to:

- hold references to `ThumbnailCache` (C1) and `DiskThumbnailCache` (C2) —
  `actor` references, `Sendable`;
- own the `ThumbnailPublishFence` state table (C3) as actor-confined state;
- drive the extended pipeline (§8).

The v1 `ThumbnailFlightKey` (`04` §9) is **subsumed** by the
`ThumbnailCacheKey` (§3.2): the v1 key `(HistoryItemReference, PixelSize)` is
replaced by `(itemID, sourceStamp, pixels, materializerVersion)`. This is a
**substitution of the single-flight join key, not a pure addition** — the keying
dimension changes from the v1 reference (which carries `ContentVersion`) to the
stamp (which does not), so two concurrent requests for the same item at
different `ContentVersion` but the same image bytes now **join the same flight**
(whereas v1 would have flown them separately). This is the single-flight facet
of the §3.2 stamp-keying decision (intentional, for the S1 benefit). It is a
private internal-type substitution (the v1 `ThumbnailFlightKey` is internal to
`HistoryStorage`, `04` §9), not a public-type modification; it is recorded as a
substitution (not a pure extension) in the §14 self-review. **Join predicate (corrected — NOT v1's "identical-concurrent-request" join).**
The single-flight join predicate is the stamp-based `ThumbnailCacheKey`, **not**
the v1 `(reference, pixels)` tuple. Under stamp-keying the join is **broader**
than v1's: concurrent requests for the same item at *different*
`ContentVersion` but the *same* image bytes (hence the same stamp) coalesce
into one decode flight. The v1 "identical-concurrent-request join" wording is
therefore **not preserved verbatim** — V2-04 substitutes a broader, stamp-
equivalence join (the single-flight facet of the §3.2 decision). What IS
preserved is the single-flight *machinery*: one decode `Task` per cacheKey, and
flight-entry removal on success/failure/cancellation (`04` §9 step 7); V2-04's
only change to step 7 is that the completed bytes are **retained** in C1/C2
(the G1/G3 lift) before the flight entry is removed.

**Per-caller publish fence (concurrent same-key callers).** Joining callers
share the decode `Task` but each carries its **own** `HistoryItemReference`
(its own fetch-time `ContentVersion`). The publish fence (§7.3) therefore runs
**per caller**, not per flight: `publishIfCurrent(cacheKey, callerRef)` re-
checks **that caller's** reference against the item's current `ContentVersion`.
Two callers joined to the same flight may get **different** publish outcomes —
caller A (reference aged out mid-decode) tags `.superseded → .discarded` while
caller B (reference still current) tags `.published` — even though both receive
bytes from the one shared decode. The lifecycle state is consequently tracked
**per in-flight call**, not per cacheKey: the fence table is keyed to
distinguish concurrent same-key callers (a per-call `ThumbnailFenceKey` — e.g.
the call's own `(cacheKey, reference)` — so each joining caller has its own
entry; callers sharing both cacheKey and reference share an outcome, so one
entry is correct for them). The table is reaped per-call when
`thumbnail(for:pixels:)` returns (§7.2 reap discipline); its steady-state size
is bounded by the in-flight *call* count (UI thumbnail-request concurrency),
which is ≥ the single-flight table size whenever callers join. This per-caller
keying is the lifecycle facet of the §3.2 stamp-keying decision and is recorded
alongside the join-key substitution in the §14 self-review.

```swift
internal struct ThumbnailFenceKey: Hashable, Sendable {
    // Per-call fence identity (§9.2). Two callers joined to the same single-
    // flight decode (same ThumbnailCacheKey) but with different references can
    // have different publish outcomes, so the fence table keys on the call, not
    // the cacheKey alone. Callers sharing both cacheKey and reference share an
    // outcome, so one entry is correct for them.
    let cacheKey: ThumbnailCacheKey
    let callRef: HistoryItemReference
}

internal actor ThumbnailService {
    private let authority: HistoryAuthority        // Sendable actor ref
    private let worker: ThumbnailWorker            // v1 actor (ImageIO decode)
    private let cache: ThumbnailCache              // C1 (new)
    private let diskCache: DiskThumbnailCache      // C2 (new)
    private var fence: [ThumbnailFenceKey: ThumbnailMaterializationState]   // C3 (new;
                                                                          // per-call, §9.2)
    private var flights: [ThumbnailCacheKey: Task<Data, Error>]            // single-flight
                                                                          // (per cacheKey)

    func thumbnail(for ref: HistoryItemReference, pixels: PixelSize) async throws
        -> ThumbnailPayload?

    // C3 publish fence (§7.3): re-checks the caller's reference is still the
    // item's current ContentVersion before delivery and transitions the per-call
    // fence entry (§9.2). Delegates the currency read to
    // Authority.isThumbnailReferenceCurrent(ref) (§9.4); the cacheKey keys the
    // per-call fence-table entry, not the Authority read.
    private func publishIfCurrent(_ cacheKey: ThumbnailCacheKey,
                                  _ ref: HistoryItemReference) async throws -> Bool
}
```

### 9.3 ThumbnailCache and DiskThumbnailCache actors

```swift
internal actor ThumbnailCache {        // C1
    private var entries: [ThumbnailCacheKey: ThumbnailCacheEntry]
    private var totalBytes: Int
    private var lru: [ThumbnailCacheKey: (stamp: Date, seq: UInt64)]
    private var lruSeq: UInt64 = 0
    private let limits: ThumbnailCacheLimits

    func lookup(_ key: ThumbnailCacheKey) async -> Data?
    func insert(_ key: ThumbnailCacheKey, png: Data) async
    func flush(materializerVersion: UInt16) async
    // No invalidate(itemID:) — retirement is LRU-lazy (§5.4); v1
    // HistoryInvalidation carries no itemID (05 §11 step 2).
}

internal actor DiskThumbnailCache {   // C2
    private let rootURL: URL                     // <Caches>/ThumbnailCache/
    private let limits: ThumbnailCacheLimits
    // NSFileCoordinator is created per-operation inside a method, confined to
    // this actor (non-Sendable class, V2-04-facts.md fact 1), and released when
    // the coordinated accessor closure returns. No coordinator is stored.

    func lookup(_ key: ThumbnailCacheKey) async -> Data?          // coordinated read
    func insert(_ key: ThumbnailCacheKey, png: Data) async        // coordinated atomic write
    func sweep() async                                            // background reclamation (§6.5)
    func deleteStale(materializerVersion: UInt16) async           // sweep-invoked stale reclaim
                                                                  // (NOT bump-eager; §4/§9.4)
}
```

Both actors hold only `Sendable` values (`Data`, `URL`, value-type key/entry
structs). Neither holds `@Model` or `ModelContext`, and **neither creates a
writable `ModelContext`**: all durable config goes through `HistoryAuthority`
(§10.3), preserving the single-context-creator rule (`05` §5). The cache/cache-
key/entry types are all `Sendable` value types (all-`let` `Sendable` members),
so no `@unchecked Sendable` is introduced.

**`await` placement (the isolation model).** The two `await`s the
`ThumbnailService.thumbnail` path performs — `cache.lookup` and (on miss)
`diskCache.lookup`/`insert` — are **outside** the `04` §9 non-suspending
Authority interval (the interval ends when `thumbnailSource` returns the
selection and releases the context). They add **no suspension inside the
serialized interval**. This **follows the same isolation discipline** as
`V2-03` §7.1's `CollectionCache` (M1: cache actor crossing is an `await`
outside the serialized interval), but the **ordering differs** and the two are
**not mirrors**: V2-04 consults the cache *between* two fences (cache lookup
after the fetch-time interval, publish fence after decode), whereas `V2-03`'s
collection cache fences at serve with a single position fence. They share only
the no-suspension-in-the-Authority-interval property. The publish fence's scalar
Authority CV re-read is a separate small non-suspending interval of its own
(single-item scalar read, `05` §5).

### 9.4 Authority methods (single-writer preservation)

New `HistoryAuthority` methods, all opening a fresh operation-local context and
releasing it before return (`05` §5), none advancing `ChangePosition`:

```swift
internal extension HistoryAuthority {
    // Read: thumbnail source fetch (v1 05 §14.5, EXTENDED to also return the
    // S1 stamp + the composed cacheKey). One non-suspending interval; no @Model
    // crosses isolation. Fails .staleContent if ref is not current (v1 04 §9 step 2).
    func thumbnailSource(for ref: HistoryItemReference, pixels: PixelSize)
        async throws -> ThumbnailSourceSelection?

    // Read: publish-fence currency check (C3 §7.3). A scalar single-item CV
    // read; returns whether ref is still the item's current ContentVersion.
    // Separate non-suspending interval.
    func isThumbnailReferenceCurrent(_ ref: HistoryItemReference) async throws -> Bool

    // Write: UX-bound config changes (§10). Own transaction; no ChangePosition,
    // no HistoryInvalidation (not a History Commit). Clamps to
    // ThumbnailCacheLimits at the boundary.
    func setThumbnailCacheConfig(diskEnabled: Bool?, maxDiskBytes: Int?) async throws

    // Write: materializer-version bump (own transaction; no ChangePosition).
    // Bumps ThumbnailCacheConfigRow.materializerVersion by ABSOLUTE value.
    // Flushes C1; C2 stale files reclaimed LAZILY (decode-time check + sweep,
    // §6.2/§6.5) — NO eager whole-cache scan/delete (§6.3 no-open-scan).
    func bumpMaterializerVersion(to newVersion: UInt16) async throws
}
```

`thumbnailSource` is the v1 `05` §14.5 thumbnail source fetch, extended to also
compute the S1 stamp and compose the `ThumbnailCacheKey` inside the same
non-suspending interval. It performs no decode (decode is `ThumbnailWorker`,
unchanged). `isThumbnailReferenceCurrent` is the publish-fence substrate — a
cheap scalar read. `setThumbnailCacheConfig` and `bumpMaterializerVersion` are
the **writer path for the `ThumbnailCacheConfigRow` fields**: D29 requires
config writes to go through the Authority (single-writer for cache config), and
these are the methods that fulfill it. Neither is a History Commit: neither
advances `ChangePosition`, and neither yields a `HistoryInvalidation` (a config
change is not a content change — though `bumpMaterializerVersion` does call
`ThumbnailCache.flush()`; C1 is empty at open for an open-time bump, and C2
stale files are reclaimed lazily by the decode-time check + the background sweep
(§6.2/§6.5), **not** by an eager `deleteStale` scan, because a materializer bump
structurally invalidates every cached thumbnail but V2-04 pays that reclamation
lazily — a stale file can only produce a miss). `bumpMaterializerVersion` is
also called from the open-time materializer-version detection (§6.4 total order
step 4): `open` compares `ThumbnailCacheConfigRow.materializerVersion` to the
compiled-in version and bumps before the facade is published if they differ.
None of these methods is part of the `HistoryAction` dispatch (`05` §8); the
closed `HistoryAction` switch is unchanged.

## 10. Public surface (ThumbnailCacheHistory)

A new public protocol in `HistoryCore`, conformed by `SwiftDataHistory`. It is a
"distinct concern" protocol (`V2-00` §6.5), not an extension of `ClipboardHistory`
(mirrors `V2-01`'s `EnrichmentHistory`, `V2-01` §8; `V2-03`'s `ReconnectHistory`,
`V2-03` §6.3). It exposes only the **cache config + status** — the thumbnail
*request* surface stays on `ClipboardHistory` unchanged.

```swift
public protocol ThumbnailCacheHistory: Sendable {
    func thumbnailCacheStatus() async throws -> ThumbnailCacheStatus
    func setDiskThumbnailCacheEnabled(_ enabled: Bool) async throws
    func setMaxDiskThumbnailCacheBytes(_ maxBytes: Int) async throws
    func clearDiskThumbnailCache() async throws                  // immediate reclaim (§6.5)
}

public struct ThumbnailCacheStatus: Sendable, Hashable {
    public let diskCacheEnabled: Bool
    public let diskBytesUsed: Int       // current disk footprint (best-effort)
    public let maxDiskBytes: Int        // the configured cap
    public let materializerVersion: UInt16
}
```

- `thumbnailCacheStatus()` reads the `ThumbnailCacheConfigRow` scalar fields and
  a best-effort `diskBytesUsed`. **`diskBytesUsed` is an ephemeral in-memory
  counter on `DiskThumbnailCache`, NOT a durable field** — the analogy to
  `V2-03`'s `journalBytes` (a durable `@Model` scalar on `JournalConfigRow`,
  `V2-03` §4.5/§4.6) is inexact and V2-04 does **not** claim to mirror it. The
  counter is rebuilt by the startup/periodic background sweep (§6.5), which sums
  file sizes during its pass; until the first post-restart sweep completes,
  `diskBytesUsed` reports 0 (the counter is lost on restart) and the status is
  **approximate**. This is intentional: making the counter durable would route
  every disk insert/delete through an Authority transaction, violating the
  actor-owned disk-cache isolation (§9.3) — the disk cache owns its own files,
  and the Authority owns only the `ThumbnailCacheConfigRow` config table (D29).
  O(1) to read the counter; no blob decode, no SwiftData/Domain leakage.
- `setDiskThumbnailCacheEnabled(_:)` toggles the durable C2 gate through the
  Authority. It is **not** a `HistoryAction`: it does not mutate history items
  and does not advance `ChangePosition`. Disabling stops new disk writes/reads;
  existing files are reclaimed by the background sweep (which runs independent
  of the flag, §6.5) and a best-effort final reclaim pass fires on toggle-off,
  so an opt-out user's derived previews do not linger indefinitely. The cache
  directory's `isExcludedFromBackupKey` flag (`C2-SECURITY-2`) is set eagerly on
  toggle-off as defense in depth. It yields no `HistoryInvalidation` and does
  not wake a live observer (cache config is not a content change).
- `clearDiskThumbnailCache()` is the user-facing **immediate-reclaim** path: it
  deletes every disk cache file (best-effort, on the actor) without toggling the
  durable gate — for an enabled user who wants the derived-preview exposure gone
  now (§11) without waiting for the sweep cadence. It is the promoted "clear
  disk cache now" control (previously a future option; now in the V2-04 surface,
  §12).
- `setMaxDiskThumbnailCacheBytes(_:)` clamps to `ThumbnailCacheLimits.maxDiskBytes`
  at the boundary and triggers a disk eviction sweep if the new cap is below the
  current footprint.
- `ThumbnailCacheHistory` reuses `HistoryItemID`-free vocabulary here (the
  status carries only scalars) and adds no name that collides with v1
  vocabulary (`V2-00` §9).

### 10.1 Exhaustive-switch and code-interaction impact

- **`HistoryAction` switch (`05` §8):** **unchanged.** V2-04 adds no case. The
  closed enum and its exhaustive dispatch are untouched.
- **`HistoryMutation` / `PlannedOutcome` (`02` §7):** **unchanged.** The caches
  are not Domain mutations; the Domain is unaware of caches (preserves D16,
  D17, D18).
- **`ClipboardHistory` protocol (`03a` §3):** **unchanged.** A v1 caller that
  holds `any ClipboardHistory` and ignores `ThumbnailCacheHistory` behaves
  exactly as on v1. `SwiftDataHistory` conforms to both; `ClipyApp` casts to
  `ThumbnailCacheHistory` only when it wants V2 cache surface. The thumbnail
  *request* method (`func thumbnail(for:pixels:) async throws -> ThumbnailPayload?`,
  `03a` §3 on `ClipboardHistory`; its DTOs `ThumbnailPayload`/`PixelSize`/
  `ThumbnailFormat`/`HistoryItemReference` live at `03b` §9) is unchanged.
- **`SwiftDataHistory` field set (`05` §2):** extended with `ThumbnailCache`
  and `DiskThumbnailCache`. Both are `actor` types, so the derived `Sendable`
  conformance is preserved (`01` §6).
- **v1 walking-skeleton tests (`06` §8):** run unchanged. **WS15 (`06` §8 WS15
  — Thumbnail version fence) interaction:** WS15 starts a thumbnail request,
  revises the item during decode, and verifies "the old result remains tagged
  with the old reference and cannot be applied to the new row" and "a request
  begun with an already stale reference fails rather than returning current
  bytes under the old key." V2-04 preserves both: (a) the fetch-time fence
  (`.staleContent` for an already-stale reference) is unchanged; (b) the
  publish fence (§7.3) *additionally* marks a mid-decode-superseded result
  `.superseded` before delivery — WS15's assertion ("cannot be applied to the
  new row") holds identically, and V2-04's parallel fixture (§13) extends WS15
  to assert the `.superseded` transition + the cache-insertion-still-happens
  property. The v1 WS15 fixture runs with the caches transparent (a hit returns
  the same bytes a miss would), so it passes unchanged.

A v1 caller holding `any ClipboardHistory` and ignoring V2-04 is unaffected:
the caches are transparent, the publish fence is internal, and no v1 public
type or enum case changed.

## 11. Security boundaries

V2-04 is **not external-facing** (no X1 boundary; it is not an audited external
write, X2, V2-05). Its security record:

- **Trust boundary:** the process boundary; no external/network input. The
  caches are written by the local `ThumbnailService`/`DiskThumbnailCache` only.
- **Content confinement.** The caches store only **derived preview bytes**
  (PNG thumbnails), never Canonical/revision/source bytes, never `@Model`. The
  disk cache's `ThumbnailDiskBlobV1` carries the key fields + checksum + PNG;
  it does not carry the source image. Source bytes are fetched as immutable
  `Sendable` `Data` inside the v1 Authority interval and handed to the worker;
  they are not persisted by the cache. No `@Model`, `CGImage`, `NSImage`, or
  `NSFileCoordinator` crosses isolation (`01` §6).
- **New durable derived-bytes exposure (Record 6).** v1 retains image source
  bytes durably (Canonical/revision blobs, `05` §3.1) but does **not** retain
  derived thumbnail bytes across launches (`04` §9 step 7: "completed bytes are
  not retained"). C2 durably persists completed PNG thumbnails in the app's
  Caches directory for up to the disk-cap/eviction window (default 512 MiB,
  §5.3). This is a new durable **derived-preview** exposure: an attacker (or a
  backup restore) with access to the cache directory can see low-resolution
  previews of every image whose thumbnail was computed, for up to the eviction
  window. It is **less** sensitive than the source images v1 already stores
  (previews are downsampled to ≤ 2,048 px per axis, `06` §2, typically far
  smaller), but it is a new durable artifact in a new location (the Caches
  directory, not the SwiftData store). It is surfaced to UX (V2-07) as a
  user-visible data practice (the disk cache is opt-in, default off — §6.4) and
  recorded here honestly. The Caches directory is excluded from iCloud backup
  by default (the standard `URLResourceKey.isExcludedFromBackupKey` semantics);
  V2-04 explicitly sets the exclusion flag as defense-in-depth (the flag is set
  regardless of the default, per Apple's guidance to set it for cache files);
  `C2-SECURITY-2` (§13) is a verification-only gate confirming the flag is set
  and persists.
- **TCC/sandbox/entitlement:** **none expected.** The Caches directory is the
  app's own container; reading/writing it requires no privacy-usage string or
  entitlement on macOS. Proof gate `C2-SECURITY-1` confirms
  (`V2-04-facts.md` OPEN 2). `NSFileCoordinator` is an in-process coordination
  primitive (no TCC surface).
- **Crash safety.** The caches are derivations. Their loss/corruption degrades
  to a miss + re-decode (C1 in-memory; C2 corrupt-file-as-miss, §6.3); they
  never produce wrong durable history state (decisions §15; D29, D30). The disk
  cache's atomic-write discipline (§6.3) prevents torn visible files; a crash
  mid-write leaves either the old file or no file.
- **Deletion latency.** When an item is retired, its in-memory cache entries
  are reclaimed lazily by LRU (§5.4 — no eager per-item retire invalidation);
  its disk cache entries are reclaimed by the background sweep (§6.5) or LRU.
  The retirement commit itself is unchanged (`02` §7) — no cache deletion
  happens in it. The sweep runs **independently of `diskCacheEnabled`** (§6.5),
  so disk thumbnails of retired items are reclaimed within the sweep cadence
  even after a user opts out, and a toggle-off fires a best-effort final reclaim
  pass; `clearDiskThumbnailCache()` (§10) is the immediate-reclaim path for a
  user who wants the derived-preview exposure gone now. The security record
  states this honestly: a retired item's thumbnail preview lingers on disk up to
  the sweep interval (or until `clearDiskThumbnailCache`); the
  `isExcludedFromBackupKey` flag (`C2-SECURITY-2`) is set on the cache directory
  to bound backup exposure of these lingering derived previews.
- **One-way-door (materializer version).** A `materializerVersion` bump makes
  the store unopenable by any older binary, app-wide (§6.4 step 4), including
  for users who never enabled the disk cache. This is a conservative posture
  (§6.2's decode-time check already treats foreign-version files as misses, so
  the refuse is defense-in-depth, not a correctness requirement) and requires
  product sign-off per release; the fail-closed refusal is the safe
  conservative choice.
- **Audit:** the caches are not audited external writes; they produce no
  `OperationRecord` (X2, V2-05). They are internal derived-preview state.

## 12. UX interaction hooks (deferred detail to V2-07)

V2-04 provides the data hooks V2-07 (UX) consumes; it owns no SwiftUI:

- **Thumbnail availability is unchanged.** The caches are transparent: a caller
  observes the same thumbnail availability (and the same `.staleContent` / `nil`
  semantics) as v1. No new indicator for "served from cache" is exposed (it is
  an internal latency detail).
- **Disk-cache settings (if product-approved).** A settings toggle bound to
  `setDiskThumbnailCacheEnabled(_:)` (default off, §6.4) and a size-cap control
  bound to `setMaxDiskThumbnailCacheBytes(_:)`, both rendered on the main actor
  from `ThumbnailCacheStatus` (`HistoryCore` DTO, §10). A "disk bytes used"
  readout sourced from `thumbnailCacheStatus()`. Toggling off stops new writes
  and fires a best-effort reclaim pass (§6.5/§10); a "clear disk cache now"
  button bound to `clearDiskThumbnailCache()` (§10) is the immediate-reclaim
  control.
- **Observation.** Because cache config changes advance no `ChangePosition` and
  yield no `HistoryInvalidation` (§10), they are **not live-observed**: an
  active `observe(...)` reflects a disk-cache toggle only on the next real
  History Commit (which advances `ChangePosition` and wakes the observer) or a
  fresh browse (which always reflects current state). V2-07 re-browses on
  toggle. This mirrors `V2-01` §12's enrichment-not-live-observed posture.
- **Data-practice disclosure.** The new durable derived-preview exposure (§11)
  is surfaced as a user-visible data practice: when the user enables the disk
  cache, the UX states that thumbnail previews of copied images are stored on
  disk (in the Caches directory) for the eviction window.
- **Accessibility / localization.** The settings labels are localizable (P2,
  V2-06); the materializer version is internal (not user-facing).

## 13. Graft-admission records (`V2-00` §4)

### Record 1 — Lifted exclusion + evidence trigger

- **C1** lifts `04` §9 step 7 ("Completed bytes are not retained by
  `HistoryStorage`"), `00` §2 Excluded ("Shared or disk materialization caches
  … generic purpose/source-stamp systems"), and `06` §3 G1. Evidence trigger:
  representative scrolling shows thumbnail decode p95 above 16 ms **and** at
  least 30% identical completed requests in the measurement window (`V2-00` §3;
  `06` §3 G1).
- **C2** lifts `00` §2 Excluded ("disk materialization caches") and `06` §3 G3.
  Evidence trigger: C1 already justified **and** measured cross-launch reuse is
  substantial **and** a structural materializer fingerprint
  (`materializerVersion`, §4 — the structural materializer schema version `04`
  §12 requires; `ThumbnailSourceFingerprint`, §3, is the separate G4 source
  stamp, not G3's structural fingerprint) is specified and fixture-proved (§13
  Record 4).
- **C3** lifts `04` §11 ("Publish fences, reap state machines, or generic
  materialization stores" — the thumbnail-purpose publish fence) and `06` §3 G6.
  Evidence trigger: at least 20% of thumbnail work is superseded or discarded
  despite cancellation and single-flight (`V2-00` §3; `06` §3 G6).
- **S1** lifts `06` §3 G4 ("Per-purpose content subversions/source stamps") for
  the thumbnail purpose. Evidence trigger: profiling shows material thumbnail
  work repeatedly invalidated by Effective Content changes that provably leave
  the thumbnail purpose's source bytes unchanged (`V2-00` §3).

### Record 2 — Invariant impact

D1–D19 are **preserved unchanged**. In particular:

- **D2 (Canonical immutability):** the caches never touch Canonical/revision
  Content; they store derived preview bytes from Effective Content source bytes.
- **D5/D6 (precise tokens):** the caches mint neither `ContentVersion` nor
  `ChangePosition`; no cache operation advances either. The stamp is a
  fingerprint (evidence, D7), not a coherence token.
- **D7 (fingerprint-is-evidence):** `ThumbnailSourceFingerprint` is evidence,
  never identity — exactly as v1 dedup treats `ContentFingerprint` (`02` §2.2)
  and `V2-01`'s S1 treats `EnrichmentSourceFingerprint` (`V2-01` §5.1). For the
  thumbnail cache, D7 is **exact where the arbiter is the fetched source bytes**
  (the stamp is computed *from* the bytes selected in the non-suspending
  interval, and the v1 fetch-time fence ensures those bytes are current), and
  **evidence-bounded where the stamp is the cache identity across revisions**:
  an xxh3-64 collision (~7e-13/~1e-11 at the disk cap, §3.2) could serve a
  different valid thumbnail under the same stamp. This residual is accepted
  (§3.2) on the grounds that it is transient, non-durable, and does not affect
  content/paste/detail. D7 itself is **preserved unchanged** — V2-04 modifies
  no v1 invariant; the stamp's *cache role* and its residual are governed by the
  new **D30** (§14), not by altering D7. That D30-governed residual is
  **stronger than `V2-01`/`V2-03`'s**: exact at fetch time, evidence-bounded at
  cache-identity time **on the read/serve path** — V2-04 has no
  collision-free serve arbiter (the stamp *is* the serve identity), unlike
  `V2-01`/`V2-03` which keep a collision-free version as the read arbiter and
  confine the D7 residual to the write/drain path. This is the intentional cost
  of the S1 benefit (§3.2). The v1 thumbnail fence (`04` §9) fences on
  `ContentVersion` (exact) and re-decodes on a version advance; V2-04's
  fetch-time fence shares that exactness, but its stamp-keyed cross-revision
  reuse accepts the fingerprint residual rather than re-decoding on every
  `ContentVersion` advance (the S1 benefit).
- **`00` §3 decision 8 (complete facts or no mutation):** the caches are
  derivations, not planning facts; the Domain planners receive no cache input and
  remain complete-fact-bounded. (Not D8 — `02` §14 D8 is "Complete candidates,"
  which governs dedup candidate completeness, a distinct concern; the
  "complete-facts" framing is `00` §3 decision 8's name. The cache-derivation
  point is sibling to D18, listed next.)
- **D16/D17/D18 (pure planning / no framework leakage / semantic-plan
  completeness):** the caches are not `HistoryMutation`; the Domain and its
  stamping contract are untouched.
- The v1 thumbnail fence (`04` §9) is the model for both the C1 fence
  (fetch-time, preserved) and the C3 publish fence (publish-time, new). D30/D31
  state the cache + publish guarantees.

V2-04 **extends** the invariant set with D29–D31 (§14). No D1–D19 is weakened.

### Record 3 — V2 proof gates

The analog of Part VI §6 (compile), §7 (schema/platform), and §9 (perf) on
macOS 26:

- **C1-COMPILE-1 (compile/dependency).** Swift 6 complete strict-concurrency
  build succeeds with **no new framework import** (V2-04 uses only Foundation +
  the ImageIO/SwiftData already in `HistoryStorage`); `ThumbnailCache`,
  `DiskThumbnailCache` are `actor` types so `SwiftDataHistory: Sendable` is
  derived; no `@unchecked Sendable` / `nonisolated(unsafe)`; `NSFileCoordinator`
  is actor-confined (non-`Sendable` class, `V2-04-facts.md` fact 1). The cache
  types are internal; no cache type leaks to `HistoryCore`/`HistoryDomain`.
- **C1-COMPILE-2 (Sendable value types).** `ThumbnailCacheKey`,
  `ThumbnailCacheEntry`, `ThumbnailSourceFingerprint`, `ThumbnailSourceSelection`,
  `ThumbnailFenceKey`, `ThumbnailDiskBlobV1`, `ThumbnailMaterializationState` are
  all `Sendable` by synthesis (all-`let` `Sendable` members); no escape hatch.
- **C2-PLATFORM-1 (NSFileCoordinator coordinated accessors).** Confirm the
  exact Swift signatures of the `NSFileCoordinator` coordinated-read and
  coordinated-write accessors on the macOS 26 SDK (the class + `init(filePresenter:)`
  are VERIFIED, facts 1–2; the specific `coordinate(readingItemAt:options:error:byaccessor:)`
  / `coordinate(writingItemAt:options:error:byaccessor:)` spellings are OPEN,
  `V2-04-facts.md` OPEN 1) and that they serialize correctly under Swift 6
  strict concurrency when confined to the `DiskThumbnailCache` actor. Confirm
  the coordinated-write + `FileManager.replaceItem` atomic-rename pattern is
  crash-safe (no visible torn file) on macOS 26.
- **C2-PLATFORM-2 (disk codec round trip).** `ThumbnailDiskBlobV1`
  encode/decode round-trips and that every corruption class (unknown version,
  oversize PNG, key/filename mismatch, checksum mismatch, materializer-version
  skew, truncated/torn file) degrades to a **miss + lazy delete**, never to
  wrong bytes and never to a caller-visible failure (the cache-law fail-soft
  contract, §6.2).
- **C2-PLATFORM-3 (ImageIO determinism — governs BOTH C1 and C2).** Confirm
  ImageIO's downsample+PNG-encode is byte-deterministic for identical source
  bytes + pixels + materializer version on macOS 26, including across process
  restarts (the materializer-determinism assumption underpinning the cache law
  for **both** C1 in-memory reuse and C2 cross-launch reuse, §5.2). The v1
  thumbnail path already assumes ImageIO decode; this gate additionally pins
  encode determinism. **Weakening condition:** if byte-determinism is not
  provable on macOS 26, V2-04 weakens the cache-law identity claim from
  "byte-identical" to "**visually-equivalent PNG**" for both C1 and C2 — the
  served bytes are a valid PNG decoding to the same pixels (the materializer is
  functionally deterministic at the pixel level even if the encoded bytes
  vary), which is cache-law-faithful for a *preview* (the cache serves
  thumbnails, not source bytes), recorded as a second bounded deviation
  alongside the D7 stamp-collision residual (§3.2/Record 4). The
  `materializerVersion` bump mechanism (§4) scopes whichever determinism holds
  to a version.
- **C2-SECURITY-1 (no TCC/entitlement).** Confirm no privacy-usage string or
  entitlement is required on macOS 26 to read/write the app's own Caches
  subdirectory (`V2-04-facts.md` OPEN 2).
- **C2-SECURITY-2 (backup exclusion, verification-only).** Verify the disk cache
  directory carries `URLResourceKey.isExcludedFromBackupKey` (set explicitly as
  defense-in-depth; the Caches directory is excluded by default, but the flag is
  set regardless per Apple's guidance for cache files - Apple notes some file
  operations reset the flag to `false`, so confirm it is reasserted on write and
  on toggle-off, §6.5/§10).
- **C1-PERF-1 (decode p95).** Thumbnail decode p95 is within the v1 budget on
  the minimum supported hardware — this is the C1/G1 evidence trigger itself
  (`06` §9); it measures the greenfield scaffold.
- **C1-PERF-2 (cache hit reduces net end-to-end thumbnail latency).** Under
  representative scrolling, ≥ 30% of identical completed requests hit C1 (the G1
  trigger's reuse fraction) **and** a hit is materially faster than a miss on
  **net end-to-end thumbnail-request latency** — the **hit-path** budget is
  source fetch + stamp compute + cache lookup + serve (measured against the miss
  path, which adds decode); the gate budgets the hit path specifically, not just
  the decode a hit avoids. Stamp-keying pays the source-fetch
  + xxh3 cost on *every* consultation (the stamp is computed inside the v1 `04`
  §9 interval from bytes that must be fetched regardless, §8.1), so a C1 hit
  avoids the decode but **not** the source fetch; the gate therefore requires
  the decode-avoided delta to dominate the fetch+stamp overhead at the hit
  fraction (the regime where stamp-keying beats a hypothetical CV-keyed cache,
  which would hit from a scalar CV without re-fetching but would lose the S1
  cross-revision benefit, §3.2). The in-interval xxh3-64 cost is budgeted at the
  64 MiB representation ceiling (`06` §2) and must remain inside the v1 `04` §9
  non-suspending interval budget (`C1/C2/C3-PERF-4`). If profiling shows source-
  fetch dominates (large `.externalStorage` images where fetch dwarfs decode), a
  future graft may mirror `ThumbnailSourceFingerprint` as a scalar on a
  lightweight per-item row (the `V2-01` `EnrichmentRow.sourceFingerprintRaw`
  pattern) so hits skip the fetch — recorded as a future option, **not** in
  V2-04 scope (V2-04 is a transparent cache with no durable per-item state,
  §1.1). Cache-law fixture proofs (hit/miss/evict/restart equivalence, §5.2)
  pass.
- **C1-PERF-3 (bounded C1 eviction).** A C1 `insert` that triggers LRU
  eviction performs a bounded, amortized batch of deletes (never an unbounded
  synchronous sweep that stalls the `ThumbnailCache` actor's lookup path, §5.3);
  the per-insert eviction cost is bounded and small.
- **C2-PERF-1 (disk cache avoids cross-launch re-decode).** Measured
  cross-launch reuse is substantial (the G3 trigger): a bounded fraction of
  post-launch thumbnail requests hit C2 and avoid re-decode; the disk
  read (coordinated) is bounded and small relative to decode p95.
- **C2-PERF-2 (disk insert/evict cap).** A disk `insert` that triggers the
  eviction pass (§6.5) bounds its work (sharded directory list + bounded header
  reads + bounded deletes) and does not block the `DiskThumbnailCache` actor's
  read path beyond a bounded budget.
- **C2-PERF-3 (disk sweep wall-clock-bound).** The background disk sweep
  (§6.5) reclaims stale + over-cap files within a wall-clock cadence regardless
  of commit rate (inactive-user bounding) **and regardless of `diskCacheEnabled`
  state** (it reclaims disabled-but-retained files, §6.5); its per-pass cost is
  bounded and it runs off the Authority. It is the mechanism that reclaims
  stale files after a lazy `bumpMaterializerVersion` (§4) and retired-item
  files after LRU (§5.4).
- **C3-PERF-1 (supersession observability cost is bounded).** Under the G6
  workload (≥ 20% superseded work), the publish fence's scalar Authority CV
  re-read per publish (§7.3) is bounded and small, and the lifecycle state
  transitions add negligible overhead. C3's value is **observability** (the G6
  supersession measurement) + **cache-insertion hygiene** (superseded bytes are
  retained for reuse, §7.1) — **not** delivery prevention (the caller still
  receives and discards the tagged payload per the v1 contract, §7.1); the gate
  confirms the fence's per-publish cost is bounded, not that it reduces caller
  apply work.
- **C1/C2/C3-PERF-4 (no Authority-interval suspension).** The cache `await`s
  (C1/C2 lookup/insert) and the publish-fence `await` are **outside** the `04`
  §9 non-suspending Authority interval (§8/§9.3); prove the interval contains
  only the position read, the version check, the Effective-Content derivation,
  the source-byte selection, and the stamp computation — no suspension (mirrors
  `V2-03` `J1-PERF-2`).

### Record 4 — Cache-law compliance (the V2-04 restatement)

The Part IV §12 law — *"For the same authoritative source state and request,
cache hit, cache miss, eviction, disabled cache, and process restart produce
semantically identical values and failures; only latency and resource use may
differ"* — is restated for C1/C2/C3:

- **Key (the `04` §12 analogue).** `ThumbnailCacheKey = (HistoryItemID,
  ThumbnailSourceFingerprint, PixelSize, materializerVersion)` (§3.2). The four
  `04` §12-mandated elements are present: (1) History Item ID — `itemID`; (2)
  the relevant authoritative version — `sourceStamp` (purpose-relative: the
  thumbnail source bytes' content-addressed identity, §3.2); (3) complete
  normalized parameters — `pixels`; (4) a structural materializer schema
  version — `materializerVersion` (§4).
- **Hit:** the served PNG is byte-identical to a fresh decode at the same key
  (materializer determinism, `C2-PLATFORM-3`) — or, if `C2-PLATFORM-3` cannot
  prove byte-determinism, a *visually-equivalent* PNG (same pixels) that is
  cache-law-faithful for a preview (§3.2). The v1 fetch-time fence (`04` §9
  step 2) already verified the request's reference is current. C1 and C2 hits
  obey this identically.
- **Miss:** the v1 decode path runs (`04` §9 step 6) and populates C1 (and C2
  if enabled); the caller receives what v1 would have returned.
- **Eviction (LRU or capacity, C1; LRU + sweep, C2):** an evicted entry is a
  miss on next read; v1 decode re-runs. Byte-identical.
- **Disabled (`diskCacheEnabled == false` for C2; C1 is always-on once G1
  fires):** C2-disabled is byte-for-byte v1 for the disk path (C1 may still
  serve in-memory); both-disabled is byte-for-byte v1. This is the cache-law
  disabled-path and the v1-faithful mode for callers that have not opted into
  the graft.
- **Restart:** C1 starts empty (first read is a miss); C2 persists across
  restart (its entries survive a clean launch). A C2 entry is served post-
  restart only if its envelope's `materializerVersion` matches the current
  compiled-in version and its key matches the request — else it is a miss (lazy
  delete). Semantically, restart produces the same values as a miss for C1; C2's
  post-restart hits are the G3 cross-launch benefit (a *latency* improvement,
  not a semantic change — the served bytes are what a miss would have produced).
- **Failure equivalence:** the caches add no caller-visible failure path. A
  `.staleContent` (stale fetch-time reference) or `nil` (no supported image)
  decision is upstream of the caches and unchanged. A corrupt C2 file is a
  silent miss (§6.2), never a caller-visible failure.

**The recorded, bounded EXCEPTION to `V2-00` §5 decision 15 + `04` §12 (D7
residual).** Decision 15 ("a stale or evicted cache degrades to a miss, **never
to wrong bytes**") and `04` §12 ("semantically identical values") hold for every
input **except** an xxh3-64 collision on the source-stamp identity, which may
serve a different *valid* thumbnail. V2-04 takes this as an **explicit, bounded,
recorded exception** to both statements — not by re-reading "wrong" to exclude
collisions (decision 15 amended now scopes "never to wrong bytes" to
non-collision inputs, with D30 the recorded carve-out; `04` §12, v1 and frozen,
admits no carve-out as written). The
exception is:

- **transient** (eviction / restart / a stamp-changing revision clears it);
- **non-durable** (it does not affect Canonical/revision/paste/detail bytes,
  dedup identity, or search; the pasted content is the v1 `pastePayload` path,
  which never consults the cache);
- **bounded to a valid-thumbnail output** (the materializer can only produce a
  valid PNG ≤ 16 MiB, `06` §2; never malformed or arbitrary bytes);
- **astronomically unlikely** (~7e-13 at ~5,000 entries, a conservative bound over the 2,048-entry in-memory
  cap, §5.3; ~1e-11 at the 20,000-entry disk cap; ~5e-20 per request pair, §3.2).

**V2-00 amendment (landed).** `V2-00` §5 decision 15 has been amended to scope
"never to wrong bytes" to *non-collision* inputs, with the per-doc
fingerprint-collision residual carved out as a bounded, transient,
preview-only exception (V2-01 D21, V2-04 D30). V2-04 owns its carve-out
**explicitly and recorded** as D30 (§14); it claims decision 15's "never to wrong
bytes" for non-collision inputs only (the amended scope) and records D30 as the
bounded residual against `04` §12 (v1, frozen, admits no carve-out as written).

**Stronger departure than `V2-01`/`V2-03`.** This is a **stronger cache-law
departure than `V2-01` (`V2-01` §5.1/Record 4) or `V2-03` (`V2-03` §7.2)**:
those caches keep a collision-free read/serve arbiter (`ContentVersion` /
`ChangePosition` respectively) and confine the D7 residual to the write/drain
path, so their serve path is collision-free; V2-04 uses the stamp AS the serve
arbiter (§3.2), so its residual lands on the read/serve path. V2-04 is the only
V2 cache without a collision-free serve arbiter — the intentional cost of the
S1 benefit (a transparent read cache has no durable per-item row to carry a
collision-free version and no background drain to two-layer the fence). A byte-
exact fence (retaining source bytes or recovering them from revision history,
D4) would eliminate the residual at disproportionate cost and is not taken.

**The cache-law fixture proofs (`C1-PERF-2` / `C2-PLATFORM-2`).** Parallel V2
fixtures pin: (a) hit == miss byte-identical for the same key (or
visually-equivalent PNG if `C2-PLATFORM-3` cannot prove byte-determinism, §3.2);
(b) eviction produces a miss that re-decodes to the same bytes; (c) C2-disabled
is byte-for-byte v1; (d) restart: C1 empty + C2-persistent-hit both produce the
same bytes as a fresh decode; (e) the D7 residual is fixture-demonstrated only
via an injected collision (a test-only stamp override), never via a real
collision; (f) a corrupt C2 file (torn / bad-checksum / version-skew /
key-mismatch) is a miss, never wrong bytes. The v1 WS15 fixture runs unchanged
(transparency); V2-04's parallel fixture extends WS15 with the C3 `.superseded`
transition + stamp-keyed-safe-insertion property.

### Record 5 — Migration impact (Part V §17 three layers)

- **Schema layer (SwiftData migration):** add the `ThumbnailCacheConfigRow`
  table. `HistorySchemaV1` is frozen (`V2-00` §2.1); `HistorySchemaV2` (the
  consolidated V2 schema introduced by V2-01 and extended by V2-02/V2-03) gains
  `ThumbnailCacheConfigRow`. Because `MigrationStage.lightweight` requires
  `VersionedSchema`-conforming *types* while v1's `HistorySchemaV1` is a plain
  `Schema` *value* (`05` §3), M1 retrofits the additive
  `HistorySchemaV1: VersionedSchema` type (already established by `V2-01`
  `E1-PLATFORM-1`/Record 5 — V2-04 reuses that retrofit, it does not re-retrofit).
  The migration is
  `MigrationStage.lightweight(fromVersion: HistorySchemaV1.self,
  toVersion: HistorySchemaV2.self)` — purely additive; no v1 row or column is
  rewritten (`V2-01` `E1-PLATFORM-1`, verified). **Data bootstrap (not
  migration):** `SwiftDataHistory.open` creates the `ThumbnailCacheConfigRow`
  singleton (`diskCacheEnabled == false`, §6.4) if absent, so a migrated v1
  store starts v1-faithful (no disk cache). Proof gate `C2-PLATFORM-2` (the
  codec) and the `V2-01`/`V2-03` migration gates cover the schema stage.
- **Blob layer (versioned blob migration):** `ThumbnailDiskBlobV1` is a new V2
  file codec (`formatVersion == 1`) for the **disk cache files**, not a SwiftData
  blob. No v1 blob (`CanonicalBlobV1`, `RevisionStateBlobV1`, `SignatureBlobV1`,
  `EffectiveTypeIdentifiersBlobV1`, `05` §4) is reinterpreted. A future disk
  codec bump adds `ThumbnailDiskBlobV2` + a `materializerVersion` advance that
  evicts old files (re-decode on next access), exactly as a v1 projection
  schema change rebuilds (`05` §15).
- **Disk-cache files (new on-disk artifact, NOT SwiftData):** the disk cache
  directory starts **EMPTY** at migration — no backfill. Thumbnails are lazily
  cached on first access. C1 starts empty (in-memory). C3 is runtime state (no
  persistence). No blob migration, no projection rebuild, no `ContentVersion`
  change, no Signature Index touch. A migrated v1 store with `diskCacheEnabled`
  later toggled on simply starts writing files on the next thumbnail requests.
- **Projection layer (rebuild):** the caches are transparent; their loss is a
  miss + re-decode. No migration invents missing bytes, reinterprets an old
  `ContentVersion`, reuses removed IDs, or enables capture before Signature
  Index / change-journal completeness is restored (`V2-00` §5 decision 18).

### Record 6 — Security boundary

V2-04 is **not external-facing** (no X1 boundary). Its security record (§11):
trust boundary = process; no network path; caches store only derived preview
PNGs (never source bytes); new durable derived-preview exposure on disk
(default off, opt-in, surfaced to UX); no TCC/entitlement expected
(`C2-SECURITY-1`); backup exclusion (flag set explicitly as defense-in-depth;
`C2-SECURITY-2` verifies); deletion
latency for retired-item disk thumbnails bounded by the wall-clock sweep;
crash-safe (corrupt file = miss, atomic-write prevents torn files); no
`OperationRecord` (internal derived state, not an audited external write).

## 14. New invariants D29–D31 (extend `02` §14)

V2-04 owns **D29–D31** — the next free numbers after V2-03's D25–D28 (V2-02 owns
D23–D24, V2-01 owns D20–D22), per the `V2-00` §4 global D-invariant registry.

- **D29 Materialization-cache single-writer + transparency.** Thumbnail cache
  durable config (`ThumbnailCacheConfigRow`) is written only through
  `HistoryAuthority`, including `bumpMaterializerVersion` and the disk-cache
  config toggle (`setThumbnailCacheConfig`, §10.3); no component outside the
  Authority — in particular `ThumbnailService`, `ThumbnailCache`,
  `DiskThumbnailCache`, which only read/write their own actor state or cache
  files — creates a writable `ModelContext` for the cache config table. The
  caches are transparent: a cache hit returns byte-identical bytes to a miss at
  the same `ThumbnailCacheKey` (materializer determinism), and a cache miss /
  eviction / disabled / restart falls through to the v1 decode (`04` §9) —
  except the D7 residual (D30). Cache config changes advance no
  `ChangePosition` and yield no `HistoryInvalidation`. *(Extends `00` §3.3
  single-writer to the V2 cache-config table; restates `V2-00` §5 decision 15's
  cache-transparency clause as an invariant.)*

- **D30 Materialization-cache version fence (the cache-key law + D7 residual).**
  Every retained thumbnail cache entry (C1 in-memory and C2 on-disk) is keyed by
  `(HistoryItemID, ThumbnailSourceFingerprint, PixelSize, materializerVersion)`,
  where the source fingerprint is xxh3-64 over the image source bytes selected
  in the same non-suspending Authority interval as the v1 fetch-time version
  fence (`04` §9 steps 2–3). A request whose reference is already stale fails at
  the fetch-time fence (`.staleContent`) before any cache lookup; a result is
  tagged with its fetch-time-verified reference. A stale, evicted, disabled, or
  version-skewed cache entry falls through to a real decode (miss), **never to
  wrong bytes**, with one recorded, bounded exception: an xxh3-64 collision on
  the source-stamp identity (~7e-13 at ~5,000 entries, a conservative bound over the 2,048-entry in-memory
  cap, §5.3; ~1e-11 at the 20,000-entry disk cap; ~5e-20 per request pair, §3.2) may serve a different *valid*
  thumbnail under the same stamp — transient, non-durable (does not affect
  Canonical/revision/paste/detail bytes, dedup identity, or search), bounded to
  a valid-PNG output, and accepted as the cost of the S1/G4 cross-revision reuse
  benefit. This exception is a bounded, recorded residual against `04` §12's
  "semantically identical values" (v1, frozen, admits no collision carve-out as
  written); `V2-00` §5 decision 15 (amended) now scopes "never to wrong bytes"
  to non-collision inputs and records this residual as D30 (§3.2/§13 Record 4).
  D7 is exact
  where the arbiter is the fetched source bytes (the stamp is computed from
  bytes verified current at the fetch-time fence) and evidence-bounded where the
  stamp is the cache identity across revisions **on the read/serve path** — a
  stronger residual than `V2-01` D21 / `V2-03` D27, which confine the D7
  residual to the write/drain path behind a collision-free serve arbiter
  (`ContentVersion` / `ChangePosition`); V2-04 has no collision-free serve
  arbiter (the stamp *is* the serve identity), the intentional cost of S1
  (§3.2). *(Mirrors `04` §9 thumbnail fence and `04` §12 cache-key requirement
  for an authoritative version + materializer schema version, adapted to a
  transparent cache with stamp-as-identity.)*

- **D31 Publish-fence no-stale-publish-as-current (lifecycle tagging).** A
  superseded thumbnail materialization result is never *published as current*
  (delivered under a reference that is no longer the item's current
  `ContentVersion`). The C3 publish fence (`ThumbnailService.publishIfCurrent`,
  §7.3) re-checks the request's reference against the item's current
  `ContentVersion` before delivery and **tags** the result: current →
  `.published`; superseded → `.superseded → .discarded`. **The payload is
  returned to the caller in both branches**, tagged with its fetch-time-
  verified reference; the v1 caller-side contract (`04` §9 step 6 "applies it
  only if its row still carries that reference") is the **sole delivery
  arbiter** (unchanged — C3 does not prevent delivery, it makes supersession
  observable). The fence table entry is **reaped on reaching a terminal state**
  (`.published`/`.discarded`), so the table holds only in-flight
  materializations, bounded by the in-flight call count (UI concurrency; ≥ the
  single-flight table size when callers join, §7.2/§9.2). A
  superseded result's bytes may still be inserted into C1/C2 — stamp-keyed
  insertion is safe by construction (`ThumbnailCacheKey` identity, §3.2/§7.3):
  the entry is correct for any future request whose source bytes share that
  stamp, regardless of the current request's supersession. *(Extends the v1
  `04` §9 fetch-time fence with a publish-time tagging fence; restates `V2-00`
  §3 C3 as an invariant. "Published as current" is the single source of truth
  for what the fence prevents — delivery itself is governed by the v1 caller-
  side check, which C3 does not replace.)*

These extend D1–D19; none weakens any. The v1 self-review gate (`06` §10) and
the V2 self-review gate (`V2-00` §8) both apply: a mechanical scan confirms no
v1 public type/schema column/codec/invariant is redefined and that every V2
type introduced — `ThumbnailCacheHistory`, `ThumbnailCacheStatus`,
`ThumbnailCache`, `DiskThumbnailCache`,
`ThumbnailMaterializationState`, `ThumbnailCacheKey`, `ThumbnailCacheEntry`,
`ThumbnailCacheConfigRow`, `ThumbnailDiskBlobV1`, `ThumbnailSourceFingerprint`,
`ThumbnailSourceSelection`, `ThumbnailFenceKey`, `ThumbnailCacheLimits` — does
not collide with v1
names. (`ThumbnailPublishFence`, referenced elsewhere as the C3 state machine,
is the conceptual label for the `fence` stored field on `ThumbnailService` plus
`ThumbnailMaterializationState`, §9.2 - not a separately declared type, hence
not a collision-scan entry.) The v1 internal `ThumbnailFlightKey` (`04` §9) is **substituted** (the
join key changes from the v1 reference to the stamp; subsumed by
`ThumbnailCacheKey`, §9.2) — this is a **substitution of a v1 *internal* type's
keying**, not a pure additive extension and not a redefinition of a v1 public
type; recorded as a substitution (semantically load-bearing: it changes which
requests join a single flight) in this V2-04 §14 self-review (the `V2-00` §8
self-review scan enumerates no clause for internal-type substitutions, so it
would not catch this mechanically; explicit reviewer sign-off is recommended
at consolidation, `V2-04-facts.md` C2-m2).

**Deleted-vocabulary posture.** `04` §11 lists "Publish fences, reap state
machines, or generic materialization stores" and "Generic … `SourceStamp`,
`ItemKey<Purpose>` … frameworks" as absent v1 machinery; `00` §2 Excluded lists
"Shared or disk materialization caches, collection caches, generic
purpose/source-stamp systems." V2-04 lifts these absences via the G1/G3/G6/G4
grafts (`V2-00` §3; §1.2). The deleted-vocabulary scan (`06` §10) mechanically
scans `docs/` (including `docs/v2/`); V2-04 uses these tokens ("publish fence,"
"materialization cache," "source stamp") as the **admitted graft names** that
`V2-00` §3 and `06` §3 canonicalize (C3 "Publish-fence materialization
lifecycle"; G1/G3 "in-memory/disk materialization caches"; G4 "source stamps"),
explicitly recorded as lifts in §1.2 — the same posture `V2-03` §1.2 took for
"durable change cursor" and "collection cache." Where V2-04 names a concrete
type, it uses **thumbnail-purpose-specific** names (`ThumbnailPublishFence`,
`ThumbnailSourceFingerprint`, `ThumbnailCache`), never the deleted *generic*
forms (`Publish fences` plural noun, `SourceStamp<T>`, `ItemKey<Purpose>`); the
generic forms appear only in verbatim-quoted rejection statements (`04` §11),
which `06` §10 permits. `ThumbnailSourceFingerprint` is a V2-scoped
per-purpose fingerprint (aligning with `ContentFingerprint`, `02` §2.2, and
`V2-01`'s `EnrichmentSourceFingerprint`), not the deleted generic
`SourceStamp`/`ItemKey<Purpose>` framework.

## 15. Platform reference anchors

Implementation must verify against the macOS 26 SDK rather than copy pseudocode
(`05` §18, `00` §5):

- [NSFileCoordinator](https://developer.apple.com/documentation/foundation/nsfilecoordinator) — coordinates read/write of files among file presenters; non-`Sendable` `class`; macOS 10.7+ (✓ macOS 26); per-file-operation, single-thread → actor-confined (`V2-04-facts.md` fact 1).
- [NSFileCoordinator init(filePresenter:)](https://developer.apple.com/documentation/foundation/nsfilecoordinator/init(filepresenter:)) — `init(filePresenter filePresenterOrNil: (any NSFilePresenter)?)`; V2-04 passes `nil` (no presenter registered; fact 2).
- [NSFilePresenter](https://developer.apple.com/documentation/foundation/nsfilepresenter) — the presenter protocol V2-04 does **not** register (no second writer admitted; future-extension graft would register it).
- [FileHandle](https://developer.apple.com/documentation/foundation/filehandle) — file-descriptor wrapper; non-`Sendable` `class`; macOS 10.0+ (fact 3); available for low-level disk I/O if needed, though `Data` + coordinated `FileManager` write is the primary path.
- [CGImageSource](https://developer.apple.com/documentation/imageio/cgimagesource) — ImageIO read source; `class`; macOS 10.8+ (✓ macOS 26; fact 4); the v1 thumbnail decode primitive (`05` §14.5) reused unchanged.
- [ModelContext transaction](https://developer.apple.com/documentation/swiftdata/modelcontext/transaction(block:)) — the atomic-commit primitive the cache-config writes share (verified `V2-03-facts.md` fact 5); V2-04 config writes are separate transactions, not History Commits.
- [MigrationStage.lightweight(fromVersion:toVersion:)](https://developer.apple.com/documentation/swiftdata/migrationstage/lightweight(fromversion:toversion:)) / [VersionedSchema](https://developer.apple.com/documentation/swiftdata/versionedschema) — V1→V2 additive schema migration (verified `V2-01`/`V2-03`); V2-04 adds `ThumbnailCacheConfigRow` to `HistorySchemaV2`.
- [AsyncStream.Continuation.yield(_:)](https://developer.apple.com/documentation/swift/asyncstream/continuation/yield(_:)) — non-blocking yield; the v1 observer-continuation primitive (`04` §4, verified `V2-01-facts.md`/`V2-03-facts.md` fact 8). V2-04 **does not consume** the `HistoryInvalidation` yield for C1 (retirement is LRU-lazy, §5.4) — contrast `V2-03`'s `CollectionCache`, which does; documented here as the primitive V2-04 explicitly declines to consume.

All facts above are recorded with verdicts in `.tmp/v2-research/V2-04-facts.md`.
Verified this cycle: `NSFileCoordinator` (class, non-`Sendable`, macOS 10.7+,
per-operation/single-thread), `NSFileCoordinator.init(filePresenter:)`,
`FileHandle` (class, non-`Sendable`, macOS 10.0+), `CGImageSource` (class,
macOS 10.8+), `URLResourceKey.isExcludedFromBackupKey` (static let,
macOS 10.8+; Apple recommends setting it for cache files). OPEN (assigned
`C2-PLATFORM-1`/`C2-PLATFORM-3`/`C2-SECURITY-1`): the exact Swift spellings of
the `NSFileCoordinator` coordinated read/write accessors on macOS 26; ImageIO
downsample+PNG-encode byte-determinism across restarts; TCC/entitlement
explicit-absence for the app's own Caches subdirectory. The backup-exclusion
decision is resolved (the flag is set explicitly as defense-in-depth, §11/§13);
`C2-SECURITY-2` is now a verification-only gate. Where a behavior
could not be MCP-fetched, it is marked OPEN there and assigned a V2 proof gate
in §13 — V2-04 makes no concrete platform claim without either a citation or a
proof gate, exactly as v1 (`00` §5).
