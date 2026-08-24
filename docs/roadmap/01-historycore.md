# Module 1 — HistoryCore

- **Status:** done (step 1; see Progress below)
- **Spec references:** `../03a-instruction-set.md` §1–§7, `../03b-instruction-set.md` §8–§12 (Part III, the entire caller interface); ownership `../01-architecture.md` §2; forbidden imports `../01-architecture.md` §8; safety bounds `../06-cross-cutting.md` §2.
- **Dependencies:** Foundation only. Imports nothing else (no SwiftData/AppKit/SwiftUI/ImageIO/xxh3, no HistoryDomain/HistoryStorage).
- **Test target:** `HistoryCoreTests`.
- **Step:** 1.

## Deliverables (from spec "Owns")

The complete public, Foundation-only surface between callers and retained History:

- **Protocol:** `ClipboardHistory: Sendable` — `perform`, `browse`, `observe`, `details`, `pastePayload`, `thumbnail` (03a §3).
- **Identity & coherence tokens:** `HistoryItemID`, `RevisionID`, `ContentVersion` (+ `.initial`, `.successor()`), `ChangePosition` (+ `.zero`, `.successor()`), `HistoryItemReference`. Package-only minters centralize creation in HistoryStorage (03a §2).
- **Raw capture seam:** `CapturedRepresentation`, `CopyOriginObservation`, `ClipboardCapture` (03a §4).
- **Closed action set:** `HistoryAction`, `PinnedPlacement`, `ClearScope`, `RevisionRequest`, `RevisionIntent`, `RevisionTarget`, `RevisionDraft`, `RevisionDecision`, `RevisionDecisionAction` (03a §5).
- **Receipts:** `HistoryReceipt`, `HistoryCommit`, `HistoryCommitOutcome` (03a §6).
- **Browse/search requests:** `SearchMode`, `HistoryBrowseKind`, `HistoryPageCursor`, `HistoryBrowseRequest`, `HistoryObservationRequest` (03a §7).
- **Read DTOs:** `UTF16TextRange`, `SearchPresentation`, `HistoryRow`, `HistoryPage` (03b §8); `HistoryRepresentation`, `RevisionSummary`, `CopyOccurrenceSummary`, `HistoryDetails`, `PastePayload`, `PixelSize`, `ThumbnailFormat`, `ThumbnailPayload` (03b §9).
- **Typed failures:** `HistoryFailure` + `InvalidInputReason`, `PinnedPlacementFailure`, `CapacityKind`, `UnavailableReason`, `PersistenceFailure` (03b §10).
- **Safety bounds:** `HistoryLimits` — the Part VI §2 bounds as an immutable
  `Sendable, Hashable` value with `.standard` (the only production value) and
  a validated package-only custom-profile seam for focused storage/codec
  tests. *(06 §2 sanctions HistoryCore as the Foundation-only home for this
  public type.)*

## Acceptance

- Part VI §6: compiles with only `import Foundation`; Swift 6 complete strict-concurrency; no `@unchecked Sendable` / `nonisolated(unsafe)` / service locator / second writer.
- Part VI §6: focused owner tests compile the caller-visible initializers,
  conformances, raw vocabulary, and behavior. Package-only Domain/Storage
  vocabulary remains excluded by access control and review; no generated
  symbol snapshot is maintained.
- Every public struct with caller construction has a real public initializer (03a/03b); every declared conformance compiles.

## Risks / notes

- The closed `HistoryAction` enum makes adding an action an owned source change across Core, Domain, Storage, tests (03a §1) — compiler-exhaustive switches must fail until handled.
- IDs/tokens are package-init; this centralizes minting, it is not a security boundary (03a §2).

## Progress

- **Step 1 landed** at [`4e3e4fd`](https://github.com/GuangDai/Clipy/commit/4e3e4fd3e403c0e3f1050f74e3eb7b9d0efdb4bb) (03a §2–§7, 03b §8–§10, 06 §2); follow-ups [`e07a34a`](https://github.com/GuangDai/Clipy/commit/e07a34a8518ff9477d1dd6efd472e6e650813e7d) (CI `XCODEGEN_HOME` step env), [`6b50d2e`](https://github.com/GuangDai/Clipy/commit/6b50d2ec7d6fd4d1dd979a34cb2860cb7855833e) and [`1cf1715`](https://github.com/GuangDai/Clipy/commit/1cf1715d39fb54c6c18ca959a32921a7d74e1128) (historical symbol-snapshot tooling, retired 2026-08-24).
- **Evidence — green at run [29964640300](https://github.com/GuangDai/Clipy/actions/runs/29964640300) (macos-26 runner, HEAD `7994844`):** compiles Swift 6 complete strict-concurrency importing only Foundation; `HistoryCoreSurfaceTests` green. The run also carried the now-retired scan/snapshot checks; they are historical evidence, not current CI requirements.
