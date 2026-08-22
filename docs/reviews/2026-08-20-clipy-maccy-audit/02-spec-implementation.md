# Clipy specification-to-implementation review

> Axis: V1/V2 specification fidelity and implementation evidence
>
> Review started: **2026-08-20T00:08:56Z (UTC)**
>
> Review ended: **2026-08-20T00:25:19Z (UTC)**
>
> Primary implementation snapshot: **`codex/v2-implementation@9c6e3b48f1bbf0c642ccbb61b233319003b6fefb`**
>
> Fixed point: **`master@dfb08f2d67fb611eec3fa80db2d6a0a63896f139`**; merge-base is the same commit
>
> UI snapshot note: the review began at `61b418bf9b9767ac84f81da3e65cfe447a509cbd` with the panel/preview/perf-lane work dirty. At **2026-08-20T00:17:06Z**, that overlay became commit `a028c8c579b365f6c2183c5042ee78a365553d2a`. At **2026-08-20T00:21:44Z**, commit `9c6e3b48f1bbf0c642ccbb61b233319003b6fefb` changed only `PreviewContent.textCharacterCap` from internal to `package` access and added its explanatory comment. That last commit changes test visibility, not runtime behavior, so it changes no finding below. Findings about the UI remain a dated snapshot, not an assumption that concurrently edited UI is frozen.
>
> Review mode: read-only. No Swift, test, configuration, existing specification, or status file was changed. This report is the only file created by this axis.

## 1. Verdict

The V1 engine and the landed V2-02 R.1–R.6 semantic core remain unusually well aligned: this pass found **no new confirmed content-lineage, deduplication, commit-token, migration, retention-selection correctness, or persistence-atomicity defect** in `HistoryCore`/`HistoryDomain`/`HistoryStorage`. That conclusion is bounded: it comes from source/spec/test inspection, not a new macOS execution.

The product and proof layers are not yet strong enough to support “comprehensively surpasses Maccy, uses less memory, and is faster” as an established result. The most material findings are:

1. `PresentationUI` directly imports ImageIO and performs image/text decoding on the Main Actor, contradicting both the V1 ownership/isolation contract and the explicit V2 UX compile gate (`SPEC-IMPL-002`).
2. The shipped retention settings cannot read persisted V1 or V2 policies. A reopened settings window displays defaults/all-disabled rather than authoritative configuration; this is a real R.7/API gap, not OPEN-2 (`SPEC-IMPL-003`).
3. The V2 retention implementation sorts candidate sets, so its worst-case planner work is `O(N log N)` while the specification and performance metadata call the path `O(retained)`/linear; the 3×/6× envelope cannot discriminate the difference (`SPEC-IMPL-006`).
4. Pasteboard reads/writes do not surface documented AppKit failure outcomes, allowing a failed/partial clipboard operation to look successful (`SPEC-IMPL-005`).
5. No same-machine Clipy-versus-Maccy A/B supports the requested superiority claim; Clipy's own record documents a 1.59 GiB peak-RSS worst-bound search run and a full-corpus snapshot per request (`SPEC-IMPL-011`).

Count: **4 High confirmed/confirmed-partial, 3 High conditional/evidence-gap, 4 Medium confirmed/confirmed-partial, 1 Medium conditional design-boundary question.** There is no Critical finding in this axis.

### Severity and status vocabulary

- **High**: release-blocking architectural/correctness/reliability issue, or a missing proof for a central product claim.
- **Medium**: bounded defect, incomplete release slice, or material documentation/platform risk.
- **confirmed**: directly established by current source/spec/test evidence.
- **confirmed-partial**: a required slice is observably incomplete, but is not being misattributed to an already-closed engine slice.
- **conditional**: the code has a concrete unsafe interleaving/boundary, but the user-visible failure depends on runtime timing or a design interpretation that the spec must resolve.
- **question**: the present documents do not settle the boundary honestly enough to classify it as an implementation defect.

## 2. Precedence and admitted scope

The review used the following precedence, rather than treating progress prose as implementation proof:

1. V1 Parts I–VI are one specification; Part III owns public surface, Part II planning, and Part V persistence/version minting (`docs/00-overview.md:63-69`).
2. V2 extends rather than redefines V1; V1 remains authoritative for V1 behavior (`docs/v2/V2-00-overview.md:3-10,31-46`).
3. The selected first V2 release is **M1 + V2-02 only**; no other graft reserves symbols, schema, or placeholders (`docs/v2/V2-PROGRESS.md:135-144`).
4. R.1–R.6 are the landed engine slices; R.7 is the UX handoff and is not recorded closed in the V2 roadmap (`docs/v2/V2-roadmap.md:365-389`).
5. V2-01 enrichment, V2-03 journal/cache, V2-04 C1/C2/C3, V2-05 gateway/App Intents, and V2-06 P1/P2/P3 remain unadmitted or blocked. Their absence is **not** a current defect.

`docs/PROGRESS.md`, `docs/v2/V2-PROGRESS.md`, `AGENTS.md`, commit messages, and CI run numbers were treated as status/evidence indices only. A claim in one of those files was checked against source and tests before being accepted.

## 3. Findings

### SPEC-IMPL-001 — PresentationUI's 500-entry image dictionary crosses an unresolved “display state vs completed cache” boundary

- **Severity:** Medium
- **Status:** conditional / question
- **Area:** PresentationUI, V1 cache law, V2-04 admission
- **Snapshot:** introduced in `a028c8c` at 2026-08-20T00:17:06Z UTC; unchanged at `9c6e3b48`

**Specification evidence.** V1 says there is one transient thumbnail single-flight coordinator and excludes shared/disk materialization caches (`docs/00-overview.md:15-35`); it says single-flight is not a completed-result cache, while narrowly stating that completed bytes are not retained by **HistoryStorage** (`docs/04-coherence.md:167-188`). Future item caches require an authoritative version, complete parameters, and a materializer schema version (`docs/04-coherence.md:210-216`). V2-07 goes further: Record 4 states that “the UI is not a cache” and that V2-07 introduces none (`docs/v2/V2-07-ux.md:874-879`). V2-04 C1 remains gated and would introduce a distinct `ThumbnailCache` keyed by source fingerprint, pixels, and materializer version (`docs/v2/V2-roadmap.md:467-486`).

**Implementation evidence.** `ThumbnailStore` keeps completed `CGImage` hits and negative results in `[HistoryItemReference: Entry]`, defaults to 500 entries, survives page replacement, and resets only after crossing its whole-cache threshold (`Sources/PresentationUI/ThumbnailStore.swift:18-55,88-157`). `HistoryPanelView` owns one long-lived instance (`Sources/PresentationUI/HistoryPanelView.swift:27-60`). The source itself calls this a completed-thumbnail cache while saying G1 is deferred (`Sources/PresentationUI/ThumbnailStore.swift:45-50`).

**Why this is conditional rather than a Storage-cache violation.** `HistoryStorage` still obeys V1 §9: it removes flights and retains no completed encoded bytes. A view necessarily holds enough decoded state to display visible rows. The unresolved issue is that a cross-page, 500-entry hit/miss dictionary is materially broader than visible-viewport state, yet the specs define neither an allowed PresentationUI display-state bound nor an app-layer cache exception. It is not the designed V2-04 C1 cache, but it also is not honestly covered by “UI owns the latest page.”

**Impact.** The dictionary makes the memory profile depend on previously visited image rows and can retain decoded images after they leave the current page. It also creates a second cache design with a different key/lifetime from future C1, increasing migration and double-caching risk.

**Why tests did not stop it.** `ThumbnailStoreTests` positively require completed and negative caching and reset/refetch (`Tests/PresentationUITests/ThumbnailStoreTests.swift:36-98,126-147`). The new smoke test asserts the cache's eviction count (`ClipyApp/Tests/ClipyIntegrationTests/SmokeMeasurementTests.swift:29-100`); it does not adjudicate whether this cache was admitted.

**Recommended direction (no implementation in this review).** Amend the spec to distinguish bounded visible-row presentation state from a reusable completed cache. If this is display state, retain only current visible/current-page references and drop them on snapshot replacement/panel close. If cross-page reuse is intentional, admit it explicitly, give it a byte—not only entry—budget, test the Part IV cache law, and reconcile it with future V2-04 C1 rather than shipping two unnamed layers.

### SPEC-IMPL-002 — PresentationUI imports ImageIO and decodes on the Main Actor

- **Severity:** High
- **Status:** confirmed
- **Area:** PresentationUI, architecture gates, responsiveness
- **Snapshot:** committed thumbnail path plus the preview path introduced in `a028c8c`; behavior unchanged at `9c6e3b48`

**Specification evidence.** V1 assigns ImageIO to the internal thumbnail implementation in `HistoryStorage` (`docs/01-architecture.md:79-88`) and expressly says Main-actor UI performs no image decode (`docs/01-architecture.md:180-187`). The selected V2 retention UX inherits that rule. V2's roadmap says PresentationUI never imports ImageIO (`docs/v2/V2-roadmap.md:616-618`), and `UX-COMPILE-1` explicitly bans that import (`docs/v2/V2-07-ux.md:906-912`).

**Implementation evidence.** `ThumbnailStore` is `@MainActor`, imports ImageIO, and invokes `CGImageSourceCreateImageAtIndex` after the thumbnail await (`Sources/PresentationUI/ThumbnailStore.swift:1-22,99-130,148-168`). The new preview also imports ImageIO, decodes text from full representation bytes, retains original encoded image bytes in `@State`, and calls `CGImageSourceCreateThumbnailAtIndex` from its SwiftUI body path (`Sources/PresentationUI/HistoryPreviewView.swift:12-25,41-69,102-124,160-198,224-244`). The portable gate still blocks only Domain/Storage/AppKit/SwiftData for PresentationUI, so it cannot catch ImageIO (`scripts/import_gate.py:59-64,177-202`; `.swiftlint.yml:69-75`).

**Apple documentation check (accessed 2026-08-20 UTC).** Apple's current [`CGImage`](https://developer.apple.com/documentation/coregraphics/cgimage) reference lists `Sendable`, so the code comment that a `CGImage` must never cross an actor boundary is no longer a valid reason to decode on MainActor. Apple's WWDC25 session [Embracing Swift concurrency](https://developer.apple.com/videos/play/wwdc2025/268/?time=1510) uses image decoding as the example of work to move off the main actor when it is slow; [Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness) similarly directs non-UI work away from the main thread.

**Impact.** Thumbnail decode can stall scrolling; preview decode/text conversion can process a V1-bounded but very large representation on the UI executor. Because `imageContent` computes the image during rendering, unrelated state invalidations can repeat work. This directly undermines the requested speed/responsiveness and clean module boundaries.

**Why tests did not stop it.** The thumbnail test uses a 1×1 PNG and is itself `@MainActor` (`Tests/PresentationUITests/ThumbnailStoreTests.swift:20-60`). Preview resolver tests use tiny values or synthetic text (`Tests/PresentationUITests/PreviewContentTests.swift:15-64`). Smoke timings are recorded, not asserted (`ClipyApp/Tests/ClipyIntegrationTests/SmokeMeasurementTests.swift:1-14,167-223`). No test checks executor isolation or the import rule, and the gate omits ImageIO.

**Recommended direction.** Keep ImageIO inside the existing thumbnail worker/HistoryStorage purpose-specific API, including a preview-sized request, or amend the architecture and use an explicitly off-main `nonisolated`/`@concurrent` decoder. Apply only the resulting `Sendable` `CGImage`/bounded DTO on MainActor. Add ImageIO to both PresentationUI gates and add a large-image responsiveness/executor regression.

### SPEC-IMPL-003 — Retention settings cannot read authoritative persisted policy state

- **Severity:** High
- **Status:** confirmed-partial (R.7 release blocker; not an R.1–R.6 engine defect)
- **Area:** HistoryCore read seam, PresentationUI settings, V2-02 R.7

**Specification evidence.** The retention UX must show the configured budget, not live current usage (`docs/v2/V2-07-ux.md:343-379`). Every settings section is supposed to render from its capability status value on panel open (`docs/v2/V2-07-ux.md:586-595`). R.7 owns unified settings/receipts/guidance and remains an unclosed slice (`docs/v2/V2-roadmap.md:365-389`). OPEN-2 excludes a **current retained-byte usage** read; it does not exclude reading configured policies (`docs/v2/V2-07-ux.md:107-113,376-379`).

**Implementation evidence.** `ClipboardHistory` exposes mutations, browse/observe, detail, paste, and thumbnail, but no V1 count-policy or V2 policy read (`Sources/HistoryCore/ClipboardHistory.swift:24-101`). The General tab opens at 200 regardless of persisted count (`Sources/PresentationUI/ClipySettingsView.swift:82-101`). The Retention tab opens every dimension disabled with hard-coded neutral values and admits that it cannot read policy state (`Sources/PresentationUI/ClipySettingsView.swift:304-345`). Pressing Apply constructs and replaces the entire policy value from those local defaults (`Sources/PresentationUI/ClipySettingsView.swift:465-498`).

**Impact.** After a restart or settings-window recreation, the UI can lie about active retention. Pressing Apply without first reconstructing every prior value can disable an active dimension or reset the count. This is particularly dangerous because retention changes can immediately retire items/prune revisions.

**Why tests did not stop it.** The composed “settings” tests call `HistoryViewState.apply…` directly and validate engine receipts/restart behavior; they never instantiate the settings view or assert readback (`ClipyApp/Tests/ClipyIntegrationTests/UISmokeJourneyTests.swift:478-566`; `WS21ComposedRetentionPolicyTests.swift:19-129`). There is no restart/open-settings/read-fields/apply-unchanged product test.

**Recommended direction.** Before declaring R.7/product completion, design a purpose-specific authoritative settings read containing V1 maximum-unpinned and V2 policies (not retained-byte usage), expose it through the deep public seam, and make the view show loading/error state until it arrives. Test persistent restart → settings open → values match → Apply unchanged causes `.unchanged` and no retirement.

### SPEC-IMPL-004 — The admitted retention UX is not localized/formatted to its own R.7 contract

- **Severity:** Medium
- **Status:** confirmed-partial (state-3/R.7 work, not an engine regression)
- **Area:** PresentationUI, accessibility/localization

**Specification evidence.** Every V2 control/status must be accessibility-labeled and every user-facing string must be `LocalizedStringResource` (`docs/v2/V2-07-ux.md:130-165,766-817`). Age/byte/count fields require locale-appropriate formatters and plural-aware catalog entries (`docs/v2/V2-07-ux.md:793-817`). R.7/UX.9 remains required for every shipped UX slice (`docs/v2/V2-roadmap.md:389,592-622`).

**Implementation evidence.** The retention view stores labels, units, status, failures, and manually pluralized messages as raw `String` (`Sources/PresentationUI/ClipySettingsView.swift:352-415,501-528,533-593`). It labels values as `MB` while multiplying them by 1,048,576 (MiB) (`Sources/PresentationUI/ClipySettingsView.swift:326-335,370-395,453-476`). `PopupPositionMode.displayName` is also raw English (`Sources/PresentationUI/PopupPositionMode.swift:22-29`). Repository search found no `.xcstrings`/`Localizable.strings` resource and no `LocalizedStringResource` use in PresentationUI. Exact-English tests lock the current wording (`Tests/PresentationUITests/FailurePresentationTests.swift:144-156`).

**Impact.** R.7/state 3 cannot be called complete. “MB” displays a decimal unit while enforcing a binary value, and manual English pluralization/number entry does not generalize to other locales or accessibility speech.

**Why tests did not stop it.** Tests assert English strings and action behavior; there is no string-catalog extraction, plural-locale, formatter, VoiceOver navigation, contrast, or Dynamic Type acceptance test.

**Recommended direction.** Move labels/hints/failures/receipts to a String Catalog via `LocalizedStringResource`, use locale-aware duration/byte/number formatting, label binary values honestly, and add the required VoiceOver/localization/product gates before advancing R.7.

### SPEC-IMPL-005 — Pasteboard failure outcomes are silently converted into success or partial data

- **Severity:** High
- **Status:** confirmed for missing write-failure handling; conditional for the provider-timeout read path
- **Area:** PasteboardAdapter, ClipyApp paste orchestration

**Specification evidence.** The adapter must freeze all relevant typed values and translate/write a `PastePayload`; its acceptance calls for byte-preserving capture and paste (`docs/roadmap/04-pasteboardadapter.md:9-19`). ClipyApp owns the one ordered payload-to-pasteboard handoff (`docs/01-architecture.md:164-174`; `docs/roadmap/06-clipyapp.md:9-20`).

**Implementation evidence.** A declared item type whose `data(forType:)` returns nil is skipped while other representations are retained (`Sources/PasteboardAdapter/PasteboardAdapter.swift:65-94`). On write, every `setData` Boolean is ignored and the method returns no result (`Sources/PasteboardAdapter/PasteboardAdapter.swift:97-122`). ClipyApp then invokes `onPasteCompleted` and closes the panel unconditionally after `write` returns (`ClipyApp/Sources/AppComposition.swift:205-227`).

**Apple documentation check (accessed 2026-08-20 UTC).** Apple's [`NSPasteboard.setData(_:forType:)`](https://developer.apple.com/documentation/appkit/nspasteboard/setdata%28_%3Afortype%3A%29) returns false when ownership changed and raises for other communication errors. Its [`data(forType:)`](https://developer.apple.com/documentation/appkit/nspasteboard/data%28fortype%3A%29) documentation says nil can mean the contents changed or the provider timed out and advises surfacing inability to complete the operation. `NSPasteboardItem.data(forType:)` is less explicit, so the timeout branch is conservatively conditional, but silently ignoring write Booleans is direct.

**Impact.** A clipboard race can leave only a prefix of the representations or omit the lineage hint, yet the UI closes as if paste succeeded. A slow provider can turn a multi-representation source into partial Canonical Content, affecting later dedup/search/paste behavior.

**Why tests did not stop it.** Adapter tests use synchronous in-process named pasteboards and assert success only (`Tests/PasteboardAdapterTests/PasteboardAdapterTests.swift:195-220`; `PasteboardAdapterStressTests.swift:89-155`). There is no injectable provider timeout, ownership-change, partial-write, or user-visible failure case.

**Recommended direction.** Give freeze/write an explicit all-or-nothing result, distinguish “empty” from “declared but unavailable,” and close the panel only after a verified full write. Add a seam that deterministically injects each documented AppKit failure and define retry/user feedback without logging clipboard bytes.

### SPEC-IMPL-006 — V2 retention is `O(N log N)` in victim-producing cases while specs and gates label it linear

- **Severity:** Medium
- **Status:** confirmed
- **Area:** HistoryDomain, HistoryStorage serialized interval, HistoryPerfRunner

**Specification evidence.** V2-02 repeatedly describes the new work as an `O(retained)` scalar sweep (`docs/v2/V2-02-retention.md:115-124,727-731,1781-1803`). The performance metadata likewise calls all three R-active lanes linear (`Sources/HistoryPerfRunner/PerfFixtures.swift:247-269`).

**Implementation evidence.** `planItemRetentionExpansion` filters the inventory, then sorts all R1 victims and all remaining R2 candidates before consuming enough victims (`Sources/HistoryDomain/PlannersRetentionExpansion.swift:106-190`, specifically `:165` and `:172`). Worst-case time is `O(V log V + C log C)`, hence `O(N log N)`, not `O(N)`. This pure planner executes within the serialized Authority planning interval.

**Why tests did not stop it.** The R-active envelope uses only 100 and 300 rows with a 6× bound. A 3× linear workload has theoretical ratio 3; `N log N` over these points remains comfortably below 6, so the gate rejects quadratic growth but cannot verify its declared linear class (`Sources/HistoryPerfRunner/PerfFixtures.swift:247-269`). Domain tests establish ordering/postconditions, not operation count (`Tests/HistoryDomainTests/RetentionExpansionPlannerTests.swift:76-421`).

**Impact.** The engine remains bounded at 5,000 items, but the written complexity claim is false and weakens any “lower time complexity than Maccy” conclusion. Repeated capture with R2 active and a small victim count pays a full candidate sort.

**Recommended direction.** Either correct the specification/fixture metadata to `O(N log N)` and budget it honestly at the 5,000-row cap, or implement an order-statistic/heap selection whose proved cost matches the intended bound. Add comparison/operation-count instrumentation or scales/bounds that actually discriminate the claimed class.

### SPEC-IMPL-007 — Preview results lack a cancellation/reference fence

- **Severity:** High
- **Status:** conditional
- **Area:** dynamic PresentationUI preview
- **Snapshot:** preview behavior from `a028c8c`, unchanged by the access-only `9c6e3b48` commit at 2026-08-20T00:21:44Z

**Specification evidence.** UI work is reference-exact where asynchronously produced item visuals are applied (`docs/01-architecture.md:176-178`; `docs/04-coherence.md:167-188`). More generally, Main-actor selection/window state must not apply a result to a superseded selection (`docs/01-architecture.md:180-187`).

**Implementation evidence.** `.task(id: previewedItem)` starts `loadContent`, but after awaiting `details(for:)`, the task writes content/occurrence without checking `Task.isCancelled` or that `previewedItem` still equals the captured reference (`Sources/PresentationUI/HistoryPreviewView.swift:102-125,224-244`). The fetched detail is requested by ID, not fenced to the captured `ContentVersion`.

**Impact.** Under rapid arrow-key selection or a concurrent revision/removal, a canceled older request can complete after a newer one and display another item's sensitive clipboard content under the current selection. It also retains the full selected image bytes in view state.

**Why tests did not stop it.** `PreviewPaneStateTests` tests timers/state only; `PreviewContentTests` is synchronous; the real-facade smoke runs selections sequentially. No scripted history suspends two detail reads and completes them in reverse order.

**Recommended direction.** Capture a selection generation/reference, check cancellation and exact current reference after every await, and discard late results. Add a deterministic reverse-completion test and a concurrent revision/removal case. Prefer a bounded preview DTO/worker so the fence composes with `SPEC-IMPL-002`.

### SPEC-IMPL-008 — UI creates dependent operations concurrently even though History promises no concurrent start order

- **Severity:** High
- **Status:** conditional
- **Area:** PresentationUI details, ClipyApp paste ordering

**Specification evidence.** Mutations linearize inside Authority, but concurrent call start order is not promised; callers requiring order must await one call before issuing the next (`docs/01-architecture.md:207-214`).

**Implementation evidence.** The detail Remove button calls fire-and-forget `viewState.remove` and immediately starts a separate detail reload (`Sources/PresentationUI/HistoryDetailsView.swift:97-105`). `HistoryViewState.remove` ultimately launches its own untracked Task (`Sources/PresentationUI/HistoryViewState.swift:230-238,336-351`). Similarly, the paste mailbox has one consumer, but the consumer calls synchronous `paste`, which launches another untracked Task; rapid selections can therefore have payload reads and writes finish out of order (`ClipyApp/Sources/AppComposition.swift:168-187,220-227`).

**Impact.** A post-remove reload may read the item before removal commits and leave stale details visible. Rapid paste selections can leave an earlier selection as the final clipboard contents or close the panel after a different request wins.

**Why tests did not stop it.** WS16 waits for the row to disappear before querying details and never drives the detail button (`ClipyApp/Tests/ClipyIntegrationTests/WS16ComposedRemoveAndNotFoundTests.swift:43-71`). Paste orchestration tests submit one item. No deterministic test parks/reorders the dependent operations.

**Recommended direction.** Expose awaitable UI mutation methods for dependent flows, await Remove before reloading/dismissing, and make paste processing explicitly serial or latest-wins with cancellation. Test the exact interleavings; do not rely on Task creation order.

### SPEC-IMPL-009 — Pasteboard capture creates an unbounded backlog of individually large captures

- **Severity:** High
- **Status:** conditional / unmeasured design gap
- **Area:** ClipyApp capture orchestration, memory

**Specification evidence.** V1 bounds one capture at 32 representations, 64 MiB each, and 128 MiB total (`docs/06-cross-cutting.md:31-64`), but G8 explicitly recognizes aggregate concurrent DTO residency as required evidence (`docs/06-cross-cutting.md:66-81`). These per-value bounds are not a queue bound.

**Implementation evidence.** Every delivered pasteboard capture starts an independent unstructured Task, specifically so a large capture does not stall polling (`ClipyApp/Sources/AppComposition.swift:189-202`). `HistoryAuthority`/preparation actors serialize relevant work, but no in-flight count, bounded channel, cancellation, or backpressure policy limits the number of frozen `Data` values waiting for them.

**Impact.** If 128 MiB observations arrive faster than ingest commits, resident memory can grow with backlog length despite every individual capture satisfying limits. Task scheduling can also reorder observations (storage preserves monotone timestamps, but not every intermediate copy).

**Why tests did not stop it.** The “rapid write” test performs 30 synchronous writes without yielding, so polling intentionally collapses them to the last visible change and the handler merely appends values; it does not combine a slow real history consumer with repeated maximum-size captures (`Tests/PasteboardAdapterTests/PasteboardAdapterStressTests.swift:157-224`).

**Recommended direction.** Specify product semantics for overload first (lossless bounded queue, sequential backpressure, or newest-wins coalescing), then implement a bounded mailbox and measure worst-case RSS with slow injected ingestion and maximum-size captures. The policy must be explicit because dropping intermediate copies changes history semantics.

### SPEC-IMPL-010 — Settings presentation uses a private selector despite a documented public API

- **Severity:** Medium
- **Status:** confirmed platform/maintenance risk
- **Area:** dynamic ClipyApp panel
- **Snapshot:** `9c6e3b48` (behavior introduced by `a028c8c`)

**Specification evidence.** Unsupported platform behavior must be expressed as a required outcome plus proof, not invented as an API fact (`docs/00-overview.md:63-69`). V2 UX applies the same “no concrete platform claim without citation/proof” rule (`docs/v2/V2-07-ux.md:162-165`).

**Implementation evidence.** `AppDelegate.openSettingsWindow` constructs `Selector("showSettingsWindow:")`; its own comment acknowledges that it is not public API (`ClipyApp/Sources/AppDelegate.swift:193-203`).

**Apple documentation check (accessed 2026-08-20 UTC).** Apple documents [`SettingsLink`](https://developer.apple.com/documentation/swiftui/settingslink) for opening/raising an app's Settings scene and [`OpenSettingsAction`](https://developer.apple.com/documentation/swiftui/environmentvalues) through `EnvironmentValues.openSettings`. Apple also documents programmatic scene presentation through [`NSHostingSceneRepresentation.environment`](https://developer.apple.com/documentation/swiftui/nshostingscenerepresentation/environment). No current public documentation was found for `showSettingsWindow:`.

**Impact.** A private selector can change without source compatibility, fail silently, or create App Review risk. The only visible Settings route is therefore less reliable than the platform's public mechanism.

**Why tests did not stop it.** Geometry/hotkey tests do not open a real Settings scene; hosted-test isolation suppresses production delegate installation. The return value of `sendAction` is ignored.

**Recommended direction.** Route the public `OpenSettingsAction`/`SettingsLink` through the SwiftUI environment or a documented hosting-scene representation, and add a macOS app-hosted test that verifies the Settings window is created or raised.

### SPEC-IMPL-011 — “Lower memory/faster than Maccy” is not established; Clipy's own worst-bound search evidence is large

- **Severity:** High
- **Status:** confirmed evidence gap
- **Area:** performance, Maccy comparison, release claims

**Specification evidence.** Performance claims require release-like workloads and machine metadata (`docs/06-cross-cutting.md:260-263`). The manual 5,000-row lane is explicitly record-only, not full G5/G8 evidence (`docs/06-cross-cutting.md:335-377`). V1's canonical disposition still records full search-body materialization as in progress: one ~1.22 GiB snapshot per request, with a supported worst-bound run at 1.59 GiB peak RSS and 1.59 s p50 after matcher optimization (`docs/V1-Verified/07-finding-dispositions.md:238-242`).

**Implementation evidence.** Each search fetches scalar fields for every retained row, including full bounded `searchBody`, builds a second `[SearchCorpusRow]`, and sorts it (`Sources/HistoryStorage/HistoryAuthority+SearchCorpus.swift:116-160,161-237,280-323`). Search continuation pages re-evaluate the corpus; concurrent searches serialize through one `SearchWorker` actor (`Sources/HistoryStorage/SearchWorker.swift:42-89,155-224`). The new UI smoke suite explicitly records timings without asserting them; its 150-item RSS check uses a 512 MiB slack bound, not a product budget (`ClipyApp/Tests/ClipyIntegrationTests/SmokeMeasurementTests.swift:1-14,102-173`).

**Impact.** The code may be faster than Maccy on some operations and slower on others, but the requested universal claim is currently unsupportable. Search has a known high-memory/high-latency worst-bound, candidate-lane churn remains unmeasured at 5,000 rows, and no artifact uses the same machine/corpus/settings to compare both apps.

**Why tests did not stop it.** Internal complexity ratios prove broad growth envelopes, not absolute latency or cross-product superiority. Record-only smoke output has no budget. Maccy is not invoked by any Clipy performance job.

**Recommended direction.** Define a reproducible same-machine A/B matrix before using superiority language: cold/warm launch-to-ready, idle/steady/peak RSS, 50/200/1,000/5,000-item capture/coalesce/search/browse/paste/thumbnail p50/p95/p99, high-candidate and 256 KiB-body adversaries, energy/wakeups, binary/store size, and UI frame/hang metrics. Match retention, history contents, cache state, build configuration, and signing. Report wins/losses per workload; do not collapse them to one adjective.

### SPEC-IMPL-012 — Status and CI records disagree with one another and with the current head

- **Severity:** Medium
- **Status:** confirmed, time-scoped to 2026-08-20T00:25:19Z UTC
- **Area:** documentation, CI evidence, release state

**Specification/process evidence.** `docs/PROGRESS.md` calls itself the living one-section-per-landed-step record whose criteria remain owned by spec/roadmap (`docs/PROGRESS.md:1-12`). V2 requires its living ledger to record commits and CI evidence (`docs/v2/V2-roadmap.md:678-685`).

**Observed contradictions.** The roadmap header says M3 is pending and its three module docs say `not-started` (`docs/roadmap/README.md:3-8`; `docs/roadmap/04-pasteboardadapter.md:1-7`; `05-presentationui.md:1-7`; `06-clipyapp.md:1-7`), while `docs/PROGRESS.md:609-666` and `AGENTS.md:33-44` say step 9 is done/green. `docs/PROGRESS.md`'s own baseline still says step 9 not started (`:14-16`). The V2 ledger ends by saying interruption and behavioral zero-decode remainders remain (`docs/v2/V2-PROGRESS.md:62-64`), although later commits `e352166` and `04234c3` implement them; the ledger has no rows for those commits. For `a028c8c`, `docs/PROGRESS.md:751-760` says CI evidence is recorded at merge and that the commit message carries a run ID, but the commit message contains no run ID. The subsequent `9c6e3b48` commit is only an access/comment change and likewise contains no run ID. At the recorded snapshot, the repository therefore contains no cited macOS-26 proof for the new AppKit/Carbon/preview code or the new skip/filter CI commands. This is “not yet evidenced,” not a claim that CI failed.

**Impact.** Reviewers cannot determine whether “done” means engine, M3, R.7, state 3, or merely source landed. Premature green wording can hide the exact dynamic UI risks above and makes test counts/run provenance unreliable.

**Why tests did not stop it.** No gate cross-checks roadmap statuses, progress ledgers, commit SHAs, run IDs, or whether an asserted CI run includes the named jobs. Source gates cannot validate prose.

**Recommended direction.** Maintain one dated release-state matrix with separate columns for source landed, macOS build/test green, perf evidence, R.7, and state 3; make all other status headers link to it. Add a lightweight documentation consistency check for impossible combinations and run-ID/commit association. Update the V2 ledger through the actual final gate-closure commits rather than relying on later narrative.

## 4. Coverage by requested area

| Area | Result at `9c6e3b48` |
|---|---|
| `HistoryCore` | No new landed-engine semantic finding. R.7 lacks an authoritative policy read (`SPEC-IMPL-003`). |
| `HistoryDomain` | R1/R2/R3 selection behavior matched the admitted spec under inspection; the complexity claim does not (`SPEC-IMPL-006`). |
| `HistoryStorage` | No new transaction/migration/retention correctness finding. Search residency and superiority evidence remain open (`SPEC-IMPL-011`). Storage thumbnail single-flight itself does **not** retain completed bytes; `SPEC-IMPL-001` is an app/UI boundary question. |
| `PasteboardAdapter` | Happy-path mapping and concealment are covered; documented AppKit failure outcomes are not (`SPEC-IMPL-005`). |
| `PresentationUI` | MainActor/ImageIO breach, policy readback gap, incomplete R.7 localization, cache-boundary question, and preview race (`001`–`004`, `007`). |
| `ClipyApp` | Dependent Task ordering, capture backpressure, and private Settings selector (`008`–`010`). |
| CI/docs | Prior step-9 run exists, but neither `a028c8c` nor access-only `9c6e3b48` has a repository-cited new run at the audit timestamp; records conflict (`012`). |
| Performance | Internal envelopes exist and V2 retention ratios were previously green, but one declared complexity class is wrong and no Clipy/Maccy A/B exists (`006`, `011`). |

## 5. No-finding and not-current-defect decisions

- No evidence was found that V2-01 OCR/enrichment, V2-03 durable journal/collection cache, V2-04 C1/C2/C3 caches, V2-05 gateway/App Intents, or V2-06 platform grafts were accidentally implemented in the engine. Their absence is intentional future scope.
- No new `HistoryAction` exhaustiveness gap was found for `.setRetentionPolicies`; Core/Domain/Storage switches and the symbol snapshot include the admitted cases.
- No new proof was found of a D1–D24 semantic violation in the landed engine. This does not erase the repository's documented deferred performance/platform risks.
- Clipy's “paste” specification ends at writing `PastePayload` to NSPasteboard (`docs/01-architecture.md:164-174`). Not synthesizing a Command-V event is therefore not a V1 conformance defect, although it can remain a product-feature difference in the separate Maccy comparison axis.
- Carbon hotkey registration is a new product choice rather than a V1/V2 requirement. Apple current symbol documentation for `RegisterEventHotKey`/dispatcher-thread guarantees was not located; this report therefore does not claim it is deprecated or incorrect. Its absence of a current cited contract belongs in platform verification for the dynamic UI commit.

## 6. Apple documentation consulted

All links were accessed on 2026-08-20 UTC; only Apple primary sources were used for platform conclusions.

- [`CGImage`](https://developer.apple.com/documentation/coregraphics/cgimage) — current conformance includes `Sendable`.
- [Embracing Swift concurrency, WWDC25](https://developer.apple.com/videos/play/wwdc2025/268/?time=1510) — image decoding/main-thread responsiveness guidance.
- [Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness) — keep non-UI work off the main thread.
- [`NSPasteboard.setData(_:forType:)`](https://developer.apple.com/documentation/appkit/nspasteboard/setdata%28_%3Afortype%3A%29) — Boolean ownership-change failure and communication-error behavior.
- [`NSPasteboard.data(forType:)`](https://developer.apple.com/documentation/appkit/nspasteboard/data%28fortype%3A%29) — nil on changed contents/provider timeout and user-feedback guidance.
- [`SettingsLink`](https://developer.apple.com/documentation/swiftui/settingslink), [`EnvironmentValues.openSettings`](https://developer.apple.com/documentation/swiftui/environmentvalues), and [`NSHostingSceneRepresentation.environment`](https://developer.apple.com/documentation/swiftui/nshostingscenerepresentation/environment) — public Settings presentation mechanisms.
- [`NSEvent.addGlobalMonitorForEvents(matching:handler:)`](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents%28matching%3Ahandler%3A%29) — key-event monitoring requires Accessibility trust; this supports why a plain global monitor is not an equivalent no-permission substitute for the chosen hotkey mechanism, but does not itself document Carbon.

## 7. Review commands and snapshot provenance

Primary commands (read-only):

```sh
git rev-parse HEAD
git rev-parse master
git merge-base master HEAD
git log master..HEAD --oneline
git diff master...HEAD
git diff HEAD
git diff --cached HEAD
git status --short
git ls-files --others --exclude-standard
rg ...
nl -ba ...
```

- At review start, `HEAD=61b418b…`, `master=merge-base=dfb08f2…`, and `git log master..HEAD --oneline` contained **58 commits**. `git diff HEAD`, `git diff --cached HEAD`, `git status --short`, and the untracked-file list captured the concurrently edited UI/App/CI overlay.
- During review, that overlay was committed as `a028c8c…`, producing the second snapshot: **59 commits** and 145 changed paths at 2026-08-20T00:20:20Z.
- At 2026-08-20T00:21:44Z, the two-line access-level/comment adjustment in `Sources/PresentationUI/HistoryPreviewView.swift` became `9c6e3b48…`. The final primary comparison is `git diff master...9c6e3b48`, containing **60 commits** and the same 145 changed paths at 2026-08-20T00:25:19Z. Inspection of `git diff a028c8c...9c6e3b48` confirmed that it changes no behavior and no finding.
- At review end, `git diff HEAD` and `git diff --cached HEAD` were empty. `git status --short` contained only the untracked `docs/reviews/` audit output being authored concurrently; there was no remaining uncommitted implementation overlay.
- The full 60-line commit list is intentionally not duplicated here; the exact reproducible command and count are recorded above.
- No Swift build/test was run on the Linux review host. Existing macOS CI run references were read as historical evidence; neither `a028c8c` nor `9c6e3b48` was called green without a run tied to that commit.

## 8. Recommended decision gates

Before claiming “feature-complete and superior to Maccy,” require these gates in order:

1. Resolve `SPEC-IMPL-002`, `005`, `007`–`010` and land a macOS 26 app-hosted product run for the actual panel commit.
2. Add authoritative policy readback and finish R.7 localization/accessibility; only then call the selected V2-02 release product-complete.
3. Decide the PresentationUI cache boundary and align code/spec/gates before V2-04 C1 is admitted.
4. Correct or implement the retention complexity claim.
5. Run the same-machine Clipy/Maccy A/B matrix and publish raw samples, build/configuration metadata, RSS methodology, and workload parity. Claims should be per workload, with explicit regressions as well as wins.
