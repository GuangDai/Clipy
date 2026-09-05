# Module 5 — PresentationUI

- **Status:** done (step 9a; landed in `c037a71` and recorded by `4c39499`,
  revised by the post-step-9 commits `a028c8c`..`cc59aa8` — including the
  dwell-driven preview pane — CI-green at run
  [32319164667](https://github.com/GuangDai/Clipy/actions/runs/32319164667);
  see `../PROGRESS.md` step 9)
- **Spec references:** ownership `../01-architecture.md` §2 row + §6 (Main actor isolation) + §4 (scripted-preview adapter allowance); browse/search DTOs `../03b-instruction-set.md` §8; detail/paste/thumbnail DTOs `../03b-instruction-set.md` §9; protocol `../03a-instruction-set.md` §3 (`ClipboardHistory`); flows `../01-architecture.md` §5.2, §5.4, §5.5, §5.7.
- **Dependencies:** `HistoryCore` (DTOs + `any ClipboardHistory`), package-only Foundation facts from `ClipboardFormats`, the concrete package-only `ContentPreview`, `SwiftUI`, and a local CoreGraphics display edge. Never imports `HistoryDomain`, `HistoryStorage`, SwiftData, ImageIO, or `@Model`; receives value snapshots and an injected `any ClipboardHistory`. Preview/Details/Edit keep separate purpose admission.
- **Test targets:** `PresentationUITests` for UI lifecycle/caller behavior and `ContentPreviewTests` for exact renderer behavior.
- **Step:** 9a.

## Deliverables

- **View state** built from `HistoryCore` DTOs (`HistoryRow`, `HistoryPage`,
  `HistoryDetails`, `PastePayload`, `ThumbnailPayload`,
  `HistoryItemReference`) plus bounded inert ContentPreview artifacts.
- **Interactions** that call `browse` / `observe` / `details` / `perform` / `pastePayload` / `thumbnail` through the injected `any ClipboardHistory`.
- **Unified retention presentation:** maximum-unpinned count and the admitted
  age/storage/revision policies share one Retention group, configured snapshot,
  and edit generation. Their distinct v1/V2 actions retain separate Apply
  controls. An unchanged exact candidate is not an action; display rounding
  must not rewrite untouched sub-unit raw values, while an edited whole-unit
  field represents the user's explicit whole-unit value.
- **Selection, window behavior, observable presentation state** on the Main actor (Part I §6).
- **Drag-out:** register each displayed row's actual Effective type, including
  opaque representations, with plain text and preferred raster types first.
  Require the displayed exact reference when the drag begins, then resolve
  current Effective Content lazily through `pastePayload(for:)` by ID
  (`03b` §9 / `04` §8 `DEC-PASTE-REFERENCE`). A drag already started can
  finish after the panel closes. A removed item fails the read; an advertised
  type hidden by a later revision completes without bytes.
- **Scripted preview adapter:** a small `ClipboardHistory` implementation for SwiftUI previews; it must be `Sendable` and must not substitute for storage semantic tests (03a §3, 01 §4).
- **Preview deep module:** `PreviewContentLoader` alone owns History reads,
  exact-reference/task/generation/lifecycle fences and publication. It maps one
  immutable Effective Content snapshot into `ContentPreview`, which owns the
  image-first/exact-text route, fixed budgets, eager ImageIO work and bounded
  inert outcomes. The SwiftUI edge constructs and immediately consumes a
  `CGImage`; no framework object enters observable state or crosses an actor or
  target signature.

## Acceptance

- `PresentationUITests`: views render from DTO snapshots; interactions issue correct requests.
- Import confinement (Part VI §6): `SwiftUI` belongs in this target and
  `HistoryDomain`/`HistoryStorage`/`SwiftData` remain forbidden by architecture
  and review.
- Details and the large preview display exact UTF-8 plus native/external
  UTF-16 plain text. A UTF-16 BOM chooses byte order; without one, native
  text uses arm64 little endian and external text uses big endian. Details
  retains its 500-character excerpt. Replace continues to require the exact
  UTF-8 paired editor codec; displaying another encoding does not authorize
  re-encoding it. Keep Current preserves its exact bytes.
- `ContentPreviewTests` prove exact UTF-8 and native/external UTF-16 behavior,
  exact PNG eager BGRA8/sRGB artifacts, malformed/unsupported classification, and
  content-free active-job/source-byte accounting. The history-pane profile
  admits at most 64 MiB across the complete immutable representation snapshot,
  before source selection or native decode: the exact aggregate boundary may
  produce a bounded artifact, while one byte over is `.resourceLimit` for
  declared text, image, and otherwise-unsupported data alike. Presentation
  lifecycle tests deterministically prove slow A→fast B, panel close, and
  same-ID revision retarget late-result fences through the real renderer seam.
  ContentPreview's production path awaits one bounded off-actor native raster
  slot, so the A→B test parks at that real native entry and B text completes
  through production scheduling rather than a DEBUG-only actor suspension.
- Thumbnail application discipline: a thumbnail result tagged with `HistoryItemReference(id, contentVersion)` is applied only while the row still carries that exact reference (Part I §5.7, Part IV §9).
- Thumbnail capacity is a product-owned policy (500 entries / 64 MiB decoded
  per surface), not caller configuration. Only owner tests may inject smaller
  ceilings or read cache/in-flight counters. This does not admit the deferred shared
  completed-thumbnail cache or establish an RSS/eviction performance budget.
- Relative copy time uses the system abbreviated formatter under the owning
  `01` §6 rule. One list-owned wall-clock minute cadence supplies the same
  explicit `now` to every row; a label may therefore lag its item-relative
  threshold by less than one minute. Rows never own timers, and there is no
  process-global clock service.
- Negative: no `@Model`, Domain state, persistence rules, or change-feed bookkeeping in this target (Part I §2).
- Negative: PresentationUI never imports ImageIO or retains encoded preview
  bytes/`CGImage`; ContentPreview never imports HistoryCore/HistoryStorage or
  owns item/reference/cache semantics.

## Risks / notes

- The UI owns the latest returned page as ordinary caller state, not a History cache tier (Part IV §11).
- Observation emits complete replacement pages, not deltas; the UI replaces, never applies event deltas (Part I §5.5, Part IV §5).
- Edit Content is append-only. Before Save, the editor explicitly states that
  Save appends an immutable revision and that previous/original content may
  remain in revision history; it must never imply that editing redacts retained
  Canonical Content or older revisions (REVIEW Card 3D).
