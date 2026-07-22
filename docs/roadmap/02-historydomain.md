# Module 2 — HistoryDomain

- **Status:** not-started
- **Spec references:** `../02-domain.md` §1–§14 (Part II, the entire functional core); purity/boundary §1.
- **Dependencies:** `Foundation` + `HistoryCore` only. No I/O, no actor, no clock, no UUID/Date generation, no ModelContext, no cache, no async (02 §1).
- **Test target:** `HistoryDomainTests`.
- **Step:** 2.

## Deliverables (from spec "Owns")

- **Content values:** `ContentRepresentation`; `ContentFingerprint`, `ContentSignatureEntry`; `CanonicalRepresentation`, `CanonicalContent`; `EffectiveContent`; `ContentRevision` (02 §2). The validating `CanonicalContent` initializer; `effectiveContent(of:)` derivation (02 §2.6).
- **Retained state:** `CopyOrigin`, `CopyOccurrence`, `PinOrdinal` (with explicit `<`), `HistoryItemState` (02 §3).
- **Prepared inputs (types only — minting is Storage):** `PreparedCapture`, `PreparedRevision` (02 §4).
- **Action-specific complete facts:** `CompleteDedupCandidates`, `RetainedItemSummary`, `CompleteRetentionInventory`, `IngestFacts`; `CompletePinnedOrder`, `PinFacts`; `RevisionFacts`; `RemoveFacts`, `ClearFacts`; `RetentionFacts`, `RetentionPolicy` (02 §5).
- **Rejection vocabulary:** `DomainRejection` (incl. `corruptLineage`) (02 §6).
- **Strong mutation plan:** `HistoryMutation`, `NewHistoryItem`, `RetirementReason`, `MutationPlan`, `PlannedOutcome`, `PlanningResult` (02 §7).
- **Pure planners (02 §8):** `planCapture`, `planPinnedPlacement`, `planUnpin`, `planRemove`, `planClear`, `planRevision`, `planRetention`.
- **Dedup helper (02 §9.2):** `canonicalContains`.
- **Invariants D1–D19** enforced by the above (02 §14).

## Acceptance

- Part VI §6: compiles importing only Foundation + HistoryCore; no `@unchecked Sendable` / `nonisolated(unsafe)` / service locator / second writer; forbidden-import scan passes.
- Domain unit tests demonstrating each of D1–D19 (Part VI §8: "Domain unit tests supplement these paths but do not replace them").
- Planner determinism (D16): identical prepared inputs + facts ⇒ identical `PlanningResult`.
- Purity: no `UUID()`/`Date()`/`ContentVersion.initial`/`successor()`/`ChangePosition.successor()` calls in Domain (02 §4) — verified by build/scan.
- `RetentionPolicy.maximumUnpinnedItems` is ≥1 (D19); `PinOrdinal.rawValue` non-negative; `CanonicalContent` rejects empty/duplicate-type/empty-bytes input.

## Risks / notes

- The Domain never sees corrupt/incomplete facts — Storage fact-loads and validates first; `corruptLineage` is the defensive backstop only (02 §6, §11 step 3).
- Plan invariants 1–10 (02 §7) are the contract Storage stamps mechanically; the Domain→Stamped rename table is in `../05-authority-kernel.md` §9.
