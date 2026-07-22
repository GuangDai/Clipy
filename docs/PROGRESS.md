# Implementation Progress

> **Status:** living record; one section per landed roadmap step, newest last.
> Maps each step of `roadmap/README.md` §3 to its commits and its CI evidence
> on the `macOS 26 ARM CI` workflow (github.com/GuangDai/Clipy; macos-26 arm64
> runners; jobs *Lint + source gates*, *SwiftPM build + test*, *XcodeGen
> generate + app build/test*). Run IDs cite
> `github.com/GuangDai/Clipy/actions/runs/<id>`.
>
> This file records progress only. Deliverable definitions and acceptance
> criteria live in the design modules (`00`–`06`) and the roadmap module docs;
> they are cited here, never restated as new semantics.

**Current HEAD:** `7994844` — run 29964640300, all three jobs green
(2026-07-22). Steps 0–5 landed; steps 6–9b not started. Phase position
(`roadmap/README.md` §3): M1 (pure compile) complete; M2 (executable
specification) in progress.

## Step 0 — scaffold (cross-cutting)

- **Status:** done. No green run on its own HEAD; the scaffold tree is first
  proven green as part of run 29904895327 (`4d0693b`).
- **Roadmap:** `roadmap/README.md` §3 step 0 (Part VI §5/§6).
- **Delivered:** SwiftPM package declaring the Part I §1 target graph as stub
  targets — 7 production targets (6 SwiftPM libraries + ClipyApp via XcodeGen)
  + 6 test targets (Part VI §5); HistoryStorage declared **without** its Fuse
  edge (resolves only once pinned at step 3); `xxh3` declared with placeholder
  source. XcodeGen `project.yml` (Part I §9 item 6), SwiftLint + import-gate
  config (Part I §8), the public-symbol no-leak snapshot harness, the
  escape-hatch source scan (no `@unchecked Sendable` / `nonisolated(unsafe)` /
  service locator / second writer), the deterministic concurrency-harness
  scaffold (finished inside `HistoryAuthority` at step 5), and the Part VI §9
  performance-runner scaffold (`HistoryPerfRunner`; fixtures populate by
  step 8). Owns the Part VI §6 graph-level proofs.

| Commit | Subject |
|---|---|
| `39abe5d` | Step 0 scaffold: SwiftPM target graph, source gates, XcodeGen app, macOS 26 ARM CI |

- **CI:** push run 29883775992 failed at workflow level before any job ran
  (env wiring; logs expired) — fixed by `e07a34a` (XCODEGEN_HOME moved to step
  env, carried under step 1 below).

## Step 1 — HistoryCore public surface

- **Status:** done. Public symbol surface snapshot-locked and gate-enforced;
  tree first fully green at run 29904895327 (`4d0693b`).
- **Roadmap:** `roadmap/01-historycore.md` (03a §2–§7, 03b §8–§10, 06 §2).
- **Delivered:** the complete public, Foundation-only caller interface —
  `ClipboardHistory` protocol (03a §3); identity/coherence tokens with
  package-only minters (03a §2); raw capture seam (03a §4); closed action set
  (03a §5); receipts (03a §6); browse/search requests (03a §7); read DTOs
  (03b §8–§9); typed failures (03b §10); `HistoryLimits.standard` (06 §2).
  Acceptance per Part VI §6: Foundation-only compile under Swift 6 complete
  strict concurrency; public surface snapshot-tested with package-only members
  excluded; forbidden-import scan live.

| Commit | Subject |
|---|---|
| `4e3e4fd` | Step 1: HistoryCore public surface (03a §2–§7, 03b §8–§10, 06 §2) |
| `e07a34a` | CI: move XCODEGEN_HOME to step env |
| `6b50d2e` | Fix symbol snapshot: pass macOS SDK to symbolgraph-extract |
| `1cf1715` | Update HistoryCore public symbol snapshot (bot, workflow symbol-snapshot.yml) |

- **CI:** `4e3e4fd` red at gates (29885917488) — symbolgraph-extract needed the
  macOS SDK passed explicitly; `6b50d2e` fixed the extraction, but its gates
  run (29886032388) still failed against the stale expected snapshot (one
  SDK-dependent symbol drifted: `HistoryFailure.snapshotExpired(current:)`);
  the dispatch-only updater workflow regenerated it (run 29886032578) and
  bot-committed `1cf1715`. Lesson: snapshot content is runner-derived, so
  regeneration is a workflow, not a local edit.

## Step 2 — HistoryDomain pure functional core

- **Status:** done. Green inside run 29904895327 (`4d0693b`).
- **Roadmap:** `roadmap/02-historydomain.md` (02 §2–§11).
- **Delivered:** pure content/lineage values with validating `CanonicalContent`
  init and `effectiveContent(of:)` (02 §2); retained state incl. `PinOrdinal`
  (§3); prepared-input types, minting left to Storage (§4); action-specific
  complete facts + `DomainRejection` (§5–§6); strong mutation plan (§7); the
  seven pure planners (§8); `canonicalContains` (§9.2); D1–D19 invariant tests
  (§14), incl. planner determinism (D16). No I/O, actor, clock, UUID/Date
  generation, or async (02 §1).

| Commit | Subject |
|---|---|
| `99dedab` | Step 2: HistoryDomain pure functional core (02 §2–§11) |

- **CI:** `99dedab` red (29897159060), both failures outside Domain code:
  `generate-xcodeproj.sh` resolved the xcodegen binary at the wrong path (the
  release zip nests a `xcodegen/` dir), and the SPM log self-scan flagged an
  unhandled-file warning (`SymbolSurface/` under HistoryCoreTests) — both fixed
  inside step-3 commit `5446780` (binary path + target `exclude`).

## Step 3 — dependencies: xxh3 + Fuse pins

- **Status:** done. Green inside run 29904895327 (`4d0693b`).
- **Roadmap:** `roadmap/07-external-deps.md` (01 §2/§4; 02 §2.2; 03b §8).
- **Delivered:** real XXH3-64 vendored at xxHash v0.8.3 behind
  `clipy_xxh3_64bits`, pin recorded in `Sources/xxh3/VENDORED.md`; package-only
  deterministic forced-collision fingerprint double for Storage tests (created
  here, first exercised at step 5 in the §7.6 proof). Fuse pinned at the exact
  1.4.0 tag commit — not the 2.0.0-rc.x pre-release (AUDIT §4b) — the deferred
  HistoryStorage→Fuse edge added, Fuse confined to HistoryStorage in the import
  gate and SwiftLint. Neither dependency appears in a public signature (01 §8).
  Also carried two scaffold fixes (xcodegen binary path, `SymbolSurface`
  exclude).

| Commit | Subject |
|---|---|
| `5446780` | Step 3: pin xxh3 (vendored xxHash v0.8.3) + Fuse (1.4.0 revision pin) |

- **CI:** `5446780` red (29898452747) — app job only: XcodeGen inferred
  `TEST_HOST` from the target name (`ClipyApp`) while `PRODUCT_NAME` is
  `Clipy`, so ClipyIntegrationTests had no test host; fixed inside step-4
  commit `39038b3` by an explicit `TEST_HOST` in `project.yml`.

## Step 4 — HistoryStorage: schema v1 + versioned codecs

- **Status:** done. Closes at run 29904895327 (`4d0693b`), the first fully
  green run — all three jobs; §7.3/§7.4 proofs pass on the runner.
- **Roadmap:** `roadmap/03-historystorage.md` step 4 (Part V §3–§4).
- **Delivered:** `HistoryItemRow` / `LastChangePositionRow` `@Model`s +
  `v1Schema`, `.externalStorage` on the two big blobs (Part V §3); the four V1
  codecs (`CanonicalBlobV1`, `SignatureBlobV1`,
  `EffectiveTypeIdentifiersBlobV1`, `RevisionStateBlobV1`) with exhaustive §4
  decode checks failing closed; `CodecRejection` → §16 persistence-failure
  mapping; proofs §7.3 (round trips) and §7.4 (corruption rejection per check).

| Commit | Subject |
|---|---|
| `39038b3` | Step 4: SwiftData schema v1 + versioned codecs (05 §3–§4) |
| `f0b0651` | Fix Schema.swift: add missing import Foundation |
| `8b5ce2f` | Fix duplicate top-level test symbols: wrap codec tests in suite structs |
| `6ba9cd3` | Fix suite-struct constants: static lets usable as default parameters |
| `52a7bb0` | Qualify static fixture constants with Self. in instance methods |
| `4d0693b` | CI: exclude benign AppIntents metadata-processor noise from app log scan |

- **CI:** `39038b3` red (29903340536) — `Schema.swift` missed
  `import Foundation` (`UUID`/`Data`/`Date` out of scope), breaking both
  builds; `f0b0651`. Then a test-compile chain, one red run each: duplicate
  top-level codec-test symbols (29904064092) → suite structs `8b5ce2f`; static
  lets illegal as default parameters (29904331101) → `6ba9cd3`; `Self.`
  qualification in instance methods (29904609707) → `52a7bb0`. The app-job log
  self-scan then failed on benign AppIntents metadata-processor noise →
  excluded by `4d0693b` (green, 29904895327).

## Step 5 — HistoryStorage: Authority + capture path

- **Status:** done. HEAD `7994844` green at run 29964640300 — all three jobs.
  Gates WS1–WS3/WS5/WS19 pass on the commit/storage side (public-read /
  observation / no-emission clauses defer to step 7 per `roadmap/README.md` §3
  WS-clause phasing); proofs §7.1 (transaction boundary) and §7.6 (forced
  collision) pass on the runner.
- **Roadmap:** `roadmap/03-historystorage.md` step 5 (Part V §2, §5–§13).
- **Delivered:** `HistoryAuthority` sole writer — open, position singleton,
  Signature Index lifecycle + startup rebuild, capture insert/coalesce with
  complete fact loading and mechanical Domain→Stamped stamping,
  `ModelContext.transaction` as the sole commit primitive (Part V §2, §5–§13);
  `IngestPreparationActor` (first xxh3 use, §6.1); `SwiftDataHistory` facade
  constructing all five actor fields, with stub actors pinning the step 6–8
  signatures; the deterministic concurrency harness + transaction-injection
  seam finished (test infra for WS12/13/15/20).

| Commit | Subject |
|---|---|
| `66a8b14` | Step 5 (impl): HistoryAuthority + capture path (05 §2,§5–§13) |
| `81dbba9` | Fix SignatureIndex: qualify static checkEntryList with Self. |
| `11bc1f7` | Fix harness: @escaping operation closures captured by Task |
| `51962db` | Step 5 (tests): WS1-WS3/WS5/WS19 + §7.1/§7.6 proofs |
| `bb1bced` | Create WS temp store dirs upfront to silence CoreData file-status noise |
| `7994844` | WS5: make .dedupIndexRebuild reachable — readiness resolution before inventory |

- **CI:** `66a8b14` red (29954745098, both build jobs) — two compile errors,
  one fix each: `SignatureIndex.checkEntryList` `Self.` qualification
  (`81dbba9`); harness operation closures captured by `Task` needing
  `@escaping` (`11bc1f7`, surfacing at *Run package tests* on 29955084433;
  first step-5 green 29955373629). `51962db` red (29964042154) — SPM log
  self-scan flagged CoreData file-status noise from WS temp-store creation;
  `bb1bced` creates the dirs upfront (green 29964233482). `7994844` fixed the
  WS5 producer path (see below) — green 29964640300.

## Notable decisions & deviations

- **WS5 `.dedupIndexRebuild` producer fix (`7994844`).** An earlier `loadFacts`
  ran the §7.1-step-5 inventory load before the step-1 readiness resolution, so
  an over-bound retained store was rejected as
  `.persistence(.invariantViolation)` and the `.dedupIndexRebuild` mapping was
  unreachable. The loader now resolves Signature Index readiness first against
  an id-only scalar fetch; an over-bound retained set always forces the rebuild
  path, whose bound check produces `.temporarilyUnavailable(.dedupIndexRebuild)`
  (06 §8 WS5, 05 §16, 02 §5.1). Recorded in
  `Tests/HistoryStorageTests/WS5DedupIndexUnavailableTests.swift`.
- **Transient `StepDeferredError` for steps 6–8 paths.** Step-5 stub actors and
  the not-yet-implemented `HistoryAuthority` methods throw internal
  `StepDeferredError.notYetImplemented` — deliberately NOT a `HistoryFailure`,
  never translated into one, propagating through the `SwiftDataHistory` facade
  unchanged so a not-yet-implemented path fails loud and distinct rather than
  misclassified as a public failure. Removed when steps 6–8 land
  (`Sources/HistoryStorage/SwiftDataHistory.swift`, `ActorStubs.swift`,
  `HistoryAuthority.swift`).
- **Symbol-snapshot updater workflow.** `.github/workflows/symbol-snapshot.yml`
  is `workflow_dispatch`-only, runs on macos-26, and commits the regenerated
  HistoryCore public-symbol snapshot as the bot (`contents: write`) — it
  produced `1cf1715`. Bot pushes do not trigger the macOS CI workflow, so
  `1cf1715` has no CI run of its own; the snapshot is enforced by the gates job
  on every subsequent push.
- **Dependency pins.** xxHash is vendored at v0.8.3 (`Sources/xxh3/VENDORED.md`
  records the pin) with a package-only forced-collision double for Storage
  tests; Fuse is pinned at the exact 1.4.0 tag commit (the 2.0.0-rc.x
  pre-release is deliberately not used — AUDIT §4b). `maxPatternLength` is a
  dead parameter in Fuse 1.4.0, so the 256-character fuzzy-query bound is
  enforced by `SearchWorker` itself at step 7 (03b §8).
- **Open spec question for step 6 — pin-ordinal compaction on remove (flagged
  by review agent-30).** `planRemove` (02 §8) emits a single
  `.retire(itemID:, .userRemoval)`; `RemoveFacts` (02 §5.4) carries only the
  target summary — no pinned order — so the planner cannot emit `.assignPin`
  ordinal shifts, and removing a pinned item may leave a gap in the pin-ordinal
  sequence. Whether compaction is required, and who emits it, must be resolved
  against Part V §9 (the Domain→Stamped stamping rules) when `commitRemove` is
  implemented at step 6.
