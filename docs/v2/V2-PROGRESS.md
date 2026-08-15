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
| 2026-08-15 | Ledger created; V2 work starts | — | done | this commit |

## 1. V2-0 — v1 executable-specification closure

**Status:** in progress (opened 2026-08-15).

Scope per `V2-roadmap` §2 Step V2-0: the recorded state-2 declaration, the
D1–D19 evidence reconciliation, and the corrected v1 `docs/PROGRESS.md`.

### 1.1 D1–D19 evidence reconciliation

- **Status:** not started.

### 1.2 State-2 declaration + `docs/PROGRESS.md` correction

- **Status:** not started.

## Open blockers and follow-ups

- None recorded yet beyond the `V2-roadmap` §4 ledger itself.
