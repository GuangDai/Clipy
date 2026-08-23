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
| 2026-08-15 | M1.3+M1.4+open wiring (implementation subagent; orchestrator diff-reviewed): `ensureRetentionExpansionConfig` fail-closed bootstrap (§8.3 bounds constants), `RetainedBytesBackfill` full-recompute upsert, `HistoryMigrationPlan` single custom hop, `open`/`performStartup` wired to the total order; `WalkingSkeletonSupport` assertion containers moved to the V2 schema (necessary: startup fetches the config row). V2-02 Record 5 wording aligned (Canonical decode is a required input of the revision codec's containment check) | M1.3/M1.4 | done (CI pending) | `474992f` |
| 2026-08-15 | **CI red #2, honestly recorded:** run 31871227640 — test-side compile errors (missing `import HistoryCore` in RetentionConfigBootstrapTests; two synchronous accesses to the actor-isolated `authority.container`). Fix `37616cb` per the repo's independent-container assertion pattern; test (a) moved to a fresh persistent store | M1.3/M1.4 | fixed | `37616cb` |
| 2026-08-15 | **M1 GREEN on macOS CI:** run [31871812062](https://github.com/GuangDai/Clipy/actions/runs/31871812062) — all four jobs success (gates/SwiftLint strict, SwiftPM build+test **402 tests** = 384 v1 + 18 new across HistorySchemaAnchorTests/HistorySchemaV2Tests/RetentionConfigBootstrapTests/HistoryMigrationTests, XcodeGen app build/test, §9 perf proofs), zero warnings (CI log scans fatal). M1.1–M1.4 executable; RET-PLATFORM-1/1b(a)–(d) fixture-proven, 1b(e) model-proven (double-backfill + wrong-scalars correction); perf/evidence lanes are dispatch-only and remain for the release-evidence pass | M1.1–M1.4 | done | run 31871812062 |
| 2026-08-15 | R.1 core contract (implementation subagent; orchestrator verified the public value file against V2-02 §3.1 verbatim + reviewed the switch audit): `HistoryRetentionPolicies`/`AgeRetention`/`StorageRetention`/`RevisionRetention` (both-nil revision normalization at construction), enum cases `.setRetentionPolicies`/`.retentionPoliciesSet(retiredItems:prunedRevisions:)`/`.storageBytes` (placement per §8.1 list), `RetentionPolicyBounds.validate` boundary predicate (isFinite-first, DC-21), the single exhaustive `HistoryAction` switch gained the R.6-owed `StepDeferredError.notYetImplemented` arm (recovered from v1 commit 66a8b14). RET-COMPILE-2 audit: no other Core-enum switches exist | R.1 | done (compile proof pending) | `3900c91` |
| 2026-08-15 | Symbol snapshot drift on run 31872553238 (expected: gates job only; SwiftLint passed inside it) → dispatch-only regeneration run [31872852249](https://github.com/GuangDai/Clipy/actions/runs/31872852249) success; bot commit `6660a7b` (+17 symbols). Full-chain verification re-triggers on this ledger push | R.1 | snapshot updated | `6660a7b` |
| 2026-08-15 | **R.1 GREEN on macOS CI:** run [31873048800](https://github.com/GuangDai/Clipy/actions/runs/31873048800) — all four jobs success (gates with the regenerated snapshot, SwiftPM build+test incl. the new RetentionPoliciesTests/RetentionPolicyBoundaryTests, app build/test, §9 proofs), zero warnings. RET-COMPILE-1/2 and the R.1 policy-bound/failure-translation fixtures are proven; R.1 closed | R.1 | done | run 31873048800 |
| 2026-08-15 | R.2 pure Domain (implementation subagent; orchestrator line-reviewed the item planner against §4.1/§4.2): fact types + both planners (§6.5 signatures verbatim, non-throwing), `HistoryMutation.pruneRevisions/.setRetentionPolicies` + `PlannedOutcome.retentionPoliciesSet` (additive), StampedMutation cases + stamper/executor switch arms (R.3/R.5/R.6-owed `StepDeferredError` deferrals; receipt mapping + pin-lane flags real), 24 Domain tests incl. prefix-not-min-cardinality, R1-strict boundary, R1-before-R2 dual exclusion, stop-at-budget, overflow saturation. **Recorded design deviation:** overflow saturates at `Int.max` rather than throwing — §6.5 fixes signatures non-throwing and §4.2's `.invariantViolation` is pipeline-level; unreachable within §8.3 bounds | R.2 | done (CI pending) | `9136a03` |
| 2026-08-15 | **R.2 GREEN on macOS CI, first try:** run [31873858920](https://github.com/GuangDai/Clipy/actions/runs/31873858920) — all four jobs success, zero warnings. RET-PRUNE-1, RET-PRUNE-2 (planner half), RET-SELECT-1 fixture-proven at the Domain seam; R.2 closed | R.2 | done | run 31873858920 |
| 2026-08-15 | R.3 (implementation subagent; orchestrator spot-checked executor integrations): projection stamping primitives (insert 0/0 stamp, in-place restamp, §5.3 shorter-blob re-encode + scalars, delete extension), live step-7 both-directions 1:1 check, RetentionClock seam (§6.4; public open unchanged), executor arms real for create/append/delete/prune; `.setRetentionPolicies` still deferred to R.6. Ripple: ProjectionCorruption/ScalarReadIsolation fixtures craft matching byte rows (step-7 is live per the sequencing note) | R.3 | done (CI pending) | `c19e2df` |
| 2026-08-15 | **CI red #3 (run 31875134075), three real failures:** (1) perf — retentionMassEviction ratio **7.03 > bound 6.0**: the per-item RetainedBytesRow predicate fetch in `.delete` degraded mass retirement to a scan per delete; (2)+(3) test compile — 14 missing `await`, one non-private method using a private type. Fix `3979be9`: ONE bounded per-transaction prefetch (`prefetchRowsForRetirements`) feeding `.delete` — keeps the v1 envelope untouched instead of amending it — plus the two test-side fixes | R.3 | fixed | `3979be9` |
| 2026-08-15 | **CI red #4 (run 31875549583), my compile slip:** `'try' cannot appear to the right of ??` in the deleteRow fallback (only error class in the log; all three compile jobs). Fix `3cfe933` (explicit branch). Process note, recorded at the owner's direction: diagnose failures by READING the full failed log, never a grep head-sample | R.3 | fixed | `3cfe933` |
| 2026-08-15 | **R.3 GREEN:** run [31875678620](https://github.com/GuangDai/Clipy/actions/runs/31875678620) — all four jobs success; **461 tests / 55 suites**; retentionMassEviction **ratio 4.93 / bound 6.0** (batch prefetch restored the envelope with margin). RET-PLATFORM-2 runtime seam + projection-lifecycle fixtures + live step-7 proven; R.3 closed | R.3 | done | run 31875678620 |
| 2026-08-16 | R.4 capture composition. **Interruption honestly recorded:** the implementation agent died at its usage limit mid-task; its uncommitted production code was verified spec-faithful by a second completion agent (fixed 13 missing `in: history` test args, added the corrupted-config fail-closed fixture, de-risked a `Dictionary.Keys == Set` comparison); orchestrator spot-checked the composition core (§4.2 nil-policy early return, §8.3 feasibility guard, primary backstop, outcome-preserving merge). 11 composition tests: triple composition one-commit/one-position, R1 strict boundary, R2 stop-at-budget, pinned-over-budget atomic failure, R3-only/all-disabled exact-v1, coalesce winner-stored-bytes ×2, count-victim exclusion, corrupted-config pre-stamp fail-closed | R.4 | done (CI pending) | `433a0fa` |
| 2026-08-16 | **CI red #5 (run 31945950665), single error class (19 lines, full-log read):** `MutationPlan`'s implicit memberwise init is internal to HistoryDomain — Storage's §4.2 merge could not rebuild the plan. Fix `688ef9b`: explicit `package init`. **R.4 GREEN:** run [31946120453](https://github.com/GuangDai/Clipy/actions/runs/31946120453) — 471 tests / 56 suites; eviction ratio 4.66/6.0. RET-PERF-1/3 composition semantics + zero-decode planning path (code-audited, RET-PLATFORM-2) proven; R.4 closed | R.4 | done | run 31946120453 |
| 2026-08-16 | R.5 revise composition (implementation subagent; orchestrator spot-checked the §6.3 fold pre-scan + reworked guards): revise-lane policy loader (R2∪R3; R1-only = exact v1), §5.4 prune-before-hard-bound ordering in the extended preparation (v1 call sites unchanged via nil-delegation), speculative R3 + unsatisfiable `.revisionBytes` re-check, R2 over projected post-prune post-append scalars (protected = pinned ∪ {revised}), fused ONE-blob-write append+prune fold with retire-side disjointness preserved (R.6-owed), 10 tests incl. at-bound discriminators both dimensions | R.5 | done (CI pending) | `13394ec` |
| 2026-08-16 | **CI red #6/#7, test-side compile only (full-log reads):** runs 31947977695/31948277265 — ContentVersion(rawValue:) wants UInt64 (×2), `String(format:)`'s CVarArg dragged `0 ..< 3` literal inference ambiguous (rewritten to fixed-UUID array), and the unmasked `TimeInterval` Double argument. Fixes `48e93c3`/`6eb1942`. **R.5 GREEN:** run [31948533018](https://github.com/GuangDai/Clipy/actions/runs/31948533018) — 482 tests / 57 suites, all four jobs. RET-PLATFORM-3/3b/4, RET-STAMP-1, RET-CONCUR-1(case 2) fixture-proven; R.5 closed | R.5 | done | run 31948533018 |
| 2026-08-16 | R.6 policy sweep (implementation subagent; orchestrator verified zero StepDeferredError references + spot-checked the no-op/merge region): `.setRetentionPolicies` end-to-end — boundary validation, PHASE A scalar-exceedance prune planning (no veto), PHASE B projected R1+R2 (protected = pinned; `now` = retentionClock.now(), the seam's first production read), the §8.3 budget rejection, PHASE C DC-27 survivors-only veto, retire-subsumes-prune dropped pre-stamping, WS21-shaped true no-op, explicit D18 policy mutation, config singleton written in the position-guarded transaction; the three deferral arms real; StepDeferredError deleted per its own contract. 8 test groups | R.6 | done (CI pending) | `58d884b` |
| 2026-08-16 | **CI red #8 (run 31949831960), two seeding failures (full-log read):** equal-length seeding payloads collided with D4 (byte-identical append → `.unchanged`), tripping the helper's sentinel. Fix `1612d27` (per-OCC-version unique final byte; lengths exact). **R.6 GREEN:** run [31950153864](https://github.com/GuangDai/Clipy/actions/runs/31950153864) — **491 tests / 58 suites**, all four jobs. RET-PERF-2/RET-PRUNE-2/RET-STAMP-2/RET-SECURITY-1 posture + DC-27 discriminator pair proven; R.6 closed. **All six V2-02 engine slices (M1 + R.1–R.6) are executable; R.7 (UX handoff) remains, gated on v1 step 9** | R.6 | done | run 31950153864 |
| 2026-08-16 | **Independent clause-level gate audit** (read-only subagent at `5f0a6f5`; every row verified by reading the actual tests, run numbers not accepted as clause evidence). Fully closed: RET-COMPILE-1/2, RET-PLATFORM-1 (minor: migrated position-singleton only implicitly asserted), 1b(a)–(d), 3, 3b, 4, RET-PRUNE-1 (all 7 clauses), RET-SELECT-1 (all 5), RET-STAMP-1/2, RET-SECURITY-1; D23/D24 assertions match Record 2's classification; M1 exits proven except noted minors. **Five named remainder groups stand between "engine executable" and "all gates closed" (roadmap §1's bar):** (1) RET-PLATFORM-1b(e) engine-level process-death interruption fixture; (2) RET-CONCUR-1(1)/(3) interleaving-with-R3 fixtures (the in-file structural justification for (3) is STALE since R.6 shipped the producer); (3) RET-PRUNE-2 revise-path half; (4) RET-PERF-1/2/3 measurement halves — the perf runner has NO R1/R2/R3-active workload; (5) RET-PLATFORM-2 zero-decode clause is code-audit only on the capture/revise planning path. **Correction of this ledger's own R.6 row: gate closure was NOT reached there — the row's gate claims are posture/scoped, not clause-complete** | audit | recorded | `002f947` |
| 2026-08-16 | Remainder groups (2)+(3)+minors closed (implementation subagent, tests only, zero production changes): RET-CONCUR-1(1) coalescing-interleave-with-R3 (WS20 harness verbatim; §5.1 relation independently reimplemented in-test; committed prune = f(reloaded phase-2 lineage)); RET-CONCUR-1(3) same-item policy-sweep interleave (R3 prune preserves ContentVersion → OCC passes; phase-2 re-read; both wrong alternatives ruled out by the final decoded lineage); RET-PRUNE-2 revise half (post-prune projection rescues from R2; survivor discriminator); RET-PLATFORM-1 position-singleton explicit assertion; M1.3 downgrade (`configSchemaVersion == 0`) fence pin. **GREEN:** run [31952390783](https://github.com/GuangDai/Clipy/actions/runs/31952390783) — **495 tests / 58 suites**, all four jobs | gate closure | partial | run 31952390783 |
| 2026-08-16 | Remainder group (4) closed: three R-active perf lanes added (`retentionExpansionCapture`/`retentionExpansionRevise`/`retentionPolicySweep`; steady-churn designs bound complexity; coverage+envelope rows; runner validators re-simulated). **GREEN with strong margins:** run [31953567448](https://github.com/GuangDai/Clipy/actions/runs/31953567448) — ratios **2.64 / 2.31 / 2.65** vs bound 6.0; all four jobs success. RET-PERF-1/2/3 measurement halves closed. Remaining: (1) 1b(e) process-death; (5) PLATFORM-2 behavioral zero-decode on capture/revise | gate closure | partial | run 31953567448 |
| 2026-08-23 | X.6 positive Gateway and public connection-bound facade landed through [PR #15](https://github.com/GuangDai/Clipy/pull/15). Granted recent/search/details/paste-payload and pin/unpin/remove traverse the production Gateway/Authority; writes atomically combine History mutation, HCR, audit, and one ChangePosition. Failure mapping, cancellation/audit precedence, save-boundary grant recheck, cadence maintenance ordering, and public facade/factory tests are included. | X.6 | done | [correctness run 32607389771](https://github.com/GuangDai/Clipy/actions/runs/32607389771); [symbol run 32606749388](https://github.com/GuangDai/Clipy/actions/runs/32606749388) |
| 2026-08-23 | X.7 App Intents composition landed through [PR #16](https://github.com/GuangDai/Clipy/pull/16). Six intents use one async connection-bound facade provider registered before store open; identity-string reconstruction, output-only entity projection, direct-call failure mapping, and the existing pasteboard writer are covered by hosted tests. The evidence is deliberately split: hosted direct calls do not prove system-manager resolution, true Siri/Shortcuts discovery or cold/warm invocation, process placement, Swift 6 queue-crash freedom, cross-process pasteboard visibility, or TCC. | X.7 | done | [correctness run 32609910701](https://github.com/GuangDai/Clipy/actions/runs/32609910701); [symbol run 32609018894](https://github.com/GuangDai/Clipy/actions/runs/32609018894) |
| 2026-08-23 | X.8 pure CLI wire-contract implementation started. The current branch splits shared bounds/types into [`ClipyCLIContract.swift`](../../Sources/ClipyCLIContract/ClipyCLIContract.swift), typed request shape into [`ClipyCLIRequestCodec.swift`](../../Sources/ClipyCLIContract/ClipyCLIRequestCodec.swift) over [`BoundedJSONParser.swift`](../../Sources/ClipyCLIContract/BoundedJSONParser.swift), and typed reply/exit rendering into [`ClipyCLIReplyRenderer.swift`](../../Sources/ClipyCLIContract/ClipyCLIReplyRenderer.swift) over [`BoundedJSONWriter.swift`](../../Sources/ClipyCLIContract/BoundedJSONWriter.swift), with named `PLAY-PY-A2A`–`A2I` fixtures in [`Tests/ClipyCLIContractTests`](../../Tests/ClipyCLIContractTests/PLAYPYA2AUnknownMajorTests.swift). This leaf is not a product CLI: it owns only pure bounded request/reply bytes and exit mapping, with no executable, process I/O, Python-to-History path, transport, authentication, Gateway dispatch, grant/audit behavior, or runtime claim. | X.8 | in progress | current source/tests; macOS correctness CI pending |

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
