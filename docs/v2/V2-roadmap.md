# V2 Implementation Roadmap

> **Status (2026-07-27):** roadmap generated; implementation not admitted.
> The V2 design documents are consolidated at the design level, but the
> repository has not yet reached the v1 executable-specification prerequisite
> and no durable trigger ledger proves that a V2 graft has fired. The
> pre-scaffold closure items in §4 must also be resolved in their owning V2
> documents before affected code lands.
>
> This roadmap owns implementation order, slice boundaries, evidence bookkeeping,
> and test naming. It owns no product or domain semantics. Where the V2 documents
> disagree, this roadmap records a blocker instead of choosing a behavior. The v1
> design documents remain frozen against V2 semantic edits and authoritative for
> v1; the v1 implementation may continue updating its living `PROGRESS.md` while
> steps 6–9 land.
>
> **Re-baselined (2026-08-15):** the §2 baseline rows and the V2-0 status were
> re-checked against the landed v1 tree — steps 6–8 are implemented,
> remediated, and verification-audited (`docs/V1-Verified/`, supported run
> 31449682036). See the review record `V2-REVIEW.md` for this pass.

## 1. How to use this roadmap

V2 is an evidence-gated portfolio, not one mandatory all-at-once release. A
capability that has not met its trigger remains design-only and contributes no
public symbol, schema model, placeholder, feature flag, or dormant code.

Status terms:

- **done** — implementation and every named proof gate are green on the macOS 26
  arm64 runner.
- **in progress** — an admitted slice is being implemented.
- **gated** — its prerequisites are present, but its evidence trigger is not
  durably recorded.
- **blocked** — a prerequisite or §4 design-closure item is unresolved.
- **not started** — admitted and unblocked, with no implementation yet.
- **not applicable** — deliberately absent from the selected release because its
  graft was not admitted.

Every implementation PR must identify:

1. the graft and durable trigger evidence;
2. the owning V2 sections and the v1 sections extended;
3. the affected D1–D19 invariants and new D20+ invariants;
4. schema, blob, and projection migration impact;
5. cache-law impact, when applicable;
6. security boundary, when external-facing;
7. the exact proof gates closed by the PR.

No status becomes **done** from unit tests alone. Compile/import/symbol gates,
real in-memory SwiftData proofs, persistent-store migration/restart proofs, and
the named performance/security gates are part of completion.

### Source map

| Design owner | Roadmap ownership |
|---|---|
| [V2-00 overview](V2-00-overview.md) | Admission protocol, inherited decisions, M1 rules, invariant registry, completion discipline |
| [V2-01 enrichment](V2-01-enrichment.md) | §7, E.1–E.8 |
| [V2-02 retention](V2-02-retention.md) | §6, R.1–R.7 |
| [V2-03 change journal](V2-03-change-journal.md) | §8, J.1–J.8 |
| [V2-04 materialization](V2-04-materialization.md) | §9, C.1–C.7 |
| [V2-05 external gateway](V2-05-external-gateway.md) | §10, X.0–X.11 |
| [V2-06 platform grafts](V2-06-platform-grafts.md) | §11, P1/P2/P3 |
| [V2-07 UX](V2-07-ux.md) | §12, UX.1–UX.9 |
| [V2 facts](V2-facts.md) | Durable platform evidence; temporary per-module sidecars must be promoted under V2-1 |

## 2. Current baseline and entry criteria

| Area | Current state | V2 consequence |
|---|---|---|
| v1 scaffold, Core, Domain, dependencies, schema/codecs, capture | Steps 0–5 landed and CI-green | Reuse; do not reopen or fold V2 semantics into these steps. |
| v1 mutations, reads, search, observation, thumbnail (steps 6–8) | Landed, remediated, and verification-audited — `docs/V1-Verified/` reports plus the final disposition ledger (no pending rows); supported code-head run 31449682036 green (314 tests, 41 suites) | Unblocks V2-02/V2-03/V2-04 design closure. V2-0's remaining entry gap is the recorded state-2 declaration below, not steps 6–8. |
| v1 product wiring | Step 9 pending (`PasteboardAdapter`/`PresentationUI` remain step-0 scaffolds) | Blocks V2-05 App Intents composition and all V2-07 UI integration, as before. |
| v1 invariant suite | Planner invariant suites now exist (`CapturePlannerInvariantTests`, `CapturePlannerRankAndCapacityTests`, `PinRevisionPlannerInvariantTests`, `RevisionPlannerInvariantTests`, `RetentionPlannerTests`, plus the HistoryStorage WS suites); the earlier "only `DomainSmokeTests`" row was stale | The D1–D19-by-number evidence question is tracked by the V1-Verified dispositions; each graft's Record 2 extends it for D20+. |
| V2 trigger evidence | Trigger definitions exist; a durable firing ledger does not | Every implementation track is gated. |
| V2 platform evidence | `V2-facts.md` cycles 1–7 hold the E1, RET, X1 App-Intents, P2 string, C2 file, and executor facts plus (cycle 6 §6.1 and cycle 7 §7.1–§7.4, 2026-08-15) the promoted V2-03/V2-04/V2-05/V2-06/V2-07 sidecars; every load-bearing citation now resolves inside `docs/v2` | Sidecar promotion (DC-01) is done; `.tmp/v2-research/` is untracked scratch only. |

### Step V2-0 — finish and freeze the v1 executable specification

**Status:** closed 2026-08-15 (record: `V2-PROGRESS.md` §1). v1 steps 6–8
landed and audited (`docs/V1-Verified/`, runs 31449682036 and 31815028830);
the state-2 declaration is recorded for the current tree in v1
`docs/PROGRESS.md` (audit-baseline section), and the D1–D19 by-number
evidence reconciliation is recorded in `docs/v2/V2-PROGRESS.md` §1.1. Step 9
remains a capability-local prerequisite for V2-05 App Intents and V2-07 UI,
not a state-2 entry gate.

Deliver:

- v1 steps 6–8 and all WS1–WS21 clauses; state 2 closes at step 8;
- the dedicated D1–D19 Domain proof suite;
- the Part VI §9 performance fixtures in `HistoryPerfRunner`;
- a corrected v1 `docs/PROGRESS.md` showing the invariant-suite evidence and
  executable-specification state 2.

Exit: the full v1 source gates, SwiftLint, `swift build`, `swift test`, generated
scaffold build/test, public-symbol snapshot, WS suite, and performance fixtures
are green with zero warnings on macOS 26 arm64. Step 9 remains a capability-local
prerequisite for V2-05 App Intents and V2-07 UI, not a state-2 entry gate.

### Step V2-1 — stabilize the V2 design inputs

**Status:** required before each selected graft; blocked on the applicable §4
items for that release.

Deliver:

- promote the per-module fact sidecars required by V2-03..V2-07 into durable
  `docs/v2` evidence, or consolidate them append-only into `V2-facts.md`;
- record the missing V2-05 cycle-5 App Intents/audit facts *(satisfied
  2026-08-15: recorded as `V2-facts.md` Cycle 6 §6.1 — the roadmap's
  "cycle-5" phrasing predates the cycle-6 landing)*;
- resolve every §4 item applicable to the selected grafts in its owning design
  document;
- run the `V2-00` §8 self-review and the final cross-document review against the
  resolved documents;
- create a living V2 implementation ledger when the first graft is admitted.

Exit: no load-bearing claim for the selected release depends only on `.tmp`; no
applicable open contradiction is being delegated to implementation; every
remaining platform uncertainty has a named proof gate and a required outcome.

### Step V2-2 — measure and record admission evidence

**Status:** gated until V2-0 and V2-1 finish.

Use the greenfield `HistoryPerfRunner` and the agreed minimum-hardware profile.
Record raw workload definition, fixture revision, machine profile, sample count,
p50/p95, and the approval record. A trigger opens implementation review; it does
not waive the proof gates that must pass after implementation.

| Graft | Admission evidence |
|---|---|
| R1/R2/R3 | Approved product requirement for each selected retention dimension. |
| E1 | Approved product spec and OCR p95 within the agreed budget. |
| Enrichment S1 | Repeated material invalidation while enrichment source bytes provably remain unchanged. |
| J1 | Recent/search p95 > 50 ms at 5,000 items, Authority queue p95 > 20 ms, or an approved reconnect requirement. |
| C1 | Thumbnail decode p95 > 16 ms and at least 30% identical completed requests. |
| C2 | C1 justified, substantial cross-launch reuse, and fixture-proved structural materializer versioning. |
| C3 | At least 20% of thumbnail work superseded/discarded despite cancellation and single-flight. |
| Thumbnail S1 | Repeated thumbnail invalidation while selected source bytes provably remain unchanged. |
| X1/X2 | Approved product spec plus a recorded fresh architecture review (including its security analysis); X2 is mandatory with X1. |
| P1 | Current capped Canonical-coverage/index rebuild p95 > 250 ms at 5,000 items, plus an approved DATA-11-compatible checkpoint proof. |
| P2 | Approved locale-sensitive matching requirement plus fixed locale fixtures. |
| P3 | Representative workload exceeds the capture-path memory budget or shows p95 copy cost unsolvable within bounded inline values. |

### Gate maintenance for every admitted slice

- Extend `scripts/import_gate.py` and `.swiftlint.yml` together. E1 permits
  Vision/PDFKit only in HistoryStorage; X1 permits AppIntents only in ClipyApp.
  Audit adds no hashing/cryptography import exception. No other import boundary
  changes.
- Keep `scripts/escape_hatch_scan.py` strict. X1 may add only the exact
  framework-owned `AppDependencyManager.shared` registration in ClipyApp; the
  scan must continue rejecting every other `.shared`/`.current`.
- Any intentional HistoryCore addition must compile first, then regenerate the
  public-symbol snapshot on the macOS runner through the dispatch workflow. Do
  not hand-edit runner-derived snapshot content.
- Preserve the `Package.swift` exclusion for
  `Tests/HistoryCoreTests/SymbolSurface/`, XcodeGen repeatability, and the
  zero-warning CI log scans.

## 3. Dependency graph and recommended release order

```text
v1 executable specification (V2-0)
        |
V2 design closure + durable facts + trigger ledger (V2-1/V2-2)
        |
        +-- admitted table/blob graft --> M1 release-specific migration slice
        |
        +-- R1/R2/R3 retention
        |
        +-- E1/S1 enrichment
        |
        +-- J1 journal/reconnect --> X1/X2 in-process gateway/audit
        |                           --> App Intents --> clipyctl codec
        |                           --> authenticated ingress + one private transport
        |
        +-- completed v1 thumbnail --> S1+C1 --> C3
        |                                      \----> C2
        |
        +-- P1 startup checkpoint
        +-- P2 localized exact search
        +-- P3 sidecar blob store
        |
        \-- capability-specific UX, shipped with each admitted backend
```

Hard dependencies:

- V2 work starts only after v1 executable-specification state 2.
- M1 is coupled to the first admitted graft that changes a schema, blob codec,
  or projection. It must not reserve all possible V2 models in advance.
- Retention follows the completed v1 mutation/revision paths.
- Enrichment follows completed v1 reads/search and capture/revision invalidation.
- J1 follows the complete v1 commit kernel. V2-03 says it reuses the Storage
  clock first specified by V2-02 even though the graft triggers are independent;
  DC-24 must resolve ownership and release order. Its retention mapping follows
  V2-02 if both ship.
- V2-05 assumes the V2-03 always-on HCR append even though X1/X2 do not
  themselves trigger J1; DC-25 must resolve whether X waits for an independently
  admitted J1 or adopts the required HCR substrate.
- V2-04 follows the completed v1 thumbnail path. C2 requires C1. The natural
  admitted order is S1+C1, then C3, then C2.
- V2-07 is incremental: a capability UI ships with its backend, not as a large
  final batch. A missing protocol conformance means the section is absent.

Recommended build order for a release that admits every graft is:

1. V2-0 through V2-2;
2. M1 base plus V2-02 retention;
3. V2-01 enrichment;
4. V2-03 journal/reconnect, then its separately justified collection cache;
5. V2-04 S1+C1, C3, then C2;
6. V2-05 storage/audit and complete in-process Gateway deny/positive substrate,
   then App Intents, then `clipyctl` pure codec, then the separately admitted
   authenticated ingress and one private transport;
7. independently admitted P1/P2/P3 grafts;
8. the matching V2-07 UI slice alongside each backend;
9. the cross-capability and product-completion pass.

This is a build-ordering choice, not a semantic dependency between otherwise
independent triggers. An untriggered track is skipped, and immutable schema
version numbers follow the actual shipping order.

## 4. Pre-scaffold design-closure ledger

These are implementation blockers, not roadmap decisions. Fix the owning V2
document and its proof gates before starting the affected slice.

| ID | Owner | Required closure |
|---|---|---|
| DC-01 | V2 facts / all modules | Promote the V2-03..V2-07 fact sidecars out of `.tmp`, add the missing V2-05 cycle-5 facts, and make every citation resolve durably. *(2026-08-15: resolved — V2-03/V2-04/V2-06/V2-07 fact sidecars promoted verbatim as `V2-facts.md` Cycle 7 §7.1–§7.4; the V2-05 facts were already promoted as Cycle 6 §6.1, satisfying the former "missing cycle-5 facts" clause; every load-bearing citation repointed; `.tmp/` remains untracked scratch only.)* |
| DC-02 | M1 / V2-02 | Reconcile the required `RetainedBytesRow` custom backfill with statements that V2-02 is lightweight-only. Prove the legal SwiftData stage topology before schema code lands. *(2026-08-15: resolved — the `V1 → V2` hop is **one `MigrationStage.custom` stage**: schema add expressed by the versioned schemas, projection backfill in its `didMigrate` (idempotent by construction, before `open` returns), migration-context pre-Authority writer recorded as the sole sanctioned exception and owned by M1. A lightweight+custom pair over one version pair is not a documented SwiftData pattern (API pages + WWDC2025/291); the two-stage wording is retracted. V2-02 §3.3 "Stage topology", Record 3 `RET-PLATFORM-1/1b`, Record 5, §13 anchors.)* |
| DC-03 | M1 / all schema grafts | Choose consolidated versus incremental shipping. Every shipped `VersionedSchema` is immutable; later grafts receive the next version instead of mutating an already-shipped `HistorySchemaV2`. *(2026-08-15: resolved — **incremental shipping**; each release's schema carries only the grafts admitted in that release and version numbers follow the actual shipping order. First release (M1 + V2-02): `HistorySchemaV2` = v1 models + retention rows only. The consolidated-era contrary statements in `V2-01` §3.2, `V2-03` §3/§14, and `V2-04` §8/§15 are superseded; each is corrected at its own graft's admission (follow-up ledger in `V2-PROGRESS.md`). V2-02 §3.3 "Incremental shipping".)* |
| DC-04 | V2-02 | Change or justify `RetainedBytesRow.itemIDRaw: String`; the v1 business ID is UUID-backed. Reconcile “disabled is byte-for-byte v1” with mandatory 1:1 byte-projection maintenance, and fix insert/coalesce/first-revision wording. *(2026-08-15: the field is now `itemID: UUID` in V2-02 §3.3 per this direction.)* *(2026-08-15, closing the remainder: projection-maintenance reconciled — §4.1/§7/D24 now read "public behavior and v1 rows exactly v1's, not byte-identical durable state (the projection is maintained 1:1 while disabled)"; insert/coalesce/first-revision wording fixed in §3.3b to insert-stamps-`revisionCount == 0`/`revisionBytes == 0` (v1 insert carries an empty revision list, `02` §2) with coalesce leaving the row unchanged.)* |
| DC-05 | V2-01 | Make the persist-time source-selection fence implementable for mixed PDF+image content. The Authority cannot repeat the worker-only PDF probe from the current `PendingEnrichment` fields. |
| DC-06 | V2-01 | Reconcile zero-blob-decode search with the claimed scalar/blob inconsistency detection; choose encoded `kind == none` versus an empty not-applicable blob. |
| DC-07 | V2-01 | Specify one coherent inbox loss/backpressure/rescan policy, the claimed secondary ordering inputs, OCR text normalization, and recovery after the terminal retry cap. |
| DC-08 | V2-01/V2-02/V2-03/V2-07 | Decide sibling public reads: `enrichmentEnabled()` (OPEN-3), batch `enrichmentStatuses(for:)` (OPEN-6), current retained bytes (OPEN-2), and `JournalAdminHistory` (OPEN-5). Omit dependent UI if an API is not admitted. *(2026-08-15: the V2-02 clause (OPEN-2) is resolved for the first release — **not admitted**, no public retained-bytes read, R.7/UX.4 show policies and receipts only; recorded in V2-02 Record 1 admission note. The enrichment (OPEN-3/OPEN-6) and journal (OPEN-5) clauses remain open with their grafts.)* |
| DC-09 | V2-03 | Reset `journalBytes` during rebase; distinguish legitimate empty bootstrap/rebase from accidental loss of the journal head; define a bounded deterministic `CollectionCacheLimits`/eviction policy and a concretely bounded `AffectedItemsBlobV1` decoder. *(2026-08-15: the `journalBytes = 0` reset is applied to the §9.2 rebase sequence; the other three items remain open.)* |
| DC-10 | V2-03 | If J1 is admitted only for reconnect, default the collection cache off until G2 evidence exists. Purpose-qualify journal versus thumbnail materializer-version methods and values. *(2026-08-15: `cacheEnabled` bootstrap default flipped to `false` in V2-03 §2.3, §4.6, and Record 5; the fixture at §17 that enables the cache now says so explicitly; the materializer-version qualification remains open.)* |
| DC-11 | V2-04 | Obtain explicit recorded review/product sign-off for the stamp-collision residual, the load-bearing single-flight join-key substitution, and materializer-version downgrade refusal, or redesign the keying. |
| DC-12 | V2-04 | Make cache insert APIs carry `contentVersion`/`builtAt`, specify C3 metrics collection, choose a concrete bounded disk wire format/decoder, and resolve whether C1 requires both G1 and G4 or G1 admits the internal S1 substrate. *(2026-08-15: the C1 `insert` signature now carries `contentVersion`/`builtAt`; the other three items remain open.)* |
| DC-13 | V2-03/V2-04 | Reconcile the cross-doc thumbnail-key description (`ContentVersion` versus source fingerprint) and map every V2-04 cache-law, collision, restart, joined-caller, corruption, sweep, and version-door obligation to the roadmap-owned stable fixtures. *(2026-08-15: the stable fixture IDs `V2-WS-C1-1/2`, `V2-WS-C2-1/2/3`, `V2-WS-C3-1` are now defined in V2-04 Record 4, so the roadmap's C.2–C.6 citations resolve; the thumbnail-key reconciliation remains open.)* |
| DC-14 | V2-05 | **Resolved (2026-08-22):** `GrantRow` is one current-state row per `(connectionID, capability)`; re-grant updates that row, while `OperationRecordRow` preserves grant/revoke/re-grant event history. |
| DC-15 | V2-05 | **Resolved (2026-08-22):** the audit hash-chain design is withdrawn under the repository no-hash rule. Compaction atomically appends its marker, deletes one prefix, advances `compactionFloor`, and preserves a contiguous retained suffix; no tamper-evidence claim. |
| DC-16 | V2-05 | **Resolved (2026-08-22):** audit payload/DTO connection and capability are optional for global/admin truth, commit position stays optional, typed codec + monotone contiguous `auditSequence` + explicit floor replace the former chain. Recovery is a separately gated diagnostic/rebase path with no content/History access and no tamper-evidence claim. |
| DC-17 | V2-06 P1 | Replace `readStartupCheckpoint() -> StartupCheckpointRow?` with an immutable `Sendable` snapshot so no `@Model` crosses a context/actor boundary. |
| DC-18 | V2-06 P2 | Define deterministic behavior when the system locale is outside the five supported fixture locales. |
| DC-19 | V2-06 P3 | **Superseded as executable closure by `DEC-P3-ADMISSION`, `DEC-P3-MIGRATION-WRITES`, and the required V2-06 §5 replacement amendment.** The historical eager-migration/raw-`AsyncBytes` direction must not be implemented. The replacement must specify bounded cursor migration, concurrent-write linearization, staging ownership, and one bounded internal reader before G8 can admit P3. |
| DC-20 | V2-06/V2-07 | **Superseded as executable closure by `DEC-PURPOSE-READ` plus the same P3 replacement amendment.** The former public `BlobStreamingHistory` consumer claim is withdrawn; a future approved purpose-read seam must name its real caller and keep framework transport objects internal. |
| DC-21 | V2-02 | Specify finite-value validation for `TimeInterval`, retain the `RET-PLATFORM-4` fallback if R3 and the v1 revision-byte hard bound use different measures, and resolve the new-item/coalesce byte-projection wording before fixtures freeze. *(2026-08-15: resolved — `maxAge.isFinite` required at the boundary (`NaN`/`±∞` → `.invalidInput(.invalidRetentionPolicy)`) and a persisted non-finite `ageMaxSeconds` fails closed at config load (V2-02 §8.3 "Finiteness"); `RET-PLATFORM-4` measure-identity fallback retained verbatim; the wording item closed under DC-04 second pass.)* |
| DC-22 | V2-05 | Reconcile “CredentialStore/Security is unbuilt and future-only” with §14’s statement that `X-PLATFORM-3` must pass for V2-05. Either remove the gate from X1/X2 completion or admit and specify the Keychain slice. |
| DC-23 | V2-00/V2-02/V2-07 | Decide whether R1/R2/R3 are one atomic retention bundle or independently admitted dimensions. Align trigger recording, public enums and policy fields, schema/defaults, implementation slices, and visible controls with that decision. *(2026-08-15: resolved — **one three-dimensional policy value, independently disable-able** (product decision, recorded as the admission record in V2-02 Record 1): the `HistoryRetentionPolicies` struct ships whole with per-dimension `nil` disabling; trigger matrix, public surface, schema defaults, and UX switches follow V2-02 as written; R.1–R.7 slices are not trimmed.)* |
| DC-24 | V2-02/V2-03 | Define ownership and release ordering for the shared Storage clock when J1 is admitted before or without retention. Do not make an independent J1 trigger silently reserve untriggered V2-02 public or schema surface. |
| DC-25 | V2-00/V2-03/V2-05 | Resolve the X1/X2 dependency on the V2-03 HCR substrate: either require independently admitted J1 or specify the exact HCR-only substrate that X subsumes, including schema, migration, reconnect visibility, and proof-gate consequences. |
| DC-26 | V2-05 | **Resolved (2026-08-22):** delete the write-only `GatewayConfigRow.generation`; `configSchemaVersion`, `nextAuditSequence`, and `compactionFloor` own the executable state. Recovery never resets the audit head, so no future-rebase placeholder is retained. |
| DC-27 | V2-02 | `.setRetentionPolicies` PHASE A fails the whole action on any item whose active revision alone exceeds the new `maxRevisionBytesPerItem`, BEFORE PHASE B R1/R2 selection (§4.4; no post-retirement re-check exists). An unpinned heavy item therefore blocks a combined threshold-lowering that R2 would satisfy by retiring it. Decide: (a) run the veto after PHASE B and exempt R1/R2 retirements (consequence narrows to "among items that survive R1/R2 retirement"; consistent with §6.3 retire-subsumes-prune; default), or (b) keep the whole-action veto and record the over-breadth as intended; touches §4.4, §8.3, RET gates. *(Found in iterative loop R2.)* *(2026-08-15: resolved, option (a) applied — the veto is now PHASE C, running after PHASE-B selection and scoped to survivors; §4.4 code block + Atomicity paragraph and §8.3 updated in V2-02.)* |
| DC-28 | V2-02 | R1 capture-lane `now` = caller `observedAt`, finiteness-checked only (`IngestPreparation.swift`); sweep lane uses the injected Storage clock (§6.4). v1 clamps persisted `lastCopiedAt` with `max()` (`PlannersCapture.swift`) but V2-02's R1 comparison is unclamped: a finite future-dated `observedAt` retires every unpinned item in one commit. Decide: (a) reject/clamp skewed `observedAt` at the boundary, or (b) accept and record the exposure in §4.2/§8.3 (default; severity LOW). *(Found in iterative loop R2.)* *(2026-08-15: resolved, option (b) applied — exposure accepted and recorded in V2-02 §4.2 (`now` bullet) and §8.3 ("Recorded exposure"); severity LOW.)* |

The closure pass must also establish one total `SwiftDataHistory.open` bootstrap
order for all selected singletons, migrations, projection rebuilds, materializer
checks, compaction/rebase checks, Signature Index reconstruction/checkpointing,
and facade publication. Per-module “after the previous singleton” prose is not a
substitute for one executable order.

## 5. M1 — release-specific migration foundation

- **Status:** admitted and in progress (2026-08-15): V2-0 closed, DC-01/02/03
  and the applicable first-graft blockers (DC-04/08-retention/21/23/27/28)
  resolved, V2-02 admitted on recorded product approval — the total open
  order below is executable now. Design-ready verdict: `V2-PROGRESS.md` §2
  (V2-00 §8 self-review (a)–(j) all PASS; final cross-document review zero
  blockers).
- **Spec references:** `V2-00` §2.1/§4/§5 decision 18; each module’s Record 5;
  v1 `05` §17.
- **Dependencies:** completed v1 schema/codecs/open path.

### M1 slices

| Step | Deliverable | Exit evidence |
|---|---|---|
| M1.1 | Add the behavior-preserving internal `HistorySchemaV1: VersionedSchema` anchor while leaving the existing `v1Schema` value, V1 model set, rows, and behavior frozen. | A current v1 store opens with no row/blob/token drift; v1 tests are byte-for-byte unchanged. |
| M1.2 | Define the next immutable schema for only the grafts admitted in that release and append the ordered migration stage. Record a schema-version ledger. | Fresh, `.memory`, and on-disk V1 stores open; already-shipped schemas are never edited. |
| M1.3 | Implement data bootstrap separately from schema migration: create/validate exactly-one config rows in the resolved total open order, with v1-faithful defaults. | Duplicate, missing-with-dependent-data, unknown-version, and downgrade cases fail closed before facade publication. |
| M1.4 | Implement projection rebuilds, notably `RetainedBytesRow`, before `open` returns. Never invent bytes or enable callers against an incomplete projection. | Backfill completeness/coherence, interruption, retry/idempotence, and rollback are fixture-proved. |
| M1.5 | **Superseded pending the P3 replacement amendment.** If P3 is admitted, migrate a bounded item batch under a durable cursor and the approved concurrent-write policy; validate each new representation before deleting legacy bytes. Do not require an eager whole-store first-launch rewrite. | Cursor resume, concurrent capture/revise/remove, bounded duration/memory per batch, missing-source, rollback, and legacy-deletion-after-validation proofs pass. |

Migration inventory:

| Graft | Schema layer | Blob layer | Projection/files layer |
|---|---|---|---|
| V2-02 | `RetentionExpansionConfigRow`, `RetainedBytesRow` | none | mandatory byte-projection backfill |
| V2-01 | `EnrichmentRow`, `EnrichmentConfigRow` | new `EnrichmentBlobV1` only | no backfill; disabled and empty |
| V2-03 | `HistoryChangeRecordRow`, `JournalConfigRow` | new `AffectedItemsBlobV1` only | no historical backfill; HCR starts at the next commit |
| V2-04 C2 | `ThumbnailCacheConfigRow` | new disk-file codec only | empty cache directory; lazy population |
| V2-05 X.3/X.4 | V3: `ConnectionRow`, `GrantRow`, `OperationRecordRow`, `GatewayConfigRow` | audit codec deferred to the X.4 spec-first atomic-audit leaf | X.3 bootstraps config + one active ungranted App Intents connection + zero audit |
| P1 | `StartupCheckpointRow` | new checkpoint codec | rebuild on miss/corruption |
| P2 | `LocalizedSearchConfigRow` | none | query-time only; no search projection rebuild |
| P3 | blocked until replacement amendment selects metadata/cursor rows | bounded representation migration; exact codec shape is amendment-owned | staged depot write/readback plus bounded orphan/in-flight recovery; no eager whole-store cutover |

M1 is complete only when each admitted module’s migration proof gates pass,
including `E1-PLATFORM-1/4`, `RET-PLATFORM-1/1b`, `J1-PLATFORM-2`,
`X-PLATFORM-1`, `P1-PLATFORM-3`, and the replacement amendment's bounded
P3 migration/recovery gates as applicable. The old eager P3 gate wording is
not executable.

### M1 total `SwiftDataHistory.open` order (current: V2 retention + V3 X.3)

Originally recorded 2026-08-15 for the first V2 retention release and extended
in place 2026-08-22 for X.3, per the §4 closing requirement (one executable
order, not per-module prose). This is the release-scoped total order; every later
release that admits another singleton/migration-bearing graft must extend
this list in place rather than append per-module "after the previous
singleton" statements. Step numbers cite the v1 `05` §13 steps they extend.

1. validate configuration and hard limits; *(05 §13 step 1)*
2. construct the `ModelContainer` with the ordered `SchemaMigrationPlan`
   (`schemas` = `HistorySchemaV1`, immutable `HistorySchemaV2`, immutable
   `HistorySchemaV3` in ship order; `stages` = the custom `V1 → V2` stage from
   DC-02 followed by the additive lightweight `V2 → V3` stage). A fresh store
   runs no stage (the V3 schema is created directly, zero items); a V2 store
   runs only the lightweight V2 → V3 hop; a V1 store runs both ordered hops.
   In the V1 → V2 hop, the additive schema change plus the
   `RetainedBytesRow` `didMigrate` backfill (idempotent by construction)
   both complete before `open` returns — whether the backfill completes
   before `ModelContainer.init` itself returns is runtime-asserted, not
   assumed (`V2-facts.md` cycle 7 §7.1 OPEN 5; `RET-PLATFORM-1b(d)/(e)`) —
   and this migration-owned context is the sole sanctioned pre-Authority
   writer; *(extends 05 §13 step 2)*
3. enter `HistoryAuthority` and create the v1 `LastChangePositionRow`
   singleton at position 0 if this is a new store; *(05 §13 step 3)*
4. validate exactly one singleton; *(05 §13 step 4)*
5. bootstrap/validate the `RetentionExpansionConfigRow` singleton
   (M1.3): absent → create all-disabled with `configSchemaVersion == 1`;
   present → validate `configSchemaVersion == 1`, `ageMaxSeconds`
   finiteness (DC-21), and non-contradictory combinations (V2-02 §3.3);
   duplicates or violations fail closed before any write path opens;
6. run the X.3 Gateway bootstrap/validation inside `HistoryAuthority`, before
   any projection/index/facade publication: absent config + all dependent tables
   empty creates one config and one active
   `Siri / Shortcuts / Spotlight` App Intents connection in the same
   transaction, with zero grants/audit; an existing config requires the exact
   matching connection and is never silently repaired. After X.4, that
   connection may be active or coherently revoked, and existing grant/audit
   rows pass the bounded current-state/retained-interval validators rather than
   the first-bootstrap zero-row rule. Config absent + any
   surviving dependent row fails closed. Config absent + all dependent rows
   empty is accepted as fresh/migration-compatible even though it is
   indistinguishable from complete future V3 Gateway-row deletion; no
   marker/hash is added and no stronger corruption-detection claim is made.
   On first bootstrap validate `nextAuditSequence == compactionFloor == 1` and
   `auditBytes == 0`; on existing X.4 state validate the contiguous retained
   interval and exact logical-byte counter. Always validate supported raw/
   config versions and the fixed App Intents display name. X.3 constructs no
   codec, registry/admin service, Gateway actor, or facade;
7. rebuild every projection-schema-v1 row to recipe v2 from validated
   Canonical/revision Effective Content in one bounded transaction; accept
   only tags 1 and 2, and publish no partial replacement on failure;
   *(05 §13 step 6; this is a derived-projection rebuild, not a SwiftData
   schema stage)*
8. validate retained row count does not exceed the hard bound, then fetch
   each row's business ID, nonzero Content Version, projection schema version,
   pin ordinal, Canonical bytes, and signature metadata; *(05 §13 step 7)*
9. require projection schema version 2; *(05 §13 step 8)*
10. decode Canonical/signatures, recompute xxh3, require authoritative
   bidirectional coverage, and build the complete index;
   *(05 §13 step 9)*
11. validate the full pinned ordinal set from scalar fields;
    *(05 §13 step 10)*
12. enforce the `RetainedBytesRow` 1:1 correspondence both directions with
   `bytesSchemaVersion == 1` and valid scalar relations
   (`RET-PLATFORM-1b(a)`); a fresh store holds this vacuously (zero items;
   rows arrive via capture-insert stamping). *(05 §13 step 11. Sequencing: the
   runtime 1:1 existence check is enforced from slice R.3, when projection
   stamping on create/append/prune/delete exists — before R.3, capture
   creates items without rows, so an unconditional check would fail every
   capture-created item. M1 proves the correspondence for migrated stores
   through the migration fixtures of `RET-PLATFORM-1b(a)`; R.3 turns the
   fixture invariant into this runtime check.
   Amended 2026-08-16
   from the measured platform fact of run 31955551834: the check runs in
   two phases — a missing-rows-only RECOVERY that re-runs the idempotent
   backfill once (`V2-02` Record 5 "Interruption recovery"), then the
   strict both-directions validation; orphans/duplicates/version
   mismatches and invalid scalar relations never recover.)*
13. publish the constructed `SwiftDataHistory` facade. This is the v1
    `ClipboardHistory` facade only; X.3 publishes no external Gateway facade.
    *(05 §13 step 12)*

The current hard-capped index build decodes Canonical to prove authoritative
negative evidence, but never decodes revision bytes merely to build the index.
This O(N) Canonical pass is capped-only: `DEC-U-SCALE-STARTUP-INDEX` must replace
it before the global hard item bound is removed, without retaining two truth
indexes. Other full-lineage decodes at open remain limited to migration
backfill or the explicit legacy projection-recipe rebuild.

## 6. V2-02 — retention expansion (R1/R2/R3)

- **Status:** R.1–R.6 landed and CI-green (2026-08-16; evidence per slice in
  `V2-PROGRESS.md` §0 — latest full-scope run 31950153864, 491 tests /
  58 suites, all four jobs, zero warnings). **R.7 (UX handoff) remains and
  is gated on v1 step 9** (`PasteboardAdapter`/`PresentationUI` scaffolds),
  per this roadmap's §2 baseline and `V2-07`'s dependency notes; it opens
  when step 9 lands. OPEN-2 stays not-admitted (Record 1).
- **Spec references:** `V2-02` §2–§12b; D23–D24.
- **Dependencies:** completed v1 mutations/revision preparation; Foundation +
  HistoryCore-only Domain; existing `HistoryAuthority`.
- **Recommended position:** first implementation graft because it has the least
  platform surface and establishes the Storage clock later reused by J1/X2.

### Retention slices

| Step | Deliverables | Exit proof |
|---|---|---|
| R.1 Core contract | Add only the retention policies, action/outcome surface, and capacity cases admitted under DC-23; validate their bounds and normalize a both-nil revision policy when R3 is included. Update all exhaustive switches and the public-symbol snapshot intentionally. | `RET-COMPILE-1/2`; policy-bound and failure-translation fixtures for every admitted dimension. |
| R.2 Pure Domain | Add complete expansion facts/summaries, `RetentionExpansionPlan`, `RevisionExpansionTarget`, `planItemRetentionExpansion`, `planRevisionRetentionExpansion`, `HistoryMutation.pruneRevisions`, `HistoryMutation.setRetentionPolicies`, and `PlannedOutcome.retentionPoliciesSet`. Implement deterministic R1 strict-age ordering, R1-before-R2 union, protected victims, checked bytes, and shortest-append-order-prefix R3 pruning (oldest-inactive first, not minimum-cardinality). | `RET-PRUNE-1/2`, `RET-SELECT-1`; deterministic and overflow fixtures; D23/D24 proofs. |
| R.3 Persistence/projection | Add and validate `RetentionExpansionConfigRow` and the business-ID-consistent `RetainedBytesRow` shape resolved under DC-04; backfill every item before open; maintain the 1:1 scalar projection on create, append, prune, and delete even while policies are disabled; inject the Storage clock internally. | `RET-PLATFORM-1/1b/2`; migration, missing-row-corruption, and projection-lifecycle fixtures. |
| R.4 Capture composition | Run v1 count planning first; when R1/R2 is active, plan over projected post-primary/post-count state, protect primary/pinned/count victims, and commit one merged plan/position. Coalesce uses the winner’s stored bytes. | `RET-PERF-1/3`; count+age+byte composition, pinned-over-budget hard failure, one-position, and disabled-public-semantics proofs. |
| R.5 Revise composition | Extend the two-phase revise preparation/recheck. Speculatively and authoritatively recompute R3, validate the hard bound on post-prune/post-append state, run R2 but never R1, and fuse append+prune into one blob write and one `ContentVersion` successor. | `RET-PLATFORM-3/3b/4`, `RET-CONCUR-1`, `RET-STAMP-1`. |
| R.6 Policy sweep | Persist the policy explicitly; run R3 first, project post-prune bytes, then R1/R2; retirement subsumes prune; same-policy/satisfied state is a true no-op; reject active-revision or pinned-byte impossibility atomically. | `RET-PERF-2`, `RET-STAMP-2`, `RET-SECURITY-1`; receipt-count and no-op proofs. |
| R.7 UX handoff | Wire unified age/storage/revision settings, receipts, pinned-over-budget guidance, accessibility, and localization. Do not claim a wall-clock sweep; omit live usage unless OPEN-2 is resolved. | Corresponding `UX-*` gates and product tests. |

Retention trigger matrix remains exact:

- capture: R1 and R2;
- revise: R2 and R3;
- `.setRetentionPolicies`: R1, R2, and R3;
- v1 count-policy change, pin, unpin, remove, and clear: no V2 expansion.

All acceptance gates:

`RET-COMPILE-1`, `RET-COMPILE-2`, `RET-PLATFORM-1`,
`RET-PLATFORM-1b`, `RET-PLATFORM-2`, `RET-PLATFORM-3`,
`RET-PLATFORM-3b`, `RET-PLATFORM-4`, `RET-PRUNE-1`,
`RET-PRUNE-2`, `RET-SELECT-1`, `RET-CONCUR-1`, `RET-STAMP-1`,
`RET-STAMP-2`, `RET-PERF-1`, `RET-PERF-2`, `RET-PERF-3`, and
`RET-SECURITY-1`.

## 7. V2-01 — enrichment pipeline (E1 + enrichment S1)

- **Status:** blocked on V2-0, M1, DC-05 through DC-08; otherwise gated until
  both E1 and enrichment-S1 triggers are recorded.
- **Spec references:** `V2-01` §2–§12; D20–D22.
- **Dependencies:** completed v1 SearchWorker/read path and capture/revision
  post-commit plumbing; xxh3; Vision/PDFKit confined to HistoryStorage.

### Enrichment slices

| Step | Deliverables | Exit proof |
|---|---|---|
| E.1 Platform spike and admission | Pin Vision revision 3, recognition configuration/languages, actual image UTI set, PDFKit import/link posture, custom executor, and TCC/entitlement outcome. Freeze representative OCR/PDF fixtures before production code. | `E1-COMPILE-2/3`, `E1-PLATFORM-3/UTI`, `E1-SECURITY-1`, and trigger evidence. |
| E.2 Core/schema/codec | Add `EnrichmentHistory`, `EnrichmentStatus`, `EnrichmentRow`, `EnrichmentConfigRow`, `EnrichmentBlobV1`, fixed limits, codec/materializer versions, and default-disabled bootstrap. Update the public-symbol snapshot. | `E1-COMPILE-1`, `E1-PLATFORM-1/2/4`; corruption matrix and singleton proofs. |
| E.3 Source selection and S1 | Implement purpose-specific `EnrichmentSourceFingerprint`, candidate collection in one Authority interval, worker-side PDF-text precedence, and the resolved two-layer read/persist fence. No generic source-stamp framework. | Mixed PDF+image, hide/not-applicable, source-change race, collision injection, and no-re-OCR S1-reuse fixtures. |
| E.4 Worker | Add `EnrichmentWorker`, `PendingEnrichment`, and derivation results. Confine non-Sendable Vision/PDFKit values; use no completion handler; run blocking work on a custom non-cooperative executor; enforce one-image, 1,000-page, 256 KiB, top-candidate, deterministic-normalization, and retry bounds. | `E1-PERF-1/6`; ordering, confidence, empty-result, truncation, error, and pool-starvation fixtures. |
| E.5 Authority persistence/lifecycle | Add source read, fenced persist, and orphan sweep methods. Persist in a separate Authority transaction without changing history items/tokens; refresh current `ContentVersion`; maintain retry state; disclose lazy OCR-text deletion. | `E1-PERF-3/5`; stale-persist, retry/recovery, corruption, orphan/startup-sweep, and no-token-change proofs. |
| E.6 Scheduler/trigger drain | Add a non-awaiting post-commit item-ID channel and the resolved bounded/completeness policy; perform startup/on-enable backlog scans after facade publication; debounce, rate-limit, pause, cancel, and reschedule deterministically. | `E1-PERF-4/7`; sustained-load no-loss/completeness, user-commit fairness, startup, and cancellation proofs. |
| E.7 Search/status/toggle | Add scalar `enrichmentText` to internal search corpus only; enforce title→body→enrichment precedence and per-mode scan bounds; decode no content/enrichment blobs on common search; implement status and default-disabled/readback behavior selected under DC-08. | `E1-PERF-2/5`, `E1-BEHAVIOR-1`; disabled WS17 equivalence, snippets/ranges/ranking, stale-row exclusion, status, and toggle fixtures. |
| E.8 UX handoff | Add last-refresh status badges, OCR match presentation, settings, data-practice/lazy-deletion disclosures, accessibility, and localization. Do not add an OCR completion push or polling loop. | `UX-COMPILE-1/2`, `UX-PERF-1`, accessibility/product tests. |

All acceptance gates:

`E1-COMPILE-1`, `E1-COMPILE-2`, `E1-COMPILE-3`,
`E1-PLATFORM-1`, `E1-PLATFORM-2`, `E1-PLATFORM-3`,
`E1-PLATFORM-UTI`, `E1-PLATFORM-4`, `E1-PERF-1`,
`E1-PERF-2`, `E1-PERF-3`, `E1-PERF-4`, `E1-PERF-5`,
`E1-PERF-6`, `E1-PERF-7`, `E1-BEHAVIOR-1`, and `E1-SECURITY-1`.

## 8. V2-03 — change journal, reconnect, and collection cache (J1)

- **Status:** blocked on V2-0, M1, DC-08 through DC-10, and DC-24; otherwise
  gated on G2 or an approved reconnect requirement.
- **Spec references:** `V2-03` §2–§17; D25–D28.
- **Dependencies:** every v1 History Commit shape; V2-02 mappings if retention
  ships; completed v1 browse before caching.

### Journal slices

| Step | Deliverables | Exit proof |
|---|---|---|
| J.1 Core contract | Add `JournalEntryKind`, versioned `ReconnectCursor`, `HistoryChangeRecord`, `ReconnectBatch`, `ReconnectFailure`, and `ReconnectHistory`; leave `ClipboardHistory`/`HistoryFailure` unchanged. Add `JournalAdminHistory` only if DC-08 admits it. | `J1-COMPILE-1`; symbol snapshot and cursor-codec proofs. |
| J.2 Schema/codec/bootstrap | Add `HistoryChangeRecordRow`, `JournalConfigRow`, `AffectedItemsBlobV1`, limits, and the resolved empty-journal marker/counters. Bootstrap with an empty post-migration journal, immutable store identity, and validated generation/materializer fields. | `J1-PLATFORM-2`; migration, codec, downgrade, total-open-order, and migrated-N→N+1 proofs. |
| J.3 Atomic append | Add `HistoryChangeRecordPayload` and `StampedCommitPlan.hcrAppend`; thread clear scope; derive a total primary kind and sorted/deduplicated affected IDs; append exactly once inside every non-empty commit before the final position write; append none for no-op. | `J1-PLATFORM-1`, `J1-PERF-1`, `V2-WS-J1-1`, `1a`, `1b`, `5`, and `7`; extended WS13 injection points. |
| J.4 Reconnect reader | Add `ChangeJournal` plus Authority reads. In one context/interval: validate store, generation, materializer, compaction floor, and head-bound future cursors (§6.2 step 5b) before a bounded ordered range fetch and head read. Preserve the retroactive-discard rule for a later-page rejection. | `J1-PLATFORM-3/4/5`, `V2-WS-J1-2/3`. |
| J.5 Compaction/recovery | Implement count/age/byte compaction, persisted floor/counter, startup and periodic triggers, head survival, materializer upgrade/downgrade handling, divergence rebase, generation bump, and cache flush in the resolved open order. | `J1-PLATFORM-2`, `J1-PERF-4/5`, `V2-WS-J1-6`. |
| J.6 Conservative collection cache | After separate G2 evidence, add a bounded deterministic first-page-only cache. Keep awaits outside the Authority interval; fence hits against position/materializer/corpus epoch (V2-01 enrichment writes advance no `ChangePosition`); continuation pages bypass. If admission was reconnect-only, remain disabled. | `J1-COMPILE-2`, `J1-PERF-2`, `V2-WS-J1-4`; cache-law, fence-race, capacity, and page-2 proofs. |
| J.7 Optional fine invalidation | Only when measured read/write behavior requires hits across commits, replace—not chain after—the blanket handler with HCR-scoped invalidation; paginate journal reads and flush on a true gap/typed expiry. | `J1-PERF-3`; starvation, contiguity, and no-thrash proofs. |
| J.8 Security/UX handoff | Surface metadata retention, resync, pull-only recently removed, and admitted admin controls. Preserve v1 live snapshot observation; add no TCC, entitlement, or OperationRecord. | `J1-SECURITY-1` plus corresponding `UX-*` gates. |

Stable journal fixtures are `V2-WS-J1-1`, `V2-WS-J1-1a`, `V2-WS-J1-1b`,
`V2-WS-J1-2` through `V2-WS-J1-7`.

All acceptance gates:

`J1-COMPILE-1`, `J1-COMPILE-2`, `J1-PLATFORM-1`,
`J1-PLATFORM-2`, `J1-PLATFORM-3`, `J1-PLATFORM-4`,
`J1-PLATFORM-5`, `J1-PERF-1`, `J1-PERF-2`, `J1-PERF-3`,
`J1-PERF-4`, `J1-PERF-5`, and `J1-SECURITY-1`.

## 9. V2-04 — thumbnail materialization (S1/C1/C2/C3)

- **Status:** blocked on v1 step 8 and DC-11 through DC-13; each sub-capability
  is independently gated by G1/G3/G6/G4.
- **Spec references:** `V2-04` §2–§14; D29–D31.
- **Dependencies:** the complete v1 thumbnail source/fetch fence/single-flight;
  M1 only for C2’s config row.
- **Natural admitted order:** S1+C1, C3, then C2.

### Materialization slices

| Step | Deliverables | Exit proof |
|---|---|---|
| C.1 Admission/sign-off | Record each trigger separately and the DC-11 decisions. Freeze the source-fingerprint key, materializer version, and determinism claim before code. | Signed design record plus `C1-PERF-1` trigger evidence. |
| C.2 S1 + C1 | Add `ThumbnailSourceFingerprint`, selection/key/entry values, bounded deterministic `ThumbnailCache`, and the approved single-flight keying. Compute source bytes/stamp in the v1 non-suspending interval; a hit avoids decode, not source fetch. | `C1-COMPILE-1/2`, `C1-PERF-1/2/3`, `C1/C2/C3-PERF-4`, `V2-WS-C1-1` cache law, `V2-WS-C1-2` collision/join proof, unchanged WS15. |
| C.3 Publish lifecycle | Add per-caller `ThumbnailMaterializationState`, fence key, current-reference Authority check, terminal cleanup, and an ephemeral metrics sink. Joined callers keep independent publish outcomes; superseded bytes remain safe to cache and the tagged payload still returns. | `C3-PERF-1`, `V2-WS-C3-1` supersession/join/cancel/cleanup proof. |
| C.4 C2 config/public seam | Add `ThumbnailCacheConfigRow`, `ThumbnailCacheHistory`, and `ThumbnailCacheStatus`; default disk off; validate/upgrade before publication; refuse downgrade; keep `.memory` disk-free. | M1 migration/symbol proofs; `V2-WS-C2-3` upgrade/downgrade-refusal, app-wide one-way-door sign-off, config no-position/no-invalidation, and `.memory` proofs. |
| C.5 Disk codec/store | Add the resolved bounded `ThumbnailDiskBlobV1` wire format and actor-confined `DiskThumbnailCache`; sharded lookup filename is non-authoritative; validate the full key/checksum/version/size; coordinate temp-write + atomic replace; corruption is miss + lazy delete. | `C2-PLATFORM-1/2/3`, `V2-WS-C2-1` corruption/collision/torn-write/restart/C1-promotion proof. |
| C.6 Bounds/sweep/security | Enforce entry/byte caps, bounded insert eviction, wall-clock sweep even while disabled, backup-exclusion reassertion, approximate status, and immediate best-effort clear. Never scan/warm the disk cache at startup. | `C2-PERF-1/2/3`, `C2-SECURITY-1/2`, `V2-WS-C2-2` sweep/opt-out/backup proof. |
| C.7 UX handoff | Add opt-in disk toggle, cap, approximate usage, clear-now action, and durable-preview/removal-latency disclosure. Never expose cache hits as product state. | Corresponding `UX-*` and product tests. |

All acceptance gates:

`C1-COMPILE-1`, `C1-COMPILE-2`, `C1-PERF-1`, `C1-PERF-2`,
`C1-PERF-3`, `C2-PLATFORM-1`, `C2-PLATFORM-2`,
`C2-PLATFORM-3`, `C2-SECURITY-1`, `C2-SECURITY-2`,
`C2-PERF-1`, `C2-PERF-2`, `C2-PERF-3`, `C3-PERF-1`, and
`C1/C2/C3-PERF-4`.

## 10. V2-05 — external gateway and audit (X1/X2)

- **Status:** X.1/X.2 contracts and X.3 schema/bootstrap are landed. **X.4 is
  the current implementation leaf; its spec-first closed codec table is
  resolved in `V2-05` §4.4.** DC-14 through DC-16 and DC-26 are resolved by
  the 2026-08-22 schema/grant/no-hash decisions. Later Gateway behavior remains gated by the
  HCR substrate and applicable product/security evidence. X2 is mandatory with
  X1.
- **Spec references:** `V2-05` §0–§14; D32–D36.
- **Dependencies:** X.4 depends on landed immutable `HistorySchemaV3` and its
  established open/bootstrap order. Later behavior depends on completed app
  composition and the HCR/Storage-clock substrate resolved under DC-24/DC-25.
  AppIntents remains confined to ClipyApp; audit adds no cryptography import.
- **Security posture:** main app process only; one gateway/Authority; no App
  Intents extension, network enrollment, second writer, or audit off-switch.
  Local Automation is a later same-EUID-account continuation through
  `clipyctl`, not a login-session identity claim.

### Gateway slices

The public `clipyctl` JSON/exit-code contract may be frozen as documentation and
golden examples before product code. That design activity is not a production
slice. Product implementation follows the table strictly: complete in-process
Gateway deny/positive behavior, then App Intents, then CLI codec, then one
private transport. No later row may fabricate evidence for an earlier row.

| Step | Deliverables | Exit proof |
|---|---|---|
| X.0 Spec/evidence closure (no product code) | Freeze V2-05 §0, the `clipyctl` public wire shape, and platform evidence questions. Signed/TCC experiments may run here, but cannot choose or ship a transport. | Owning docs agree; unresolved authenticated ingress and format-inventory injection remain explicit blockers rather than inferred answers. |
| X.1 Closed vocabulary and allow matrix — **Batch 6 implementation leaf** | Add only `Sources/HistoryCore/ExternalGatewayTypes.swift`, `Sources/HistoryStorage/ExternalAccessPolicy.swift`, and `Tests/HistoryStorageTests/ExternalAccessPolicyTests.swift`; update the HistoryCore symbol snapshot. Preserve App Intents browse/readContent/manage exactly; deny cross-kind, unknown, and not-yet-admitted revise pairs. | `PLAY-PY-GW0`; table-driven total-matrix proof plus public-symbol/import/escape-hatch gates. No schema, actor, CLI, transport, credential, hash, or request digest. |
| X.2 Public Gateway contract | Add the remaining Foundation-only `ExternalHistory`, `GatewayAdminHistory`, identities, requests/results, failures, and connection/grant/audit DTOs. `OperationRecordDTO.connectionID`/`capability` are optional because global rebase/compact has no target connection and admin has no external grant capability. Leave every v1 closed enum/protocol unchanged. Do not fabricate a dispatcher or publish a facade before durable bootstrap and the real Gateway exist. | Run the public-symbol/import/escape-hatch checks for this contract-only leaf. It closes only the Foundation/public-surface clauses; aggregate `X-COMPILE-1/3` remain open until the real X.5 Gateway and its approved imports exist. No synthetic Gateway response. |
| X.3 Schema/limits/bootstrap — **landed** | Add a new immutable `HistorySchemaV3` containing the four Gateway/Audit models; never edit shipped `HistorySchemaV2`. Add fixed `ExternalLimits`. Bootstrap and validate exactly one config plus one active `Siri / Shortcuts / Spotlight` App Intents connection, zero grants, and zero audit rows. `GrantRow` is one current-state row per connection/capability; `GatewayConfigRow` has no `generation`. Do not implement `OperationPayloadBlobV1`, operation literal cases, registry/admin, actor, facade/factory, App Intents, CLI, or transport. | `X-PLATFORM-1/2`; V2→V3 migration, supported-prior migration, model/raw/config validation, missing-config-with-surviving-data rejection, identity/reopen persistence, exact zero-grant/zero-audit startup, and proof that no facade/admin/actor ships. Record the causal ceiling: config absent + all dependent tables empty is fresh/migration-compatible but indistinguishable from complete future V3 bootstrap deletion, so reconstruction is allowed and no marker/hash is added. Bootstrap must finish before any future facade publication. |
| X.4 Audit/admin substrate — **current implementation leaf; spec gate resolved** | Implement exactly the frozen `V2-05` §4.4 table: preserve operation raws 1...15, define raw 10 as connection revoke, add distinct raws 16 capability revoke / 17 connections read / 18 grants read / 19 audit read, and audit all three public admin reads. Land all 17 request / 15 result cases before any writer, then central audit store, then current-state connection/grant admin and startup-validation replacement. Every admitted attempt awaits exactly one audit commit before returning/throwing; rate-limit denials are one immutable row per call, never coalesced or updated. Per blob cap is 16 KiB. Logical `auditBytes` is exactly `payloadBlob.count + 128` per retained row with checked accounting; no implementation chooses another overhead. Re-grant updates one row; audit owns event history. Freeze/test the internal rebase transaction, but add no public recovery opener: ordinary-open corruption remains fail-closed and is not claimed runtime-recoverable. No audit off-switch, audit hash, generic payload, facade, transport, credential behavior, or performance work. | The case-table proof is documentation-complete. Code exit remains `PLAY-PY-GW1` through `GW4`: every tag/cross-field corruption matrix; admin-read high-water and append-before-publication behavior; monotone/floor and exact logical-byte accounting; atomic admin mutation+audit; current-state grant lifecycle; healthy-store admin rebase/compaction; privacy and optional attribution. A future recovery-only opener needs separate review before `corruptionDetected` rebase is reachable for an ordinary-open rejection. |
| X.5 In-process Gateway denial | Add `ExternalGateway`/registry dispatch through the real Authority. Only after X.3 bootstrap and this real actor exist, add the public `ExternalHistoryFacade` concrete type and `SwiftDataHistory.makeExternalHistoryFacade(for:)` accessor that bake the authoritative connection into the facade; never ship a placeholder/unavailable dispatcher. Prove unknown connection, no grant, revoked grant, invalid pair, and rate denial stop before History access. | `PLAY-PY-B1`, `PLAY-PY-B2`; authoritative denial and no-content/no-mutation proofs plus public facade/factory construction through the real Gateway. |
| X.6 In-process Gateway positive | Through the same production actor and real Authority, complete one granted bounded browse plus the approved App-Intents write/read subset, including save-boundary recheck and audit behavior. | `PLAY-PY-B0G`, `X-BEHAVIOR-1`; positive browse, TOCTOU revoke, write atomicity, privacy, and failure mapping. |
| X.7 App Intents composition | In `ClipyApp` only, add the six intents/shortcuts provider, obtain the baked App Intents facade, register it once with the framework-owned allowance, and resolve via `@Dependency`. It must use X.5/X.6, not duplicate policy. | `PLAY-PY-B0I`, `X-COMPILE-2/3/4`; cold/warm integration and unresolved-dependency clean-denial tests. |
| X.8 `clipyctl` pure codec | After X.7, implement the already frozen JSON stdin/stdout and stable exit mapping as pure code. It produces no synthetic Gateway response and has no transport. Capability JSON remains owner-summary declaration only. | `PLAY-PY-A2A` through `PLAY-PY-A2I`; parser/stdio/closed-operation golden tests. No Python-to-History claim. |
| X.9 Authenticated ingress and one private transport | First resolve `DEC-PY-AUTHENTICATED-INGRESS` target/access ownership; then select one transport from signed evidence and connect `clipyctl` to the same Gateway. The same-EUID claim is account-wide, not login-session identity. | `PLAY-PY-F0`, `PLAY-PY-F1`, then `PLAY-PY-B3`, `PLAY-PY-B3A`, `PLAY-PY-B3B`, `PLAY-PY-B3C`, `PLAY-PY-B4`, `PLAY-PY-B5`. **BLOCKED-SPEC** while ingress is unresolved. |
| X.10 Local Automation capability rollout | Separately admit browsePreview, Effective-only content, organize, delete, and only later revise. `describeFormatCapabilities` may execute only after the owner-summary runtime injection owner is approved. | Corresponding `PLAY-PY-C1` through `PLAY-PY-C5`, `PLAY-PY-D1A` through `PLAY-PY-D9`, `PLAY-PY-E1A` through `PLAY-PY-E7`, and signed `PLAY-PY-F3A…F3D` leaves; live grant, OCC, audit, bounded-content, and release proofs. |
| X.11 UX handoff | Add enable/revoke, per-kind capability controls, paginated audit, denial/failure/recovery state, same-account disclosure, shared-caller/quota, and audit-persistence disclosure. | Corresponding `UX-*`, privacy, accessibility, and product tests. |

All acceptance gates:

`X-COMPILE-1`, `X-COMPILE-2`, `X-COMPILE-3`, `X-COMPILE-4`,
`X-PLATFORM-1`, `X-PLATFORM-2`, `X-PLATFORM-3` according to the
scope resolved under DC-22, `X-BEHAVIOR-1`, `X-SECURITY-1`,
`X-SECURITY-2`, `X-SECURITY-3`, `X-SECURITY-4`, `X-PERF-1`,
`X-PERF-2`, `X-PERF-3`, and `X-PERF-4`.

## 11. V2-06 — independent platform grafts (P1/P2/P3)

The three grafts share a document, not an admission. Each may ship or remain
not applicable independently.

### P1 — persistent Signature Index checkpoint

- **Status:** blocked on V2-0, M1, and DC-17; gated on G5.
- **Regime:** capped profile only. Recipe-v2 legacy projection validation runs
  before either reuse or rebuild. The current DATA-11 authoritative Canonical
  coverage pass also remains mandatory: a matching checkpoint may not bypass
  it until an owning P1 amendment supplies an equally strong corruption proof.
  Production U-scale must first resolve
  `DEC-U-SCALE-STARTUP-INDEX` by replacing/amending this complete in-memory
  index with one authoritative durable candidate-query/lazy-shard path; it may
  not keep two truth indexes.
- **Dependencies:** completed authoritative Signature Index rebuild. P1 does
  not checkpoint the enrichment backlog or HCR.

| Step | Deliverable |
|---|---|
| P1.1 | Add `StartupCheckpointRow`, `SignatureIndexBlobV1`, immutable snapshot/posting values, codec, and Authority read/write helpers returning only `Sendable` values. |
| P1.2 | Add startup reuse: compare scalar checkpoint/version/position, decode only on a match, and transparently rebuild on absence/staleness/corruption. Always retain v1 pin-order validation. |
| P1.3 | After rebuild/reuse, write the checkpoint in a separate Authority transaction before facade publication, without position/invalidation changes. |

Acceptance: `P1-COMPILE-1`, `P1-PLATFORM-1`, `P1-PLATFORM-2`,
`P1-PLATFORM-3`, `P1-PERF-1`, unchanged WS14, and a dedicated
reuse/rebuild/corruption/disabled/restart-equivalence fixture.

### P2 — locale-sensitive exact search

- **Status:** blocked on V2-0, M1, and DC-18; gated on G7.
- **Dependencies:** completed v1 exact/fuzzy/regexp search and observation.
- **Non-goals:** no fourth mode, no fuzzy/regexp change, no projection column or
  rebuild.

| Step | Deliverable |
|---|---|
| P2.1 | Add `LocalizedSearchConfigRow`, fixed limits, public `LocalizedSearchHistory`/`LocalizedSearchStatus`, default-disabled bootstrap, and locale validation. |
| P2.2 | Branch exact mode at query time through verified `NSString.range(of:options:range:locale:)`; preserve empty-term recent behavior, title-before-body, ordering, snippets, and UTF-16 ranges; add width-insensitive matching for Japanese by language code. |
| P2.3 | Add the internal predicate-change signal so active search re-queries at the same `ChangePosition`; recent observers ignore it, and a predicate change expires every in-flight search cursor (mint-predicate mismatch -> `.snapshotExpired`, V2-06 §4.5). Add settings UI. |

Acceptance: `P2-COMPILE-1`, `P2-PLATFORM-1`, `P2-PLATFORM-2`,
`P2-PLATFORM-3`, `P2-PERF-1`, byte-for-byte disabled WS17, and
locale/region/empty-term/range/ordering/observer plus
predicate-change cursor-expiry fixtures.

### P3 — sidecar blob store and streaming

- **Status:** blocked on V2-0, M1, `DEC-P3-ADMISSION`,
  `DEC-P3-MIGRATION-WRITES`, and a replacement amendment for V2-06 §5; gated
  on G8. P3 is never a prerequisite for the independent many-small U-scale
  track.
- **Dependencies:** completed capture/revision preparation and detail/paste read
  paths. P3 is local only.

| Step | Deliverable |
|---|---|
| P3.1 | After the owning amendment resolves purpose-read and migration-write semantics, add the actor-confined `ContentDepot`, representation locators, and one bounded reader/lease seam. |
| P3.2 | Write selected large representations to random-ID, path-confined staging files during preparation; force `.memory` inline and track explicit commit/abort ownership. Do not use content hashes as identity or integrity machinery. |
| P3.3 | Commit only small locators through Authority; before publish, validate declared length and perform staged byte-exact readback through the same reader. Missing source, short/truncated read, path escape, and read failure are typed failures. |
| P3.4 | Implement one bounded `Sendable` sequential reader: fence `ContentVersion` at open, use the approved chunk/permit budget, and keep the transport/framework object internal. No raw `FileHandle.AsyncBytes` or end-of-stream hash contract is public. |
| P3.5 | Implement a bounded, resumable item-by-item legacy migration with a durable cursor and the approved concurrent-write policy; validate new representation state before deleting legacy bytes. Treat the depot generation as inseparable from backup/restore and reclaim orphans by bounded enumeration. |

Acceptance: `P3-COMPILE-1`, `P3-PLATFORM-1`, `P3-PLATFORM-2`,
`P3-PLATFORM-3`, `P3-PLATFORM-4`, `P3-PLATFORM-5`, and
`P3-PERF-1`, including bounded migration/resume, capture/sweep race,
abort cleanup, path/symlink escape, missing-sidecar, stream integrity-window,
memory-residency, deterministic O_EXCL random-ID collision retry (forced
EEXIST, then success on the next injected ID), and backup-boundary proofs.

### Independent U-scale/count track

Many-small history remains on Scheme A unless its own evidence selects a new
layout. Production `count=nil` requires both an optional user maximum-unpinned
policy and removal/replacement of the separate pinned-inclusive global hard
bound. Before that transition, current-layout `PLAY-DISK-0A/0B/1/2A/3/4/5/6`,
metadata/index/search/retention/UI boundedness, and the 5,001 → 50k → 250k →
1m scale gates must pass. P3 success neither unlocks nor substitutes for this
track.

## 12. V2-07 — incremental UX integration

- **Status:** blocked on v1 step 9 and DC-08/DC-20; otherwise ships with each
  admitted user-facing backend.
- **Spec references:** `V2-07` §2–§17.
- **Dependencies:** HistoryCore DTOs/protocols only in PresentationUI; concrete
  protocol casts and composition in ClipyApp.
- **Owns:** no graft, invariant, schema, codec, actor, durable state, or public
  DTO.

### UX slices

| Step | Deliverable | Admission |
|---|---|---|
| UX.1 Composition shell | Main-actor `@Observable` state and conditional casts to the admitted distinct-concern protocols. A nil cast omits the section. The App Intents facade is admitted by registration, not cast: `ClipyApp` builds it via `makeExternalHistoryFacade(for:)` and performs the single sanctioned `AppDependencyManager.shared.add` at the composition root (V2-05 §6.5 / V2-07 §8.2). | First user-facing V2 backend. |
| UX.2 Refresh framework | Implement the not-live-observed re-read contract for derivation/config/admin state; no polling; honest last-refresh labels. P2 predicate change is the only self-healing same-position search exception. | Any V2 UI. |
| UX.3 Enrichment | Status-at-last-refresh badges, OCR search presentation, enable setting/readback selected under DC-08, and data-retention disclosure. | E1. |
| UX.4 Retention | Render only the dimensions admitted under DC-23, with matching receipts and validation/capacity guidance; omit current usage without the OPEN-2 API. | Retention surface admitted under DC-23. |
| UX.5 Reconnect/journal | Pull-only recently removed/resync; advanced controls only with public `JournalAdminHistory`. | Approved reconnect UI and/or admitted admin API. |
| UX.6 Thumbnail disk cache | Toggle, cap, approximate usage, clear now, and preview-retention disclosure; never expose hit state. | C2. |
| UX.7 Gateway/audit | Connection/grant controls, capability split, audit/rebase/compaction viewer, shared-caller/quota and persistence disclosures. | X1/X2. |
| UX.8 Localized search | Enable toggle and supported-locale picker; search locale stays independent of UI language. | P2. |
| UX.9 Accessibility/localization/previews | Label/value/hint, VoiceOver phrases, no color-only state, Dynamic Type/contrast, String Catalog, plural/date/duration/byte formatting, and scripted preview updates. | Every shipped UX slice. |

PresentationUI never imports SwiftData, HistoryStorage, HistoryDomain, AppKit,
Vision, PDFKit, ImageIO, CryptoKit, or AppIntents, and never decodes a content or
audit blob.

Acceptance: `UX-COMPILE-1`, `UX-COMPILE-2`, `UX-PLATFORM-1`,
`UX-PLATFORM-2`, and `UX-PERF-1`, plus hosted integration, VoiceOver,
localization, disclosure, and product tests for every selected surface.

## 13. Cross-capability integration pass

After individually green grafts, prove their compositions rather than assuming
pairwise correctness:

1. **One commit kernel.** Capture/revise/pin/unpin/remove/clear/retention and
   successful external writes still produce one transaction, one
   `ChangePosition`, correct Signature Index delta, exactly one HCR, and—only
   for successful external writes—one atomic audit record.
2. **Retention + journal.** R1/R2 retirement maps to `.retire`; R3-only maps to
   `.retireRevision`; mixed membership+prune uses the documented primary kind and
   affected-ID union.
3. **Retention + enrichment.** Item retirement leaves only the documented lazy
   enrichment-orphan window; R3 does not invalidate current enrichment because
   Effective Content is unchanged.
4. **Enrichment + search + P2.** Locale-sensitive exact matching applies to the
   selected scalar fields without changing fuzzy/regexp, decode bounds, ranking,
   or UTF-16 range contracts.
5. **Journal + collection cache + observation.** Durable reconnect/cache
   completeness does not replace or duplicate v1 transient snapshot
   observation. The cache fence composes with V2-01: a ready enrichment
   persist or enable toggle bumps `corpusEpoch` without advancing
   `ChangePosition`, and both §7.1 windows (lookup->fence,
   interval-exit->insert) treat the bump as a miss (`V2-WS-J1-4` epoch arms).
6. **Thumbnail + revisions.** Fetch fence, approved stamp-key single-flight,
   cache insertion, publish fence, and caller-side reference check each retain
   their distinct role under joined callers and concurrent revisions.
7. **P3 + every consumer.** Capture/revise/detail/paste/fingerprint/enrichment/
   thumbnail paths produce the same logical bytes for inline and handle-backed
   storage; bounded consumers do not accidentally materialize full sidecars.
8. **Migration + startup.** Exercise every supported prior schema version and
   selected-feature combination through one total open order, including failure
   injection between every migration/bootstrap phase.
9. **Security.** No second writer/process, network path, content-bearing audit,
   grant cache, path escape, unreviewed entitlement, or broad service-locator
   exception appears.
10. **Disabled-path compatibility.** Every admitted-but-disabled capability is
    v1-faithful at its public seam. Internal projection maintenance required for
    future enablement is allowed only where explicitly specified and tested.

## 14. Completion states

### V2 design ready

- V2-0 and V2-1 complete;
- §4 has no unresolved blocker for the selected release;
- durable facts and cross-references resolve;
- every selected graft has a recorded trigger and all six applicable
  `V2-00` §4 admission records;
- the invariant registry remains collision-free:
  V2-01 D20–D22, V2-02 D23–D24, V2-03 D25–D28,
  V2-04 D29–D31, V2-05 D32–D36, V2-06 D37–D39,
  and V2-07 none.

### A graft is executable

- its full slice sequence and every named proof gate pass on macOS 26 arm64;
- fresh, `.memory`, migrated, corruption, rollback, restart, concurrency, and
  performance cases appropriate to that graft pass;
- source gates, SwiftLint, strict-concurrency builds, package tests, generated
  app tests, and public-symbol snapshot are warning-free;
- the living V2 progress ledger records commits and CI evidence.

### A V2 release is product complete

- every graft selected for that release is executable;
- §13 compositions pass;
- app packaging/launch, accessibility, localization, privacy/security
  disclosures, and product tests pass;
- untriggered grafts are recorded as **not applicable**, not as missing code;
- no temporary research file or untracked generated Xcode project is part of the
  release source of truth.

## 15. Traceability and progress recording

Use this task/PR header:

```text
Roadmap slice:
Graft + trigger evidence:
V2 spec sections:
v1 sections extended:
Invariants preserved/extended:
Migration layers:
Cache/security record:
Proof gates closed:
CI run:
```

When the first V2 graft starts, create a living `docs/v2/V2-PROGRESS.md` rather
than editing frozen v1 `docs/PROGRESS.md`. Record one section per roadmap slice,
including deviations, migration version allocated, proof gates, commits, CI
runs, and follow-up blockers. Update this roadmap’s status lines as slices land.

## 16. Explicitly excluded from this roadmap

- multi-process direct writers;
- CloudKit or multi-device sync;
- ML embeddings, semantic search, classification, or summarization;
- remote/network blob storage;
- a generic materialization/cache/source-stamp framework;
- migration from Maccy;
- scanned-PDF OCR beyond the admitted text-layer behavior;
- Keychain credentials unless a later separately admitted graft closes
  `X-PLATFORM-3`;
- P3 large-attachment preview/export unless OPEN-7 becomes a separately designed
  post-V2 capability.

These exclusions are not backlog slices. Admitting any of them requires a new
design document, evidence trigger, invariant/migration/security review, and
roadmap amendment.
