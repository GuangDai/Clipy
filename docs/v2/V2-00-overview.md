# Clipboard Manager - V2 Design Specification (post-v1 expansion)

> **Status (2026-07-23):** design-consolidation in progress. V2 is the **post-v1
> expansion**. It *extends* - never *redefines* - the v1 specification
> (`00`–`06`). v1 remains authoritative for v1 behavior; V2 owns only new
> surface and the graft of new capabilities onto the v1 architecture. V2 is
> admitted only after v1 reaches **executable specification** (Part VI state 2).
> Each V2 capability is a *graft* gated by the Part VI §3 evidence-trigger
> protocol; this overview lifts no gate without its evidence. Like v1 at
> consolidation time, V2 is "design-consolidated, scaffold proof pending."

## 1. Purpose

V2 answers one question:

> *After the v1 executable specification passes, what does the product become
> next, and how is each new capability grafted onto the v1 architecture without
> weakening a single v1 load-bearing decision or invariant?*

V2 admits the capabilities v1 explicitly excluded (`00` §2 Excluded), the
performance grafts G1–G8 (`06` §3) once their evidence triggers fire, and the
product-deferred capabilities (`06` §4) once each has an approved architecture
review recorded in its owning doc. It does not silently introduce any of them;
each carries its evidence, its v1-invariant impact, its V2 proof gates, and its
migration impact.

V2 is **not** a rewrite. The v1 target graph, isolation model, single-writer
authority, immutable content lineage, two-stage dedup, coherence tokens,
snapshot observation, and cache law are all presupposed correct and unchanged.

## 2. Relationship to v1

### 2.1 v1 is untouched and authoritative

- V2 does not modify any v1 public type, `HistoryAction` case, schema column,
  codec, invariant, proof gate, or forbidden-dependency rule. v1 behavior is
  defined by `00`–`06` and is not redefined here.
- V2 extends v1 by **addition**: new public cases/protocols/tables are added
  behind new V2 modules or behind capability-gated extensions of existing ones.
  A v1 caller that ignores V2 surface behaves exactly as on v1.
- Where V2 must change a v1 schema (e.g., add a table for the change journal),
  it does so via the Part V §17 three-layer migration (schema / blob /
  projection); it never mutates `HistorySchemaV1` in place. `HistorySchemaV1`
  (`v1Schema`) is **frozen**; V2 introduces `HistorySchemaV2` and a migration
  plan. Migration from the **Maccy** schema remains excluded - the greenfield
  lineage is `HistorySchemaV1 -> V2`, not Maccy -> greenfield.

### 2.2 V2 inherits every v1 load-bearing decision

The twelve decisions in `00` §3 and the nineteen invariants D1–D19 (`02` §14)
are **reaffirmed unchanged** for all v1 behavior. V2 adds decisions §13–§18
(§5 below); it weakens none of §1–§12. In particular, every V2 graft must
preserve:

- **Single write authority (`00` §3.3):** `HistoryAuthority` remains the sole
  creator/user of writable `ModelContext`s. External / App-Intents /
  third-party writes route through it; no external path creates a context.
- **No model leakage (`00` §3.4):** `@Model` / `ModelContext` /
  `PersistentIdentifier` remain internal to `HistoryStorage`. New V2 modules
  (enrichment, audit) hold their own `@Model`s, also internal to their owner.
- **Immutable content lineage (`00` §3.5) + D2:** Canonical Content is never
  overwritten. Enrichment is a *derivation* off it, not a mutation.
- **Complete facts (`00` §3.8) + D8:** V2 retention/enrichment planners receive
  only complete, action-specific facts; no partial aggregate, no bounded-empty
  scan.
- **Cache law (Part IV §12):** every V2 cache (C1/C2/C3) is semantically
  indistinguishable from a miss.
- **Forbidden-dependency / escape-hatch gates (`01` §8, `06` §6):** V2 adds no
  `@unchecked Sendable`, no `nonisolated(unsafe)`, no app-owned authoritative
  `.shared`/`.current` service locator (framework-mandated DI seams populated
  once at the composition root are excepted - see V2-05 §6.5
  `AppDependencyManager.shared` carve-out), no second writer, no public
  SwiftData/Domain leakage.

## 3. V2 scope - admitted grafts

| ID | Capability | v1 exclusion ref | Evidence trigger (admits design work) | Doc |
|---|---|---|---|---|
| E1 | Enrichment / OCR + enrichment search corpus | `00` §2; `06` §4 | Approved product spec; OCR p95 within budget on min hardware | V2-01 |
| R1 | Age-based user retention | `00` §2; `06` §4 | Approved product requirement | V2-02 |
| R2 | Byte-based (storage) user retention | `00` §2; `06` §4 | Approved product requirement | V2-02 |
| R3 | Automatic revision retention | `00` §2; `06` §4 | Approved product requirement | V2-02 |
| J1 | Durable History Change Record + reconnect cursor + collection cache | `06` §3 G2 | At the hard retained bound, recent/search p95 > 50 ms or Authority queue p95 > 20 ms under the agreed workload; **or** an approved reconnect product requirement | V2-03 |
| C1 | In-memory completed-thumbnail cache | `06` §3 G1 | Thumbnail decode p95 > 16 ms and ≥ 30% identical completed requests in the measurement window | V2-04 |
| C2 | Disk thumbnail cache | `06` §3 G3 | C1 already justified + measured cross-launch reuse is substantial + a structural materializer fingerprint is specified and fixture-proved | V2-04 |
| C3 | Publish-fence materialization lifecycle | `06` §3 G6 | ≥ 20% of thumbnail work is superseded or discarded despite cancellation and single-flight | V2-04 |
| S1 | Per-purpose content source stamps | `06` §3 G4 | Profiling shows material work repeatedly invalidated by Effective Content changes that provably leave that purpose's source bytes unchanged | V2-01, V2-04 |
| X1 | ExternalGateway + external connections/grants + App Intents + third-party writes | `00` §2; `06` §4 | Approved product spec | V2-05 |
| X2 | Operation Record auditing + Audit/Connections domains | `00` §2; `06` §4 | X1 approved (audit is X1's consequence; subsumption justified in V2-05 Record 1) | V2-05 |
| P1 | Persistent startup checkpoint | `06` §3 G5 | Metadata-only startup/index rebuild p95 > 250 ms at 5,000 items on the minimum supported hardware profile | V2-06 |
| P2 | Localized search projection (G7 slot; V2-06 implements query-time, no projection column) | `06` §3 G7 | Product requirement for locale-sensitive matching + migration behavior; fixtures define normalization/ordering for supported locales | V2-06 |
| P3 | Blob-store handle/streaming content abstraction | `06` §3 G8 | A representative workload exceeds the capture-path memory budget or shows p95 copy cost unsolvable within the bounded inline-value design | V2-06 |
| M1 | V1 -> V2 schema / blob / projection migration | `05` §17 | Any of the above ships | each |

*The trigger column above is a summary; the canonical verbatim triggers live in
`06` §3 (G1–G8) and `06` §4 (product-deferred), restated in each capability's
owning Record 1. The fresh architecture review required by `06` §4 for every
product-deferred graft is discharged structurally by the §4 six-record admission
protocol and recorded per-graft in its owning Record 1.*

### 3.1 Excluded from V2 (remains post-V2)

- **Multi-process direct writers.** V2's external gateway (X1) routes external
  access through one process's `HistoryAuthority`; it does not permit a second
  process to open its own `ModelContainer` against the same store. Multi-process
  direct writers need a separate file-locking / multi-context architecture review.
- **CloudKit / multi-device sync.** The change journal (J1) is **local**
  durability + reconnect, not multi-device sync. CloudKit sync implies
  multi-writer conflict resolution and is post-V2.
- **ML / embedding / semantic search.** V2 enrichment (E1) is OCR text only.
  Embedding-based semantic search, classification, and summarization are
  post-V2.
- **Remote / network blob storage.** P3 (blob streaming) is a **local**
  file-handle abstraction only.
- **Generic materialization framework.** V2 caches are **purpose-specific**
  (thumbnail only). The deleted generic `ItemKey<Purpose>` / `OutputParams`
  (Part IV §11 "absent v1 coherence machinery") / five-store framework
  (`00` §2 Excluded) is **not reintroduced**; S1 source stamps are per-purpose
  *fingerprint* evidence, not a generic materialization tier.
- **Migration from the Maccy schema** remains excluded (greenfield lineage; M1 is
  `HistorySchemaV1 -> V2` only).

## 4. Graft-admission protocol

A V2 capability is *admitted* (may be designed and, after its proof gates pass,
shipped) only when its owning doc records **all applicable §4 records** - 1, 2,
3, 5 unconditionally; 4 if the graft is a cache; 6 if external-facing:

1. **Lifted exclusion + evidence trigger.** The v1 exclusion reference and the
   measured/approved trigger from §3 that opens the design review.
2. **Invariant impact.** Which of D1–D19 are preserved unchanged, which are
   *extended* (with new D20+ invariants named and stated), and proof that none
   is weakened.
3. **V2 proof gates.** The analog of Part VI §6 (compile/dependency), §7
   (schema/platform), and §9 (performance) the graft must pass on the macOS 26
   runner before it is called executable.
4. **Cache-law compliance** (if the graft is any cache): the Part IV §12 law
   restated for the graft's key and eviction, with a fixture proving
   hit/miss/eviction/restart equivalence.
5. **Migration impact.** Which of the three Part V §17 layers (schema / blob /
   projection) the graft touches, and the migration plan that never invents
   missing bytes, reinterprets an old `ContentVersion`, reuses removed IDs, or
   enables writes before Signature Index / change-journal completeness is
   restored.
6. **Security boundary** (if external-facing): the trust boundary, capability
   model, TCC / sandbox / entitlement impact, and the audit record producer.

No graft reserves a public protocol, schema column, or placeholder type in v1.
v1's Part VI §10 self-review gate (no deleted v1 vocabulary except in explicit
rejection/history statements) is reaffirmed; V2 adds its own self-review gate in
§8.

## 5. New V2 load-bearing decisions (extend `00` §3)

13. **Enrichment is a derivation, not a mutation.** OCR/enrichment produces
    derived text indexed off Canonical/Effective Content; it never overwrites
    Canonical, never mints a `ContentVersion`, and never participates in dedup
    identity. Enrichment results carry their own derivation version and are
    version-fenced against the source `ContentVersion`, mirroring the v1
    thumbnail fence (Part IV §9).
14. **The change journal is append-only and crash-consistent; reconnect is
    bounded.** A History Change Record is append-only, written atomically with
    its item mutations, and a reconnect cursor is expiry-bounded. Replay is
    provably complete or the cursor is rejected (a `.snapshotExpired` analogue).
    The journal does **not** replace v1's transient invalidation for live
    observation; it adds durable reconnect and is the *completeness mechanism* a
    collection cache (J1) may depend on (Part IV §12).
15. **Every cache obeys the v1 cache law and is fenced by authoritative
    version.** C1/C2/C3 caches are indistinguishable from a miss; a cache key
    contains `HistoryItemID` + the relevant authoritative version + complete
    normalized params + a structural materializer schema version. A stale or
    evicted cache degrades to a miss, never to wrong bytes - scoped to
    non-collision inputs; the per-doc fingerprint-collision residual each
    derivation/cache doc records (e.g., V2-01 D21, V2-04 D30) is a bounded,
    transient exception.
16. **External writes cross one audited, capability-gated boundary; the
    Authority remains the sole durable writer.** App Intents / ExternalGateway /
    third-party callers express History Actions (or a capability-scoped subset)
    that route through `HistoryAuthority`; no external path creates a
    `ModelContext` or bypasses fact-loading/planning. Every external write
    produces an Operation Record in the Audit domain.
17. **Retention expansion is planner-driven and complete-fact-bounded.** R1/R2/R3
    extend the Domain planner with new victim-selection dimensions and new
    complete facts; the one-`ChangePosition`-per-commit rule (D6) and the
    victim-selection rules (D13, D14) apply unchanged; D19's count-dimension
    guarantee applies
    unchanged, with D24 (V2-02) extending the capacity-failure surface to an
    orthogonal byte-budget dimension (`.storageBytes`) - D19's literal universal
    claim ("only the global hard retained-item bound can force a capacity
    failure") is narrowed to the count dimension by an explicit extension
    (V2-02 §4.5/Record 2; the count guarantee is preserved, the byte-budget
    failure is an orthogonal new producer). Retention never violates D2
    (Canonical immutability).
18. **Migration is explicit and three-layered.** M1 distinguishes SwiftData
    schema migration, versioned blob migration, and projection rebuild (Part V
    §17). No migration invents missing active-revision bytes, reinterprets an old
    `ContentVersion`, reuses removed IDs, or enables capture before Signature
    Index / change-journal completeness is restored.

## 6. Cross-cutting themes (detailed in owning docs)

### 6.1 Data pipeline
v1's pipeline is `NSPasteboard -> PasteboardAdapter -> IngestPreparation ->
Authority -> Domain plan -> transaction -> index -> invalidation -> receipt`
(`01` §5.1). V2 adds two **side pipelines** that branch off the canonical/commit
path without entering it: (a) an **enrichment pipeline** that derives searchable
text from retained image/PDF content off the commit interval and writes an
enrichment index (V2-01); (b) an **audit pipeline** that records Operation
Records for external writes (V2-05). Both are derivations/observations of
authoritative state, never additional writers (decision §16).

### 6.2 Data flow
- **Reads:** v1 scalar reads are unchanged. V2 adds enrichment-corpus reads
  (search may consult the enrichment index) and change-journal reads (reconnect).
  Neither decodes Canonical/revision blobs except where v1 already does
  (detail/paste/thumbnail).
- **Writes:** one path through `HistoryAuthority` (decision §16). Retention
  expansion writes are new victim mutations on the same plan/transaction path
  (decision §17).
- **Caches:** sit between Authority reads and the caller; every cache hit is
  fenced by the authoritative `ContentVersion`/`ChangePosition` (decision §15).

### 6.3 Code model
New V2 modules/actors (all `Sendable`, actor-isolated, no escape hatches): an
`EnrichmentWorker`/`EnrichmentScheduler` (V2-01), an HCR append path on
`HistoryAuthority` + a `ChangeJournal` reader actor + `ReconnectCursor` reader
(V2-03), cache stores for thumbnail (V2-04),
an `ExternalGateway` + capability grants + `OperationRecord` audit (V2-05). Each
new actor is added to `SwiftDataHistory`'s field set or composed in `ClipyApp`;
none stores `@Model` across operations; none weakens the v1 isolation model
(`01` §6).

### 6.4 Security boundaries
- **Content sensitivity:** OCR runs on-device (Vision) (V2-facts); image bytes
  never leave the process; enrichment text is stored with the same `.externalStorage` /
  bounded-projection discipline as v1 (`05` §3).
- **External access:** the ExternalGateway is the single trust boundary;
  capabilities are grant-scoped; every external write is audited (decision §16).
  TCC/sandbox entitlements are explicit and minimal.
- **Crash safety:** the change journal and caches are derivations; their loss
  degrades to a miss/rebuild, never to wrong durable state (decisions §14, §15).

### 6.5 Code interaction
V2 surface is added behind the closed `HistoryAction` / `ClipboardHistory` seam
where it is a caller action, or behind new purpose-specific protocols where it is
a distinct concern (enrichment, audit, external). Adding a V2 History Action is
an owned exhaustive-switch change across Core/Domain/Storage/tests, exactly as
v1 (`03a` §1).

### 6.6 UX interaction
V2 UX (V2-07) is built only from `HistoryCore` DTOs + new V2 DTOs, on the main
actor, with no SwiftData/Domain leakage. New surfaces: enrichment status /
indicator, retention settings, change-history / reconnect (if exposed),
external-connection management, accessibility, and localization (P2). Observation
remains snapshot-replacement (Part IV §5).

## 7. Parts and ownership

1. [Overview](V2-00-overview.md) (this file): scope, graft-admission, inherited
   + new decisions, cross-cutting themes.
2. [Enrichment Pipeline](V2-01-enrichment.md): E1 OCR derivation model,
   enrichment index, S1 source stamps, security, UX.
3. [Retention Expansion](V2-02-retention.md): R1 age, R2 byte, R3 revision
   retention; planner / facts extensions; bounds; UX.
4. [Change Journal & Reconnect](V2-03-change-journal.md): J1 durable record,
   reconnect cursor, collection cache, coherence evolution, crash consistency.
5. [Materialization Caches](V2-04-materialization.md): C1 in-memory thumbnail,
   C2 disk thumbnail, C3 publish fence; cache law; keys; eviction.
6. [External Gateway & Audit](V2-05-external-gateway.md): X1 gateway /
   connections / grants / App Intents / third-party writes, X2 Operation Records
   + Audit/Connections domains; trust boundary.
7. [Platform Grafts](V2-06-platform-grafts.md): P1 startup checkpoint, P2
   localized search, P3 blob streaming.
8. [UX Interactions](V2-07-ux.md): V2 UX across all capabilities; accessibility;
   localization.
9. [Roadmap](V2-roadmap.md): V2 implementation order with evidence gates,
   respecting the graft-admission protocol.

## 8. V2 specification precedence and proof-gate discipline

- V2 docs extend `00`–`06`; v1 owns v1 surface, V2 owns new surface. On conflict
  for v1 behavior, **v1 wins**.
- V2 makes **no concrete platform claim** without a V2 proof gate or an
  MCP-verified citation. Platform facts are MCP-verified in `V2-facts.md`. Where
  a platform behavior is not guaranteed by documented API, V2 states the
  required outcome and assigns an implementation-time proof, exactly as v1
  (`00` §5).
- **V2 self-review gate** (before any V2 capability is called executable): a
  mechanical scan confirms (a) no v1 public type / schema column / codec is
  redefined; (b) every admitted graft has all applicable §4 records (records 4
  and 6 conditional on applicability); (c) every cache doc
  restates the Part IV §12 law; (d) no V2 doc reserves v1 surface; (e) D1–D19
  are each either preserved-unchanged or explicitly extended with a stated new
  invariant; (f) all V2 public type names are consistent across V2 docs and do
  not collide with v1 names; (g) D19's narrowing-to-count-dimension (V2-02 D24)
  is a sanctioned explicit extension (not a forbidden weakening) - the count
  guarantee is preserved, the byte-budget failure is an orthogonal new producer;
  (h) adding a case to a v1-closed public enum
  (`HistoryAction`, `HistoryCommitOutcome`, `CapacityKind`) or a v1 package enum
  (`HistoryMutation`, `PlannedOutcome`) or a v1 internal enum (`StampedMutation`,
  `05` §9) is sanctioned extension-by-addition (not a redefinition of an
  existing case's meaning) - the closed enum makes every required exhaustive
  switch compiler-visible, so the design owns and atomically updates every
  affected switch site across Core/Domain/Storage/tests at the same commit as
  the case addition (`03a` §1, §6.5); V2-02's contingency fallback (reuse v1
  cases) applies if a future governance decision disallows enum-case addition; (i) the
  `HistoryChangeKind` carve-out is MOOT (V2-03 pre-emptively renamed it
  `JournalEntryKind`); bare `R1`/`R2`/`R3` tokens (V2-02 graft IDs / dimension
  labels) do not match the deleted-v1 phrase "R0 / R1 / R2 as shipped tiers"
  (`06` §10) and need no carve-out.

## 9. Naming and placement

V2 docs live in `docs/v2/` with the `V2-` filename prefix, leaving the v1
`docs/` files (`00`–`06`, `AUDIT.md`, `PROGRESS.md`, `roadmap/`) untouched
(per the directive: do not modify code or existing docs, only generate new
docs). Cross-references to v1 use relative paths (`../00-overview.md`,
`../06-cross-cutting.md#3-deferred-g1g8-grafts`, etc.). V2 type/identifier names
reuse v1 vocabulary (`HistoryItemID`, `ContentVersion`, `ChangePosition`,
`CanonicalContent`, `EffectiveContent`, `HistoryAuthority`, …) verbatim and add
new names with a `V2-`-scoped or domain-prefixed convention defined per doc.
