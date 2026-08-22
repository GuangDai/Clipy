# Module 5 — PresentationUI

- **Status:** done (step 9a; landed in `c037a71` and recorded by `4c39499`,
  revised by the post-step-9 commits `a028c8c`..`cc59aa8` — including the
  dwell-driven preview pane — CI-green at run
  [32319164667](https://github.com/GuangDai/Clipy/actions/runs/32319164667);
  see `../PROGRESS.md` step 9)
- **Spec references:** ownership `../01-architecture.md` §2 row + §6 (Main actor isolation) + §4 (scripted-preview adapter allowance); browse/search DTOs `../03b-instruction-set.md` §8; detail/paste/thumbnail DTOs `../03b-instruction-set.md` §9; protocol `../03a-instruction-set.md` §3 (`ClipboardHistory`); flows `../01-architecture.md` §5.2, §5.4, §5.5, §5.7.
- **Dependencies:** `HistoryCore` (DTOs + `any ClipboardHistory`); `SwiftUI`. Never imports `HistoryDomain`, `HistoryStorage`, SwiftData, or `@Model`; receives value snapshots and an injected `any ClipboardHistory`.
- **Test target:** `PresentationUITests`.
- **Step:** 9a.

## Deliverables

- **View state** built only from `HistoryCore` DTOs (`HistoryRow`, `HistoryPage`, `HistoryDetails`, `PastePayload`, `ThumbnailPayload`, `HistoryItemReference`).
- **Interactions** that call `browse` / `observe` / `details` / `perform` / `pastePayload` / `thumbnail` through the injected `any ClipboardHistory`.
- **Selection, window behavior, observable presentation state** on the Main actor (Part I §6).
- **Scripted preview adapter:** a small `ClipboardHistory` implementation for SwiftUI previews; it must be `Sendable` and must not substitute for storage semantic tests (03a §3, 01 §4).

## Acceptance

- `PresentationUITests`: views render from DTO snapshots; interactions issue correct requests.
- Import confinement (Part VI §6): `SwiftUI` confined to this target; a deliberate `HistoryDomain`/`HistoryStorage`/`SwiftData` import fails the scan.
- Thumbnail application discipline: a thumbnail result tagged with `HistoryItemReference(id, contentVersion)` is applied only while the row still carries that exact reference (Part I §5.7, Part IV §9).
- Relative copy time uses the system abbreviated formatter under the owning
  `01` §6 rule. One list-owned wall-clock minute cadence supplies the same
  explicit `now` to every row; a label may therefore lag its item-relative
  threshold by less than one minute. Rows never own timers, and there is no
  process-global clock service.
- Negative: no `@Model`, Domain state, persistence rules, or change-feed bookkeeping in this target (Part I §2).

## Risks / notes

- The UI owns the latest returned page as ordinary caller state, not a History cache tier (Part IV §11).
- Observation emits complete replacement pages, not deltas; the UI replaces, never applies event deltas (Part I §5.5, Part IV §5).
