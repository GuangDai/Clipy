# Module 6 — ClipyApp

- **Status:** done (step 9b; landed in `c037a71` and recorded by `4c39499`,
  revised by the post-step-9 commits `a028c8c`..`cc59aa8` — the panel is now
  a Maccy-style AppDelegate-owned floating `NSPanel` with a Carbon ⇧⌘C
  summon instead of a SwiftUI `MenuBarExtra` — CI-green at run
  [32319164667](https://github.com/GuangDai/Clipy/actions/runs/32319164667);
  see `../PROGRESS.md` step 9)
- **Spec references:** composition-root ownership `../01-architecture.md` §2 row + §5.1 (capture-lane health/retry) + §5.6 (paste orchestration) + §8 (forbidden service-locator/second-writer) + §9 item 6 (XcodeGen app-target gate) + §4 (scripted-preview adapter); paste coherence `../04-coherence.md` §8; caller example `../03b-instruction-set.md` §12; adapter open `../05-authority-kernel.md` §2.
- **Dependencies:** `HistoryCore`, `HistoryStorage` (`SwiftDataHistory`), `PasteboardAdapter`, `PresentationUI`. It is the **sole composition root** and the only place that coordinates History with outbound pasteboard writes.
- **Test target:** `ClipyIntegrationTests`.
- **Step:** 9b.

## Deliverables

- **Concrete construction:** `SwiftDataHistory.open(configuration:)` with `HistoryLimits.standard`; wire it as the `any ClipboardHistory` injected into `PresentationUI` and used by the paste path (Part V §2).
- **Lifecycle:** process-wide single `SwiftDataHistory`; no `.shared`/`.current`
  service locator; guard against a second `open` over the same canonical
  persistent StoreRoot, including standardized `..` and filesystem-symlink
  aliases, before creating another `ModelContainer`. This is a same-process
  guard inferred from Part I §8's no-second-writer rule; it is not a
  cross-process lease.
- **App activation lifecycle (REVIEW Card 14C):**
  `NSApplication.didResignActiveNotification` closes only the visible panel
  session and its browsing observation; the app-owned clipboard capture
  observation continues. `didBecomeActiveNotification` never opens the panel.
  The next explicit summon starts a fresh panel session/generation. These app
  focus callbacks are not proxies for `NSWorkspace` login-session switching or
  system sleep/wake, which remain distinct workspace notification semantics.
- **Summon shortcut registration (REVIEW Card 14B):** keep the current default
  ⇧⌘C binding, but expose an advisory warning for Apple's exact documented
  Shift-Command-C “Show Colors” conflict; this is not a hard rejection or a
  general registry of standard shortcuts. A replacement chord is registered
  before the saved preference or active token changes. If candidate
  registration fails, the old token and preference remain authoritative and
  the same candidate is available to Retry. If a saved chord cannot register
  at startup, report it unavailable and retain it for Retry rather than
  silently falling back to ⇧⌘C. General Settings opens one app-owned
  recorder: Escape cancels, and a bare or modifier-only key cannot become a
  candidate. The recorder submits the exact AppKit virtual key code and
  conventional modifiers to the same safe replacement operation; it does not
  add a second registrar or claim alternate-layout runtime behavior.
- **Capture overload:** one already-started complete capture plus one
  replaceable latest pending value, drained serially. Replacing pending
  publishes the cumulative content-free count; no frozen value queue or
  automatic retry is introduced (`DEC-CAPTURE-OVERLOAD`).
- **Paste orchestration:** `history.pastePayload(for:)` → `PasteboardAdapter.write(payload)` — the only History→pasteboard hand-off, kept outside the History transaction (Part I §5.6; Part IV §8; 03b §12).
- **Dependency injection:** supplies `any ClipboardHistory` (production = `SwiftDataHistory`, previews = scripted adapter) to the UI without leaking Storage/Domain types (Part I §2, §4).
- **External surface coherence:** one internal `AppIntentHistoryIngress`
  contains the existing connection-bound `ExternalHistoryFacade`. A positive
  external remove asks `HistoryViewState` to mint the exact purge, then awaits
  the AppDelegate-owned real `HistoryPanelSurfaceState.apply` through one
  app-local relay before the Intent returns; pin/unpin/unchanged/failure do not
  purge. This is
  the composition join between two existing owners, not a second Gateway,
  writer, change feed, or global cache bus (REVIEW Card 9B).

## Acceptance

- `ClipyIntegrationTests`: **re-run the WS1–WS21 paths through the composed app** (real `SwiftDataHistory` + `PasteboardAdapter` + `PresentationUI`), not just the in-isolation History tests — this is the end-to-end acceptance for the walking skeleton (Part VI §8: "each path crosses the public `ClipboardHistory` interface and real `SwiftDataHistory`").
- XcodeGen-produced app target builds; the SwiftPM library graph stays package-owned (Part I §9 item 6).
- `ClipyIntegrationTests`: a second `open()` over an already-open persistent URL is detected and rejected — it does not create a second writer or `ModelContext` (Part I §8).
- `ClipyIntegrationTests`: app resign closes one active panel/browsing session
  without stopping capture; app active alone creates no session; the next
  explicit summon starts exactly one replacement observation with a fresh
  generation.
- `ClipyIntegrationTests`: the app-internal summon-shortcut controller proves
  safe failed swap, Retry, reset, saved-startup failure, and exactly-once token
  cleanup through an injected registration closure. AppDelegate owns that
  controller's production start/stop lifecycle; General Settings receives
  framework-neutral current/unavailable state, the exact Show Colors advisory,
  and Change/Retry/Reset intents. Direct recorder tests require Escape
  cancellation, reject bare/modifier-only input, and preserve exact admitted
  key/modifier facts; the existing running Settings journey opens and cancels
  the real recorder without adding another app launch.
- `ClipyIntegrationTests` + `PresentationUITests` + `ClipyUITests`: marked
  Return/Escape stays with the current text responder; settled list-root
  Escape clears search then closes, while the running Details/editor journeys
  retain their own dismissal behavior. In the real editor, dirty Escape and
  Cancel share one discard confirmation, confirmed discard closes, and a
  subsequently reopened clean editor cancels directly without that warning.
  Synthetic hosted dispatch does not claim a physical CJK input-source matrix.
- `PresentationUITests` + `ClipyIntegrationTests`: only the current settled
  search generation's first authoritative page requests one content-free
  result-count announcement. Replacement snapshots, refresh, pagination, and
  superseded streams remain silent; a cursor preserves lower-bound (`N+`)
  wording.
- `ClipyIntegrationTests`: pausing the first real in-memory History capture and
  submitting an already-frozen burst preserves only the active and newest
  pending values, keeps stable owner-retained slot/byte facts bounded, records
  every pending replacement, and drains active then latest. Presentation tests
  require the cumulative replacement count in the warning. This does not
  establish provider acquisition peak or process RSS.
- Negative (Part I §8): ClipyApp makes no Domain decision and creates no duplicate persistence path; it does not pass a business ID to `registeredModel(for:)`; it holds no second writer or UI-bound `ModelContext`.
- `ClipyIntegrationTests`: with a real in-memory Authority and post-commit
  observation deliberately held, an authorized `RemoveItemIntent` returns
  only after the exact stale row is removed; an unrelated row survives and a
  no-op external mutation publishes no purge.

## Risks / notes

- Paste is intentionally not durable History state — a clipboard side effect happens after `pastePayload` returns, outside the transaction (Part IV §8).
- This module owns the M3 composition + state-2 re-verification via `ClipyIntegrationTests`; full state-3 acceptance (packaging/notarization, `.app` launch, accessibility, localization, product tests) is deferred to separate acceptance outside this roadmap (Part VI §11).
- Card 14B runtime coverage across a signed app, alternate keyboard layouts,
  Secure Input, and a real conflicting process remains open; controller tests
  and headless Carbon registration do not establish those environments.
