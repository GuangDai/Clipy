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

**Audit baseline:** `8f316c9` (2026-08-02). **Verified remediation code
head:** `2fb7845` (2026-08-11). Steps 0–8 are implemented and M2/state 2 is
complete; step 9 (product wiring), M3, and state 3 are not started.
Public-symbol workflow
[31448087991](https://github.com/GuangDai/Clipy/actions/runs/31448087991)
is green. Final code-head run
[31449682036](https://github.com/GuangDai/Clipy/actions/runs/31449682036)
passed all source/lint gates, Swift 6 strict-concurrency builds, 314 tests in 41
suites, generated-app build/test, all 13 release workloads, and the workflow's
diagnostic self-scans. No unexcluded warning/error diagnostic remained; the
narrow AppIntents-metadata and headless `com.apple.linkd.autoShortcut`
exclusions remain documented in the workflow history below.

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
  closing the D1–D19 M2 acceptance item. No I/O, actor, clock, UUID/Date
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
  222-ID status ledger: 110 fixed, 32 deferred, 31 duplicate, 30 not-a-defect,
  19 documented, and no active or pending rows.
- **Domain:** 47 direct tests exercise all seven planners across commit/no-op,
  rejection, capacity, deterministic ordering, and complete mutation payloads;
  the suite records the exact D1–D19 ownership split.
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
  snapshot is enforced by the gates job on every subsequent push, including
  final code-head run 31449682036.
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

- **Status:** in progress. The canonical 222-row ledger currently has one
  reopened `in-progress` item; broader measurement-gated work remains
  explicitly deferred until supported admission evidence exists.
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
  Supported green CI remains before the canonical finding becomes `fixed`.
