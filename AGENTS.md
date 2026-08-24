# AGENTS.md — Clipy (Greenfield Clipboard Manager for macOS)

Guidance for AI coding agents working in this repository. Read this before making
any change. The design documents under `docs/` are authoritative; this file is
only a map.

## 1. Project overview

Clipy is a **from-zero macOS clipboard-history application**, a greenfield
redesign implemented against a consolidated design specification in `docs/`
(`docs/00-overview.md` through `docs/06-cross-cutting.md`, plus `docs/roadmap/`
and the living status file `docs/PROGRESS.md`).

The v1 product captures clipboard values, coalesces repeat copies, lists and
searches retained history, pins and reorders items, removes or clears items,
appends immutable content revisions, produces paste payloads, and produces
thumbnails.

**Platform and toolchain:**

- macOS 26+ only (`platforms: [.macOS(.v26)]`), arm64.
- Swift 6 language mode with **complete strict concurrency** everywhere.
- SwiftPM owns the library graph (root `Package.swift`, swift-tools-version 6.2).
- XcodeGen owns the app target (`ClipyApp/project.yml`); the generated
  `.xcodeproj` is a build artifact — regenerate, never hand-edit.
- SwiftLint for custom architectural rules (`.swiftlint.yml`), mirrored by
  portable Python scans in `scripts/` so gates also run without SwiftLint.
- Building or testing the code requires a Mac with Xcode 26 / Swift 6.2. The
  Python source gates (`scripts/import_gate.py`, `scripts/escape_hatch_scan.py`)
  run on any platform; everything else (including
  `scripts/public_symbol_snapshot.sh`) needs macOS + `xcrun`.

**Current state (2026-08-24, `master` through PR #34):** steps 0–9 are
done and CI-green (scaffold + gates, `HistoryCore` public surface,
`HistoryDomain` pure core, dependency pins, schema v1 + codecs,
`HistoryAuthority` capture/mutations/reads/observation/thumbnail, product
wiring: PasteboardAdapter, PresentationUI, ClipyApp composition); the V2
M1 schema migration plus V2-02 retention slices R.1–R.6 are landed
(`docs/v2/V2-PROGRESS.md`). The 2026-08-22 REVIEW remediation is under
way: CI lane split (PR #2), normal-path correctness batches (PR #3–#7),
and the External Gateway ladder X.2–X.7 (public contract, V3 schema +
deny-by-default bootstrap, X.4 audit/admin substrate, X.5 denial/
admission, X-HCR V4 substrate + atomic-evidence proofs, X.6 positive
reads/writes + the public connection-bound `ExternalHistoryFacade`, and
X.7 App Intents composition — six intents behind one async app-owned ingress
provider registered before store open; it contains the one connection-bound
facade and joins positive external removal to the existing panel purge owner,
`supportedModes = [.background]`,
output-only entities, no `EntityQuery`, confined to `ClipyApp/Sources`).
`DEC-RET-READ` and its bounded Settings consumer/persistent readback closure
landed in PR #32 (merge `1c221e6`; master run 32678654503).
`DEC-PREVIEW-TARGET` and the concrete package-only `ContentPreview` deep
module landed in PR #33 (merge `ffd0e9f`; final PR run 32682438863; master
run 32682682345).
GOV-1's manual exact/scale caller landed in PR #34 (merge `f48d87f`; PR run
32684566664; master run 32684916238). Its same-SHA manual run 32685185124 has
Exact A/B green with all 13 thresholds passing and scale evidence still in
progress. Batch 33 is implementing Card 9B external-remove purge plus bounded
Card 15C/15D accessibility leaves; treat those source changes as unlanded
until their PR and master correctness runs are recorded.
Both dispatch-only physical-evidence cells are green on `master` as of
2026-08-23: the General pasteboard cross-process run 32632263996 and the
Card 6B APFS ENOSPC capture-transaction run 32636093920 (the latter via
the §16 stamped-plan capacity admission added in PR #25 — Core Data
raises an uncatchable `NSInternalInconsistencyException` instead of an
out-of-space error when an external-storage interim file cannot be
created on a full volume). Manual signed-runtime run 32573198119 is also
green on `master`, within the bounded proof scope described in §7.
Post-step-9 additions: the perf/AB helper proofs live in the separate
`HistoryPerfTests` target/lane (the default `swift test` skips them), and the
panel is a Maccy-style AppDelegate-owned floating `NSPanel` (Carbon ⇧⌘C
summon, cursor/status-item/center/last-position placement, dwell-driven
preview pane) — no longer a SwiftUI `MenuBarExtra` window.
Always check `docs/PROGRESS.md` and the REVIEW ledger
(`docs/reviews/2026-08-22-clipy-maccy-deep-review/10-implementation-status.md`)
for the exact landed state before assuming a feature exists.

## 2. Architecture and module layout

Downward-only dependency graph; one public History boundary. The public seam is
the `ClipboardHistory` protocol in `HistoryCore` (`Sources/HistoryCore/
ClipboardHistory.swift`). Callers express a `HistoryAction` or request
purpose-specific DTOs; they never see SwiftData, Domain state, fingerprints, or
canonical content internals.

```text
ClipyApp (XcodeGen app, composition root)
├── PresentationUI ────────→ HistoryCore + ClipboardFormats + ContentPreview
├── PasteboardAdapter ─────→ HistoryCore
└── HistoryStorage ────────→ HistoryCore + ClipboardFormats
          │                → HistoryDomain
          ├───────────────→ xxh3 (vendored C, package-internal)
          └───────────────→ Fuse (external SPM, fuzzy search)
HistoryDomain ─────────────→ HistoryCore
ClipboardFormats ──────────→ Foundation only (package-only stable facts)
ContentPreview ────────────→ ClipboardFormats + CoreGraphics + ImageIO
                             (package-only bounded transient renderer)
ClipyCLIContract ──────────→ Foundation only (package-only pure wire contract)
HistoryRestartProbe ───────→ HistoryCore + HistoryStorage (test evidence only)
```

| Target | Surface | Role |
|---|---|---|
| `ClipboardFormats` | Package-only, Foundation-only | Open-world exact identifiers and declared string-codec facts; no purpose policy, registry, plugin, cache, or decoder |
| `ContentPreview` | Package-only concrete actor/values | Exact preview source selection, fixed resource profiles, text codecs, eager ImageIO decode, bounded inert text/BGRA8 artifacts; no History/reference/lifecycle/cache/plugin ownership |
| `ClipyCLIContract` | Package-only, Foundation-only, no product | X.8 bounded UTF-8 JSON request/reply codec and stable exit classes; no executable, standard-stream I/O, transport, credential, Gateway/History access, or fabricated result |
| `HistoryCore` | Public, Foundation-only | `ClipboardHistory` protocol, IDs/tokens, closed `HistoryAction` set, request/response DTOs, receipts, typed failures, `HistoryLimits.standard` |
| `HistoryDomain` | `package` access, Foundation-only, pure | Content lineage, complete action facts, seven pure planners, typed mutation plans. No I/O, actors, clocks, UUID/Date generation, or async |
| `HistoryStorage` | Public concrete `SwiftDataHistory` + internal implementation | Sole SwiftData authority, schema/codecs, `HistoryAuthority` actor (single writer), fact loaders, Signature Index, read projections, observation plumbing, thumbnail single-flight |
| `PasteboardAdapter` | Public adapter | NSPasteboard observation/writes ↔ `HistoryCore` raw values. No Domain state, no fingerprints |
| `PresentationUI` | Public UI | SwiftUI view state over `HistoryCore` DTOs plus ContentPreview artifacts; owns exact-reference/task/lifecycle fences, never ImageIO decode |
| `ClipyApp` | Composition root | Concrete construction, lifecycle, paste orchestration, App Intents entry points, DI |
| `xxh3` | Package-internal C | 64-bit representation fingerprints (vendored xxHash v0.8.3) |
| `HistoryPerfRunner` | Executable | Part VI §9 performance-runner scaffold (fixtures populate at step 8) |
| `HistoryRestartProbe` | Test evidence executable target | Card 1C-1 three-process public-API restart tracer; no declared package product |

**Load-bearing rules (docs/01-architecture.md §3/§6/§8):**

- Single write authority: `HistoryAuthority` is the only component that creates
  or uses writable `ModelContext`s; one fresh context per isolated operation,
  `ModelContext.transaction` is the sole commit primitive.
- Only immutable `Sendable` values cross module/actor boundaries. `@Model`,
  `ModelContext`, `PersistentIdentifier`, `NSImage`, `CGImage` never cross.
- Only `HistoryCore` (plus the `SwiftDataHistory` constructor and adapter/UI
  entry points) is `public`. Cross-target implementation vocabulary uses Swift
  `package` access. `@Model` types are internal to `HistoryStorage`.
- Accessing a closed `HistoryAction` set: adding an action is an owned source
  change and must make compiler-exhaustive switches fail until handled.
- No application-owned `.shared`/`.current` service locators, no
  `@unchecked Sendable`, no `nonisolated(unsafe)` — enforced by gates (§4).
  The only framework-owned exception is one composition-root
  `AppDependencyManager.shared.add(dependency:)` registration; hosted tests use
  standalone `AppDependencyManager()` instances.
- Two-stage dedup: xxh3 signature candidates, then byte-exact confirmation; a
  fingerprint is evidence, never identity. `HistoryItemID` is independent of
  SwiftData identity and content hashes.
- Coherence tokens: `ContentVersion` advances only when Effective Content bytes
  change; `ChangePosition` advances exactly once per non-empty History Commit.
  Observation returns authoritative snapshots (state, not event deltas).

## 3. Repository layout

```text
Package.swift                 SwiftPM manifest (the single target-graph truth)
.swiftlint.yml                custom architectural lint rules (mirror of scripts/)
Sources/<Target>/             one dir per SwiftPM target
Sources/xxh3/                 vendored xxHash C source (+ VENDORED.md pin record)
Tests/<Target>Tests/          SwiftPM test targets mirroring each library
Tests/HistoryCoreTests/SymbolSurface/HistoryCore.symbols.txt   public symbol snapshot
ClipyApp/                     XcodeGen spec, app sources, hosted integration tests
docs/                         the design specification (00–06), AUDIT.md, PROGRESS.md
docs/roadmap/                 implementation roadmap, one doc per module
scripts/                      gate scripts (see below)
.github/workflows/            correctness, manual/reusable performance
                              evidence, symbol-snapshot workflows
```

## 4. Build, gate, and test commands

All Swift/Xcode commands require **macOS 26 arm64 with Xcode 26** (the CI
runner image; enforced in every workflow job).

```sh
# Source gates (import confinement, escape hatches, symbol snapshot)
bash scripts/run_gates.sh               # full local gate set
bash scripts/run_gates.sh --source-only # CI source lane; avoids a duplicate build

# SwiftLint (macOS, same rules as the gates)
swiftlint lint --strict --no-cache

# SwiftPM build + test (Swift 6 strict concurrency)
swift build
swift test                                    # default lane: functional tests only (skips HistoryPerfTests)
swift test --filter 'HistoryPerfTests\.'      # local performance helper suite

# HistoryCore public symbol snapshot (macOS only)
bash scripts/public_symbol_snapshot.sh            # check
bash scripts/public_symbol_snapshot.sh --update   # regenerate after intentional change

# App project (macOS only)
xcodegen generate --spec ClipyApp/project.yml     # or bash scripts/generate-xcodeproj.sh
xcodebuild -project ClipyApp/ClipyApp.xcodeproj -scheme ClipyApp \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO test

# Manual Release runtime evidence (ad-hoc signature only; macOS CI equivalent)
bash scripts/ci/run_signed_runtime.sh \
  signed-runtime-logs DerivedData-SignedRuntime \
  "${TMPDIR:-/tmp}/xcodegen-2.45.4"
```

**Gate semantics:**

- `scripts/evidence_workflow_gate.py` — protects the GOV-1 CI policy that was
  lost in the original workflow split: one `workflow_dispatch`-only caller
  invokes same-SHA reusable correctness before the exact-matcher and scale
  evidence siblings, never cancels an active evidence run, and retains the
  Actions-owned 1,000/5,000-row plus measurement-stage liveness guards.
- `scripts/import_gate.py` — per-target import confinement (Part I §8):
  `ClipboardFormats` and `ClipyCLIContract` → Foundation only;
  `ContentPreview` → Foundation + ClipboardFormats + CoreGraphics + ImageIO;
  `HistoryCore` → Foundation only;
  `HistoryDomain` → Foundation + HistoryCore;
  `HistoryStorage` must not import AppKit/SwiftUI/adapters/PresentationUI;
  `PasteboardAdapter` must not import HistoryDomain/HistoryStorage/SwiftUI/
  SwiftData; `PresentationUI` must not import HistoryDomain/HistoryStorage/
  AppKit/SwiftData/ImageIO; `HistoryRestartProbe` → Foundation + HistoryCore +
  HistoryStorage only; `xxh3` and `Fuse` are confined to `HistoryStorage`;
  `AppIntents` is confined to `ClipyApp/Sources` and the hosted
  `ClipyIntegrationTests`. Import attributes such as `@preconcurrency` and
  access-level imports are parsed and cannot evade the gate. The scan covers
  SwiftPM sources plus XcodeGen-owned app sources and app test targets.
  `.swiftlint.yml` mirrors these; keep both in sync when changing rules.
- `scripts/escape_hatch_scan.py` — rejects `@unchecked Sendable`,
  `nonisolated(unsafe)`, and `static let/var shared|current` in SwiftPM and
  `ClipyApp` sources/tests. It also requires exactly one framework-owned
  `AppDependencyManager.shared.add(dependency:)` call at
  `ClipyApp/Sources/AppIntents/AppIntentDependencyRegistration.swift` and
  rejects shared-manager access everywhere else, including hosted tests.
- `scripts/public_symbol_snapshot.sh` — diffs the extracted public symbol graph
  of `HistoryCore` against `Tests/HistoryCoreTests/SymbolSurface/
  HistoryCore.symbols.txt`. Snapshot content is runner-derived: if it drifts
  unintentionally on CI, regeneration happens via the dispatch-only
  `.github/workflows/symbol-snapshot.yml` (bot commit), not a local edit.

**Do not add useless hashes.** CI orchestration, generated-project
repeatability, change detection, cache coordination, artifact naming, test
selection, and agent handoff must not introduce SHA/checksum/content-hash
steps or hash-derived state. Compare the actual files or directories directly
(`diff`, `cmp`, or the owning tool's native validation), and use explicit
versions and typed state. A new integrity hash is allowed only when an
authoritative design document requires that exact security property and the
user explicitly approves the new boundary. The existing package-internal xxh3
fingerprint is a product-domain dedup candidate filter only; it is never
identity and must not be reused as CI or infrastructure machinery.

**Do not over-design defensively.** Add a guard only for a repository rule, an
observed failure, or a concrete failing fixture. Do not build speculative
scanners, protocol layers, state machines, fallback paths, or duplicated gates
for hypothetical future risks. Prefer the smallest direct check at the owning
boundary, and delete a guard when the underlying failure mode no longer exists.

**Compiler warnings are CI failures.** SwiftPM logs are scanned for diagnostics;
the two XcodeGen-owned app/test targets set Swift and Clang warnings as errors
without forcing those settings onto external package targets. Runtime framework
logs are not parsed as compiler output. Write warning-free code.

## 5. Code style guidelines

- Swift 6 mode, complete strict concurrency, zero warnings. Design for
  actor isolation explicitly; the greenfield targets ban every escape hatch.
- Access control discipline: `public` only for the caller-visible seam;
  `package` for cross-target implementation vocabulary; `internal`/`private`
  inside storage. `@Model` types stay internal to `HistoryStorage` and never
  appear in a `public` or `package` signature.
- Foundation-only in `HistoryCore` and `HistoryDomain`. Domain code is pure:
  no I/O, no actors, no clocks, no UUID/Date generation, no async — clocks and
  ID sources are package-only injected dependencies.
- Match the spec's vocabulary (`HistoryAction`, `HistoryCommit`,
  `ChangePosition`, `Effective Content`, `CanonicalContent`, `StampedPlan`,
  `DomainRejection`, …) instead of inventing synonyms.
- Comments in this repo are dense and cite spec sections (e.g. `05 §9`,
  `02 §5.4`). Follow that convention when changing behavior-bearing code.
- Traceability: commits/PRs cite the roadmap module doc, the spec section, and
  the WS gate or Part VI proof they serve (`docs/roadmap/README.md` §4).

## 6. Testing instructions

- Test framework: Swift Testing (`swift test`), test targets mirror owners:
  `HistoryCoreTests`, `HistoryDomainTests`, `HistoryStorageTests`,
  `ContentPreviewTests`,
  `PasteboardAdapterTests`, `PresentationUITests` (SwiftPM), plus
  `ClipyIntegrationTests` hosted by the app (XcodeGen-only, not in
  `Package.swift`). `HistoryPerfTests` (SwiftPM) holds the perf/AB
  measurement-helper proofs for the `HistoryPerfRunner` executable; the
  PR/push correctness lane skips it (`--skip 'HistoryPerfTests\.'`). Its
  reusable workflow is dormant until a future correctness-gated caller is
  deliberately added.
- Persistence tests use the real `SwiftDataHistory` with an **in-memory**
  `ModelContainer` — there is no second fake writer implementation. A scripted
  `ClipboardHistory` double is allowed only for SwiftUI previews, never as a
  substitute for storage semantic tests.
- Determinism: a package-only forced-collision fingerprint double
  (`Tests/HistoryStorageTests/Fixtures/ForcedCollisionFingerprint.swift`) drives
  dedup-collision tests; a deterministic concurrency harness +
  transaction-injection seam (`Tests/HistoryStorageTests/ConcurrencyHarness/`)
  drives ordering proofs.
- Tests that create temp on-disk stores must create the store directories
  upfront to keep CoreData file-status noise out of CI log scans.
- Walking-skeleton gates WS1–WS21 (`docs/06-cross-cutting.md` §8) and Part VI
  proofs (§7.x) name the acceptance tests per roadmap step; WS test files are
  named `WS<N>…Tests.swift`. Roadmap steps 5–6 close commit-side clauses;
  read/observation clauses close at step 7.
- `Tests/HistoryCoreTests/SymbolSurface/` is excluded from compilation via the
  target `exclude` in `Package.swift` — keep that exclude intact.

## 7. CI and deployment

- `.github/workflows/correctness.yml` is the only push/PR workflow. It has
  three jobs: **Lint + source gates**, **SwiftPM build + test**, and
  **XcodeGen generate + app build/test**. Job steps delegate to `scripts/ci/`
  so the same commands are reproducible without copying shell across YAML.
- The exact-matcher and scale-admission workflows remain reusable
  `workflow_call` modules and run only through the dedicated manual
  `workflow_dispatch` caller after same-SHA correctness succeeds. They never
  run on push or pull request. The performance helper/proof workflow remains
  reusable-only with no caller.
- `scripts/diagnostic_scan.py` owns the narrow log profiles. Every macOS job
  invokes the shared macOS 26/arm64 runner contract.
- `.github/workflows/symbol-snapshot.yml` is `workflow_dispatch`-only and
  bot-commits a regenerated HistoryCore symbol snapshot. Bot pushes do not
  re-trigger CI; the snapshot is enforced by the SwiftPM correctness job on
  subsequent pushes.
- `.github/workflows/signed-runtime.yml` is `workflow_dispatch`-only. It builds
  the Release app once, applies and verifies a local ad-hoc signature carrying
  the Hardened Runtime flag, rejects iCloud/ubiquity entitlements in that exact
  signed artifact, and runs a direct process-lifecycle smoke. It does **not**
  prove Developer ID identity, secure timestamp, notarization/stapling,
  Gatekeeper, TCC, login-item, Carbon/status-item, Space, or WindowServer
  behavior; those remain state-3 distribution/manual cells.
- There is no release/deployment pipeline yet. The product-wired app remains
  short of Part VI §11 "state 3": packaging, accessibility, localization, and
  the distribution/manual acceptance cells are still open.

## 8. Dependencies and pins

- **xxHash v0.8.3** vendored in `Sources/xxh3/` behind `clipy_xxh3_64bits`;
  pin recorded in `Sources/xxh3/VENDORED.md`. Package-internal, no product.
- **Fuse 1.4.0** pinned by exact revision
  (`26ba868691b2d8b7bf2b1322951eb591be70ccca`) in `Package.swift` — the
  2.0.0-rc.x pre-release is deliberately **not** used (`docs/AUDIT.md` §4b).
  Confined to `HistoryStorage` (inside the `SearchWorker` actor).
  Note: `maxPatternLength` is a dead parameter in Fuse 1.4.0, so the
  64-character fuzzy-query bound (Fuse 1.4.0's single-`Int` bitap ceiling) is
  enforced by `SearchWorker` itself.
- Neither dependency may appear in a public signature.
- No other third-party dependencies. Do not add any without a design-doc change
  (`docs/roadmap/07-external-deps.md`).

## 9. Security and data-safety considerations

- Clipboard content is sensitive: `HistoryCore`/`HistoryDomain` handle raw
  bytes only as `Data` values; large blobs use `.externalStorage` attributes in
  the SwiftData schema; content blobs must not cross actor boundaries as
  anything but immutable `Sendable` values.
- The four versioned blob codecs (`CanonicalBlobV1`, `SignatureBlobV1`,
  `EffectiveTypeIdentifiersBlobV1`, `RevisionStateBlobV1`) decode with
  exhaustive checks and **fail closed** (`CodecRejection` → typed persistence
  failure). Preserve that behavior; never silently ignore decode anomalies.
- No network access, no external services, no telemetry anywhere in v1.
- The banned-construct scans (§4) are a hard safety boundary — do not weaken
  them, and do not work around a gate by reformatting code to evade a regex.

## 10. Where to look before changing things

- `docs/00-overview.md` — v1 truth: what is included/excluded, load-bearing
  decisions, spec precedence.
- `docs/01-architecture.md` — target graph, isolation model, forbidden
  dependencies, build-time gates.
- `docs/02-domain.md` … `docs/06-cross-cutting.md` — per-part semantics.
- `docs/roadmap/README.md` §3 — implementation order and step status.
- `docs/PROGRESS.md` — landed steps, CI evidence, notable deviations, and open
  spec questions (e.g. the pin-ordinal compaction question flagged for step 6).
- `docs/AUDIT.md` — design audit history; behavior changes may need a §3 entry.
- `docs/reviews/2026-08-22-clipy-maccy-deep-review/10-implementation-status.md`
  — the REVIEW implementation ledger. Check it before taking a review card;
  update the affected row in the same PR so completed leaves are not repeated.
- `docs/reviews/2026-08-22-clipy-maccy-deep-review/11-ai-todo-map-2026-08-23.md`
  — AI-generated point-in-time audit + todo map (2026-08-23, baseline
  `cda2ba0` → `a3e6774`). Not a live ledger; when it drifts, the ledger and
  owning specs win.
