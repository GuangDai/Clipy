# Design Audit & Change Log (traceability root)

> **Status:** living document. NOT part of the seven-file v1 specification
> (`00`–`06`). It records how the spec was audited, what was found, and every
> edit made to the spec so future development can trace *why* each line is the
> way it is. Authored 2026-07-19.
>
> Every spec edit MUST append a row to §3 (Change Log) referencing a Finding ID.

## 1. Method

Two independent verification tracks whose results are **merged** (cross-checked)
before any edit is trusted:

1. **Multi-agent workflow** (`clipboard-design-audit`): 4 rounds × ≤5 agents,
   Analyze → Investigate → Critique → Settle, over 5 stable slices:
   S1 cross-doc consistency, S2 Swift 6 concurrency, S3 SwiftData platform,
   S4 domain logic, S5 read/observation/search/thumbnail. Agents used Apple MCP
   and context7 where relevant.
2. **Direct primary-source verification** by the orchestrator (Apple docs MCP,
   the `krisk/fuse-swift` README, repo greps) of the load-bearing platform
   claims, so workflow verdicts are never trusted singly.

Any edit triggers a re-audit round (goal: "改后必再审，循环至干净").

### Finding ID scheme
`<source>-<NN>` where source is `IND` (independent/orchestrator) or
`WF-<slice>` (workflow slice). Severity: `critical | major | minor | nit`.
Verdict: `CONFIRMED` (real defect, fix) · `REFUTED` (looks wrong, is correct) ·
`OPEN` (needs more evidence).

## 2. Findings register

| ID | Sev | Location | One-line | Verdict | Status |
|---|---|---|---|---|---|
| IND-01 | minor | 00:11, 06:230 | `docs/greenfield/` path referenced but actual dir is `docs/` | CONFIRMED | fixed |
| IND-02 | minor | 00:66, 01:158, 04:68 | `CONTEXT.md` referenced 3× but file absent | CONFIRMED | fixed |
| IND-03 | major | 03 §8, 06 §2, 01 §4 | Fuse `maxPatternLength` default 32 vs 256-char fuzzy bound → long queries silently nil | CONFIRMED | fixed |
| IND-04 | minor | 03 §8, 01 §4 | Fuse `location`/`distance` (relevance-affecting) undiscussed | CONFIRMED | fixed |
| IND-05 | nit | 01 §4 | "Fuse 1.4.x" version unverified; dep not named precisely; Sendable-by-confinement implicit | REFUTED | fixed (repo named `krisk/fuse-swift`, 1.4.0 confirmed latest stable; non-Sendable confinement documented in Module 7) |
| WF-* | ? | — | *(workflow findings merged after run completes)* | — | pending |

### Design-correct confirmations (REFUTED-as-fine, kept for provenance)

| Claim | Evidence | Result |
|---|---|---|
| `ModelContext.transaction(_:)` commits on closure success w/o extra `save()` | Apple: "Runs the provided closure, and once it finishes, writes any pending inserts, changes, and deletes to the persistent storage." block = "closure to run **before performing a save operation**." `transaction(block:)` macOS 14+. | CORRECT (failure-case correctly gated as Part VI §7.1 proof) |
| `propertiesToFetch` limits scalar reads; blob access faults | Apple: "if you subsequently access a nonfetched attribute, you'll incur the additional overhead of fetching the corresponding value from the persistent storage." | CORRECT (design gates no-fault as Part VI §7.5 proof) |
| `registeredModel(for:)` is not a business-ID lookup | Apple: `func registeredModel<T>(for persistentModelID: PersistentIdentifier) -> T?`; returns model only if "known to the context; otherwise nil". | CORRECT |
| Fuse threshold 0.7 + score-lower-is-better | `krisk/fuse-swift` README: threshold 0.0–1.0 (default 0.6); example score 0.444, 0 = perfect. | CORRECT |
| `HistoryItemID`/`RevisionID` `<` via `UUID.uuid` bytes | `UUID.uuid` is a 16-byte tuple; `withUnsafeBytes(of:).lexicographicallyPrecedes` yields deterministic total order. | CORRECT |
| `@Attribute(.externalStorage)` is a hint, not a guarantee | No dedicated Apple page; standard Core Data/SwiftData behavior; design does not depend on it for correctness. | CORRECT (posture) |
| Part VI §10 deleted-vocabulary leakage | Repo grep: every hit is inside an explicit rejection/history statement or the gate's own list. | GATE PASSES |
| Part III ↔ Part VI §2 numeric bounds | Mechanical cross-check: regexp prefix 1,000, fuzzy prefix 5,000, snippet 322, regexp-pattern limit deferred to Part VI's 512, fuzzy-query/search-term bounds live only in Part VI. No Part III vs Part VI mismatch. | CONSISTENT (IND-03 maxPatternLength gap stands separately) |

## 3. Change log

Every spec edit appends here: `date | finding | file:section | old → new`.
Pass 1 (2026-07-19) — all 15 MAJORS + ~20 minors/nits; re-audit follows.

| Finding | File:§ | Change |
|---|---|---|
| S1-01/S1-02/S4-01 | 02 §5.5 | `maximumUnpinnedItemCount`→`maximumUnpinnedItems`; "non-negative"→"at least 1, matching Part VI 1–5,000; 0 rejected at boundary" |
| S4-02 | 02 §6, §11 | added `DomainRejection.corruptLineage`; full DomainRejection→HistoryFailure mapping table; step 2→staleContent, step 3→corruptLineage, step 4 = Domain invariants only (Storage enforces numeric bounds) |
| S4-08 | 02 §3.1 | lastSource = `incoming.sourceApplication ?? existing.lastSource` (no nil overwrite / source regression) |
| S4-06 | 02 §2.1 | normalized set forbids empty-bytes representations |
| S4-18 | 02 §14 D3 | strengthened to iff: `activeRevisionID==nil` ⟺ revisions empty |
| S4-05/S4-21 | 02 §3.2 | PinOrdinal explicit `<`; rawValue non-negative note |
| S4-03/S4-10/S4-11/S4-16 | 02 §13 | stamping-contract note; one-advance-per-plan promoted; overflow→`.coherenceToken`/`.copyCount` |
| S4-07 | 02 §14 | added D19 (retention floor ≥1) |
| S1-07 | 03 §5 | RevisionDecisionAction resolution semantics (.inheritCanonical/.replace/.hide; hide omits from Effective, retained in Canonical; all-hidden rejected) |
| S1-03/S5-15 | 03 §10 | added `InvalidInputReason.invalidRetentionPolicy`, `.invalidSearchTerm` |
| S5-04/S5-12/S5-14/S5-17/IND-04 | 03 §8 | regexp NSFA + 1,000/title-and-body; Fuse fixed params; maxPatternLength self-enforced (dead in 1.4.0); Fuse-range→UTF-16; fuzzy pinned-first |
| S3-01 | 05 §3.1 | revisionStateBlob active-bytes clarified for Canonical-state (nil active ⟺ empty list) |
| S2-15 | 05 §2 | SwiftDataHistory Sendable derivation comment (5 actor fields) |
| S1-08 | 05 §9 | stamping bullet for setRetentionPolicy |
| S1-06/S1-12/S1-13/S1-20/S5-07 | 05 §16 | failure translation: `.dedupIndexRebuild` vs `.factProof` split; `.transaction`/`.coherenceToken` producers; cursor→`.snapshotExpired` |
| S2-02/S2-04/S2-06/S2-07/S2-10/S5-10/S1-10 | 01 §6 | all background isolations declared `actor`; RevisionPreparationActor added; SearchWorker confines non-Sendable Fuse; ThumbnailService owns flight table; manual-ModelContext-off-main note |
| S1-04 | 06 WS9 | made reachable (planner-seam hard-bound test) |
| S1-05/S1-30/S1-31 | 06 | added WS16 (remove+notFound/placement), WS17 (search+ranges+failures), WS18 (pagination+snapshotExpired), WS19 (out-of-order monotonicity), WS20 (concurrent revision+coalesce) |
| S1-15 | 00 §1, 06 §10 | `docs/greenfield/`→`docs/` |
| S1-16 | 00 §5, 01 §5.5, 04 §4 | CONTEXT.md references → inline (no external-file dependency) |

Outstanding after Pass 1 → addressed in Pass 2 (same date):

| Finding | File:§ | Change |
|---|---|---|
| S1-26 | 06 §2 | declared `HistoryLimits` (+ `standard`); test-bounds injection at planner seam |
| S1-17/S3-12 | 05 §3 | defined `historySchemaV1` = `Schema(HistoryItemRow, LastChangePositionRow)`; clarifies ModelContainer registration |
| S2-05 | 05 §14.2 | declared `SearchCorpusSnapshot` + `SearchCorpusRow` (Sendable) |
| S1-18 | 03 §8 | `pinnedPosition` is 0-based, equals `PinOrdinal`, nil if unpinned |
| S1-19 | 05 §2 | `open` throws `HistoryFailure` (invalidRetentionPolicy / persistence openStore/corrupt/invariant) |
| S1-11 | 05 §9 | Domain `HistoryMutation` → `StampedMutation` rename table |
| S3-02/03/05/06/14/15 + S4-15 | 05 §4, 06 §7.4 | aligned exhaustive decode-check / corruption-rejection lists; active-ID nil semantics (D3); fingerprint coverage-only per D7; effectiveTypeIdentifiersBlob format |
| S5-03/05/06 | 03 §8 | excerpt clamp (body<320), conditional ellipsis offset; regexp rejects backreferences, permits non-capturing groups |
| S2-08 | 03 §3 | scripted preview adapter must be `Sendable` |
| S1-24 | 03 §12 | example `snapshot.historyItemID` annotated as adapter-decoded hint |
| S5-08 | 04 §9 | thumbnail step 2 is the version gate; step2→3 gap covered by old-reference tagging |
| S1-23 | 06 WS8 | "the middle" → "the item now occupying the middle position" |

Pass 3 (2026-07-19, re-audit-driven) — fixed the 28 issues the re-audit found
(most introduced by Pass 1/2). Re-audit #2 verifies.

| Finding | File:§ | Change |
|---|---|---|
| S4-N1/S4-R2-1/S3-R9/S4-R2-2 | 02 §2.5,§2.6,§14 D3,§11; 03 §5 | removed false `activeRevisionID==nil ⇔ Effective==Canonical` biconditional (revert-to-canonical is a counter-example); D3 iff is about the revision *list*; §2.5 Rule 1, §2.6, §11 step 3 enumerate both corrupt directions |
| S1-R1 | 06 §11 | `WS1–WS15` → `WS1–WS21` |
| S3-R1 | 06 WS21 | added WS21 (`setRetentionPolicy` + `retentionPolicySet` outcome) |
| S3-R7 | 02 §5.1 | fact-load failure splits `.factProof` vs `.dedupIndexRebuild` |
| S5NEW-01 | 04 §9 | thumbnail steps 2–3 are one non-suspending Authority interval; fence is the off-Authority decode |
| S5NEW-03 | 03 §8 | fuzzy: pinned rows by `pinOrdinal`, unpinned rows by Fuse score (removed "each bucket" contradiction) |
| S1-R2 | 06 WS16 | placement→`targetMissing` vs remove/unpin/revise→`notFound` is by-design |
| S1-R3 | 05 §3 | renamed binding `historySchemaV1`→`v1Schema` (no casing collision) |
| S2R2-N1 | 05 §6.2 | declared `RevisionPreparationSnapshot` |
| S2R2-N2 | 01 §4 | removed "may run on a dedicated actor" hedge |
| S2R2-N3/N4 | 01 §6 | `@ModelActor` option + corrected proof gate to Part VI §6 |
| S3-R2/R8 | 06 WS5/WS13 | pinned `.dedupIndexRebuild` / `.persistence(.transaction)` |
| S3-R3/R4/R5/R6 | 05 §4,§16 | `EffectiveTypeIdentifiersBlobV1` codec; projection/title/searchBody bounds; bidirectional signature coverage; transaction covers framework save-boundary |
| S4-R2-3/R2-4 | 02 §11 step 2/4 | named `.invalidRevisionDraft` for invariant failures |
| S5NEW-02 | 01 §6 | SwiftDataHistory stores 5 actors; ThumbnailWorker owned by ThumbnailService |
| S5NEW-04 | 03 §8 | excerpt context redistributed at body edges |
| S5NEW-05 | AUDIT §3 | S5-12 removed from "remaining" (fixed in Pass 1) |
| S5-R2-1/R2-2 | 03 §8 | regexp over-limit→`.invalidRegularExpression`; non-capturing groups permitted unless nested-quantifier |

Pass 4 (2026-07-20, post-02:20) — final verification CLEAN (go for split) + 3
clarity fixes + the doc-size split.

| Finding | File:§ | Change |
|---|---|---|
| verify-minor-1 | 02 §2.5 Rule 3 | "means" → "implies … (one direction; iff in D3)" |
| verify-minor-2 | 04 §9 | removed duplicate stale-before-step-2 sentences (Pass 3 editing artifact) |
| verify-minor-3 | 03 §8 | added `(a+\|b)+` example for quantified-alternation rejection |
| doc-split (§5) | 03 → 03a + 03b | split 736-line `03-instruction-set.md` into `03a` (§1–7, 348 lines) + `03b` (§8–12, 390 lines); updated 00 §4 (Part III = A+B), 00 §5 ("seven files" → Parts I–VI with III split), 06 §10 WS16 ref `Part III §10`→`Part III-B §10`; `03-instruction-set.md` filename now unreferenced |

Remaining (genuinely low-priority, deferred): S2-12/13/16, S3-04/07/08/09/13,
S4-04/13/14, S5-13/18, S1-21/22/32, S5-09/16 — wording/traceability nits that do
not affect correctness. Re-audit #2 + final verifier both CLEAN.

### Roadmap (2026-07-20)

Built `docs/roadmap/` (README + 7 module files), **covering all 8 Part I §2 targets** (xxh3+Fuse co-documented in Module 7)
(HistoryCore, HistoryDomain, HistoryStorage, PasteboardAdapter, PresentationUI,
ClipyApp, xxh3+Fuse), ordered by Part VI §5. Each module doc: Status · Spec-ref ·
Dependencies · Deliverables · Acceptance (WS#/Part VI proof) · Risks. A semantic
1:1 verification agent returned no invented content; 4 citation/scope nits
fixed: (a) `03-historystorage` WS range → WS1–WS21 + added WS15; (b) same file
Deliverables added `PreparedRevisionBundle`/`SearchCorpusSnapshot`/`SearchCorpusRow`;
(c) `06-clipyapp` XcodeGen gate ref → Part I §9.6; (d) README §3 de-duplicated
WS11/WS12 between steps 5–6. Mechanical self-check passed (all spec-refs resolve,
all internal links resolve, all cited types exist in spec).

**Design → roadmap → code traceability chain is now complete and reversible:**
any spec section → its module (README §2 map) → its WS/proof gate; any code →
its spec section + gate via the module doc + this change log.

### Roadmap critique + revision (2026-07-20)

A 4-round × ≤5-agent roadmap-critique workflow judged the first roadmap draft
**NOT SOUND** on completeness and ordering (66 confirmed / 5 refuted / 0 open).
Load-bearing findings, all fixed in this revision:

- **No Phase-0 scaffold** (RC1-01/04): README §3 started at HistoryCore with no
  step to create the package/target graph/XcodeGen/import-gate/symbol-snapshot
  that HistoryCore's own Acceptance invokes, and no owner for the Part VI §6
  graph-level proofs. **Fix:** added step 0 (scaffold) owning the §6 graph proofs.
- **xxh3 + Fuse unsequenced — both are step-4 compile deps** (RC1-05, RC2-01/10,
  RC4-05): `SwiftDataHistory.searchWorker` is a stored field initialized by
  `open`, so Fuse (not just xxh3) is needed at step 4. **Fix:** added step 3
  (integrate xxh3 + Fuse before step 4).
- **9/21 WS gates mis-steped** (RC2-02..09, RC3-02, RC4-08, RC5-01): gates at
  steps 5–6 carried public-read/observation clauses checkable only at step 7/9b;
  WS14 (restart) was unplaced. **Fix:** WS-clause-phasing note + WS14 placed at
  step 6; full suite re-runs at step 9b.
- **State-3 product concerns unowned** (RC1-02, RC4-09, RC5-02). **Fix:** §5
  state-3 deferral note (separate acceptance per Part VI §11).
- **HistoryLimits type unowned** (RC1-03). **Fix:** Module 1 Deliverables +
  AUDIT flag (spec does not locate the type; HistoryCore is the natural home).
- **Hierarchy**: added Phase 0/M1/M2/M3 phases, module-owner prefixes, step-9 split
  (9a/9b) (RC4-03/04/07); HistoryStorage sub-steps 4–8 (RC4-06); Test-target
  line on every module (RC1-06/RC4-13); import-confinement Acceptance on
  Modules 2–5 (RC1-09/RC5-15/17); HistoryStorage BLOCKER risk flags for §7.1/§7.2
  + concurrency-harness prerequisite (RC5-04/07/08/18); spec-ref completions
  (RC3-05/11/12); Module 7 renamed "Dependencies" with Deliverables (RC4-02/11);
  §9 added to completion gating (RC3-01/RC5-03); traceability §4 softened for
  cross-cutting edits (RC3-10/RC5-06); "1:1" wording corrected to "covers all 8
  targets" (RC3-07/RC4-01); Foundation-dep column made consistent (RC3-03/13).

Post-revision self-check passed (WS1–WS21 all cited; steps 0/3 + phases present;
every module has a Test target; no broken links; §9 in completion gating).

### Roadmap Round B — fresh-lens verification + fixes (2026-07-20)

5 fresh-lens agents (developer-simulation / verbatim-fact / mechanical /
adversarial / completeness). Verdict converged: **no critical; sound on
architecture, isolation, single-writer, graft-promises, stub-actor `Sendable`,
and step-order topology**. Load-bearing fixes applied:

- **MAJOR — concurrency harness unscheduled** (3 agents; adversarial raised to
  MAJOR): WS12/13/15/20 need a deterministic concurrency harness + (WS13) a
  transaction-injection seam, neither in the spec. **Fix:** scaffolded at step 0,
  finished at step 5; added as Module 3 Deliverable (test infrastructure); §5
  notes state-2 requires it delivered.
- **MAJOR — phasing note mis-stated WS2 + omitted WS5:** WS2 has no observed-page
  clause (only WS1); WS5's no-row/no-position/no-invalidation clauses need step 7.
  **Fix:** dropped WS2, added WS5; clarified **state 2 closes at step 8** (all WS
  via direct `SwiftDataHistory`, reads at step 7, harness at step 5); step 9b is
  M3 re-verification, not a state-2 requirement.
- **A1 (unanimous, 5 agents) — "1:1 with Part VI §5" false:** Part VI §5 lists 7
  targets incl xxh3 but NOT Fuse (external SPM). **Fix:** reworded — Part I §2
  lists both; Part VI §5 lists xxh3, Fuse is external.
- **A2 — step-0 build break:** "create exactly Part I §1 graph" included the
  HistoryStorage→Fuse edge, unresolved until step 3. **Fix:** step 0 declares
  placeholder/stub targets, HistoryStorage WITHOUT the Fuse edge, xxh3 with
  placeholder source; step 3 adds the real xxh3 + the Fuse edge.
- **WS19 mis-steped (step 6 → step 5):** WS19 is capture/coalesce occurrence
  monotonicity, not a mutation. Moved.
- Plus: M↔state mapping; M2 arrow includes step 3; "7 production = 6 SwiftPM +
  ClipyApp via XcodeGen"; "(7+6) Part VI §5" citation; "every module … where
  applicable"; manifest-convention softened; `.factProof` attributed to Storage
  boundary (not planner); snapshot package-init clarified; §7.2 moved to step 7
  (read-side); §7 proofs phased by step; §7.5 projection-redesign fallback;
  Module 6 second-open citation + state-2 wording; `HistoryLimits` sanctioned in
  06 §2 (HistoryCore home); xxh3 collision-double = Storage-only; AUDIT register
  statuses refreshed (no stale "open"); `8a/8b`→`9a/9b`; ClipyApp→HistoryCore
  edge footnoted; "Part I §9 item 6" (not §9.6); Step label on every module.

### Roadmap Round C — adversarial re-verify + fixes (2026-07-20)

Single adversarial agent found a propagation blocker: §7.2 had been moved to
step 7 in the module doc but NOT in README (step 5 still claimed it — an
impossible BLOCKER proof). Fixed: §7.2 now only at step 7 across README + 03;
§7.4 added to step 4; "Part I §9 item 6" (not §9.6); step-7 deferral list
broadened; xxh3/Fuse incremental-convention wording aligned; §9 perf-runner
scheduled (step 0 scaffold); `ClipyIntegrationTests` XcodeGen-hosted note.

### Roadmap Round D — full 4-round verify + fixes (2026-07-20)

4-round × ≤5-agent workflow (5 fresh angles). **Architecture confirmed SOUND by
all angles** (chain compiles step-by-step, `swift package resolve`@step0,
stub-actor `Sendable`, WS partition exact = 5@5+10@6+5@7+1@8, state-2 reachable
@step8). 1 MAJOR + ~13 MINOR found — all documentation precision, not
architecture. **MAJOR fixed: Fuse first-used timing** — README/07 said
"Fuse@step5" but 03 (architecturally correct) says the step-5 `SearchWorker` is
a stub; **Fuse is first USED at step 7** (WS17 is its sole consumer). Split to
xxh3@5 / Fuse@7 (both pinned step 3). Minors fixed: WS2/WS21 added to step-7
deferral lists; WS4 removed from the step-5-6 example; M2 arrow prepends
`deps (xxh3+Fuse) →`; §9 release-runner added to M2 closure; `HistoryConfiguration`
→ `HistoryAction` in the ClipyApp→HistoryCore footnote; module-shape adds `Step`;
§7.7/§7.8 + §9 phased by step; xxh3-double timing (step 3 created / step 5
exercised); `HistoryLimits` parenthetical (06 §2 now sanctions); Pasteboard-
AdapterTests overclaim removed; Module 6 second-open positive gate; 00-overview
"1:1"→"covering all 8". Round E verification follows.

## 4. Workflow final verdicts (merged with independent verification)

`clipboard-design-audit` complete: 20 agents, 4 rounds (Analyze→Investigate→
Critique→Settle). **108 unique issues → 97 CONFIRMED / 18 REFUTED / 0 OPEN.**
Per-defect detail: journal at
`…/subagents/workflows/wf_88c66729-323/journal.jsonl` (one `result` line per
agent); aggregated output captured 2026-07-19.

> Independent cross-check caught an R1 over-claim that R2–R4 also refuted:
> `S2-concurrency-01` ("fuse-swift HEAD = 2.0.0-dev, different API") — actually
> latest stable tag = **1.4.0** (design pin correct); 2.0.0-rc.1 is pre-release.
> This is why fixes waited for verified verdicts, not R1 alone.

### 4b. Critical independent resolutions (load-bearing)

| Item | Workflow raised | Independent verdict | Action |
|---|---|---|---|
| Fuse version "1.4.x" | S2-01 (major: wrong version/API) | **REFUTED** — 1.4.0 is the latest stable tag; 2.0.0-rc.1 is pre-release. Design pin is correct. | none (keep 1.4.x); possibly name repo `krisk/fuse-swift` for traceability |
| Fuse `maxPatternLength` | S5-02 + IND-03, **deepened by S5-17 (major)** | **CONFIRMED** — Fuse 1.4.0 source shows `maxPatternLength` is a DEAD param (never read; "return nil" unimplemented). So the bound cannot be delegated to Fuse. | **fix in the design, not Fuse**: 03 §8 enforces the 256-char fuzzy-query bound itself (reject >256 pre-Fuse via `invalidInput`); do not claim Fuse enforces it |
| Fuse `location`/`distance` | IND-04 | **CONFIRMED gap** — relevance-affecting, undiscussed | fix: fix+fixture in 03 §8 / 01 §4 |
| Fuse non-Sendable (Swift 5 class) | S5-01, S2-02 | **CONFIRMED** — confinement to SearchWorker is correct design, but SearchWorker's `actor` declaration is missing → `SwiftDataHistory: Sendable` not provable | fix: declare `actor SearchWorker` (and ThumbnailService isolation) |
| `ModelContext` main-actor? | S2-10 (major) | **NOT fatal** — only the SwiftUI-environment context is main-actor-bound; manual `ModelContext(container)` is usable off-main (SwiftData `@ModelActor`/`ConcurrencySupport` exists for exactly this). | fix: 01 §6 / 05 §5 must state non-use of env context + gate Swift-6 compilability + evaluate `@ModelActor` (cross-ref S2-04) |
| `transaction(_:)` closure sync? | S2-03 (major) | **RESOLVED** — Apple signature `func transaction(block: () throws -> Void) throws`; synchronous non-Sendable closure ⇒ no-await interval is type-system-enforced | none (cite signature) |

### 4c. CONFIRMED defects by severity (97 total; fix pass in §3/§6 order)

**MAJOR (15)** — S2-15 `SwiftDataHistory: Sendable` unprovable (SearchWorker /
ThumbnailService fields); S3-01 "active bytes always present" false for
Canonical-state items; S5-17 Fuse `maxPatternLength` dead param (see 4b);
S1-01 retention two field names; S1-02 retention range contradicts (Part II
"non-negative" vs Part VI "1–5,000"); S1-03 no `InvalidInputReason` for
out-of-range retention; S1-04 WS9 failure unreachable at fixed 5,000 bound;
S1-05 included behaviors with no WS path; S1-06 `UnavailableReason
.dedupIndexRebuild` no producer; S1-07 `RevisionDecisionAction.hide` no
semantics; S1-08 Part V §9 stamping omits `setRetentionPolicy`; S2-02
SearchWorker not declared `actor`; S4-01 (=S1-02) retention floor; S4-02
`effectiveContent` corrupt-lineage throw has no `DomainRejection` corruption
case + §11 step 3 contradicts §6; S5-14 Fuse ranges are Character-indices into
a lowercased copy, violating the UTF-16 `matchedRanges` contract.

**MINOR (54)** — S1-10/11/12/13/14/15/16/17/18/19/20/26/30/31; S2-04/05/06/07/
08/12/13/16; S3-02/03/04/05/06/07/11/12/14/15/16; S4-03/04/05/06/07/08/10/11/
13/16/17/18; S5-01/02/03/04/05/06/07/08/15/18. (Locations in workflow output.)

**NIT (14)** + **QUESTION (14)** — wording / traceability; resolved in the fix
pass with one-line clarifications or explicit "out of v1 scope" notes.

### 4d. Notable REFUTED (18) — looks wrong, is correct (kept for provenance)

S2-01 (Fuse 1.4.x is correct); S2-09 (`Data` is Sendable); S2-03 (`transaction`
closure is synchronous); S2-10 (manual ModelContext usable off-main); S1-09 /
S1-13 / S1-27 / S1-28 / S1-29 (role-prose ≠ type-name; documented synonyms;
field order semantically irrelevant; intentional layer seams are not gate
violations); + remainder in workflow output. Do not re-flag these.

## 5. Doc-size analysis & split proposal

Per-section line counts (measured 2026-07-19). Goal target: ≤ ~300 lines/file.

**02-domain.md (598 lines)** — candidate 3-way split along sub-domains:
- 02a Content lineage & state (§1–§3): 201 lines
- 02b Facts, rejection & mutation plan (§4–§7): 203 lines
- 02c Planners → invariants (§8–§14): 191 lines

**03-instruction-set.md (726 lines, largest)** — candidate 4-way split:
- 03a Identity, protocol & capture (§1–§4): 165
- 03b Actions, receipts & browse/search (§5–§7): 173
- 03c DTOs (§8–§9): 234
- 03d Failures, guarantees & examples (§10–§12): 151

**05-authority-kernel.md (609 lines)** — candidate 3-way split:
- 05a Adapter, schema & codecs (§1–§4): 211
- 05b Context, preparation, facts & dispatch (§5–§8): 141
- 05c Plan → platform anchors (§9–§18): 257

Small docs stay as-is: 00 (67), 01 (240), 04 (192), 06 (265).

**Split cost:** the spec cross-references heavily ("Part V §10", "see
02-domain.md"). Splitting forces a cross-ref cascade and contradicts
00-overview §5 ("these seven files") + the Part I–VI framing. Decision
deferred to §6 sequencing — correctness first, structure second.

## 6. Sequencing & roadmap plan

Ordered to minimize risk (each gate re-audited before the next):

1. **Merge** workflow findings into §2 (dedup vs IND-*). *(blocked on workflow)*
2. **Fix in place** — every CONFIRMED defect edited in the current 7-file
   structure; each edit logged in §3 with Finding ID + old→new.
3. **Re-audit #1** — fresh analyze→critique round over the edited docs; loop
   2–3 until no CONFIRMED regression.
4. **Split** (if still warranted after §5) — apply the chosen split, update
   every cross-ref mechanically, update 00-overview §5 file count.
5. **Re-audit #2** — confirm cross-ref integrity post-split.
6. **Roadmap** — modular, **covering all 8 design modules** (7 docs; xxh3+Fuse
   co-documented in Module 7), each roadmap module cross-links its source spec
   sections and its WS/proof gates (Part VI). Re-audited for full correspondence.

Roadmap shape (drafted here, finalized post-split): per module —
`status · dependencies · deliverables · acceptance (WS#/proof) · spec-ref`.
Modules mirror Part I targets: HistoryCore, HistoryDomain, HistoryStorage,
PasteboardAdapter, PresentationUI, ClipyApp, plus xxh3/Fuse integration notes,
ordered by Part VI §5 recommended implementation order.
