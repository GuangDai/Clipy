# Clipy V1 — Codebase Architecture Verification (Master Summary)

> **What this is:** a deep, multi-angle verification of the **v1 implementation** (`Sources/`) against the design specification (`docs/00–06`), covering correctness, time/space complexity, efficiency, concurrency/isolation, security & privacy, edge cases, exposed API surface, test coverage, and spec conformance. The audit at `8f316c9` was analysis-only; the dated remediation overlays record the later implementation and proof work.
> **Method:** seven module-level plus one cross-cutting **3-cycle 审查(Review)→调研(Research)→批评(Critique)** workflows (the user-mandated 9-step structure), run serially. Each cycle's Review surfaced candidate findings across dimension bundles; Research independently verified each against Apple docs MCP, the repo spec, web sources, and source re-reads (skeptic-first, default REFUTED); Critique synthesized, ranked, corrected, and deepened. Per module: ~22 agents, ~50–92 min, ~1.6–2.5M tokens. The orchestrator independently cross-checked every headline finding against the source.
> **Output location:** `docs/V1-Verified/` (Markdown — per the user's explicit instruction, not HTML).
> **HEAD audited:** `8f316c9` (2026-08-02).
> **Remediation tracking:** the audit narrative is historical; the mechanically
> complete current status ledger is `07-finding-dispositions.md`.
>
> **Final remediation closure (2026-08-11):** all 109 findings that were
> awaiting supported-runner proof are `fixed`. Public-symbol workflow
> [31448087991](https://github.com/GuangDai/Clipy/actions/runs/31448087991)
> and final code-head run
> [31449682036](https://github.com/GuangDai/Clipy/actions/runs/31449682036)
> are green; the latter passed 314 tests in 41 suites and all 13 release
> workloads. Final dispositions are 110 `fixed`, 32 `deferred`, 31 `duplicate`,
> 30 `not-a-defect`, 19 `documented`, and no active or pending rows. Historical
> defect descriptions and recommendations below remain as audit provenance.
>
> **Post-closure overlay (2026-08-11):** source-inclusive thumbnail hydration
> is fixed by supported run 31494740863, and a dispatch-only absolute
> performance-evidence lane and the WL2 independent-process rerun are in
> pre-proof. The current checksum is 111 `fixed`, 29 `deferred`, 31
> `duplicate`, 30 `not-a-defect`, 19 `documented`, 2 `in-progress`, and 0
> `pending`.

## Reports in this directory

| File | Module | Critical | Major | Minor | Nit | Total | Status |
|---|---|---|---|---|---|---|---|
| `01-historycore.md` | HistoryCore (public surface) | 0 | 0 | 9 | 11 | 20 | ✅ final |
| `02-historydomain.md` | HistoryDomain (planners, facts, invariants) | 0 | 2 | 19 | 12 | 33 | ✅ final |
| `03a-codecs.md` | HistoryStorage codecs + schema | 0 | 2 | 15 | 12 | 29 | ✅ final |
| `03b-authority-kernel.md` | HistoryAuthority commit kernel | 0 | 1 | 18 | 19 | 38 | ✅ final |
| `03c-search-reads-observation.md` | Search, reads, observation, fact loaders | **1** | 8 | 21 | 7 | 37 | ✅ final |
| `03d-index-ingest-thumbnail-facade.md` | Signature index, ingest, thumbnail, facade | **1** | 0 | 11 | 18 | 30 | ✅ final |
| `04-perf-deps-stubs.md` | Perf runner, xxh3, Fuse, stubs | **1** | 1 | 19 | 14 | 35 | ✅ final |
| `05-cross-cutting.md` | Security / API / tests / complexity / gates synthesis | — | — | — | — | — | ✅ synthesis |
| `06-remediation-plan.md` | Ordered remediation batches and completion evidence | — | — | — | — | — | ✅ complete |
| `07-finding-dispositions.md` | Canonical status ledger and completeness checksum | **3** | **14** | **112** | **93** | **222** | ✅ complete |
| **`00-verification-summary.md`** | **This file** | **3** | **14** | **112** | **93** | **222** | — |

*All seven modules completed the full 3-cycle (审查→调研→批评) verification; every headline finding was independently confirmed by the orchestrator against the source.*

## Executive verdict

**The architecture is sound and the code is unusually disciplined** — downward-only target graph, single-writer `HistoryAuthority` with an OCC position-guard that converts the scariest concurrency hazard (actor-reentrancy double-commit) into a *detected spurious rollback*, immutable-`Sendable`-only boundary crossings, exhaustive fail-closed blob codecs, Foundation-only public surface, checked arithmetic on all coherence tokens, and three layered source gates. The spec-to-code traceability is excellent. **There is no structural or architectural failure.**

**The baseline verification found 3 critical and 14 major defects**, plus
~200 minor/nit items. The supported remediation above closes every non-deferred
implementation/proof item. The three baseline criticals were:

1. **`fuse-bitap-crash-and-corruption`** (`SearchWorker.swift:577`) — a fuzzy query of **≥90 characters trapped the process** and 65–89 silently returned empty results. **Remediation: `fixed`** — all profiles cap fuzzy queries at 64 and WS17's complete boundary sweep is green in run 31449682036. *(03c)*
2. **`concealed-type-leak-flat-schema`** (`IngestPreparation.swift:172`) — password-manager content next to a concealed marker could be retained and surfaced. **Remediation: `fixed`** — pasteboard-level concealment, whole-capture rejection, six-marker coverage, no-hash/no-commit regressions, and the public-symbol snapshot are green in workflows 31448087991/31449682036. *(03d)*
3. **`wl8-currently-red-on-master-blocks-section9-acceptance`** (`.github/workflows/macos26-arm-ci.yml`) — the baseline proof measured Authority serialization rather than single-flight sharing. **Remediation: `fixed`** — WL8 measures the production `ThumbnailService` after one prefetch, retains an untimed facade smoke, and passes in the 13-workload release run 31449682036. *(04)*

The major WS18 continuation, projection-scalar, regexp-admission, search-term
envelope, and thumbnail failure-vocabulary remediation clusters are also
**fixed**. Their adversarial and persistent-store fixtures all pass in run
31449682036.

## The systemic root causes (fix these, and ~60% of the findings dissolve)

These six patterns recur across modules; addressing them is the highest-leverage work:

1. **`private` pure algorithms behind a facade-only test suite** — the structural reason *both* criticals (1) and (2's neighbor findings) shipped. The frozen pure helpers (regex guard, excerpt, UTF-16 translation, projector, planners, `SignatureIndex.apply` divergence paths, `IngestPreparation` rejection branches, `PageCursorCodec`) are `private`/`private static`, so the WS1-WS21 suite exercises them only indirectly through happy paths. **Fix:** elevate pure helpers to `internal` + add direct `@testable` suites. Force-multiplier for the whole audit. *(02, 03c, 03d, 03a)*
2. **A closed failure vocabulary (`§16 CapacityKind`) accumulating pressure** — one missing dimension (thumbnail-output; capture-representation/byte) causes 5+ misclassification findings (16 MiB thumbnail exceed → `.invariantViolation`; empty bytes → `.byteLimit`). **Fix:** amend `§16` once with the missing `CapacityKind` cases. *(03d, 03a)*
3. **Syntactic proxies for semantic properties** — the regex guard predicts ICU NFA backtracking from textual inspection (misses `(a|a)+`); the 256-char fuzzy bound is set without reference to the engine's bitap width. Both defenses are decoupled from the thing they protect. **Fix:** couple the bounds to the engine (64-char bitap limit) and add a cooperative watchdog for regex (requires `page()` to become `async`). *(03c)*
4. **Comment/spec/`PROGRESS.md` overclaims treated as contracts** — `SignatureIndex:104` "never drops a true candidate" (false under corruption), `ContentProjector:29` + spec §4 line 225 "decode re-verifies projection bounds" (no path does), `§7.1 step 6` "verify generation agrees" (generation never read), `PROGRESS.md:81` "D1-D19 delivered" (smoke-only), `IngestPreparation:68` "prevents password-manager retention" (it doesn't), observe "terminates because positions advance monotonically" (mathematically incomplete), `StepDeferredError` (dead). **Fix:** batch-correct the prose to match the code (or vice-versa). *(all modules)*
5. **The flat `ClipboardCapture` data model drops pasteboard-level context** — root cause of critical #2. The adapter boundary loses the item/concealed-marker context the filter needs. *(03d)*
6. **Inline-value memory tax with no spec owner** — content bytes in `Sendable` value DTOs / inline `String` columns (`searchBody` is inline, not `.externalStorage`) → multi-GiB materialization on the read path (`details()` hydrates ≤256 MiB; `searchCorpusSnapshot` materializes ≤1.22 GiB per query). G8's evidence gate names only the write path. *(01, 03a, 03b, 03c)*

## Complexity & efficiency — the highest-ROI reductions

- **`searchCorpusSnapshot` per-keystroke rebuild** (cross-module: 03a/03b/03c) — cache keyed by `ChangePosition`, invalidated on corpus-touching commits. *Single highest-leverage fix.*
- **`projection-joins-full-body-before-truncation`** (03c) — **fixed**:
  bounded streaming accumulation and the title-only revision path pass their
  direct regressions in run 31449682036.
- **`evictionOrdered` before `victimCount`** (02) — derive `victimCount` first, gate the sort.
- **`validateFinalPinOrder` per commit** (03b) — `pinOrdinal != nil` predicate (O(P)); gate on plan content.
- **`details()` summary-only hydrate + `projectTitleOnly`** (01, 03b) — skip non-active revision bytes + redundant `searchBody` projection.
- **Per-`Character` `String(char).utf16.count`** (03c) — iterate the `utf16` view once.
- **Batched `id IN (...)` fetches** for clear/retention and dedup candidates (03b).

## Test coverage — the dominant gap

At the audited baseline, every module's deepest finding cluster was **test
coverage of pure safety-critical paths**. Remediation added direct planner,
search/projector, Signature Index, ingest, cursor, codec, and Authority-guard
coverage; run 31449682036 passes 314 tests in 41 suites. The baseline analysis
remains useful provenance for why those suites were added. See
`05-cross-cutting.md §4`.

## Gates & CI

Strong and well-maintained (`import_gate`, `escape_hatch_scan`, `public_symbol_snapshot` — all with self-tests, CI strictness on warnings). Two gaps: (a) the gates are **line-based regex, not AST-based** (evadable via comments/strings; convention-backed); (b) the perf runner **cannot close the spec's own G2/G5 evidence gates** (in-memory, ≤1000 items, ~20-byte payloads, skips fsync), leaving every "deferred behind measured evidence" perf finding *unfalsifiable* and three platform assumptions (`.externalStorage` faulting, `ModelContext.transaction` durability, nil-coalescing `#Predicate` translatability) unverified — these gate ~12-18 severity ratings. **Extending the runner is a force-multiplier for the whole review.** See `05-cross-cutting.md §7`.

## Notable REFUTED (provenance — these are correct, do not re-flag)

- **"Non-suspending-interval-convention-only = silent corruption"** — REFUTED: the `executeCommitTransaction` position guard detects reentrancy double-commit as a spurious rollback. *(03b)*
- **HistoryCore `HistoryLimits.standard` force-unwrap traps** — REFUTED: the table values satisfy every guard; a spec-violating edit traps loudly at first access, which is the intended behavior. *(01)*
- **`transaction(_:)` needs a second `save()`** — REFUTED per Apple docs (closure success commits). *(AUDIT.md)*
- **Fuse 1.4.0 `maxPatternLength` enforces the 256-char bound** — REFUTED (it's a dead parameter); the worker self-enforces. *(AUDIT.md, 03c)* — note this is distinct from critical #1 (the bound is enforced *at 256*, but 256 itself is wrong for the 64-bit bitap).
- Several "step-1 totals include transient reps" / "thumbnail cancellation discards the payload" findings were corrected or refuted during the research phases — see each report's "Notable REFUTED" section.

## Prioritized recommendations (highest-ROI first)

1. **Lower `maximumFuzzyQueryCharacters` 256→64** + amend `03b §8` / `06 §2` + add a length-sweep regression test (incl. the ≥90 no-substring crash case). Kills critical #1. *(03c)*
2. **Fix the concealed-type leak at the `Capture.swift` seam** (pasteboard-level flag + drop-whole-capture). Kills critical #2. *(03d)*
3. **Rework `wl8`** to call `ThumbnailService.thumbnail` directly; decouple bullet-9 from the perf-proofs pass/fail until then. Kills critical #3. *(04)*
4. **Elevate pure helpers to `internal` + add direct `@testable` suites** (planners, search helpers, `SignatureIndex`, `IngestPreparation`, `PageCursorCodec`, `HistoryAuthority` guards). Would have caught criticals #1 and #2 pre-merge. *(all)*
5. **Amend `§16 CapacityKind`** with thumbnail-output + capture-representation/byte dimensions. Kills the 5-finding misclassification cluster. *(03d, 03a)*
6. **Fix the unpinned-continuation pagination bug** (head-group-contamination detection + WS18 regression test). The one correctness defect in the authority kernel. *(03b)*
7. **Add a `ChangePosition`-keyed `SearchCorpusSnapshot` cache.** Eliminates the per-keystroke ≤1.22 GiB rebuild. *(03a, 03b, 03c)*
8. **Batch-correct the comment/spec/PROGRESS overclaims** to match the code (or bring the code up to the prose). *(all)*
9. **Extend `HistoryPerfRunner`** to on-disk ≥1000-item ≥64 KiB-body fixtures with p95 + RSS + durable fsync — makes G2/G5 answerable and resolves the 3 platform assumptions. *(04, 03b)*
10. **The complexity-reduction cluster** (streaming projection truncation, `victimCount`-first gating, `validateFinalPinOrder` predicate, `details()` summary-only hydrate). *(02, 03b, 03c)*

## What was verified as sound (confidence areas)

- The **single-writer + OCC + non-suspending-interval** concurrency spine (position guard).
- The **four versioned blob codecs'** fail-closed decode discipline (envelope pre-check, checked arithmetic, exhaustive §4 checks, §16 mapping) — *for the blobs*.
- **`HistoryCore`'s** access-control discipline, `Sendable` derivation, checked-arithmetic tokens, Foundation-only purity.
- **`HistoryDomain`'s** pure-functional planners (D1-D19 hold under inspection; the gap is *proof*, not soundness).
- The **three source gates** and CI strictness.
- **xxHash v0.8.3** pin correctness and the deterministic forced-collision test double.
- The **deterministic concurrency harness** + transaction-injection seam (WS12/WS13/WS15/WS20 infrastructure).

---

*Master summary of `docs/V1-Verified/01–05`. All seven modules completed the full 3-cycle 审查→调研→批评 verification; every headline finding was independently confirmed by the orchestrator against the source (the pagination major at `HistoryAuthority.swift:2370`, the concealed-type critical at `IngestPreparation.swift:172`, and the Fuse bitap critical via Swift arithmetic semantics). The per-module reports are authoritative for detailed failure scenarios and recommendations; `07-finding-dispositions.md` is authoritative for canonical IDs and current status.*
