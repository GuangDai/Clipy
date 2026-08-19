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

**Current state (2026-08-19, branch `codex/v2-implementation`):** steps 0–8
are done and CI-green (scaffold + gates, `HistoryCore` public surface,
`HistoryDomain` pure core, dependency pins, schema v1 + codecs,
`HistoryAuthority` capture/mutations/reads/observation/thumbnail), and the V2
M1 schema migration plus V2-02 retention slices R.1–R.6 are landed
(`docs/v2/V2-PROGRESS.md`). Step 9 (product wiring: PasteboardAdapter,
PresentationUI, ClipyApp composition) is **implemented locally and awaiting
its first commit + macOS CI run** — the menu-bar panel (search/pin/reorder/
remove/clear), details + revise editor, unified retention settings (v1 count +
V2-02 age/storage/revision dimensions), pasteboard capture/paste round-trip,
and the WS1–WS21 composed re-verification in `ClipyIntegrationTests` are
written and pass the Python source gates, but have not yet compiled on a Mac.
Always check `docs/PROGRESS.md` for the exact landed state before assuming a
feature exists.

## 2. Architecture and module layout

Downward-only dependency graph; one public History boundary. The public seam is
the `ClipboardHistory` protocol in `HistoryCore` (`Sources/HistoryCore/
ClipboardHistory.swift`). Callers express a `HistoryAction` or request
purpose-specific DTOs; they never see SwiftData, Domain state, fingerprints, or
canonical content internals.

```text
ClipyApp (XcodeGen app, composition root)
├── PresentationUI ────────→ HistoryCore
├── PasteboardAdapter ─────→ HistoryCore
└── HistoryStorage ────────→ HistoryCore
          │                → HistoryDomain
          ├───────────────→ xxh3 (vendored C, package-internal)
          └───────────────→ Fuse (external SPM, fuzzy search)
HistoryDomain ─────────────→ HistoryCore
```

| Target | Surface | Role |
|---|---|---|
| `HistoryCore` | Public, Foundation-only | `ClipboardHistory` protocol, IDs/tokens, closed `HistoryAction` set, request/response DTOs, receipts, typed failures, `HistoryLimits.standard` |
| `HistoryDomain` | `package` access, Foundation-only, pure | Content lineage, complete action facts, seven pure planners, typed mutation plans. No I/O, actors, clocks, UUID/Date generation, or async |
| `HistoryStorage` | Public concrete `SwiftDataHistory` + internal implementation | Sole SwiftData authority, schema/codecs, `HistoryAuthority` actor (single writer), fact loaders, Signature Index, read projections, observation plumbing, thumbnail single-flight |
| `PasteboardAdapter` | Public adapter | NSPasteboard observation/writes ↔ `HistoryCore` raw values. No Domain state, no fingerprints |
| `PresentationUI` | Public UI | SwiftUI view state over `HistoryCore` DTOs only |
| `ClipyApp` | Composition root | Concrete construction, lifecycle, paste orchestration, DI |
| `xxh3` | Package-internal C | 64-bit representation fingerprints (vendored xxHash v0.8.3) |
| `HistoryPerfRunner` | Executable | Part VI §9 performance-runner scaffold (fixtures populate at step 8) |

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
- No `.shared`/`.current` service locators, no `@unchecked Sendable`, no
  `nonisolated(unsafe)` — enforced by gates (§4).
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
.github/workflows/            macos26-arm-ci.yml, symbol-snapshot.yml
```

## 4. Build, gate, and test commands

All Swift/Xcode commands require **macOS 26 arm64 with Xcode 26** (the CI
runner image; enforced in every workflow job).

```sh
# Source gates (import confinement, escape hatches, symbol snapshot)
bash scripts/run_gates.sh          # gates 1–2 run anywhere; gate 3 needs macOS+xcrun

# SwiftLint (macOS, same rules as the gates)
swiftlint lint --strict --no-cache

# SwiftPM build + test (Swift 6 strict concurrency)
swift build
swift test

# HistoryCore public symbol snapshot (macOS only)
bash scripts/public_symbol_snapshot.sh            # check
bash scripts/public_symbol_snapshot.sh --update   # regenerate after intentional change

# App project (macOS only)
xcodegen generate --spec ClipyApp/project.yml     # or bash scripts/generate-xcodeproj.sh
xcodebuild -project ClipyApp/ClipyApp.xcodeproj -scheme ClipyApp \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO clean build test
```

**Gate semantics:**

- `scripts/import_gate.py` — per-target import confinement (Part I §8):
  `HistoryCore` → Foundation only; `HistoryDomain` → Foundation + HistoryCore;
  `HistoryStorage` must not import AppKit/SwiftUI/adapters/PresentationUI;
  `PasteboardAdapter` must not import HistoryDomain/HistoryStorage/SwiftUI/
  SwiftData; `PresentationUI` must not import HistoryDomain/HistoryStorage/
  AppKit/SwiftData; `xxh3` and `Fuse` are confined to `HistoryStorage`.
  `.swiftlint.yml` mirrors these; keep both in sync when changing rules.
- `scripts/escape_hatch_scan.py` — rejects `@unchecked Sendable`,
  `nonisolated(unsafe)`, and `static let/var shared|current` in `Sources/` and
  `Tests/`.
- `scripts/public_symbol_snapshot.sh` — diffs the extracted public symbol graph
  of `HistoryCore` against `Tests/HistoryCoreTests/SymbolSurface/
  HistoryCore.symbols.txt`. Snapshot content is runner-derived: if it drifts
  unintentionally on CI, regeneration happens via the dispatch-only
  `.github/workflows/symbol-snapshot.yml` (bot commit), not a local edit.

**SwiftPM warnings are CI failures.** CI self-scans build/test logs for any
`warning:`/`error:` line (with a narrow AppIntents-metadata exclusion on the app
job). Write warning-free code; `swift build` and `swift test` must produce zero
warnings.

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
  `PasteboardAdapterTests`, `PresentationUITests` (SwiftPM), plus
  `ClipyIntegrationTests` hosted by the app (XcodeGen-only, not in
  `Package.swift`).
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

- `.github/workflows/macos26-arm-ci.yml` (push/PR to `master`, macos-26 arm64
  runners) has three jobs: **Lint + source gates** (gates + SwiftLint strict),
  **SwiftPM build + test**, **XcodeGen generate + app build/test** (generation
  is run twice and diffed for repeatability). Every job enforces the macOS
  26.x / arm64 runner and fails on any warning/error line in logs.
- `.github/workflows/symbol-snapshot.yml` is `workflow_dispatch`-only and
  bot-commits a regenerated HistoryCore symbol snapshot. Bot pushes do not
  re-trigger CI; the snapshot is enforced by the gates job on subsequent pushes.
- There is no release/deployment pipeline yet: the app is a step-0 scaffold
  (`LSUIElement` agent stub, placeholder window). Packaging, accessibility,
  and localization are Part VI §11 "state 3" acceptance, outside the current
  roadmap.

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
