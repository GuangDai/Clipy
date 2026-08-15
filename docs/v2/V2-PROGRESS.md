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
| 2026-08-15 | D1–D19 evidence reconciliation mapped (read-only audit subagent; counts independently re-verified: 52 domain tests / 384 `@Test` / 49 suites at `dfb08f2`) | V2-0 §1.1 | done | `1acbb52` |
| 2026-08-15 | State-2 declaration re-affirmed for current tree; stale counts corrected in v1 `docs/PROGRESS.md` | V2-0 §1.2 | done | `1acbb52` |
| 2026-08-15 | DC-01: fact sidecars promoted verbatim as `V2-facts.md` Cycle 7 §7.1–§7.4 (implementation subagent; append-only verified 1521+/0−; 36 citation repoints across V2-03/04/06/07 plus the V2-05 Cycle-6 §6.1 blockquote fix + 3 roadmap edits; orchestrator re-verified diff and spot-checked repoints) | V2-1 | done | this commit |
| 2026-08-15 | Product decisions recorded: first release = M1 + V2-02; DC-23 = one policy value, three independently disable-able dimensions; OPEN-2/DC-08-retention = not admitted, deferred. Admission record written into `V2-02` Record 1 | V2-1/V2-2 | done | this commit |
| 2026-08-15 | DC-02 closed: single `MigrationStage.custom` hop topology (sosumi: API pages + WWDC2025/291; lightweight+custom on one version pair undocumented → two-stage wording retracted; idempotence-by-construction + runner-proved interruption added to `RET-PLATFORM-1b(e)`; pre-Authority migration-context exception recorded, owned by M1) | V2-1 | done | this commit |
| 2026-08-15 | DC-03 closed: incremental shipping, ship-order version allocation; `HistorySchemaV2` = v1 + retention rows only | V2-1 | done | this commit |
| 2026-08-15 | DC-04 remainder closed (byte-for-byte claims qualified at §4.1/§7/D24; insert/coalesce/first-revision wording fixed in §3.3b against v1's empty-lineage-at-insert, `02` §2); DC-21 closed (`maxAge.isFinite` boundary check + persisted non-finite fails closed, §8.3) | V2-1 | done | this commit |
| 2026-08-15 | DC-27 closed (option (a): veto moved to PHASE C after PHASE-B retirement selection, scoped to survivors; §4.4 + §8.3); DC-28 closed (option (b): exposure accepted and recorded, §4.2 + §8.3) | V2-1 | done | this commit |
| 2026-08-15 | B6: one total `SwiftDataHistory.open` bootstrap order recorded (11 executable steps, release-scoped M1 + V2-02, extending v1 `05` §13; roadmap §5 "M1 total open order") | V2-1 | done | this commit |
| 2026-08-15 | B7: `V2-00` §8 self-review (a)–(j) all PASS + final cross-document review, verdict **RELEASE DESIGN READY**, zero blockers, 5 LOW (all applied: M1 status line, order-step-2 wording aligned to `RET-PLATFORM-1b(d)` runtime assertion, registry §14 pointers, work-log rows; schema-name supersessions already follow-ups). Review subagent record preserved in this row; DC-24 adjudicated NOT applicable to this release | V2-1 | done | `b203fdd` |
| 2026-08-15 | Draft PR [#1](https://github.com/GuangDai/Clipy/pull/1) opened against `master` to carry the V2 chain on the macOS CI | process | done | PR #1 |
| 2026-08-15 | M1.1: `HistorySchemaV1: VersionedSchema` anchor + `HistorySchemaAnchorTests` (TDD; expected values from v1 `05` §3). `v1Schema` value/models/rows/behavior frozen; `open` untouched | M1.1 | done (CI pending) | `c1687e7` |
| 2026-08-15 | Docs chain green on macOS CI (all gates, zero warnings) | process | done | run [31870142315](https://github.com/GuangDai/Clipy/actions/runs/31870142315) |
| 2026-08-15 | M1.2 (schema half): `HistorySchemaV2` (2.0.0) + `RetentionExpansionConfigRow` + `RetainedBytesRow` + `HistorySchemaV2Tests` + the immutable schema-version ledger `docs/v2/V2-SCHEMAS.md`. Schema definition only — no open wiring yet | M1.2 | done (CI pending) | `8a15458` |
| 2026-08-15 | Total-open-order step 7 sequencing annotation: runtime 1:1 `RetainedBytesRow` check activates at R.3 (projection stamping); M1 proves it for migrated stores via fixtures | V2-roadmap §5 | done | `6278aed` |
| 2026-08-15 | **CI red, honestly recorded:** runs 31870294903/31870409039 failed — M1.1/M1.2 test files lacked `import Foundation` (`UUID`/`Data`/`Date` out of scope; SwiftPM job). Root cause: written on the Linux host which cannot compile; the PR chain IS the compile gate. Fix `3e488d3` | M1.1/M1.2 | fixed | `3e488d3` |

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

## 2. V2-1 — design-input stabilization (first release: M1 + V2-02)

**Status:** done (2026-08-15). Closed: DC-01, DC-02, DC-03, DC-04,
DC-08-retention-clause (OPEN-2 not admitted), DC-21, DC-23, DC-27, DC-28;
release scope decided and V2-02 admitted (Record 1); the one total open
order recorded (roadmap §5); `V2-00` §8 self-review (a)–(j) all PASS and the
final cross-document review returned **RELEASE DESIGN READY** with zero
blockers (DC-24 adjudicated not applicable to this release — it triggers at
J1's admission). V2-1 is complete for the M1 + V2-02 release; M1 code may
start.

### 2.1 Release-scope and admission decisions (product owner, 2026-08-15)

- First release admits **M1 + V2-02 (R1+R2+R3)** only; no other graft is
  admitted, so none reserves schema, symbols, or placeholders.
- **DC-23:** one `HistoryRetentionPolicies` value, three independently
  disable-able dimensions; slices untrimmed.
- **OPEN-2 (DC-08 retention clause):** no public retained-bytes read; UX
  shows policies and receipts only.
- DC-03 follows: incremental shipping; `HistorySchemaV2` = v1 + retention
  rows; later grafts take later versions.

## Open blockers and follow-ups

- **None for the M1 + V2-02 release** — design is ready; M1 code slices
  (M1.1–M1.4) may start. Their progress is recorded in §3 as it lands.
- **Follow-up (each graft's own admission):** correct the consolidated-era
  schema-name statements superseded by DC-03 ship-order allocation —
  `V2-01` §3.2 (claims `HistorySchemaV2` includes
  `EnrichmentRow`/`EnrichmentConfigRow`), `V2-03` §3 (~line 242, "the
  consolidated V2 schema introduced by V2-01 and extended…") and its §14
  migration record (~2513–2522), and `V2-04` §8/§15 (`ThumbnailCacheConfigRow`
  added to `HistorySchemaV2`, ~2034–2043 and ~2210). Retention takes
  `HistorySchemaV2`; each later admitted graft receives the next version.
- **Follow-up (V2-02 Record 1):** the admission names OPEN-2 as not-admitted;
  revisiting it requires a new admission record (it is not silently
  reserved).
- Beyond the release scope, `V2-roadmap` §4 retains its open DC rows for the
  unselected grafts; this ledger does not track them until their grafts are
  selected.
