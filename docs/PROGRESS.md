# Implementation Progress

> **Status:** living record; one section per landed roadmap step, newest last.
> Maps each step of `roadmap/README.md` §3 to its commits and its CI evidence
> on the `macOS 26 ARM CI` workflow (github.com/GuangDai/Clipy; macos-26 arm64
> runners; jobs *SwiftPM build + test* and *XcodeGen generate + app
> build/test*). Run IDs cite
> `github.com/GuangDai/Clipy/actions/runs/<id>`.
>
> This file records progress only. Deliverable definitions and acceptance
> criteria live in the design modules (`00`–`06`) and the roadmap module docs;
> they are cited here, never restated as new semantics.

**Audit baseline:** `8f316c9` (2026-08-02). **Current landed baseline:**
`master` through [PR #40](https://github.com/GuangDai/Clipy/pull/40) / merge
`c89f2ba` (2026-08-24). Steps 0–9 are
implemented and CI-green;
M2/state 2 is complete. Step 9 (product wiring: PasteboardAdapter +
PresentationUI + ClipyApp composition) is done, including its post-step-9
revisions: the perf/AB measurement-helper proofs live in the split
`HistoryPerfTests` target, and the browsing surface is a Maccy-style
AppDelegate-owned floating `NSPanel` (Carbon ⇧⌘C summon,
cursor/status-item/center/last-position placement, dwell-driven preview pane)
rather than a SwiftUI `MenuBarExtra`. M3/state 3 (packaging, accessibility,
localization, product acceptance per Part VI §11) remains open.

**Current CI provenance (2026-08-24):** the PR #40 merge head `c89f2ba` was
green across the then-current source-gate, SwiftPM, and XcodeGen jobs at
[run 32699272489](https://github.com/GuangDai/Clipy/actions/runs/32699272489).
PR #34 restores the manual-only exact/scale evidence caller and scale-phase
liveness contract. Its final PR run
[32684566664](https://github.com/GuangDai/Clipy/actions/runs/32684566664) and
master push run
[32684916238](https://github.com/GuangDai/Clipy/actions/runs/32684916238)
passed all three correctness jobs. Manual run 32685185124 attempt 1 was blocked
by the known `HistoryViewStateTests` runner slow-window cluster; attempt 2's
same-SHA correctness is green, Exact A/B is green with
`productionIntegrationEligible == true` and all 13 cases passing, and the
5,000-row scale sibling is green across preparation, tie-heavy browse, Debug
exact probe, Release exact search, and independent-process warm open.
The Exact A/B lane above did run; the separate performance-helper/proof lane did not,
and the scale artifact remains record-only rather than a budget admission. The
earlier PR #20 ordinary ad-hoc Release artifact passed the finite
Card 5D symbol inventory at
[release-surface run 32619756885](https://github.com/GuangDai/Clipy/actions/runs/32619756885).
That dispatch proves zero matches for the 26 reviewed demangled literals in
that exact PR #20 artifact, not a complete instrumentation or
distribution/runtime audit. The latest signed UDS discriminator evidence
remains bounded to run
[32615713100](https://github.com/GuangDai/Clipy/actions/runs/32615713100).
Neither ordinary correctness nor that retired finite-symbol run proves production
Data Protection Keychain persistence/reopen/delete or authenticated ingress,
Developer ID identity, secure timestamp, notarization/stapling, Gatekeeper,
App Sandbox, Keychain sharing, different-EUID callers, TCC, fresh login-item,
Carbon/status-item, Space, WindowServer behavior, or true Siri/Shortcuts
discovery and cold/warm invocation.

**CI provenance of the landed head (2026-08-20):** the post-step-9
convergence ran `a028c8c` (run 32316689047, cancelled —
`PreviewContent.textCharacterCap` access level), `9c6e3b4` (run 32317009871,
cancelled — `NSApplication.alertWindow` compile failure plus five
dwell-test failures), `9a637a6c` (run 32317628976, FAILED — XcodeGen app
build/test leg), and `d35f3b9` (run 32318520597, FAILED — app test
failures), closing at `cc59aa8` with green run
[32319164667](https://github.com/GuangDai/Clipy/actions/runs/32319164667)
(Lint + source gates, SwiftPM build + test, XcodeGen generate + app
build/test, SwiftPM perf/AB helper tests, Perf proofs §9 all green; the two
dispatch-only admission lanes are out of the per-push scope).

**Historical state-2 evidence (2026-08-11, `2fb7845`):** public-symbol
workflow
[31448087991](https://github.com/GuangDai/Clipy/actions/runs/31448087991)
is green. The state-2 code-head run
[31449682036](https://github.com/GuangDai/Clipy/actions/runs/31449682036)
passed all source/lint gates, Swift 6 strict-concurrency builds, 314 tests in 41
suites, generated-app build/test, all 13 release workloads, and the workflow's
diagnostic self-scans. No unexcluded warning/error diagnostic remained; the
narrow AppIntents-metadata and headless `com.apple.linkd.autoShortcut`
exclusions remain documented in the workflow history below.

**State-2 declaration, current tree (2026-08-15, `dfb08f2`):** the M2/state-2
declaration above is re-affirmed for the post-closure complexity-pass head.
At `dfb08f2` the package carries 384 `@Test` functions in 49 suite structs
(HistoryDomain: 52 tests across 7 files, including `ComplexityBoundaryTests`);
the supported full-scope run
[31815028830](https://github.com/GuangDai/Clipy/actions/runs/31815028830)
is green end to end including the evidence lane. The by-number D1–D19
evidence reconciliation (the V2-0 deliverable named by
`docs/v2/V2-roadmap.md` §2) is recorded in `docs/v2/V2-PROGRESS.md` §1.1.

## Step 0 — scaffold (cross-cutting)

- **Status:** done. No green run on its own HEAD; the scaffold tree is first
  proven green as part of run 29904895327 (`4d0693b`).
- **Roadmap:** `roadmap/README.md` §3 step 0 (Part VI §5/§6).
- **Delivered:** SwiftPM package declaring the Part I §1 target graph as stub
  targets — 7 product/library targets (6 SwiftPM libraries + ClipyApp via
  XcodeGen), the non-product `HistoryPerfRunner` executable, and 6 initial test
  targets (Part VI §5; `HistoryPerfRunnerTests` is added by the V1 verification
  remediation); HistoryStorage declared **without** its Fuse
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
  seven pure planners (§8); and `canonicalContains` (§9.2). The remediation
  tree adds a 47-test direct Domain suite across all seven planners and records
  the D1–D19 ownership matrix, including Storage-owned stamping and structural
fact/Sendable proofs. The 47-test direct suite is green in run 31449682036,
closing the D1–D19 M2 acceptance item. The post-closure complexity pass grew
it to 52 tests across 7 files at the current head (adding
`ComplexityBoundaryTests` and a fourth retention-selector ordering fixture,
then splitting two files); the by-number evidence map is recorded in
`docs/v2/V2-PROGRESS.md` §1.1. No I/O, actor, clock, UUID/Date
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

## Step 6 — HistoryStorage: mutations

- **Status:** done. HEAD `9c6801a` green at run 30724821449 — all three jobs.
  Gates WS6–WS10, WS13, WS14, WS16, WS20, WS21 pass on the commit/storage
  side (public-read / observation / no-emission clauses defer to step 7 per
  `roadmap/README.md` §3 WS-clause phasing).
- **Roadmap:** `roadmap/03-historystorage.md` step 6 (Part V §6.2,
  §7.2–§7.3, §8–§11; Part II §8, §10–§12).
- **Delivered:** the five mutation fact loaders (`MutationFactLoaders` —
  complete pinned order, pin, revision, remove, clear, retention; Part V
  §7.2–§7.3); the seven step-6 `HistoryAuthority` methods — pin placement,
  unpin, remove, clear, retention-policy commits plus the §6.2 two-phase
  revision (`revisionPreparationSnapshot` + `commitRevision`) — all on the
  capture path's fact-load/plan/stamp/transaction/post-commit spine, sharing
  the extracted `executeStampedPlan` tail (Part V §9–§11); the real
  `RevisionPreparationActor` (03a §5 decision resolution, Part VI hard-limit
  validation with checked arithmetic, Revision-ID/timestamp minting, §15
  projection); the WS20 `.revisionCommitEntry` suspension point; and the
  IMP6-01 spec amendment — `RemoveFacts` carries the proven pinned order so
  removing a pinned item compacts the lane in the same commit (02 §5.4/§10,
  05 §7.3, AUDIT §3).

| Commit | Subject |
|---|---|
| `315e6e0` | IMP6-01: pin-ordinal compaction on remove — RemoveFacts carries pinned order (02 §5.4/§10, 05 §7.3) |
| `888a290` | Step 6 (impl): mutation commits — pin/unpin/remove/clear/retention + two-phase revision (05 §6.2/§7.2–§7.3/§9–§11, 02 §8) |
| `47d4398` | Step 6 (tests): WS6-WS10, WS13, WS14, WS16, WS20, WS21 gates (06 §8) |
| `9c6801a` | CI: exclude benign LaunchServices autoShortcut noise from app log scan |

- **CI:** `315e6e0` green (30550057801); `888a290` green (30554426902);
  `47d4398` red at the app job only (30724705323) — its log self-scan matched
  intermittent LaunchServices "com.apple.linkd.autoShortcut" connection noise
  from the headless test-host app (same class as the AppIntents exclusion);
  excluded by `9c6801a` (green, 30724821449). The SwiftPM job carrying all
  ten new WS suites was green on its first attempt.

## Step 7 — HistoryStorage: reads + observation

- **Status:** done. Gates WS4, WS11, WS12, WS17, WS18 pass; the deferred
  public-read / observation / no-emission clauses of WS1–WS21 close in
  `WSReadClosureATests.swift` / `WSReadClauseClosureBTests.swift`; proofs §7.2
  (fresh-context visibility — second BLOCKER retired) and §7.5 (scalar read
  isolation) pass on the runner. Green at run 30731659350 alongside step 8
  (see the CI narrative below — the step's gates were finalized by two
  follow-up fix commits).
- **Roadmap:** `roadmap/03-historystorage.md` step 7 (Part V §14; Part IV
  §1–§7; Part III-B §8–§9).
- **Delivered:** `recentPage` (scalar two-lane fetch, pinned ordinal then
  recency/ID, store-level continuation anchors with a boundary-tie exactness
  guard; Part V §14.1); the versioned `PageCursorCodec` (04 §6: query shape +
  position + ordering anchor + process marker, manual Codable wire forms
  because HistoryCore identity types are deliberately not `Codable`);
  `searchCorpusSnapshot` (§14.2, scalar corpus in default order) + the real
  `SearchWorker` — exact / fuzzy (Fuse 1.4.0, pinned-first, self-enforced
  64-Character query bound) / regexp (conservative unsafe-pattern guards)
  with UTF-16 matched ranges and the frozen body-excerpt algorithm (03b §8);
  `details` / `pastePayload` (§14.3); the `observe` subscribe-before-query
  loop with the position-recheck discard path and `bufferingNewest(1)`
  coalescing (04 §5); `currentPosition` plus the WS12 `.readEntry` /
  `.positionRecheckEntry` suspension points.

| Commit | Subject |
|---|---|
| `d8fd950` | Step 7 (impl): reads + observation — recentPage/cursor codec, SearchWorker+Fuse, details/paste, observe loop (05 §14, 04 §5–§7, 03b §8–§9) |
| `c2c0580` | Fix data-race error: bind row scalars before mapCodecFailure closures (searchCorpusSnapshot) |
| `963b90d` | Step 7: facade actor fields private→internal for the WS12/WS15 harness (05 §2 deviation) |
| `59444d9` | Step 7 (tests): WS4/WS11/WS12/WS17/WS18 + deferred read clauses + §7.2/§7.5 proofs (06 §8/§7) |
| `72fa778` | Fix step-7 test compile errors: .search(text:mode:) case, missing awaits |
| `ff0706f` | Fix WS11 test: explicit Task closure return type HistoryPage? |
| `06f9761` | Fix recentPage continuation anchors (store-level lane bounds, WS18) |
| `4dbec39` | WS18: fetch limit+2 for unpinned continuations — anchor row consumes one slot |

- **CI:** `d8fd950` red (30729393154, both build jobs) — Swift 6 strict
  concurrency rejected capturing the non-Sendable `@Model` row in the
  actor-isolated `mapCodecFailure` closures of `searchCorpusSnapshot`;
  `c2c0580` binds the Sendable scalar values first (green, 30729512984).
  `59444d9` red (30730028403, SwiftPM job) — three test compile errors
  (`.search` bare case, two missing `await`s), fixed by `72fa778`; that run
  also surfaced a `Task` closure return-type inference failure in WS11,
  fixed by `ff0706f`. The next run (30730499770, carrying step-8 commits)
  had WS18's pagination gate catch a real step-7 defect: `recentPage`
  applied continuation anchors only in memory while the store fetch stayed
  `limit+1`, starving continuation pages — anchors moved to store-level lane
  bounds (`06f9761`), plus one anchor-slot depth fix (`4dbec39`, SwiftPM
  green 30731143421).

## Step 8 — HistoryStorage: thumbnail single-flight + §9 acceptance

- **Status:** done and accepted. Gate WS15 and all 13 §9 release workloads pass
  in run 31449682036. Historical runs `30731659350`/`30734778016` exposed the
  invalid WL8 construction; remediation now measures the production
  `ThumbnailService` from one prefetched source and retains the facade path as
  an untimed wiring smoke.
- **Roadmap:** `roadmap/03-historystorage.md` step 8 (Part IV §9; Part V
  §14.5; Part VI §9).
- **Delivered:** `HistoryAuthority.thumbnailSource` — dimension validation,
  one-item fetch, the Content-Version fence (`.staleContent` for an already
  stale reference; current bytes never returned under an old key),
  Effective-Content derivation, and the frozen v1 ImageIO-decodable type set
  (concrete UTIs, no abstract `public.image`) — one non-suspending interval
  (04 §9 steps 1–4, 05 §14.5); `ThumbnailService` single-flight table +
  owned `ThumbnailWorker` — join-or-create per exact key, ImageIO
  downsample + PNG re-encode off-Authority, 16 MiB output bound, flight
  entry removed on success/failure/cancellation, completed bytes never
  retained (04 §9 steps 5–7); the WS15 `.decodeEntry` suspension seam; and
  the §9 `HistoryPerfRunner` rewrite — 13 workload fixtures across the 9
  bullets (exact/fuzzy/regexp are distinct fixtures), median-of-5 timings
  against declarative complexity-envelope ratio checks (no numeric latency
  targets, §9), JSON fixtures + machine metadata uploaded as CI artifacts.

| Commit | Subject |
|---|---|
| `6902cbb` | Step 8 (impl): thumbnail single-flight — Authority source fence + ThumbnailService/Worker ImageIO decode (04 §9, 05 §14.5) |
| `60f4d5b` | Step 8: WS15 suspension seam on ThumbnailService (.decodeEntry) |
| `06f9761` | Fix recentPage continuation anchors + CFBoolean warning + WS15 gate |
| `4dbec39` | WS18: fetch limit+2 for unpinned continuations — anchor row consumes one slot |
| `c1bd259` | CI: unwrap-proof autoShortcut exclusion; §9 perf runner (workloads + perf-proofs job) |

- **CI:** `6902cbb` red (30730499770, both build jobs) — the app job's log
  self-scan caught two real warnings (`kCFBooleanTrue` IUO coerced to `Any`),
  fixed inside `06f9761`; the SwiftPM job caught the WS18 continuation-anchor
  starvation (see step 7) plus a `try?`-unused test warning. `06f9761` red
  (30730996351) — one anchor-slot depth bug (the date-bounded fetch includes
  the anchored row; it now fetches limit+2, `4dbec39`, SwiftPM green
  30731143421). `4dbec39` red at the app job — the autoShortcut exclusion
  missed line-WRAPPED variants of the noise; the exclusion now matches the
  service name anywhere in the line (`c1bd259`). Run 30731659350 was cancelled
  while the Perf job was still running and produced no §9 pass evidence. The
  audited baseline `8f316c9` is red at latest run `30734778016` only in `Perf
  proofs (§9)` because WL8 includes Authority serialization; the correctness
  jobs remain green. Remediation V1V-04-001
  isolates steps 5–7 of the production thumbnail pipeline after one prefetch;
  run 31449682036 proves the corrected construct green. V1V-04-002…04 additionally repair the
  runner's median/ratio/sample contracts, WL1b timed construct, versioned
  non-PII fixtures, structural §9 workload map, failure-log wording, dead
  helpers, and U+0130 Fuse range proof. V1V-04-005 adds the single declarative
  scales/growth/bound/headroom table plus direct CRC-32/xorshift32 KATs.
  `HistoryPerfRunnerTests` is present; run 31449682036 proves the package tests
  and all 13 release workloads green.

## V1 verification remediation — supported-runner closure (2026-08-11)

- **Status:** complete. Public-symbol workflow 31448087991 is green. Final
  code-head run 31449682036 passed every source/lint gate, 314 tests in 41
  suites, app build/test, all 13 release workloads, and the workflow's
  diagnostic self-scans. No unexcluded warning/error diagnostic remained; the
  narrow AppIntents-metadata and headless `com.apple.linkd.autoShortcut`
  exclusions remained in force. Earlier runs 31448531234 and 31449140919 exposed the
  Swift Testing inference and inverted-`ClosedRange` fixture failures; both
  repairs are included in, and proven by, the final run.

| Commit | Subject |
|---|---|
| `28e6335` | Close the audited v1 correctness, proof, API, performance-runner, and documentation gaps |
| `9d65dcb` | Regenerate the HistoryCore public-symbol snapshot (bot; workflow 31448087991) |
| `88641ad` | Fix WS18 scalar-row ordering access exposed by supported compilation |
| `1b72f68` | Fix Swift Testing page-count inference exposed by supported compilation |
| `2fb7845` | Validate six HistoryLimits endpoints before constructing ClosedRange values |

- **HistoryCore limits:** the package-only initializer receives range endpoints
  separately, validates positivity/order/containment, and constructs
  `ClosedRange` values only after those checks. This makes all three malformed
  range rejections genuine failable-initializer paths instead of pre-init
  runtime traps.
  `docs/V1-Verified/07-finding-dispositions.md` remains the authoritative
  222-ID status ledger. The post-closure overlay below supersedes that run's
  historical checksum; the current checksum is 111 fixed, 29 deferred, 31
  duplicate, 30 not-a-defect, 19 documented, 2 in-progress, and no pending
  rows.
- **Domain:** 47 direct tests (52 across 7 files at the current head) exercise
  all seven planners across commit/no-op, rejection, capacity, deterministic
  ordering, and complete mutation payloads; the suite records the exact
  D1–D19 ownership split, and the by-number map with its seam splits is
  recorded in `docs/v2/V2-PROGRESS.md` §1.1.
- **Authority/facts:** one-shot transaction injections now reach the position
  guard and all four concrete apply guards through normal APIs, proving typed
  failure plus row/position rollback. Capture reuses one duplicate-checked
  scalar inventory for retained-ID and retention facts on the healthy path;
  stale/unready state adds only the signature-metadata rebuild scan.
- **Search/observation:** direct regexp/parser tests cover nested/POSIX sets,
  ICU quoted literals, backreferences, alternation/quantifiers, and inline
  comments-mode rejection; direct UTF-16 tests cover supplementary and
  combining content. A deterministic worker-entry seam proves a commit during
  old-snapshot evaluation cannot become the subscriber's first visible page.
  The three-page search assertion now gives Swift Testing explicitly typed
  page-count operands after run 31448531234 rejected its array literals as
  ambiguous; it passes in run 31449682036.
- **Performance runner:** all 12 gated fixtures consume one declarative
  complexity-envelope table; WL1b is explicitly record-only. Preflight checks
  scale monotonicity, theoretical growth, finite bounds, the standard 1.5×
  headroom floor, and WL1a's sole 1.2× exception. Pure helper tests pin the PNG
  CRC and deterministic noise stream used by WL8. All 13 release workloads
  pass in run 31449682036.

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
- **Recent-page bounds reconciled by V1V-03B-001/002.** Pinned continuations
  now use SwiftData's documented sorted-result `fetchOffset` at
  `anchorOrdinal`, avoiding both the unproved optional-Int predicate and the
  former quadratic prefix fetch while retaining the anchor for full
  `(ordinal,date,id)` validation. Lane reads are capacity-aware: first pages
  normally materialize at most `limit + 1` scalars; pinned and unpinned
  continuations need `limit + 2` for their validated/inclusive anchor. Ambiguous ID
  ties take the hard-bounded §14.1 exactness fallback. The authoritative Part
  V/VI performance language now states these envelopes rather than weakening
  the claim only in this progress log. WS18 carries both same-date and
  multi-pinned-page traversal regressions. Run 31448195535 exposed that the
  same-file `HistoryAuthority` ordering extension could not read the scalar
  row's `private` timestamp; the member now uses the narrowest valid
  `fileprivate` access, and WS18 passes in run 31449682036.
- **Facade actor fields `private` → `internal` (`963b90d`, 05 §2 snippet
  deviation).** Part V §2's illustrative snippet declares the five
  `SwiftDataHistory` actor fields `private`; the WS12/WS15 deterministic
  harness must install suspension handlers on the facade's OWN Authority
  from `@testable` tests, which requires same-module visibility. `internal`
  members of a public struct are unreachable outside the HistoryStorage
  module, so the Part I §8 surface contract is unchanged. Recorded in the
  field's doc comment.
- **Observation discard path uses a position recheck, not buffer peeking
  (04 §5 steps 3–4).** `AsyncThrowingStream` offers no non-blocking peek,
  so the `observe` loop closes the registration→first-query race by
  re-reading the durable position (`HistoryAuthority.currentPosition`) and
  discarding/requerying while it is newer than the page — the §5 guarantee
  ("a commit in between is recorded") is preserved through read-after-commit
  (04 §1/§3) rather than by consuming the newest-value buffer; the buffered
  invalidation is later skipped by the phase-2 `latestPosition > position`
  guard. WS12 drives both paths via the `.readEntry` /
  `.positionRecheckEntry` suspension points.
- **`searchCorpusSnapshot` returns a labeled tuple.** The step-5 stub's
  pinned return type gained `continuationAnchor` so the Authority (which
  alone can decode/validate cursors against its process marker) passes the
  decoded anchor to `SearchWorker.page` — cursor decode and marker ownership
  stay on the Authority per 04 §6; the worker never sees a raw cursor.
- **Dead `StepDeferredError` scaffold was removed by the V1 verification
  cleanup.** Steps 6–8 had already retired every throw site; the zero-use type
  and contradictory step-phasing comments are now gone and it is not part of
  the reachable failure vocabulary.
- **Symbol-snapshot updater workflow.** `.github/workflows/symbol-snapshot.yml`
  is `workflow_dispatch`-only, runs on macos-26, and commits the regenerated
  HistoryCore public-symbol snapshot as the bot (`contents: write`). It
  produced the original `1cf1715` lock and remediation snapshot `9d65dcb`
  (workflow 31448087991). Bot pushes do not trigger the macOS CI workflow; the
  snapshot is enforced by the SwiftPM correctness job on every subsequent
  push, including final code-head run 31449682036.
- **Dependency pins.** xxHash is vendored at v0.8.3 (`Sources/xxh3/VENDORED.md`
  records the pin) with a package-only forced-collision double for Storage
  tests; Fuse is pinned at the exact 1.4.0 tag commit (the 2.0.0-rc.x
  pre-release is deliberately not used — AUDIT §4b). `maxPatternLength` is a
  dead parameter in Fuse 1.4.0, so `SearchWorker` enforces the engine-safe
  64-character fuzzy-query bound itself (03b §8; V1V-03C-001).
- **Resolved spec question — pin-ordinal compaction on remove (flagged by
  review agent-30, resolved at step-6 start as AUDIT IMP6-01).** `planRemove`
  originally emitted a single `.retire(itemID:, .userRemoval)` from a
  target-only `RemoveFacts`, so removing a pinned item left a gap in the
  pin-ordinal sequence that Part V §10's final-order revalidation would reject
  — every such transaction had to fail. Part V §9 gives no mechanical answer
  (the stamping table never invents shifts). The only D12-consistent
  resolution: `RemoveFacts` now carries the proven `CompletePinnedOrder`
  (02 §5.4) and `planRemove` emits the same compaction shifts unpin does
  before its `.retire` (02 §10); the remove fact load includes the §7.2
  pinned-order load (05 §7.3). Clear needs no such fact (`.unpinned` keeps all
  pins, `.all` removes all rows — both trivially contiguous); retention never
  retires pinned items (D13).

## Post-closure complexity pass (2026-08-11)

- **Status:** in progress. The canonical 222-row ledger currently has two
  `in-progress` performance-evidence items: 111 `fixed`, 29 `deferred`, and no
  `pending` rows. Broader measurement-gated changes remain deferred until the
  new supported artifacts can answer their exact trigger units.
- **Pure bounded algorithms:** [`1168d1d`](https://github.com/GuangDai/Clipy/commit/1168d1d)
  starts signature intersection from the smallest posting, validates D12 pin
  permutations in O(P), removes payload hashing from Canonical containment,
  uses a bounded O(N log K) retention selector for small victim counts, and
  bounds the unpinned exactness fallback's retained scalar state to O(L).
  Supported run
  [31483423935](https://github.com/GuangDai/Clipy/actions/runs/31483423935)
  passed all gates, 319 tests in 42 suites, app build/test, and all 13 release
  workloads.
- **Thumbnail source single-flight:** red-test commit
  [`7be8d02`](https://github.com/GuangDai/Clipy/commit/7be8d02) and run
  [31484363706](https://github.com/GuangDai/Clipy/actions/runs/31484363706)
  prove the missing source-inclusive interface (the expected SwiftPM compile
  failure; every independent job passed). The implementation now places full
  source hydration inside the exact-key task and gives joiners scalar fences;
  success/`nil`/failure/removal and the WS15 stale-join race are present.
  Supported run
  [31494740863](https://github.com/GuangDai/Clipy/actions/runs/31494740863)
  passed source/lint gates, SwiftPM build/tests, app build/test, and all 13
  release workloads; `thumbnail-source-full-image-copy` is now `fixed`.
- **Manual performance admission:** `HistoryPerfRunner` now has pre-proof code
  for a dispatch-only persistent 5,000 × 256 KiB corpus. It records 101 raw
  samples plus nearest-rank p50/p95/p99 for individual tie-heavy browse pages
  and worst-bound absent-term exact searches, with process peak RSS from
  `/usr/bin/time -l`. Warm-open samples use independently terminated child
  processes after one full-corpus validation warmup. Setup records the sum of
  seed- and validation-process phase durations, never a percentile. The job is
  record-only; the exact-search RSS is a
  structural ceiling rather than complete G8 evidence, and the GitHub runner
  is not an approved minimum-hardware profile for G5. Supported compile/run
  artifacts remain before the canonical evidence finding can leave
  `in-progress`. Diagnostic run
  [31498144173](https://github.com/GuangDai/Clipy/actions/runs/31498144173)
  passed every ordinary job but exposed the setup defect: the public-capture
  loop reached only 1,500/5,000 rows and logged 599 CoreData failures cloning
  missing `.externalStorage` `.interim` files (the first failures appeared
  after the 750-row marker and before the 1,000-row marker). The pre-proof
  replacement seeds 4,999 rows through Authority-owned fixed 64-row create
  batches (79 transactions), then
  requires one public coalesce and one public insert before measurement. A
  fixed 1,000 × 256 KiB smoke crosses the reproduced failure boundary and
  scans for the exact diagnostic before the full corpus runs. This changes
  disposable setup from cumulative O(N²) retained-inventory work and 5,000
  transactions to O(total bounded bytes + indexed creates) and O(N/64)
  transactions, with O(64 × bounded-row-bytes) transient setup space. Run
  [31505519746](https://github.com/GuangDai/Clipy/actions/runs/31505519746)
  measured 1,000-row setup at 21.74 seconds and 5,000-row setup at 116.90
  seconds with no missing-external-data diagnostic, but also exposed that the
  45-minute exact-search timeout was incorrectly masked by the completion
  shell gate. The gate now explicitly requires successful mode outcomes,
  complete 101-sample JSON, and non-empty timing records. Run
  [31527425658](https://github.com/GuangDai/Clipy/actions/runs/31527425658)
  then reproduced one intermittent `.interim` clone failure after all 4,999
  seeded rows, proving lexical facade release was not a deterministic CoreData
  teardown boundary. Seed and public validation now run as separate executable
  invocations with a fail-closed primitive JSON handoff; supported rerun
  [31529727208](https://github.com/GuangDai/Clipy/actions/runs/31529727208)
  completed the 5,000-row setup in 124.5 seconds with no missing-external-data
  diagnostic, and completed browse/warm-open evidence, but the absent-term
  exact step was killed at 90 minutes. Its log contained only the mode-start
  line, its timing file was empty, and no JSON existed: the runner performed
  one validation, one warmup, and 101 measured public searches before writing
  any result, repeatedly materializing and scanning roughly 1.22 GiB per
  request (at least 125 GiB across the mode) with no progress checkpoint.
  The follow-up adds opt-in `#if DEBUG` JSON checkpoints inside the real
  Authority/SearchWorker path for fetch, projection/validation, sort, exact
  title/body scan, and page construction, with progress every 250 rows and no
  clipboard/query/source/path fields. A separate one-request Debug probe runs
  first on the same full corpus; failure preserves its partial trace and skips
  the 90-minute Release and later warm-open steps. A successful probe proceeds
  directly to the canonical Release path, which still records all 101
  independent calls with immediate validation, warmup, and per-sample
  begin/completion checkpoints. Run
  [31597596383](https://github.com/GuangDai/Clipy/actions/runs/31597596383)
  then completed the 4,999-row seed cleanly but emitted one missing `.interim`
  clone 31 seconds into the separate 5,000-row validation process; validation
  still returned position 81 and 50 recent rows, so the clean-log gate failed
  before the Debug search probe could run. That run also exposed an independent
  WL2 harness flaw: same-process best-effort teardown produced an 8.137× warm
  open ratio against the 8× envelope. The next iteration puts startup,
  capture, and recent-read model lifetimes inside operation-local autorelease
  pools, adds immediate prepare phases plus opt-in Debug storage-lifecycle
  checkpoints, and lets the short probe run after a non-throwing preparation
  diagnostic while still skipping all long canonical measurements. WL2 now
  populates, warms, and internally times each open in a fresh child process;
  launch/teardown time is excluded and the 8× bound is unchanged. Supported
  diagnostic evidence is pending.

## Codebase complexity pass — scan budgets, deferred presentations, fused excerpts (2026-08-14)

A full algorithm audit (Domain planners, Storage search/read paths,
authority/codec/runner) confirmed no quadratic planner remains; the pass
landed constant-factor and allocation reductions with frozen 03b §8
semantics: exact/regexp/recent-equivalent scans stop at the page's
`limit + 1` post-anchor survivor bound (deep continuations and expired
anchors still scan fully), matched-row excerpts and UTF-16 translations
defer to page materialization, the excerpt window fuses its walks (bounded
probe + one forward walk + ≤ windowCapacity backward steps instead of a
full-body count plus two offset walks), the fuzzy lane slices its body
prefix as a Substring with the count from the same pass and drops the
per-row title prefix copy, capture lane-1 equality compares
`typeIdentifier → bytes` dictionaries instead of hashing clipboard bytes
into Sets, and `ContentProjector.project` skips decoding further
representations once title and body budgets are complete. Fuzzy and regexp
lanes gained Debug begin/progress/complete probe events with separate
title/body accounting; new boundary tests pin the eviction heap/sort
quarter-threshold agreement, 100-revision lineage resolution/rejection,
multi-representation lane-1 equality, the projector budget skip, the
prefix-slice Character bound, and the fused excerpt's capacity-edge,
zero-length, and multi-scalar-grapheme windows. The admission workflow's
strict log scans now prefilter the recovered CoreData external-storage
clone race (`.interim` clone failures with successful copy fallbacks, runs
31808691118/31809994808) while keeping every other warning/error line
fatal and the jq row/position assertions as the integrity gate. Supported full-scope run
[31815028830](https://github.com/GuangDai/Clipy/actions/runs/31815028830)
is green end to end, including the evidence lane under the prefilter;
the recent-equivalent window fix it required (anchor row must stay in the
evaluated array for `page` to drop) is locked by the new continuation
test.

## V2-02 retention final-gate closeout

- **Engine gates:** `e352166` added the process-death migration fixture and
  behavioral capture/revise zero-decode proofs; `d30673c` fixed the fixture
  compile. The runner observation required `04234c3`: SwiftData had stamped
  the schema before the killed custom-stage data committed, so `open` owns one
  idempotent missing-row recovery pass followed by the strict bidirectional
  validation. The owning V2-02/roadmap docs cite
  [run 31955551834](https://github.com/GuangDai/Clipy/actions/runs/31955551834)
  for that recovered outcome. This closes the final two engine-gate groups;
  it does not claim SwiftData migration interruption is atomic.
- **R.7 handoff:** v1 step 9 later delivered the unified retention settings,
  configured-policy reads, receipt feedback, pinned-over-budget guidance, and
  hosted/accessibility source wiring. Its tests-only-scope evidence is
  [run 32260455839](https://github.com/GuangDai/Clipy/actions/runs/32260455839),
  recorded below. Actual localization, VoiceOver/FKA, and other state-3
  runtime cells remain open; R.7 is no longer pending on step 9.

## Step 9 — product wiring: PasteboardAdapter + PresentationUI + ClipyApp

- **Status:** done. Green at run
  [32260455839](https://github.com/GuangDai/Clipy/actions/runs/32260455839)
  — Lint + source gates, SwiftPM build + test (the full package suite,
  539 tests in 64 suites at this head), and XcodeGen generate + app
  build/test (the generated project compiles and the hosted
  `ClipyIntegrationTests` pass), all with zero unexcluded warning/error
  log lines. The run was dispatched on the branch with the new
  `admission_scope: tests-only` input (workflow change `1826cee`: gates +
  SwiftPM + app jobs only), so the Perf-proofs, 5,000-row admission, and
  A/B lanes were deliberately not run — they remain required for their own
  evidence goals, not for step 9.
- **Roadmap:** `roadmap/README.md` §3 step 9 — module docs
  `roadmap/04-pasteboardadapter.md` (9a), `roadmap/05-presentationui.md` (9a),
  `roadmap/06-clipyapp.md` (9b); UX bounds from `01` §5–§6/§8, `03a` §4/§5/§7,
  `03b` §8–§12, `04` §5–§9, `05` §6.1, `06` §2/§8, plus the admitted V2-02
  retention settings surface (`docs/v2/V2-07-ux.md` §5/§6; first release =
  M1 + V2-02). Working design contract: `.tmp/step9/design.md` (scratch, not
  spec).
- **Delivered:**
  - `PasteboardAdapter` — `@MainActor` adapter (NSPasteboard is non-Sendable;
    MainActor isolation provides the Sendability) with `capture(observedAt:)`
    (freezes the first item's retainable representations, frontmost bundle ID
    as `sourceApplication`, lineage-hint decode, six-marker whole-capture
    concealment per `05` §6.1 — markers never stripped while siblings
    retained), `write(_:)` (Effective Content + `com.clipy.lineageHint` round
    trip, `03b` §9/§12), and `PasteboardObserver` (changeCount polling —
    NSPasteboard exposes no change notification; `01` §5.1). Unit tests cover
    the roadmap-04 acceptance list over private named pasteboards.
  - `PresentationUI` — `@MainActor @Observable HistoryViewState` (snapshot-
    replacement observation per `04` §5, one-shot cursor pagination with
    `.snapshotExpired` recovery per `04` §6, 250 ms-debounced search restart,
    typed-failure surface), `ThumbnailStore` (reference-exact keying per
    `01` §5.7/`04` §9, ImageIO decode — AppKit stays out of this target),
    `MatchHighlighting` (UTF-16 ranges per `03b` §8), `FailurePresentation`,
    and the scripted `PreviewClipboardHistory` (`01` §4). Views:
    `HistoryPanelView` (menu-bar panel: search header with Exact/Fuzzy/Regexp
    mode picker + 64-Character fuzzy clamp, Pinned/Recent sections, context
    menus, keyboard shortcuts, pagination, failure banner, footer with
    clear/settings/quit), `HistoryDetailsView` (info grid, Effective/Canonical
    content, revisions + revert, OCC-aware), `ReviseEditorView`
    (keep/hide/replace per representation, incoherent-draft guard), and
    `ClipySettingsView` (General: v1 count policy + clear actions; Retention:
    the unified V2-02 age/storage/revision group with receipt feedback).
  - `ClipyApp` — the sole composition root: `AppComposition.open` (persistent
    store under Application Support, second-open rejection per `01` §8),
    capture wiring, the only History→pasteboard paste hand-off
    (`01` §5.6/`04` §8), `MenuBarExtra` window-style panel + `Settings`
    scene, SMAppService launch-at-login.
  - `ClipyIntegrationTests` — the WS1–WS21 walking-skeleton paths re-run
    through the composed stack (real `SwiftDataHistory` + `PasteboardAdapter`
    + `HistoryViewState`), plus `AppCompositionTests` (second-open guard) and
    `AppPasteOrchestrationTests` (lineage-hint paste round trip);
    `ClipyIntegrationTests` gained package-product dependencies in
    `project.yml` so the hosted bundle can import the libraries. Fault-
    injection/suspension-seam clauses deliberately remain in the storage-side
    suites (each such clause is named in its composed suite's header).

| Commit | Subject |
|---|---|
| `c037a71` | Step 9: product wiring — PasteboardAdapter + PresentationUI + ClipyApp |
| `4c39499` | Docs: record step 9 implementation state |
| `1826cee` | CI: add tests-only dispatch scope (gates + SwiftPM + app tests, no perf lanes) |
| `e61b650` | Fix step-9 compile errors from CI run 32252737582 |
| `f4afa09` | Fix missed String→Text description in HistoryListView empty state |
| `3d4f388` | Fix test compile from run 32254796602 (PRODUCT_MODULE_NAME; makeStream) |
| `2a9f79f` | Fix integration/adapter test compile from run 32255661896 |
| `06c580c` | Fix test failures from CI run 32256916252 (see below) |
| `91d04dd` | WS15 composed: replace truncated white-PNG fixture |

- **CI:** seven dispatched runs on `codex/v2-implementation` (all
  `tests-only` scope): 32252737582 and 32254241169 failed on first-compile
  errors in the new PresentationUI/test code (SwiftUI API shapes; all
  fixed); 32254796602/32255661896 reached the test-compile stage
  (`@testable import` needed an explicit `PRODUCT_MODULE_NAME`; a
  swift-testing runtime-`skip` call does not exist — the pasteboard probe
  now throws; `waitFor` argument order); 32256916252 compiled everything
  and surfaced fifteen test failures — two real code defects
  (`PasteboardObserver`'s `Task`-hopped poll is never serviced under a
  manual runloop spin, now pinned to `RunLoop.main` `.common` with a
  `MainActor.assumeIsolated` synchronous poll; `MatchHighlighting` relied
  on `Range(NSRange,in:)` which CLAMPS mid-surrogate-pair bounds into the
  enclosing Character instead of returning nil — ranges splitting a
  surrogate pair are now explicitly dropped, 03b §8), five composed-suite
  expectation errors (asserting stronger than the storage contract: fuzzy
  calibration, pre-debounce page races, unpinned-only retention counting
  D13, insert-time `firstCopiedAt`/`firstSource` non-folding 02 §3.1), and
  one latent pre-step-9 fixture error
  (`RetainedBytesProjectionLifecycleTests`: "corruption" is 10 letters, so
  `canonicalBytes` is 25 not 26 — introduced by `04234c3`, which never had
  a recorded CI run; red since authored). 32259544566 then had both build
  + test legs green but failed the app-log self-scan on libpng
  `Not enough image data` ERROR lines from a truncated WS15 white-PNG
  fixture (3-byte IDAT for a 5-byte scanline — libpng recovers, so tests
  passed; the fixture is now a complete, CRC-checked encode). Final green:
  32260455839.


## Post-step-9: real-scale fixture harness + stress/smoke suites

- **Status:** done. Green at run
  [32269792986](https://github.com/GuangDai/Clipy/actions/runs/32269792986)
  (tests-only dispatch on `codex/v2-implementation`: gates, SwiftPM build +
  test, XcodeGen app build/test — perf lanes deliberately out of scope).
- **Fixtures:** `scripts/generate_fixtures.py` (deterministic `--seed
  20260819`, byte-identical reruns; Pillow in `.tmp/fixture-venv/`) produces
  `clipy-fixtures-v1`: 19 images (4K masters PNG/JPEG/TIFF, 1080p BMP, 720p
  animated GIF, 12 random crops, 7680×4320, 512 icon), 9 texts
  (100 KB–5 MB: real repo Swift sources, JSON, Markdown, CJK, emoji,
  long-lines, lorem, plus the 256 KiB search-body and 1 KiB title boundary
  straddlers), 300 KB RTF/HTML, a minimal valid PDF, and 50 file URLs;
  per-file sha256 in `manifest.json`. Hosted on GitHub release
  [`fixtures-v1`](https://github.com/GuangDai/Clipy/releases/tag/fixtures-v1)
  (tarball sha256 `ca1a5e11…`); `scripts/fetch_fixtures.sh` verifies the
  checksum and unpacks; both CI test jobs fetch it and export
  `CLIPY_FIXTURES_DIR`; suites gate with `.enabled(if:
  FixtureCatalog.available)` so a fresh clone's `swift test` stays green
  (swift-testing has no runtime skip API — the trait is the mechanism).
- **Suites:** `RealScaleStressTests` + `BoundaryLimitsStressTests`
  (bulk capture/coalescing, search-body + title truncation, 4K/8K thumbnail
  bounds, inclusive 64 MiB / 32-representation / 128 MiB edges, retention
  D13 at scale), `UISmokeJourneyTests` (browse/paginate/search/details/
  revise/settings over the real corpus), `PasteboardAdapterStressTests`
  (4K image and 5 MB text round trips, rapid-write boundedness, concealed
  5 MB whole-capture freeze), `RenderStormAndMemoryTests` (no page
  amplification + convergence under a 100-commit burst, debounce-storm
  settling, RSS leak tripwire, activate/deactivate hygiene).
- **Convergence (4 runs):** 32265918298 — three new-suite compile errors
  (bracket typo, redeclared local, thumbnail key type); 32267167679 —
  load-exposed flake: `pollUntil`'s 2 s wall-clock budget starved
  MainActor task slots under the now-parallel heavy suites (identical code
  green at 91d04dd), budget raised to 10 s, and the render-storm tripwire
  corrected to no-amplification + convergence (the strict `<` coalescing
  claim is owned deterministically by the storage WS12 suspension suites);
  32268871305 — tests all green, SPM log self-scan caught the known-benign
  CoreData `.interim` external-storage clone race from the real-scale
  suites' on-disk temp stores; the admission lane's existing awk prefilter
  now also covers the SPM and app self-scans (runs 31808691118/31809994808
  documented the same noise).


## Post-step-9: perf/AB test-lane split + Maccy-style panel (hotkey, position, preview)

- **Status:** done. Landed on `codex/v2-implementation` at `a028c8c`;
  CI-green at the closing head `cc59aa8`, run
  [32319164667](https://github.com/GuangDai/Clipy/actions/runs/32319164667)
  (intermediate runs 32316689047/32317009871 cancelled and
  32317628976/32318520597 failed — the full convergence narrative is in the
  header's CI-provenance block).
- **Test-lane split:** the perf/AB measurement-helper proofs moved from
  `HistoryPerfRunnerTests` to the renamed SwiftPM target `HistoryPerfTests`
  (`Tests/HistoryPerfTests/`). The default `swift test` lane now skips it
  (`--skip 'HistoryPerfTests\.'`) so the standard targets carry functional
  tests only. The current performance helper/proof, 5,000-row admission, and
  exact-matcher A/B workflows remain reusable `workflow_call` modules. Batch
  32 adds one correctness-gated, `workflow_dispatch`-only caller for exact and
  scale evidence; the performance helper/proof module remains caller-less.
  None runs on push or pull request.
- **Panel (Maccy replication):** the browsing surface moved off the SwiftUI
  `MenuBarExtra` (a menu-bar-extra window can be neither summoned nor
  positioned programmatically) onto Maccy's model: an AppDelegate-owned
  AppKit `NSStatusItem` + a fixed-size floating `NSPanel` (non-activating,
  key-capable, closes on focus loss, `.statusBar` level, every-space
  collection behavior) + a Carbon `RegisterEventHotKey` ⇧⌘C global summon —
  replicated WITHOUT adding the KeyboardShortcuts dependency
  (docs/roadmap/07-external-deps.md's no-new-deps rule stands). Placement
  (`PopupPositionMode`: cursor / status-item / screen-center / last-position,
  pointer-screen aware, visible-frame clamped, drag-persisted normalized
  anchor) is pure geometry in ClipyApp (`PopupPositionGeometry`); the mode is
  user-configurable in Settings → General. The store now opens at launch
  instead of at first panel appearance — a clipboard manager must capture
  while closed. Paste closes the panel via `AppComposition.onPasteCompleted`
  (the panel never activates the app, so the paste target keeps focus).
- **Preview pane (Maccy's slideout, replicated):** PresentationUI gains
  `PreviewPaneState` (200 ms dwell-to-peek auto-open on selection change with
  cancel-and-reschedule debounce, ⌃Space manual toggle, manual-close
  suppression until the next selection change, panel key-status arming),
  `HistoryPreviewView` (image-first Effective Content preview, UTF-16/UTF-8
  frozen-encoding text decode, 50,000-character cap,
  source/count/timestamp metadata bar), and `PanelGeometry` (the shared
  400 + 1 + 320 × 560 window-width vocabulary both the SwiftUI frame and the
  AppKit `setFrame` read). The window widens for the preview with a single
  no-animation `setFrame` that pins the anchor edge (Maccy's layout-storm
  lesson); Esc clears an active search, else closes the panel.
  Batch 31 later moves preview ImageIO/source-selection/resource policy into
  the concrete package-only `ContentPreview` actor and replaces retained
  CGImage with a bounded inert eager raster; the loader's History/reference/
  task/lifecycle ownership is unchanged.
- **Smoke/measurement hooks (ClipyIntegrationTests,
  `SmokeMeasurementTests`):** thumbnail-cache memory eviction (deterministic
  entry-count proof at an injected ceiling of 3: six inserts leave exactly
  two entries), corpus memory loading (RSS bounded across a full 150-item
  page-through), render-speed first-page/page-turn timing capture, and the
  preview pane end-to-end over the real facade. Measurements print as
  grep-able `clipy.smoke.measurement` JSON lines — recorded, never asserted.
  `PanelAndHotKeyTests` proves the origin geometry over synthetic screen
  frames and headless Carbon registration; `PreviewPaneStateTests` and
  `PreviewContentTests` (PresentationUITests) cover the state machine and the
  resolver. `ThumbnailStore` gained an injectable entry ceiling plus
  `cachedEntryCount`/`inFlightCount` observability for the eviction smoke.
- **Hosted-test isolation:** `AppDelegate.isRunningTests` (XCTest linkage or
  `XCTestConfigurationFilePath`) skips the status item, hotkey, and
  production-store open under the test host — Maccy's `enable-testing`
  pattern; the composed suites keep composing their own stacks.

## Master correctness closeout (2026-08-22)

- **Status:** landed on `master` through PR #8. PR #7 is correctness-green at
  run 32572531247; PR #8 is correctness-green at run 32573066624. Both runs
  passed the three supported correctness jobs named in the header.
- **Signed Release runtime evidence:** manual `master` run 32573198119 is
  green. Its support ceiling is the ad-hoc signature, Hardened Runtime flag,
  iCloud/ubiquity entitlement negative, and direct process-lifecycle smoke;
  the state-3 distribution and WindowServer-dependent cells remain open.
- **Workflow state:** `.github/workflows/correctness.yml` is the only push/PR
  workflow. Batch 32 gives the reusable scale-admission and exact-matcher
  evidence modules one manual-only caller that first invokes same-SHA
  correctness; performance helper/proof remains reusable-only. Symbol-snapshot
  and signed-runtime remain `workflow_dispatch`-only.

## External Gateway continuation (2026-08-23)

- **X.6 landed:** [PR #15](https://github.com/GuangDai/Clipy/pull/15) is
  correctness-green at
  [run 32607389771](https://github.com/GuangDai/Clipy/actions/runs/32607389771);
  its HistoryCore symbol update came from
  [run 32606749388](https://github.com/GuangDai/Clipy/actions/runs/32606749388).
  This closes the bounded positive Gateway reads/writes, atomic HCR + audit +
  History commit path, failure mapping, cadence fence, and public
  connection-bound facade/factory at their test seams. It does not prove
  performance, App Intents framework invocation, credential, CLI, or transport
  behavior.
- **X.7 landed:** [PR #16](https://github.com/GuangDai/Clipy/pull/16) is
  correctness-green at
  [run 32609910701](https://github.com/GuangDai/Clipy/actions/runs/32609910701);
  its HistoryCore identity reconstruction surface came from
  [symbol run 32609018894](https://github.com/GuangDai/Clipy/actions/runs/32609018894).
  This closes the bounded six-intent composition, output-only projections,
  one early async facade provider, direct-call failure mapping, and real
  in-memory History/pasteboard-adapter hosted paths at their tested seams.
  True Siri/Shortcuts discovery and cold/warm invocation, framework
  system-manager resolution, process placement, Swift 6 queue-crash freedom,
  cross-process pasteboard visibility, and TCC remain signed-runtime cells and
  are not closed by hosted tests.
- **X.8 landed:** [PR #17](https://github.com/GuangDai/Clipy/pull/17) is
  correctness-green at
  [run 32613689337](https://github.com/GuangDai/Clipy/actions/runs/32613689337).
  It adds the no-product, Foundation-only pure wire seam: the shared
  [`ClipyCLIContract`](../Sources/ClipyCLIContract/ClipyCLIContract.swift)
  constants/types, typed
  [request codec](../Sources/ClipyCLIContract/ClipyCLIRequestCodec.swift) with
  bounded JSON [parser](../Sources/ClipyCLIContract/BoundedJSONParser.swift),
  and typed
  [reply renderer](../Sources/ClipyCLIContract/ClipyCLIReplyRenderer.swift)
  with bounded JSON [writer](../Sources/ClipyCLIContract/BoundedJSONWriter.swift),
  plus the
  `PLAY-PY-A2A`–`A2I` tests under
  [`ClipyCLIContractTests`](../Tests/ClipyCLIContractTests/PLAYPYA2AUnknownMajorTests.swift).
  The runner evidence closes only the specified pure bounded UTF-8 JSON
  request grammar, deterministic reply bytes, closed `browsePreview`
  operation, content-free stderr bytes, and stable exit mapping. This batch
  changed no HistoryCore public surface, so it needed no symbol-snapshot run;
  no performance/AB lane ran. It adds no executable, process I/O,
  Python-to-History path, transport, authentication, Gateway dispatch,
  grant/audit behavior, or signed-runtime proof; those X.9+ layers remain
  open.
- **X.9 F0A discriminator landed:** [PR #18](https://github.com/GuangDai/Clipy/pull/18) adds a
  compile-time-isolated app-side
  [`UnixSocketF0Listener`](../ClipyApp/Sources/Automation/UnixSocketF0Listener.swift),
  fixed probe-only [frame codec](../ClipyApp/Tools/ClipyUDSF0Shared/UnixSocketF0Protocol.swift),
  and non-product diagnostic
  [`ClipyUDSF0Client`](../ClipyApp/Tools/ClipyUDSF0Client/ClipyUDSF0Client.swift). The
  dispatch-only signed-runtime lane tests bounded ad-hoc
  signed same-EUID UDS cold/warm, incomplete-frame, normal-cleanup, and
  SIGKILL/stale-recovery mechanics. The exact flagged app/client artifact is
  green at [signed-runtime run 32615713100](https://github.com/GuangDai/Clipy/actions/runs/32615713100).
  [Correctness run 32615569895](https://github.com/GuangDai/Clipy/actions/runs/32615569895)
  is green across all three jobs for the same SwiftPM graph and normal app
  scheme; the later F0-only Darwin-call correction is compiled and executed by
  the signed run. It is not `clipyctl`, does not decode X.8 JSON or reach
  History/Gateway, and proves no credential, authenticated ingress, Developer
  ID/notarization, App Sandbox, Keychain sharing, different-EUID caller, TCC,
  or interactive no-activation behavior.
- **X.9 F1 prerequisite kind hardening landed:**
  [PR #19](https://github.com/GuangDai/Clipy/pull/19), merged as `2ec8911`, is
  green across all three correctness jobs at
  [run 32617502726](https://github.com/GuangDai/Clipy/actions/runs/32617502726).
  [`ExternalGateway`](../Sources/HistoryStorage/ExternalGateway.swift) threads
  the expected connection kind into the Authority-owned read, write, and rate
  paths; [`GatewayAuthorization`](../Sources/HistoryStorage/GatewayAuthorization.swift)
  rechecks the durable row kind and closed policy at the authoritative storage
  boundary. The real in-memory V4
  [`GatewayConnectionKindRecheckTests`](../Tests/HistoryStorageTests/GatewayConnectionKindRecheckTests.swift)
  prove bidirectional wrong-kind authorization/read and wrong-kind writes are
  unaudited and do not mutate History/HCR/ChangePosition, while correct-kind
  granted/revoked behavior retains its existing audit contract. The rate path
  is threaded and compiled but has no dedicated wrong-kind behavioral fixture
  in this leaf. This is only a storage-layer expected-kind/policy prerequisite:
  it adds no credential
  custody, authenticated UDS ingress, local positive browse, X.8 JSON
  dispatch, product `clipyctl`, locator/cursor, schema/public surface, or new
  signed platform evidence.
- **X.9 F1 server credential ordinary/injected leaf landed:**
  [PR #20](https://github.com/GuangDai/Clipy/pull/20), merge `604e335`, contains
  the exact 16-byte connection UUID + 32-byte
  secret value in
  [`LocalAutomationCredential`](../Sources/HistoryStorage/LocalAutomationCredential.swift)
  and the actor-confined app-private Data Protection Keychain adapter in
  [`CredentialStore`](../Sources/HistoryStorage/CredentialStore.swift).
  [`LocalAutomationCredentialStoreTests`](../Tests/HistoryStorageTests/LocalAutomationCredentialStoreTests.swift)
  exercise literal shape, system secret generation, exact
  round-trip/delete, duplicate/malformed/corrupt/unavailable behavior through
  an injected in-memory external-operations seam; the suite passed in
  [correctness run 32619384577](https://github.com/GuangDai/Clipy/actions/runs/32619384577).
  This closes only the ordinary compiled implementation and injected-store
  behavior leaf. Signed-artifact Data Protection Keychain
  persistence/reopen/delete remains open, and the batch includes no client credential file,
  enrollment/revocation coordination, credential comparison/authentication,
  authenticated ingress, Gateway/History dispatch, product CLI, or signed DPK
  result.
- **Additional Batch 18 evidence leaves landed at their specified ceilings:**
  [`StableIdentityRetirementTests`](../Tests/HistoryStorageTests/StableIdentityRetirementTests.swift)
  is a tests-only public-History D1 proof that byte-identical recapture after
  removal mints a fresh item identity while the retired ID stays not-found; it
  changes no production code.
  [`GatewayConnectionKindRateDenialTests`](../Tests/HistoryStorageTests/GatewayConnectionKindRateDenialTests.swift)
  directly covers the PR #19 rate-denial follow-up: bidirectional wrong-kind
  calls remain unaudited and correct-kind local denial appends one bounded
  audit without changing History/HCR/position. Both suites passed in
  [correctness run 32619384577](https://github.com/GuangDai/Clipy/actions/runs/32619384577).
  The now-retired dispatch-only finite-symbol mechanism produced 0 matches
  across 26 reviewed literals in the exact
  ordinary ad-hoc Release artifact at
  [run 32619756885](https://github.com/GuangDai/Clipy/actions/runs/32619756885).
  The symbol result is not a complete instrumentation audit and proves no
  Developer ID, timestamp, notarization, Gatekeeper, TCC, UI, or other runtime
  behavior. Its workflow, script, and literal inventory were deleted on
  2026-08-24 and are not current correctness machinery.
- **Card 5A mapping/live-revoke leaf landed:**
  [`PasteboardAccess`](../Sources/PasteboardAdapter/PasteboardAccess.swift)
  maps the documented AppKit access cases to a neutral Sendable value, while
  [`CaptureAccessState`](../ClipyApp/Sources/Capture/CaptureAccessState.swift)
  owns six content-free app states and deny-by-default polling policy.
  [`PasteboardObserver`](../Sources/PasteboardAdapter/PasteboardObserver.swift)
  now preflights access on immediate/timer cycles, and the composition/panel
  wiring publishes a non-empty-history recovery banner. The new
  [`PasteboardAccessTests`](../Tests/PasteboardAdapterTests/PasteboardAccessTests.swift)
  and [`AppCaptureAccessTests`](../ClipyApp/Tests/ClipyIntegrationTests/AppCaptureAccessTests.swift),
  plus the existing observer-retry suite, cover mapping, reducer precedence,
  denied-startup zero reads, live-revoke stop-before-payload, and allowed
  observer reuse in [correctness run 32619384577](https://github.com/GuangDai/Clipy/actions/runs/32619384577).
  This closes the specified mapping/live-revoke behavior, not platform access
  acceptance.
  There is no Pause UI, no provider-specific timeout/cause inference, and no
  proof of the General pasteboard prompt, TCC/System Settings transitions,
  clean profiles, or signed runtime behavior.
- **Card 5B optional hosted exact-outcome characterization landed:**
  [`AppCaptureExactOutcomeTests`](../ClipyApp/Tests/ClipyIntegrationTests/AppCaptureExactOutcomeTests.swift)
  uses a real named private `NSPasteboard`, public lazy-data-provider API,
  production observer/composition, and real in-memory History to characterize
  a declared type whose provider supplies no bytes. The hosted suite passed in
  [correctness run 32619384577](https://github.com/GuangDai/Clipy/actions/runs/32619384577),
  observing one content-free declared-unavailable failure, zero capture-lane
  slots, and unchanged empty History. It does not diagnose timeout/permission
  or prove General pasteboard/TCC.
- **Card 10C four-state hosted leaf landed:**
  [`LaunchAtLoginSettings`](../Sources/PresentationUI/LaunchAtLoginSettings.swift)
  exposes neutral off/on/requires-approval/unavailable presentation, while
  app-owned
  [`LaunchAtLoginController`](../ClipyApp/Sources/Settings/LaunchAtLoginController.swift)
  confines ServiceManagement, refreshes authoritative status, preserves a
  content-free operation-failure episode, and fences stale completions.
  [`LaunchAtLoginSettingsTests`](../Tests/PresentationUITests/LaunchAtLoginSettingsTests.swift)
  and
  [`LaunchAtLoginControllerTests`](../ClipyApp/Tests/ClipyIntegrationTests/LaunchAtLoginControllerTests.swift)
  cover the current model/controller seams; settings appearance and app-active
  refresh are wired through `ClipySettingsView`/`AppDelegate`. The SwiftPM
  presentation suite and hosted controller suite passed in
  [correctness run 32619384577](https://github.com/GuangDai/Clipy/actions/runs/32619384577).
  This proves the four-state model and injected hosted controller behavior; it
  does not prove fresh-install registration, external
  revoke, logout/login, actual System Settings behavior, or a signed installed
  artifact.
- **Batch 19 Card 6B APFS capture-transaction physical evidence GREEN
  (2026-08-23, dispatch run
  [32636093920](https://github.com/GuangDai/Clipy/actions/runs/32636093920)):**
  the disposable 256-MiB UDRW APFS image experiment observed the full leaf:
  `volume.filesystem=apfs`, `volume.writable_metadata=true
  (WritableVolume)`, a 1-MiB write+remove preflight, seed tokens matched, a
  real competing-allocation ENOSPC (`competitor.result=enospc`, 6.6 MB left),
  the production capture transaction rejected as
  `.temporarilyUnavailable(.insufficientDiskSpace)` with the seed unchanged
  (`PRESSURECAPTURE_OK`), capacity released, and a fresh-process seed reopen
  (`VERIFYSEED_OK`); summary line `pressure_capture=transaction rejected with
  seed preserved`. Reaching green required the batch-22..27 chain: the
  branch's two multi-line-interpolation syntax errors (PR #24), stamped-plan
  capacity admission in docs/05 §16 (PR #25) — added because run
  [32632262141](https://github.com/GuangDai/Clipy/actions/runs/32632262141)
  proved Core Data raises an uncaught
  `NSInternalInconsistencyException` (`Can't create externalDataReference
  interim file : 28`) instead of an out-of-space error when an
  external-storage interim file cannot be created on a full volume — the raw
  `volumeAvailableCapacity` fact after the important-usage variant returned
  zero on the mounted volume (PR #26, run
  [32634051113](https://github.com/GuangDai/Clipy/actions/runs/32634051113)),
  and a breadcrumbs-only EXIT trap after the runner's bash 3.2 fired the
  inherited trap inside substitution subshells mid-body three times (PRs
  #27–#29, runs 32634454727/32635233048/32635568571). The ceiling still
  excludes disk-full open/migration, revise/remove/clear under exhaustion
  after admission passes (the Apple-framework crash ceiling documented in
  §16/AUDIT), StoreRoot recovery, and any signed or distribution
  environment.
- **Batch 19 General pasteboard cross-process scaffold landed; visibility
  evidence remains open:**
  [`GeneralPasteboardCrossProcessProbeTests`](../Tests/PasteboardAdapterTests/GeneralPasteboardCrossProcessProbeTests.swift),
  [`run_pasteboard_cross_process.sh`](../scripts/ci/run_pasteboard_cross_process.sh),
  and the dispatch-only
  [`pasteboard-cross-process`](../.github/workflows/pasteboard-cross-process.yml)
  workflow define two independent short-lived ad-hoc test-host processes in
  one login session. The first writes independently declared synthetic bytes
  to `.general` through production `PasteboardAdapter.write`; only after it
  exits does the second use native AppKit to byte-compare the value. The
  scaffold landed in PR #21 and is correctness-green at run 32621152027. The
  first physical attempt
  [32621160138](https://github.com/GuangDai/Clipy/actions/runs/32621160138)
  failed while compiling the aggregate Release test host because testable
  modules had not been enabled. PR #22 enabled them, but attempt
  [32621668622](https://github.com/GuangDai/Clipy/actions/runs/32621668622)
  then failed in that same pre-launch aggregate Release build because a
  repository test referenced the DEBUG-only `MigrationBackfillAbortProbe`.
  **Cross-process visibility is now observed GREEN (2026-08-23, dispatch run
  [32632263996](https://github.com/GuangDai/Clipy/actions/runs/32632263996))**
  after PR #24 fixed the two build-blocking interpolation syntax errors and
  the tolerant Info.plist-absent inventory: the writer published the
  16-byte synthetic `com.clipy.probe.cross-process` payload through the
  adapter, the ad-hoc+hardened-runtime bundle signing and the swift-testing
  discovery/filter chain held, and the reader byte-compared the value after
  the writer host exited. This leaf does not test TCC, App Intents, a target
  application, write atomicity, or WindowServer behavior.
- **Batch 19 Settings Clear surface-purge routing landed:**
  [`ClipySettingsView`](../Sources/PresentationUI/ClipySettingsView.swift) now
  sends Danger Zone Clear through the shared
  [`HistoryViewState.clearAwaitingReceipt`](../Sources/PresentationUI/HistoryViewState.swift)
  owner instead of performing the History action directly. The new
  [`SettingsClearSurfacePurgeTests`](../Tests/PresentationUITests/SettingsClearSurfacePurgeTests.swift)
  fixture distinguishes unchanged, typed failure, and committed receipts:
  unchanged/failure must preserve the existing surface, while only a committed
  Clear may publish and apply the whole-surface purge. PR #21 and correctness
  run 32621152027 compile and execute this discriminator. This closes only the
  Settings Clear ingress: App Intents/Gateway external remove still bypasses
  the owner, and page observation still lacks off-page purge facts, so overall
  Card 9B remains Partial.
- **Batch 19 preview dwell test repair landed without a new product claim:**
  [`PreviewPaneStateTests`](../Tests/PresentationUITests/PreviewPaneStateTests.swift)
  now use a finite scheduler-turn oracle and the delay-injection seam instead
  of wall-clock sleeps that starved the MainActor on the hosted runner. The
  repaired suite passed in correctness run 32621152027. Production dwell
  behavior did not change, and this tests-only repair proves no WindowServer,
  pixel, or accessibility behavior.
- **PLAY-STOR-1 logical ledger arithmetic is Done at its pure ceiling:**
  [`RetainedBytesStamping`](../Sources/HistoryStorage/RetainedBytesStamping.swift)
  stamps capture insert `canonicalBytes` from the signature-envelope
  representation-byte sum and initializes revision count/bytes to zero in the
  same transaction. The literal
  [`captureInsertStampsOneToOneRow`](../Tests/HistoryStorageTests/RetainedBytesProjectionLifecycleTests.swift#L138)
  fixture independently decodes the signature entries and proves a 17-byte
  capture produces exactly `canonicalBytes == 17`, `revisionCount == 0`, and
  `revisionBytes == 0`; it is green in run 32621391305. This closes only the
  pure committed-logical-payload arithmetic requested by `PLAY-STOR-1`.
  `RetainedBytes` deliberately excludes WAL, staging, thumbnails, resident
  copies, filesystem allocation, and other physical categories, so this is not
  a physical storage, RSS, or capacity-manager result.
- **Batch 21 bounded closure is landed and correctness-green:**
  [PR #23](https://github.com/GuangDai/Clipy/pull/23), merge `96bfb341`, passed
  all three jobs in PR run
  [32623287645](https://github.com/GuangDai/Clipy/actions/runs/32623287645)
  and master push run
  [32623493462](https://github.com/GuangDai/Clipy/actions/runs/32623493462).
  Hosted
  [`HistoryListPaginationHostedTests`](../ClipyApp/Tests/ClipyIntegrationTests/HistoryListPaginationHostedTests.swift)
  mounts the production list against an all-pinned first page;
  [`FloatingPanelFrameHostedTests`](../ClipyApp/Tests/ClipyIntegrationTests/FloatingPanelFrameHostedTests.swift)
  observes real same-process `NSPanel` frame expansion/collapse;
  [`SearchAdmissionBeforeIOTests`](../Tests/HistoryStorageTests/SearchAdmissionBeforeIOTests.swift)
  checks invalid exact/fuzzy/regexp requests before context/corpus I/O;
  [`RetentionSettingsDraft`](../Sources/PresentationUI/RetentionSettingsDraft.swift)
  and its tests preserve untouched sub-day/sub-MiB values, dirty-field
  conversion, confirmation, and edit-generation fencing; and
  [`AccessibilityAnnouncement`](../ClipyApp/Sources/Accessibility/AccessibilityAnnouncement.swift)
  plus hosted tests publish one content-free AppKit announcement per new
  authoritative capture-failure episode. The same branch also adds bounded,
  content-free APFS owning-boundary diagnostics and explicit pasteboard
  build/process/phase markers to discriminate the two failed workflows. Until
  later dispatches, those two were diagnostic instrumentation only; physical
  APFS and pasteboard behavior are attributed separately to runs 32636093920
  and 32632263996. The five normal acceptance leaves are Done only at their
  specified hosted/pure/admission/notification ceilings. These leaves do not
  close localization or the complete unified-retention journey,
  AX/VoiceOver/FKA, multi-screen/Spaces/WindowServer behavior, General
  pasteboard visibility, physical APFS ENOSPC, external surface purge, signed
  Data Protection Keychain, or distribution acceptance.
- **Batch 30 `DEC-RET-READ` + Card 10A consumer closure is landed:**
  [PR #32](https://github.com/GuangDai/Clipy/pull/32), merge `1c221e6`, resolves
  configured retention as a purpose-specific public
  `ClipboardHistory` read while keeping live retained-byte usage excluded. It
  hoists both Settings tabs onto one panel-owned count+policy snapshot/edit
  generation, adds the awkward-unit Presentation action proof, and adds
  `RET-READ-1A` public persistent owner-release/reopen/read/reapply evidence.
  PR run 32678325377 and master push run 32678654503 are green. Localization,
  visual count relocation into one group, AX/FKA, and live usage remain open.
- **Batch 31 `DEC-PREVIEW-TARGET` deep-module migration is landed and
  correctness-green:** [PR #33](https://github.com/GuangDai/Clipy/pull/33),
  merge `ffd0e9f`, passed all three jobs in final PR run
  [32682438863](https://github.com/GuangDai/Clipy/actions/runs/32682438863)
  and master run
  [32682682345](https://github.com/GuangDai/Clipy/actions/runs/32682682345). One
  package-only concrete `ContentPreview` actor now owns exact preview source
  selection, fixed resource profiles, text codecs, ImageIO decode, and bounded
  eager raster/text outcomes. PresentationUI owns History/reference/task/
  lifecycle fences but no longer imports ImageIO or publishes/retains CGImage.
  The same batch migrates encoded thumbnail display materialization without
  moving HistoryStorage's source/version/single-flight or ThumbnailStore's
  surface-local reference/cache policy. Exact UTF-8 and PNG artifact proofs,
  deterministic A3/A4/A5 late-result tests, the one-native-slot handoff proof,
  gates, and owning documents are green. Earlier attempts
  32681250466/32681513849 exposed respectively three missing `try` markers in
  throwing TaskLocal test scopes and a concrete 12.5-second ImageIO completion
  under the 962-test parallel runner versus the old 10-second monotone poll;
  both were fixed before the green run. A later docs-only attempt 32682113026
  showed that merely widening the timeout made the same-owner concurrent
  ImageIO window drift to about 23 seconds, so the final branch restores the
  10-second failure bound and serializes the ThumbnailStore native/display
  owner suite instead.
- **Batch 32 GOV-1 manual evidence caller is landed:** PR #34 / merge
  `f48d87f` adds one
  `workflow_dispatch`-only caller that invokes reusable same-SHA correctness
  before starting the exact-matcher and 5,000-row evidence siblings in
  parallel. The scale script is phase-dispatched again so Actions owns the
  historical 5/10/45/15/90/45-minute liveness guards, preserves the short
  Debug probe after a full-prepare cleanliness failure, skips long canonical
  work in that case, and uploads only an explicit artifact allowlist. A narrow
  portable contract gate locks those facts. PR run 32684566664 and master run
  32684916238 are correctness-green. Manual run 32685185124 attempt 2 has the
  exact sibling green; its schema-v2 artifact reports all 13 decision cases
  passing and `productionIntegrationEligible == true`. The scale sibling is
  also green: 5,000-row setup was 166,473 ms; tie-heavy public browse-page
  p50/p95/p99 was 1,076/2,148/2,654 ms; the 11-sample exact-search p50 was
  2,666 ms with p95/p99 intentionally absent below their support floors; and
  101 independent-process warm opens measured 14,841/22,244/23,136 ms. The
  recorded worst process high-water marks are ceilings, not attribution or G8
  proof. GOV-1 is Done at this record-only evidence ceiling; no G2/G5/G8,
  approved-hardware, positive-RSS-budget, fsync/crash, or general
  external-storage no-fault claim exists.
- **Batch 33 Card 9B + bounded accessibility leaves are landed:** PR #35 /
  merge `10decae`; final PR correctness 32688665740 and master correctness
  32688965362 attempt 2 are green. One
  internal `AppIntentHistoryIngress` now joins the existing public Gateway
  facade to one AppDelegate-owned `HistoryPanelSurfaceState` through an
  app-local relay only after a positive external remove and before the Intent
  returns. A real in-memory Authority test holds the
  post-commit observation and proves exact row retirement plus real surface
  application at that ordering
  boundary; a Presentation owner test carries the same purge through a parked
  thumbnail flight. Panel-initiated committed Remove publishes one
  content-free medium-priority announcement, while unchanged/failure remain
  silent; the large image preview label uses literal decoded pixel dimensions.
  It does not prove Siri/Shortcuts system invocation, AX tree, actual VoiceOver/FKA,
  localization, WindowServer, or signed runtime.
- **Batch 34 panel journey is landed; archive identity remains Partial:** PR #36 /
  merge `2bc4a8e`; final PR correctness 32691964885 attempt 2 and master
  correctness 32692472789 are green. PR #36
  adds one XcodeGen `bundle.ui-testing` target and a DEBUG-only launch envelope
  that substitutes only a temp store and allowed pasteboard posture. The
  tracer must still pass actual app launch → hotkey-tail summon → search
  first responder → arrow selection → production General-pasteboard write →
  exactly one close. Final PR run 32691591462 passes all three correctness
  jobs, including the stronger direction discriminator: replacement search
  selects newest beta, Down must select alpha, and the final General
  pasteboard value is byte-exact alpha before the panel disappears. The same
  PR makes AppDelegate
  the only panel-session observation owner and records pure newest/arrow/
  reopen behavior. Its independent Card 16A leaf freezes bundle
  `com.clipy.ClipyApp`, version `0.1.0` build `1`, utility category, explicit
  empty entitlements and an original AppIcon, plus a portable archive
  validator and manual-only workflow. It remains Partial until a protected
  release tag exists and the real unsigned archive artifact passes; it proves
  no Developer ID signing, notarization, staple, Gatekeeper, TCC, or release.
- **Batch 35 generic Local Automation enrollment gate is landed:** PR #37 /
  merge `dd433d9`; final PR correctness 32693281604 and master correctness
  32693554157 are green. The
  public `GatewayAdminHistory` witness now rejects `.localAutomation` before
  Authority admission, audit, clock use, ID minting, or durable mutation.
  A real in-memory public-facade test requires connections/grants to remain
  equal and the public audit page to contain no `adminEnroll`; storage-only
  kind/rate/recheck fixtures call the internal Authority directly. This closes
  only the forbidden generic publication
  route; client file custody, enrollment/revocation coordinator, server
  authentication, ingress, transport, and CLI remain open.
- **Batch 36 in-process credential authentication kernel is landed:** PR #38 /
  merge `1834eca`; final PR correctness 32694144024 attempt 2 and master
  correctness 32694673199 are green. An
  exact 48-byte presentation parses its embedded UUID, loads the server
  credential, performs one fixed full-byte traversal comparison, and reuses
  the canonical durable connection loader through a narrow unaudited scalar
  preflight. Malformed, missing, wrong-secret, and orphan presentations return
  no identity; exact active and revoked credentials return only the durable
  connection ID so a later unique Gateway remains responsible for audited
  revoked/not-granted outcomes. Real V4 Authority tests require all verifier
  paths to leave Gateway state/audit unchanged. No ingress DTO, framing,
  peer-EUID proof, transport, client custody, coordinator, or CLI is added.
- **Batch 37 running-app row accessibility characterization is landed:** PR
  #39 / merge `5ee1963`; final PR correctness 32696012215 attempt 2 and master
  correctness 32696647481 are green. The existing XCUI process journey now
  also requires both history rows to
  materialize as stable-ID button accessibility elements and requires their
  labels to contain the distinguishable alpha/beta titles before the Down →
  alpha product-paste proof. A real hosted NSPanel/NSHostingView experiment
  exposed only an empty public `AXGroup` on the CI runner even after becoming
  active/key, so that experiment was removed rather than replaced by a private
  or fabricated SwiftUI tree. Card 15B default/named AX action execution,
  actual VoiceOver/FKA, localization, and signed runtime remain open.
- **Batch 38 Editor/Settings bounded controls are landed:** PR #40 / merge
  `c89f2ba`; PR-head correctness 32698639889 and master correctness
  32699272489 are green. The revision
  editor now carries the approved pre-Save immutable-history disclosure with
  one literal Presentation proof. The running-app Settings journey opens the
  real Settings scene, materializes the Launch at Login control, enables the
  age threshold, and requires the strict-retention warning/destructive action
  before Esc cancels while preserving the draft. This is not a hosted editor
  copy/Esc proof, a four-state ServiceManagement runtime proof, or complete
  unified-retention acceptance.
- **Batch 39 executes five bounded leaves across frozen todo-map areas
  4.1–4.4/4.7 and is landed:** [PR #41](https://github.com/GuangDai/Clipy/pull/41) /
  merge `87db3d6`; final PR correctness 32705015919 and master correctness
  32705436579 are green. It
  keeps independent evidence ceilings: (4.1) one visually unified
  count+V2 retention group with semantic no-change Apply gating, untouched
  raw-value preservation, and explicit whole-unit edit intent; (4.2) verified
  preassigned Local Automation
  publication plus an internal exact-credential-to-unique-Gateway
  `browsePreview` route; (4.3) a four-terminated-process retention
  write/read/update/read tracer; (4.4) running-app Search Clear/focus plus a
  public AXPress default-Copy cell; and (4.7) ThumbnailStore test-knob/counter
  contraction. The proposed narrow regex/log gates and the pre-existing
  static-source, SwiftLint, dependency/vendor, generated-project, test-selection,
  and public-symbol machinery were removed at the user's direction. Current
  correctness is the two parallel SwiftPM and XcodeGen build/test jobs. The
  Search Clear/focus journey exposed and then fixed a real AppKit event bug:
  `FloatingPanel` had read keyboard-only `keyCode` from mouse events before
  delivering them to `super`, which made panel controls ignore clicks. The
  public AXPress cell remains an explicit skip on the untrusted CI runner.
  These leaves do not upgrade the signed/TCC/
  VoiceOver/FKA/Developer-ID/full-disk/migration cells or the client-custody,
  transport, and opaque-locator design blockers.
- **Batch 40 landed direct product leaves across 4.1–4.5:** PR
  [#42](https://github.com/GuangDai/Clipy/pull/42) (merge `cb3de0d`) carries
  the product bundle; PR [#43](https://github.com/GuangDai/Clipy/pull/43)
  (merge `00c3fee`) keeps Authority cancellation a 64-row/two-chunk
  functional proof instead of a default-lane scale fixture; PR
  [#44](https://github.com/GuangDai/Clipy/pull/44) (merge `5ea8794`) joins the
  Settings Clear scripted observation before its state-publication deadline.
  Product-head correctness 32712455441 and final master correctness
  32715020428 are green. Card 8C now presents paged counts as lower bounds
  and clears a selection removed by authoritative replacement; Preview Retry is admitted
  only for typed transient/renderer failures; Details Pin/Unpin owns one
  pending intent; count retention has a running-app receipt/purge journey;
  capture item-ID collisions are rejected by pure Domain and retried eight
  bounded times by Storage; Authority corpus projection and all three search
  modes check cooperative cancellation at a 32-row cadence with a pre-yield
  publication fence. X.7
  external row/details wrappers carry authoritative Effective title and
  revision count into App Intents from one coherent projection. The panel now
  exposes Pause/Resume with baseline-on-resume privacy semantics, distinguishes
  denied access from empty History, and has running-app denied/recovery
  journeys. Additional bounded evidence covers
  negative-origin panel geometry, focus-loss/modal/reopen lifecycle, and the
  current treatment of unknown pasteboard bookkeeping UTIs. They do not prove
  real TCC/VoiceOver/FKA, Spaces/Stage Manager,
  signed runtime, client credential custody/transport, or arbitrary native
  matcher preemption inside one synchronous row evaluation.
