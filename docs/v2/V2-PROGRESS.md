# V2 Implementation Progress Ledger (living)

> **What this is:** the living record mandated by `V2-roadmap` §15. One section
> per roadmap slice as it starts; every completed work item is recorded here
> **at completion time**, with its commit, evidence, and follow-ups. The v1
> `docs/PROGRESS.md` stays frozen for v1. Status terms mirror `V2-roadmap` §1.
>
> **Ground truth at ledger creation (2026-08-15):** branch `codex/v2-implementation`
> off `master` `dfb08f2` (v1 steps 0–8 landed and verification-audited;
> `docs/V1-Verified/` closure run 31449682036, 314 tests / 41 suites green;
> step 9 still scaffold). Work host is Linux: local verification covers the
> Python source gates (`scripts/import_gate.py`, `scripts/escape_hatch_scan.py`)
> only; every Swift build/test/symbol-snapshot claim must cite a macOS CI run
> observed through a PR to `master`. No Swift claim is ever recorded from local
> execution.
>
> **Working method (per work item):** 阅读 doc → 实现 (subagent where useful) →
> 审查 → 测试 → 审查 → 提交 → 记录. Each item's entry below names: what the
> docs required, what was implemented, who reviewed and what they found, what
> verification ran (with run links), and what remains open. Deviations are
> recorded, never silently absorbed.

## 0. Work log

| Date | Item | Slice | Result | Evidence |
|---|---|---|---|---|
| 2026-08-15 | Ledger created; V2 work starts | — | done | `dafade4` |
| 2026-08-15 | D1–D19 evidence reconciliation mapped (read-only audit subagent; counts independently re-verified: 52 domain tests / 384 `@Test` / 49 suites at `dfb08f2`) | V2-0 §1.1 | done | this commit |
| 2026-08-15 | State-2 declaration re-affirmed for current tree; stale counts corrected in v1 `docs/PROGRESS.md` | V2-0 §1.2 | done | this commit |

## 1. V2-0 — v1 executable-specification closure

**Status:** done (2026-08-15), except the standing V2-0 exit re-run note below.

Scope per `V2-roadmap` §2 Step V2-0: the recorded state-2 declaration, the
D1–D19 evidence reconciliation, and the corrected v1 `docs/PROGRESS.md`.
Method: one read-only audit subagent produced the by-number map against
`docs/02-domain.md` §14 and the live test tree; every count it reported was
independently re-verified by grep before being recorded; the map and the
declaration were then written into the docs cited below.

### 1.1 D1–D19 evidence reconciliation

- **Status:** done. The by-number map (source: audit of `dfb08f2`):
  - **D1, D2, D3, D4, D7, D9, D10, D11, D13, D15, D19** — direct planner
    tests in `Tests/HistoryDomainTests/` (`CapturePlannerInvariantTests`,
    `CapturePlannerRankAndCapacityTests`, `PinRevisionPlannerInvariantTests`,
    `RevisionPlannerInvariantTests`, `RetentionPlannerTests`,
    `ComplexityBoundaryTests`), most with end-to-end WS reinforcement in
    `Tests/HistoryStorageTests/`.
  - **D5, D6** — Storage-owned by the declared seam split
    (`DomainSmokeTests.swift:16` ownership matrix); proven by WS1/WS2/WS9/
    WS10/WS11/`TransactionBoundaryProofTests`.
  - **D8, D17** — structural, per the same matrix: D8 by non-failable
    `Complete*` fact wrappers (partial candidacy unconstructible) plus the
    WS5 fail-closed index-unavailable proof; D17 by the import-confinement
    and escape-hatch gates plus Swift 6 strict-concurrency builds. No runtime
    test asserts either; that is the recorded owning seam, not a gap.
  - **D12** — `PinRevisionPlannerInvariantTests` compaction fixtures plus
    `WS8`/`PinnedOrderValidatorTests`.
  - **D14** — projected-recency victim fixtures in
    `CapturePlannerRankAndCapacityTests` and `WS9` (WS file does not cite the
    D-number; substance is proven).
  - **D16, D18** — proven by input-order-permutation equivalence fixtures and
    complete-payload assertions across all planner suites (no test cites the
    number; the assertions are the proof).
- **Honest residuals (recorded, not blocking):** D1's "never reused after
  deletion" clause is covered only indirectly (removal-absence + fresh-ID
  creation); no single test captures remove-then-recapture ID freshness.
- **Conclusion:** all nineteen invariants have direct test evidence or a
  documented owning seam, matching V1-Verified R3's exit condition ("direct
  tests exist only at the documented seams and cover every named
  branch/invariant", `docs/V1-Verified/06-remediation-plan.md:49`, status
  `complete`).

### 1.2 State-2 declaration + `docs/PROGRESS.md` correction

- **Status:** done. `docs/PROGRESS.md` audit-baseline section now carries a
  dated state-2 declaration for the current tree (`dfb08f2`: 384 `@Test` in
  49 suite structs, HistoryDomain 52 tests / 7 files; full-scope run
  31815028830 green end to end), and its two stale "47-test" claims (Step 2
  section, verification summary) were corrected with growth notes and a
  pointer to §1.1 above.
- **Standing note:** V2-0's formal exit ("full gates … green with zero
  warnings on macOS 26 arm64") is evidenced by run 31815028830 at `4c5622c`;
  the doc-only V2-0 closure commits that follow re-run nothing locally (Linux
  host); the next code-carrying PR re-establishes the green chain on CI.

## Open blockers and follow-ups

- None recorded yet beyond the `V2-roadmap` §4 ledger itself.
