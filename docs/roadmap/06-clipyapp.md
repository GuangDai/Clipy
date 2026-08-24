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
- **Lifecycle:** process-wide single `SwiftDataHistory`; no `.shared`/`.current` service locator; guard against a second `open` over the same persistent URL — an implementation responsibility inferred from Part I §8's no-second-writer rule (not stated verbatim by any single spec section).
- **Paste orchestration:** `history.pastePayload(for:)` → `PasteboardAdapter.write(payload)` — the only History→pasteboard hand-off, kept outside the History transaction (Part I §5.6; Part IV §8; 03b §12).
- **Dependency injection:** supplies `any ClipboardHistory` (production = `SwiftDataHistory`, previews = scripted adapter) to the UI without leaking Storage/Domain types (Part I §2, §4).
- **External surface coherence:** one internal `AppIntentHistoryIngress`
  contains the existing connection-bound `ExternalHistoryFacade`. A positive
  external remove awaits `HistoryViewState.acceptCommittedExternalRemoval`
  before the Intent returns; pin/unpin/unchanged/failure do not purge. This is
  the composition join between two existing owners, not a second Gateway,
  writer, change feed, or global cache bus (REVIEW Card 9B).

## Acceptance

- `ClipyIntegrationTests`: **re-run the WS1–WS21 paths through the composed app** (real `SwiftDataHistory` + `PasteboardAdapter` + `PresentationUI`), not just the in-isolation History tests — this is the end-to-end acceptance for the walking skeleton (Part VI §8: "each path crosses the public `ClipboardHistory` interface and real `SwiftDataHistory`").
- XcodeGen-produced app target builds; the SwiftPM library graph stays package-owned (Part I §9 item 6).
- `ClipyIntegrationTests`: a second `open()` over an already-open persistent URL is detected and rejected — it does not create a second writer or `ModelContext` (Part I §8).
- Negative (Part I §8): ClipyApp makes no Domain decision and creates no duplicate persistence path; it does not pass a business ID to `registeredModel(for:)`; it holds no second writer or UI-bound `ModelContext`.
- `ClipyIntegrationTests`: with a real in-memory Authority and post-commit
  observation deliberately held, an authorized `RemoveItemIntent` returns
  only after the exact stale row is removed; an unrelated row survives and a
  no-op external mutation publishes no purge.

## Risks / notes

- Paste is intentionally not durable History state — a clipboard side effect happens after `pastePayload` returns, outside the transaction (Part IV §8).
- This module owns the M3 composition + state-2 re-verification via `ClipyIntegrationTests`; full state-3 acceptance (packaging/notarization, `.app` launch, accessibility, localization, product tests) is deferred to separate acceptance outside this roadmap (Part VI §11).
