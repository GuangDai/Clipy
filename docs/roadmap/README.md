# Implementation Roadmap

> **Status:** design-consolidated, scaffold not started (see `../06-cross-cutting.md`
> §1 status boundary). This roadmap is a traceable map from the **design modules**
> (Part I §2 target graph) to **implementation work**, ordered by Part VI §5.
> Every module cross-links the spec sections that define it and, where applicable,
> the WS gates / Part VI proofs that bound it.
>
> Authored 2026-07-20; roadmap-critiqued and revised across multiple rounds (see
> `../AUDIT.md`). The design was audited CLEAN; this roadmap assumes that
> consolidated design and restates it for navigation only — it owns no new
> semantics except explicitly-marked build-ordering decisions.

## 1. How this roadmap is organized

- One file per design module. **7 docs cover all 8 Part I §2 targets**; `xxh3`
  and `Fuse` are co-documented together as dependencies in Module 7. (Part I §2
  lists both as separate target rows; Part VI §5 lists `xxh3` as a scaffold
  target but treats `Fuse` as an external SPM dependency, not a created target.)
- Each module file has the same shape: **Status · Spec references · Dependencies
  · Deliverables · Acceptance · Risks/notes · Test target · Step**.
- The implementation order (§3) mirrors Part VI §5, grouped into phases, and
  makes each module's dependencies available before it — including Module 07's
  `xxh3`+`Fuse`.

## 2. Module map (covers all 8 Part I §2 targets)

| # | Module | Spec owner | Roadmap doc | Depends on |
|---|---|---|---|---|
| 1 | `HistoryCore` | 03a + 03b (Part III) | [01-historycore.md](01-historycore.md) | Foundation |
| 2 | `HistoryDomain` | 02 (Part II) | [02-historydomain.md](02-historydomain.md) | HistoryCore |
| 3 | `HistoryStorage` | 04 + 05 (Part IV + V) | [03-historystorage.md](03-historystorage.md) | HistoryCore, HistoryDomain, xxh3, Fuse (SwiftData, ImageIO) |
| 4 | `PasteboardAdapter` | 01 §2/§4; 03a §4 | [04-pasteboardadapter.md](04-pasteboardadapter.md) | HistoryCore (AppKit) |
| 5 | `PresentationUI` | 01 §2 | [05-presentationui.md](05-presentationui.md) | HistoryCore (SwiftUI) |
| 6 | `ClipyApp` | 01 §2; 01 §5.6 | [06-clipyapp.md](06-clipyapp.md) | HistoryCore¹, HistoryStorage, PasteboardAdapter, PresentationUI |
| 7 | Dependencies (`xxh3` + `Fuse`) | 01 §2/§4 | [07-external-deps.md](07-external-deps.md) | external |

¹ The Part I §1 graph draws ClipyApp → {PresentationUI, PasteboardAdapter,
HistoryStorage}; the direct ClipyApp→HistoryCore edge (for `any ClipboardHistory`,
`PastePayload`, `HistoryAction`) is implied by type-reference imports and
is not drawn in the structural graph.

Test targets mirror each owner (`HistoryCoreTests`, `HistoryDomainTests`,
`HistoryStorageTests`, `PasteboardAdapterTests`, `PresentationUITests`,
`ClipyIntegrationTests`), per Part VI §5.

## 3. Implementation order (Part VI §5), grouped into phases

**Phases → Part VI states:**
- **Phase 0 — scaffold** (step 0): package + build/test gates. No Part VI state.
- **M1 — pure compile** (steps 1–2): HistoryCore, HistoryDomain. No WS gates; symbol-surface + invariant tests only.
- **M2 — executable specification** (steps 3–8): deps (xxh3+Fuse) → schema → Authority → mutations → reads → thumbnail. **Closes state 2** when WS1–WS21 + Part VI §6/§7/§9 pass via direct `SwiftDataHistory` invocation AND the concurrency harness (step 5) is delivered AND the §9 release-like runner is provisioned (scaffolded step 0, fixtures by step 8).
- **M3 — product wiring** (step 9): Pasteboard/UI/App; re-runs WS1–WS21 end-to-end through the composed app (this is M3 re-verification, not a state-2 requirement).
- **State 3 (product complete)** is separate acceptance outside this roadmap (Part VI §11).

**Steps** (module owner in bold):

0. **scaffold (cross-cutting).** Create the SwiftPM package declaring the Part I §1 target graph as **placeholder/stub targets** — 7 production targets (6 SwiftPM libraries + ClipyApp via XcodeGen) + 6 test targets (Part VI §5). HistoryStorage is declared **without** its Fuse target-dependency edge (Fuse is an external SPM package that resolves only once pinned at step 3); `xxh3` is declared with placeholder source (real C/ObjC++ content lands at step 3). Add XcodeGen `project.yml` (Part I §9 item 6), SwiftLint/import-gate config (Part I §8), the public-symbol-no-leak snapshot harness, the no-`@unchecked Sendable` / `nonisolated(unsafe)` / no-service-locator source scan, **and the deterministic concurrency test harness scaffold** (required by WS12/13/15/20; its transaction-injection seam is finished inside `HistoryAuthority` at step 5), **and provision the Part VI §9 performance-runner scaffold** (release-like runner + recorded-fixture/machine-metadata capture; fixtures populate as HistoryStorage matures, §9 closes at step 8). `ClipyIntegrationTests` is an XcodeGen-hosted target (it exercises the composed app); the other five test targets are SwiftPM-owned. This step owns the Part VI §6 graph-level proofs: whole-graph Swift 6 build, per-target framework import confinement, all-targets public-symbol snapshot, and the global escape-hatch scan.
1. **Module 1 — HistoryCore:** compile public values + protocol; lock the symbol surface (Part VI §6).
2. **Module 2 — HistoryDomain:** compile pure values, facts, planners; invariant tests (D1–D19).
3. **Module 7 — integrate xxh3 + Fuse:** pin exact resolved revisions; swap the real C/ObjC++ source into the `xxh3` placeholder target; pin the Fuse 1.4.x SPM revision and **add the deferred HistoryStorage→Fuse package-dependency edge**; add the package-only deterministic xxh3 collision double. Both are then resolvable. **xxh3 is first used at step 5** (`IngestPreparationActor`, 05 §6.1); **Fuse is first used at step 7** (the full `SearchWorker` implementation for WS17 — the step-5 `SearchWorker` is a stub with no Fuse field). *(Incremental convention: step 0 declares HistoryStorage without the Fuse edge and xxh3 with placeholder source, so step 4's schema/codec code imports neither; step 3 pins real revisions and adds the Fuse edge; xxh3 is first imported at step 5, Fuse at step 7.)*
4. **Module 3 — HistoryStorage (schema + codecs):** round trips + corruption rejection (Part VI §7.3, §7.4).
5. **Module 3 — HistoryStorage (Authority + capture):** Authority open, position singleton, Signature Index rebuild, capture insert/coalesce, **and finish the concurrency harness + transaction-injection seam** (test infra for WS12/13/15/20). Gates: **WS1–WS3, WS5, WS19**; proofs §7.1, §7.6.
6. **Module 3 — HistoryStorage (mutations):** pin order, revision, remove/clear, retention. Gates: **WS6–WS10, WS13, WS14, WS16, WS20, WS21**.
7. **Module 3 — HistoryStorage (reads + observation):** purpose-specific reads + observation. Gates: **WS4, WS11, WS12, WS17, WS18**; proofs §7.2, §7.5. *(Closes the deferred public-read / observation / no-emission clauses of WS1, WS5, WS6, WS7, WS8, WS9, WS10, WS13, WS14, WS16, WS19.)*
8. **Module 3 — HistoryStorage (thumbnail):** single-flight. Gate: **WS15**.
9a. **Modules 4 + 5 — PasteboardAdapter + PresentationUI** (Core-only leaf siblings; parallelizable).
9b. **Module 6 — ClipyApp:** composition root; **re-run WS1–WS21 end-to-end** through the composed app (`ClipyIntegrationTests`) — M3 re-verification, not a state-2 requirement.

> **WS-clause phasing.** Steps 5–6 close the **commit/receipt/storage side** of
> their WS gates. Several also carry **public-read / observation / no-emission
> clauses** checkable only at step 7 (reads + observation): e.g. WS1 observed
> page, WS2 occurrence-count/no-second-row, WS5 no-row/no-position/no-invalidation,
> WS6/WS8/WS9/WS10/WS14/WS16/WS19/WS21 public reads, WS7/WS13 no-observation-emission.
> (WS4 is a step-7 gate in full — paste payload. WS2 has no observed-PAGE clause
> specifically — only WS1 does — but its other read clauses still defer to step 7.) A gate is "fully passed" only when
> its last clause's dependencies are in. **State 2 closes at step 8**: all
> WS1–WS21 pass via direct `SwiftDataHistory` invocation (reads at step 7, the
> concurrency harness delivered at step 5). Step 9b re-runs the suite through
> the composed `ClipyApp` as M3 end-to-end re-verification — it is not a
> state-2 requirement.

This order mirrors Part VI §5. The additions over §5 are the explicit scaffold
(step 0, which §5 implies via "compile" but does not list), the explicit xxh3+
Fuse integration (step 3), and the concurrency harness (scaffolded step 0,
finished step 5) — all required for the gates to be runnable in order.

## 4. Traceability model

Every implementation task cites in its PR/commit: the roadmap module doc, the
spec section, the WS gate or Part VI proof, and (if behavior changes) a
`../AUDIT.md` §3 entry. Primary-owner spec edits trace forward via the §2 map;
**cross-cutting spec edits** (e.g. 06 §2, 01 §6, 01 §8, 06 §6) require a grep
across module docs to find every affected owner. The design → roadmap → code
chain is reversible: any code traces back to a spec section and a WS gate; any
spec edit traces forward to its module(s).

## 5. Completion gating (from Part VI)

- **Design consolidated** ✅ (Parts 00–06 + this roadmap; AUDIT.md CLEAN).
- **Executable specification** ⛔ pending — Part VI §6 (compile/dependency) +
  §7 (schema/platform) + §9 (performance) + WS1–WS21 on the supported macOS runner,
  with the concurrency harness + transaction-injection seam delivered (step 5).
- **Product implementation complete** ⛔ pending — UI, pasteboard, packaging,
  accessibility, localization, product tests.

Per Part VI §11, final **state-3 acceptance** (packaging/accessibility/
localization/product tests) requires separate acceptance tests outside this
roadmap; the module docs below own states 1–2 only. Do not advance a module past
`done` until its Acceptance gates pass on the greenfield scaffold (Part VI §9:
no latency claim satisfied by the current Maccy repo counts).
