# Module 6 — ClipyApp

- **Status:** not-started
- **Spec references:** composition-root ownership `../01-architecture.md` §2 row + §5.6 (paste orchestration) + §8 (forbidden service-locator/second-writer) + §9 item 6 (XcodeGen app-target gate) + §4 (scripted-preview adapter); paste coherence `../04-coherence.md` §8; caller example `../03b-instruction-set.md` §12; adapter open `../05-authority-kernel.md` §2.
- **Dependencies:** `HistoryCore`, `HistoryStorage` (`SwiftDataHistory`), `PasteboardAdapter`, `PresentationUI`. It is the **sole composition root** and the only place that coordinates History with outbound pasteboard writes.
- **Test target:** `ClipyIntegrationTests`.
- **Step:** 9b.

## Deliverables

- **Concrete construction:** `SwiftDataHistory.open(configuration:)` with `HistoryLimits.standard`; wire it as the `any ClipboardHistory` injected into `PresentationUI` and used by the paste path (Part V §2).
- **Lifecycle:** process-wide single `SwiftDataHistory`; no `.shared`/`.current` service locator; guard against a second `open` over the same persistent URL — an implementation responsibility inferred from Part I §8's no-second-writer rule (not stated verbatim by any single spec section).
- **Paste orchestration:** `history.pastePayload(for:)` → `PasteboardAdapter.write(payload)` — the only History→pasteboard hand-off, kept outside the History transaction (Part I §5.6; Part IV §8; 03b §12).
- **Dependency injection:** supplies `any ClipboardHistory` (production = `SwiftDataHistory`, previews = scripted adapter) to the UI without leaking Storage/Domain types (Part I §2, §4).

## Acceptance

- `ClipyIntegrationTests`: **re-run the WS1–WS21 paths through the composed app** (real `SwiftDataHistory` + `PasteboardAdapter` + `PresentationUI`), not just the in-isolation History tests — this is the end-to-end acceptance for the walking skeleton (Part VI §8: "each path crosses the public `ClipboardHistory` interface and real `SwiftDataHistory`").
- XcodeGen-produced app target builds; the SwiftPM library graph stays package-owned (Part I §9 item 6).
- `ClipyIntegrationTests`: a second `open()` over an already-open persistent URL is detected and rejected — it does not create a second writer or `ModelContext` (Part I §8).
- Negative (Part I §8): ClipyApp makes no Domain decision and creates no duplicate persistence path; it does not pass a business ID to `registeredModel(for:)`; it holds no second writer or UI-bound `ModelContext`.

## Risks / notes

- Paste is intentionally not durable History state — a clipboard side effect happens after `pastePayload` returns, outside the transaction (Part IV §8).
- This module owns the M3 composition + state-2 re-verification via `ClipyIntegrationTests`; full state-3 acceptance (packaging/notarization, `.app` launch, accessibility, localization, product tests) is deferred to separate acceptance outside this roadmap (Part VI §11).
