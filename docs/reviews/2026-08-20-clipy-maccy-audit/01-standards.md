# Engineering standards review

> Review axis: repository standards, architecture boundaries, concurrency,
> persistence safety, source/CI gates, test ownership, and code smells.
>
> Review started: **2026-08-20T00:09:08Z (UTC)**
>
> Review ended: **2026-08-20T00:28:59Z (UTC)**
>
> Reviewer environment: Linux 6.18 x86_64. No Swift, `xcrun`, Xcode,
> `xcodebuild`, or SwiftLint was available; no Swift/Xcode build was attempted.
>
> Mutation policy: read-only review. The only file created by this reviewer is
> this report. No source, test, workflow, configuration, existing specification,
> or status file was changed.

This is the **Standards** axis of the larger Clipy/Maccy audit. It does not make
the cross-product feature or benchmark verdict; those belong to the sibling
specification, Apple-platform, performance, and comparison reports. UI findings
are explicitly snapshot-scoped because the UI changed while this review was in
progress.

## 1. Pinned comparison and moving snapshots

The requested fixed point resolved as follows:

- `master`: `dfb08f2d67fb611eec3fa80db2d6a0a63896f139`
- merge-base of `master` and the initial head: the same
  `dfb08f2d67fb611eec3fa80db2d6a0a63896f139`
- initial head at review start: `61b418bf9b9767ac84f81da3e65cfe447a509cbd`
- branch: `codex/v2-implementation`
- primary committed comparison: `git diff master...61b418bf9b9767ac84f81da3e65cfe447a509cbd`
- commit enumeration: `git log master..61b418bf9b9767ac84f81da3e65cfe447a509cbd --oneline`
  returned **58 commits**.

That initial three-dot diff covered 128 paths, approximately 27,208 insertions
and 303 deletions. At review start, `git diff HEAD`, `git diff --cached HEAD`,
`git status --short --untracked-files=all`, and every untracked Swift source/test
were also inspected. The index contained only two staged 100%-similar renames
from `Tests/HistoryPerfRunnerTests/` to `Tests/HistoryPerfTests/`; the matching
manifest/workflow/docs edits were initially unstaged. That staging split was a
transient commit-safety hazard, not a defect in the combined tree, and was
resolved by the later UI commit.

The concurrent UI work produced two additional committed snapshots:

1. At **2026-08-20T00:16:36Z**, `a028c8c579b365f6c2183c5042ee78a365553d2a`
   landed the dirty UI tree plus concurrent additions. The explicit comparison
   `git diff 61b418b..a028c8c` covered 27 paths, 2,406 insertions and 208
   deletions. `git diff --check` was clean.
2. At **2026-08-20T00:21:44Z**, `9c6e3b48f1bbf0c642ccbb61b233319003b6fefb`
   changed only `PreviewContent.textCharacterCap` from internal to `package` so
   the in-package tests compile. The comparison was inspected separately.

The final implementation snapshot for this report is therefore
`9c6e3b48f1bbf0c642ccbb61b233319003b6fefb`, while the requested 58-commit
review remains pinned to `61b418b` and the two UI deltas are called out rather
than silently folded into it.

At the initial snapshot, the untracked implementation files later captured by
`a028c8c` were:

```text
ClipyApp/Sources/AppDelegate.swift
ClipyApp/Sources/HotKey/GlobalHotKey.swift
ClipyApp/Sources/Panel/FloatingPanel.swift
ClipyApp/Sources/Panel/PanelRootView.swift
ClipyApp/Sources/Panel/PopupPositionGeometry.swift
ClipyApp/Tests/ClipyIntegrationTests/PanelAndHotKeyTests.swift
ClipyApp/Tests/ClipyIntegrationTests/SmokeMeasurementTests.swift
Sources/PresentationUI/HistoryPreviewView.swift
Sources/PresentationUI/PanelGeometry.swift
Sources/PresentationUI/PopupPositionMode.swift
Sources/PresentationUI/PreviewPaneState.swift
Tests/PresentationUITests/PreviewContentTests.swift
Tests/PresentationUITests/PreviewPaneStateTests.swift
```

The audit directory's `README.md` was separately created by the orchestrating
review and is not implementation input.

## 2. Standards and checks applied

Repository standards were read from:

- `AGENTS.md`
- `.swiftlint.yml`
- `scripts/import_gate.py`
- `scripts/escape_hatch_scan.py`
- `Package.swift`
- `ClipyApp/project.yml`
- `docs/00-overview.md`
- `docs/01-architecture.md`
- `docs/04-coherence.md`
- `docs/06-cross-cutting.md`
- `docs/roadmap/README.md`
- `docs/roadmap/03-historystorage.md`
- `docs/roadmap/04-pasteboardadapter.md`
- `docs/roadmap/05-presentationui.md`
- `docs/roadmap/06-clipyapp.md`
- `docs/v2/V2-02-retention.md`, `V2-04-materialization.md`,
  `V2-07-ux.md`, `V2-roadmap.md`, and `V2-PROGRESS.md`.

The `code-review` skill's Standards process and Fowler smell baseline were
applied. Repo-specific standards take precedence; smells below are explicitly
judgement calls, never violations.

At **2026-08-20T00:22:59Z**, on `9c6e3b4` plus only audit-document changes:

```text
import_gate: OK — 106 Swift files, no violations
escape_hatch_scan: OK — 207 Swift files, no banned constructs
git diff --check 61b418b..HEAD: clean
git diff --check HEAD: clean
```

Both scripts' self-tests also passed earlier in the review. A manual all-Swift
scan, including `ClipyApp/Sources` and `ClipyApp/Tests`, found no
`@unchecked Sendable`, `nonisolated(unsafe)`, or `static let/var shared|current`.

These green source gates do **not** clear findings S-2 and S-4: S-2 is omitted
from the import-rule tables, and S-4 is a semantic failure in the workflow's
own log filter.

## 3. Documented-standard findings

### S-1 — High — `RetainedBytesRow` accepts impossible scalars instead of failing closed

**Classification:** hard violation; committed at the initial `61b418b` snapshot.

`docs/v2/V2-02-retention.md:450-453` defines `canonicalBytes`,
`revisionCount`, and `revisionBytes` as counts/sums. Its projection-coherence
rule at line 462 says an inconsistent scalar must fail closed and must never be
used as a stale byte fact. `docs/06-cross-cutting.md:56-64` also requires bounded,
non-wrapping byte arithmetic.

The read boundary does not enforce even the scalar-only invariants:

- `Sources/HistoryStorage/RetentionConfigLoading.swift:193-235` fetches all
  three values, checks only row count, schema version, and duplicate item ID,
  then copies the `Int`s directly into planning facts.
- `Sources/HistoryStorage/RetainedBytesStamping.swift:397-436` performs the
  startup 1:1 check with only `itemID` and `bytesSchemaVersion`; a version-1
  row with negative or above-hard-bound values opens successfully.
- `Sources/HistoryDomain/PlannersRetentionExpansion.swift:142-153` then treats
  the sum as the authoritative R2 total. A row with `canonicalBytes == -1`
  and `revisionBytes == 0` yields a negative footprint, so a positive byte
  budget appears satisfied with no error. Conversely, an impossible huge
  value can cause valid items to be retired.
- `Sources/HistoryStorage/RetentionPolicySweep.swift:196-203` uses negative
  `revisionCount`/`revisionBytes` as “not exceeding”, so R3 skips the lineage
  decode that could have exposed the mismatch.
- The checked helpers at
  `Sources/HistoryDomain/PlannersRetentionExpansion.swift:297-319` detect
  machine overflow, not negative or semantically impossible input. The comment
  at lines 314-316 even mentions a corrupt negative scalar, but ordinary
  subtraction involving a negative does not set the overflow flag.

This is data-safety relevant: local store corruption can silently under-retain
or over-delete clipboard history instead of returning
`.persistence(.invariantViolation)`. Existing corruption coverage in
`RetainedBytesProjectionLifecycleTests.swift:407-476` exercises missing,
orphan, and unknown-version rows, but no negative/over-bound scalar matrix.

The minimum proof obligation is scalar-only validation before constructing
`ProjectedItemScalars` (nonnegative values, per-field hard bounds, and structural
relationships such as zero revisions implying zero revision bytes), plus
corruption fixtures on every R1/R2/R3 consumer. Exact in-range blob/projection
mismatch remains a separate design limitation of the deliberate zero-decode R2
lane and should be stated honestly rather than implied to be universally
detected.

### S-2 — High — PresentationUI owns ImageIO decode on the MainActor, and the gates miss it

**Classification:** hard violation; one occurrence is committed before the UI
delta, and `a028c8c` adds a second.

The direct standards are unambiguous:

- `docs/01-architecture.md:81-86` assigns the one v1 ImageIO decoder to the
  internal `HistoryStorage` thumbnail implementation.
- `docs/01-architecture.md:182-197` says the MainActor performs no image decode
  and assigns decode/downsample to `ThumbnailWorker`.
- `docs/roadmap/03-historystorage.md:51` says “ImageIO only here.”
- `docs/v2/V2-07-ux.md:906-912` explicitly forbids ImageIO in
  `PresentationUI` under `UX-COMPILE-1`.
- `AGENTS.md:88-92` forbids `CGImage` crossing the public module/actor boundary.

Contrary code:

- `Sources/PresentationUI/ThumbnailStore.swift:15,21-29,113-124,163-167`
  imports ImageIO and decodes the returned PNG into `CGImage` in a
  `@MainActor` type. `image(for:)` at line 92 is public and returns `CGImage`,
  even though its consumers are internal PresentationUI views.
- `a028c8c` adds
  `Sources/PresentationUI/HistoryPreviewView.swift:12-16,160-197`, which
  performs a second ImageIO source decode/downsample synchronously on the UI
  rendering path from full Effective Content bytes.

The portable gate passed while scanning both files because
`scripts/import_gate.py:60-64` and `.swiftlint.yml:69-75` omit ImageIO from the
PresentationUI blocklist and provide no global ImageIO-owner rule. Thus the
documented compile gate currently proves less than the specification says.

This should be resolved as an ownership decision, not papered over: either keep
ImageIO/decode in the specified background owner and make the UI consume a
renderable, bounded result without a public `CGImage` seam, or amend the
architecture, isolation rule, and both gates with an explicit, measured UI
decode design. The current mixed state is neither.

### S-3 — High — the current UI implements the deferred completed-thumbnail cache without G1/C1 admission

**Classification:** hard scope violation; present at `61b418b`, extended for
measurement at `a028c8c`.

`docs/00-overview.md:23-35` excludes shared materialization caches from v1.
`docs/04-coherence.md:167-186` freezes thumbnail coordination as single-flight,
not a completed-result cache. `docs/06-cross-cutting.md:66-79` says a G1 shared
in-memory completed-thumbnail cache does not belong to v1 until representative
scrolling proves decode p95 above 16 ms and at least 30% completed-request reuse.
`docs/v2/V2-roadmap.md:467-485` still places C1 behind admission/sign-off and a
source-fingerprint/materializer-version design.

`Sources/PresentationUI/ThumbnailStore.swift:24-51,106-157` nevertheless keeps
completed `CGImage` hits and negative misses in a shared dictionary across the
browsing surface, defaulting to 500 entries. Its own comment at lines 45-49
calls the completed cache deferred G1 work. `a028c8c` makes the ceiling
injectable and exposes public cache counts.

The new `SmokeMeasurementTests.swift:29-99` proves entry-count reset and records
one RSS delta; it does not establish either G1 admission threshold, cache-law
equivalence, the V2 source-fingerprint key, a materializer version, or a
representative byte/RSS bound. This makes a “smaller memory” claim especially
unsafe: the cache retains decoded images by count rather than decoded byte cost.

Either treat the store as unadmitted and remove completed shared retention from
the current release, or run the documented admission process and implement the
approved V2-04 cache contract. A view retaining only the image it is actively
displaying is not the same design as a 500-entry cross-row cache.

### S-4 — High — the warning/error log exclusion fails open at end of file

**Classification:** hard CI-gate violation; introduced by `f20db0e`.

`AGENTS.md:166-169` and `AGENTS.md:221-225` require warnings/errors to fail CI,
apart from narrowly documented noise. The CoreData exclusion is implemented
five times in `.github/workflows/macos26-arm-ci.yml` (starts at lines 193, 365,
752, 811, and 996) as an awk state machine:

```awk
/^CoreData: error: Failed to clone external data reference/ { block = 1 }
block && /\}\}$/ { block = 0; next }
block { next }
{ print }
```

There is no `END` check. If a CoreData block is truncated or its formatting
changes so no `}}` line appears, the filter discards the entire rest of the
log, including unrelated compiler warnings, `error:`, and `** TEST FAILED **`.
A read-only synthetic probe during this review fed an opening line, a detail
line, `warning: unrelated compiler warning`, and `** TEST FAILED **`; the
filter emitted the empty string.

The exclusion is therefore not narrow/fail-closed even if every historical
sample happened to terminate. The five copied implementations also create a
Fowler **Duplicated Code** maintenance risk. A single checked filter should
recognize the complete known block, fail if EOF arrives while inside one, and
be fixture-tested against truncated and adversarial neighbouring diagnostics.

### S-5 — High — the new panel uses one nonexistent API and one deliberately non-public API

**Classification:** hard platform/API violation in `a028c8c`, confirmed by the
macOS 26 compiler on `9c6e3b4`.

First, `ClipyApp/Sources/Panel/FloatingPanel.swift:130-136` reads
`NSApp.alertWindow`. macOS 26 CI run 32317009871 failed the generated app build
with `value of type 'NSApplication' has no member 'alertWindow'`. This is the
exact Part VI class of an invalid platform API, not an availability question.

`docs/00-overview.md:65-69` says undocumented platform behavior must become an
explicit proof obligation rather than an invented API. Yet
`ClipyApp/Sources/AppDelegate.swift:195-203` says the selector is “not public
API” and invokes `NSApp.sendAction(Selector(("showSettingsWindow:")), ...)`.

Apple documentation was rechecked on **2026-08-20T00:19:45Z–00:19:46Z** via
the Sosumi Apple-DocC mirror:

- [OpenSettingsAction](https://developer.apple.com/documentation/swiftui/opensettingsaction)
  is public on macOS 14+ and presents the app's Settings scene.
- [NSHostingSceneRepresentation.environment](https://developer.apple.com/documentation/swiftui/nshostingscenerepresentation/environment)
  is public on macOS 26+ and its Apple example specifically calls
  `settingsScene.environment.openSettings()` from an AppKit action.

The project floor is macOS 26, so a documented Settings path exists. The
nonexistent property must be corrected, and the string selector should not be
accepted as a stable macOS 26 implementation surface or as evidence that the
panel is production-ready.

### S-6 — Medium — the Carbon callback's MainActor premise has no symbol-level proof

**Classification:** hard proof gap, not a claim that the callback is currently
observed on the wrong thread; added by `a028c8c`.

`ClipyApp/Sources/HotKey/GlobalHotKey.swift:9-11,133-163` claims that a handler
installed on `GetEventDispatcherTarget()` always runs on the main thread and
therefore calls `MainActor.assumeIsolated`. The Apple-documentation search on
2026-08-20 found general archived Cocoa guidance that the application main
thread handles UI events, but no current symbol contract for
`GetEventDispatcherTarget`/`InstallEventHandler` guaranteeing the callback's
thread or Swift MainActor executor.

The only gate,
`ClipyApp/Tests/ClipyIntegrationTests/PanelAndHotKeyTests.swift:126-142`, proves
registration and then calls `hotKey.fire()` directly under `@MainActor`; it
never delivers an actual Carbon event through `globalHotKeyEventHandler` and
therefore cannot validate the premise. Under `docs/00-overview.md:67`, this
needs either a cited documented guarantee or a supported macOS runtime proof
that enters the C callback. Until then, it is an unclosed platform assumption.

### S-7 — Medium — progress/roadmap records contradict the actual state and CI evidence

**Classification:** hard documentation/traceability violation; spans the
initial snapshot and `a028c8c`.

The docs are declared authoritative, but they currently disagree:

- `docs/PROGRESS.md:14-16` says step 9/M3 are not started; the same file at
  lines 609-705 says step 9 is done and CI-green.
- `docs/roadmap/04-pasteboardadapter.md:3`,
  `05-presentationui.md:3`, and `06-clipyapp.md:3` all still say
  `not-started`.
- `docs/roadmap/README.md:139-145` still lists UI/pasteboard/product tests as
  pending while `AGENTS.md:33-49` and `docs/PROGRESS.md` say the step-9 UI and
  composed tests landed.
- `AGENTS.md:229-231` still calls the app a step-0 placeholder, and
  `AGENTS.md:221-225` still describes three CI jobs even though `a028c8c`
  adds the separate `perf-tests` job (and the workflow also has performance
  lanes).
- Most importantly, `a028c8c` added `docs/PROGRESS.md:753-754`, claiming CI
  evidence was recorded at merge and the commit message carried its run ID.
  The commit message has no run ID. Read-only GitHub inspection at
  **2026-08-20T00:22:09Z** showed
  [run 32316689047](https://github.com/GuangDai/Clipy/actions/runs/32316689047)
  for `a028c8c` completed cancelled: the SwiftPM and perf-test jobs failed to
  compile because `PreviewContent.textCharacterCap` was internal, and app/perf
  jobs were cancelled. `9c6e3b4` fixes only that access level. At
  **2026-08-20T00:26:43Z**, its
  [run 32317009871](https://github.com/GuangDai/Clipy/actions/runs/32317009871)
  also completed cancelled: source gates and the new perf-test lane passed,
  but the app failed to compile on `NSApplication.alertWindow` (S-5) and the
  standard SwiftPM lane failed five preview-dwell tests (S-8).

These results prove the report's fixed final head is not CI-green; they do not
predict the result of a later corrective commit. They also prove the current
status prose overclaims evidence and cannot safely guide another agent. Status
summaries should be synchronized and distinguish “landed”, “CI pending”,
“tests-only green”, and full state-3 acceptance.

### S-8 — Medium — new dwell tests repeat a documented two-second CI starvation failure

**Classification:** hard test-determinism/acceptance violation in `a028c8c`,
still present at `9c6e3b4`.

The shared polling helper documents the exact known failure mode at
`Tests/PresentationUITests/ScriptedHistory.swift:312-321`: a two-second
wall-clock deadline expired before MainActor tasks got a slot under parallel
real-scale suites in run 32267167679, so the repo deliberately raised the
default to ten seconds.

The new `PreviewPaneStateTests.swift:35,49,89,124,151` bypasses that default and
passes `.seconds(2)` to five dwell assertions. In macOS 26 run 32317009871, all
five failed (six issues total) while the same suite's non-two-second cases
passed. The observed failure therefore reproduces the repository's recorded
load-exposed flake rather than proving the state machine wrong.

For a delay/cancellation state machine, a deterministic injected clock/sleeper
or suspension seam is stronger than another wall-clock increase. At minimum,
new tests must not reinstate the exact timeout the shared harness marks unsafe.
No UI acceptance claim is green while this suite is red.

## 4. Judgement calls: code-smell baseline

The items in this section are design prompts, not standards violations.

### J-1 — Duplicated Code / Shotgun Surgery in retention composition

The capture, revise, and policy-sweep lanes repeat the same broad algorithmic
shape in:

- `RetentionConfigLoading.swift:300-486`
- `RetentionReviseComposition.swift:117-329`
- `RetentionPolicySweep.swift:121-449`

Each independently loads/project scalars, constructs
`RetentionExpansionItemSummary` arrays, derives protected items, performs
checked irreducible-byte feasibility, calls the same item planner, and merges
retirements. The lane-specific projection rules are real and must stay visible,
but the shared mechanics are large enough that adding or correcting one
retention dimension requires coordinated edits in three places. S-1 is an
example of a missing validation that reaches all three.

A deeper internal module could centralize validated scalar construction,
inventory normalization, and feasibility, while accepting explicit lane-owned
primary/protection/time inputs. This is a judgement call because V2-02's three
trigger algorithms are intentionally distinct and extensively specified.

### J-2 — Duplicated Code / Shotgun Surgery in frozen content-type policy

The same textual UTI set and decoding rule occur in
`ContentProjector.swift:253-278`, `HistoryDetailsView.swift:658-715`,
`ReviseEditorView.swift:349-384`, and, after `a028c8c`,
`HistoryPreviewView.swift:60-96`. The seven image UTIs likewise occur in
`HistoryAuthority+DetailAndThumbnail.swift:153-161`,
`ThumbnailStore.swift:61-74`, `HistoryDetailsView.swift:671-683`, and
`HistoryPreviewView.swift:85-96`. Comments explicitly say to keep copies in
sync.

Some duplication is forced by the current target boundary, but three copies
inside PresentationUI are not. Drift changes editability, icons, preview, and
thumbnail prefetch independently. Consolidating the PresentationUI-local
display policy would reduce that risk without leaking HistoryStorage types.

The pasteboard concealment marker duplication is **not** included here: the
spec explicitly requires independent adapter/storage defense in depth.

### J-3 — possible Speculative Generality / overly broad UI test surface

`ThumbnailStore.cachedEntryCount` and `inFlightCount` are public solely for the
app-hosted smoke suite (`ThumbnailStore.swift:53-59`), and
`PreviewContent.resolve` documents that it is public so a hosted test can call
it (`HistoryPreviewView.swift:34-43`). This expands the shipped module surface
for test observability, while `AGENTS.md:175-178` reserves public access for
caller-visible entry points. The public `CGImage` return is already a hard part
of S-2; the counters/resolver are a lower-confidence API-depth concern because
PresentationUI is itself a public assembly target.

Consider test seams that do not become production API, or explicitly declare
these as supported caller surfaces with compatibility obligations.

### Smells examined and suppressed

- `SwiftDataHistory` forwarding is not reported as **Middle Man**: the repo
  explicitly defines it as the deep public boundary that owns closed dispatch,
  observation, and failure translation.
- Composed WS test repetition is not reported as **Duplicated Code**: roadmap
  06 explicitly requires WS1–WS21 re-verification through the composed app.
- The three byte-identical `FixtureCatalog.swift` copies are not reported:
  their header records the deliberate test-target-isolation tradeoff and the
  copies are currently byte-identical.
- Core's string/`Int`/`Data` DTOs are not reported as **Primitive Obsession**:
  the authoritative public spec mandates those representations.
- No evidence-sufficient **Mysterious Name**, **Feature Envy**, **Data Clumps**,
  **Repeated Switches**, **Message Chains**, or **Refused Bequest** was found.
  The only `HistoryAction` dispatch remains an exhaustive switch with no
  default.

## 5. Standards areas with no finding

The review found no evidence-sufficient breach in these areas:

- `HistoryCore` and `HistoryDomain` remain Foundation-only; Domain has no
  public declarations, actor, I/O, async, or clock/UUID/Date generation.
- V2's new HistoryCore cases are handled in the single exhaustive
  `SwiftDataHistory.perform` switch.
- `@Model` types remain internal to HistoryStorage and do not occur in public
  or package signatures.
- Product `ModelContext` creation remains within `HistoryAuthority`; the V1→V2
  migration-context writer is an explicitly recorded M1 exception. Fresh
  operation contexts and `ModelContext.transaction` remain the commit pattern;
  no product trailing `save()` was found.
- No banned concurrency escape hatch or app-owned `.shared`/`.current`
  declaration was found.
- The combined `Package.swift` and `ClipyApp/project.yml` graphs retain the
  intended downward library dependencies; no generated `.xcodeproj` edit was
  present.
- SwiftPM test targets mirror owners, and storage semantic tests continue to
  use real `SwiftDataHistory` rather than a fake writer.
- No network/telemetry API was found in production `Sources` or
  `ClipyApp/Sources`. Fixture download is CI/test infrastructure, checksum
  pinned, not a runtime product path.

These are static/source conclusions. The supported macOS runner is still the
authority for strict-concurrency compilation, SwiftData behavior, XcodeGen
repeatability, and warning-free builds.

## 6. Suggested order of resolution

1. Close S-1 before relying on R2/R3 for destructive retention decisions.
2. Decide the thumbnail ownership/cache model once, then resolve S-2 and S-3
   together and strengthen the import gates.
3. Make the CI diagnostic filter fail closed (S-4); otherwise future green
   logs can hide the evidence needed to validate every other change.
4. Remove the invalid/private platform calls, close the Carbon callback proof,
   and make the dwell tests deterministic (S-5/S-6/S-8) before calling the new
   panel production-ready.
5. Reconcile status documents only after the current head has a completed green
   CI result (S-7).

## Appendix A — requested 58-commit list

Command:

```sh
git log master..61b418bf9b9767ac84f81da3e65cfe447a509cbd --oneline
```

Output (58 commits, newest first):

```text
61b418b Docs: real-scale fixture harness + stress/smoke suites green at run 32269792986
f20db0e CI: strip known-benign CoreData .interim clone-race blocks in the SPM and app log self-scans (same prefilter the admission lane carries; surfaced by the real-scale suites' on-disk temp stores in run 32268871305)
f0580c5 Fix load-exposed test flakiness from run 32267167679: pollUntil budget 2s→10s (CI runner saturation starved MainActor task slots — identical code was green at 91d04dd); render-storm asserts no-amplification + convergence (strict coalescing proof lives in storage-side WS12 suspension suites)
1a080fb Fix stress-suite compile errors from run 32265918298: bracket/paren typo in boundary helper, windowEnd redeclaration, thumbnail fetch key type
4572690 Real-scale smoke/stress suites over the fixtures-v1 release
980546a Fixture infrastructure: fetch_fixtures.sh (sha256-pinned release download), FixtureCatalog loader (duplicated per test target), CI fetch step in both test jobs
8766b76 Add deterministic test-fixture generator (real-scale 4K images, 100KB–5MB texts, rich docs; tarball + manifest + sha256)
56d9dcb Docs: step 9 CI-green at run 32260455839 (tests-only scope); record the seven-run convergence narrative
91d04dd WS15 composed: replace truncated white-PNG fixture (3-byte IDAT → complete 5-byte scanline); libpng partial-decode ERROR lines failed the app-log self-scan
06c580c Fix test failures from CI run 32256916252
2a9f79f Fix integration/adapter test compile from run 32255661896: throw probe error (no runtime skip in swift-testing), reorder waitFor params for trailing-closure calls, WS14 tuple order, drop stray .utf8
3d4f388 Fix test compile from run 32254796602: PRODUCT_MODULE_NAME=ClipyApp for @testable import; drop invalid makeStream trailing closure
f4afa09 Fix missed String→Text description in HistoryListView empty state (run 32254241169)
e61b650 Fix step-9 compile errors from CI run 32252737582: .formStyle(.grouped), manual range clamp, Text() descriptions, revise intent: label, Image(_:scale:label:) for CGImage, closure arg labels, thumbnail flatMap decode
1826cee CI: add tests-only dispatch scope (gates + SwiftPM + app tests, no perf lanes)
4c39499 Docs: record step 9 implementation state (AGENTS.md current state; PROGRESS.md step 9 entry, CI evidence pending)
c037a71 Step 9: product wiring — PasteboardAdapter + PresentationUI + ClipyApp (roadmap 04–06; 01 §5/§6/§8; 03a §4/§5/§7; 03b §8–§12; 04 §5–§9; 05 §6.1; 06 §8)
04234c3 Interruption recovery: open-time idempotent backfill re-run (measured fact)
d30673c Fix interruption-fixture compile: import HistoryCore; capture terminationReason
e352166 Final gate remainders: process-death interruption fixture; behavioral zero-decode
192da1e Ledger: perf remainder closed (ratios 2.64/2.31/2.65 vs 6.0); restore prior row
e1c31cb Perf lanes: R-active workloads (RET-PERF-1/2/3 measurement halves)
1663c49 Ledger: remainder groups 2+3 and minors closed green (495 tests)
e503dd7 Gate-remainder fixtures: RET-CONCUR-1(1)/(3), RET-PRUNE-2 revise half, migration/downgrade minors
002f947 Ledger: independent clause-level gate audit; five remainder groups named
5f0a6f5 Ledger + roadmap: R.6 closed green; all six V2-02 engine slices executable
1612d27 Fix R.6 seeding: per-revision unique payloads (D4 .unchanged collision)
58d884b R.6 policy sweep: .setRetentionPolicies end-to-end (PHASE A/B/C, DC-27)
dcfd941 Ledger: R.5 closed green (run 31948533018; 482 tests)
6eb1942 Fix R.5 test compile: TimeInterval is Double (Date init argument)
48e93c3 Fix R.5 test compile: UInt64 conversions + literal-ambiguity-free UUID fixture
13394ec R.5 revise composition: speculative R3 + hard-bound ordering + fused blob write
6256fdd Ledger: R.4 closed green (run 31946120453; 471 tests; agent interruption recorded)
688ef9b Fix R.4 compile: explicit package init on MutationPlan
433a0fa R.4 capture composition: R1/R2 expansion over projected post-count state
ab5bd73 Ledger: R.3 closed green (run 31875678620; 461 tests; eviction ratio 4.93/6.0)
3cfe933 Fix deleteRow fallback expression: no 'try' to the right of ??
3979be9 R.3 fix: batch the retirement projection-row fetch; test compile fixes
c19e2df R.3 persistence/projection: 1:1 stamping lifecycle, live step-7 check, Storage clock
f0a9ef1 Ledger: R.2 landed and green (run 31873858920, first try)
9136a03 R.2 pure Domain: retention-expansion facts, planners, prune/policy mutations
3ddbc8d Ledger: R.1 green on run 31873048800 (all four jobs, regenerated snapshot enforced)
7a18701 Ledger: R.1 landed, symbol snapshot regenerated (bot 6660a7b)
6660a7b Update HistoryCore public symbol snapshot
3900c91 R.1 core contract: HistoryRetentionPolicies + action/outcome/capacity cases
a772e0e Ledger: M1 green on CI run 31871812062 (402 tests, 4 jobs, zero warnings)
37616cb Fix M1.3/M1.4 test compile: HistoryCore import + no actor-isolated container access
768dba0 Ledger: M1.3/M1.4 rows
474992f M1.3 + M1.4 + open wiring: config bootstrap, byte backfill, single custom hop
2245191 Ledger: record the M1.1/M1.2 CI import-Foundation red + fix honestly
3e488d3 Fix M1.1/M1.2 test compile: add missing import Foundation
6278aed Annotate open-order step 7 sequencing; ledger rows for M1.1/M1.2 half
8a15458 M1.2 (schema half): HistorySchemaV2 with the retention rows + version ledger
c1687e7 M1.1: add the behavior-preserving HistorySchemaV1 VersionedSchema anchor
b203fdd Record M1 total open order; complete V2-1 (self-review + final review READY)
ad2b02d Close V2-1 design blockers DC-01..04/08/21/23/27/28; admit V2-02 (M1 + retention release)
1acbb52 Close V2-0: state-2 declaration and D1-D19 evidence reconciliation
dafade4 Open the living V2 progress ledger
```

Post-list UI commits reviewed separately:

```text
a028c8c Split perf/AB proofs into HistoryPerfTests lane; Maccy-style hotkey panel + preview
9c6e3b4 Fix PreviewContent.textCharacterCap access level (package, for the in-package resolver tests)
```
