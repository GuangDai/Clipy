# Module 1 — HistoryCore

- **Status:** not-started
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
- **Safety bounds:** `HistoryLimits` — the Part VI §2 bounds as an immutable `Sendable, Hashable` value with `.standard` (the single value production and tests use). *(06 §2 sanctions HistoryCore as the Foundation-only home for this public type.)*

## Acceptance

- Part VI §6: compiles with only `import Foundation`; Swift 6 complete strict-concurrency; no `@unchecked Sendable` / `nonisolated(unsafe)` / service locator / second writer.
- Part VI §6: public symbol surface is snapshot-tested so package-only Domain/Storage vocabulary cannot leak. The expected surface is derived mechanically from the 03a §2–§7 + 03b §8–§9 public declarations (public structs/enums/protocols and their public members); these public types appear, but their `package init` members — and `ContentVersion.initial`/`successor()`, `ChangePosition.zero`/`successor()` — must NOT appear in the snapshot (package-only minters, not public API).
- Part VI §6 build-time gate: a deliberate forbidden import fails the import scan.
- Every public struct with caller construction has a real public initializer (03a/03b); every declared conformance compiles.

## Risks / notes

- The closed `HistoryAction` enum makes adding an action an owned source change across Core, Domain, Storage, tests (03a §1) — compiler-exhaustive switches must fail until handled.
- IDs/tokens are package-init; this centralizes minting, it is not a security boundary (03a §2).
