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
| [V2-05 external gateway](V2-05-external-gateway.md) | §10, X.1–X.7 |
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
| V2 platform evidence | `V2-facts.md` cycles 1–5 hold the E1, RET, X1 App-Intents, P2 string, C2 file, and executor facts; V2-03..V2-06 still cite temporary `.tmp/v2-research` sidecars | Remaining sidecar promotion (DC-01) is still required before scaffold work. |

### Step V2-0 — finish and freeze the v1 executable specification

**Status:** v1 steps 6–8 have landed and been audited (2026-08-15 re-baseline,
`docs/V1-Verified/`, run 31449682036); the remaining V2-0 work is the recorded
state-2 declaration, the D1–D19 evidence reconciliation, and (capability-local
only) step 9.

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
- record the missing V2-05 cycle-5 App Intents/audit facts;
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
| P1 | Metadata-only startup/index rebuild p95 > 250 ms at 5,000 items. |
| P2 | Approved locale-sensitive matching requirement plus fixed locale fixtures. |
| P3 | Representative workload exceeds the capture-path memory budget or shows p95 copy cost unsolvable within bounded inline values. |

### Gate maintenance for every admitted slice

- Extend `scripts/import_gate.py` and `.swiftlint.yml` together. E1 permits
  Vision/PDFKit only in HistoryStorage; X1 permits CryptoKit only in
  HistoryStorage and AppIntents only in ClipyApp. No other import boundary
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
        +-- J1 journal/reconnect --> X1/X2 gateway/audit (relation resolved by DC-25)
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
6. V2-05 storage/gateway/audit, then App Intents;
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
| DC-01 | V2 facts / all modules | Promote the V2-03..V2-07 fact sidecars out of `.tmp`, add the missing V2-05 cycle-5 facts, and make every citation resolve durably. |
| DC-02 | M1 / V2-02 | Reconcile the required `RetainedBytesRow` custom backfill with statements that V2-02 is lightweight-only. Prove the legal SwiftData stage topology before schema code lands. |
| DC-03 | M1 / all schema grafts | Choose consolidated versus incremental shipping. Every shipped `VersionedSchema` is immutable; later grafts receive the next version instead of mutating an already-shipped `HistorySchemaV2`. |
| DC-04 | V2-02 | Change or justify `RetainedBytesRow.itemIDRaw: String`; the v1 business ID is UUID-backed. Reconcile “disabled is byte-for-byte v1” with mandatory 1:1 byte-projection maintenance, and fix insert/coalesce/first-revision wording. *(2026-08-15: the field is now `itemID: UUID` in V2-02 §3.3 per this direction; the projection-maintenance and insert/coalesce/first-revision wording items remain open.)* |
| DC-05 | V2-01 | Make the persist-time source-selection fence implementable for mixed PDF+image content. The Authority cannot repeat the worker-only PDF probe from the current `PendingEnrichment` fields. |
| DC-06 | V2-01 | Reconcile zero-blob-decode search with the claimed scalar/blob inconsistency detection; choose encoded `kind == none` versus an empty not-applicable blob. |
| DC-07 | V2-01 | Specify one coherent inbox loss/backpressure/rescan policy, the claimed secondary ordering inputs, OCR text normalization, and recovery after the terminal retry cap. |
| DC-08 | V2-01/V2-02/V2-03/V2-07 | Decide sibling public reads: `enrichmentEnabled()` (OPEN-3), batch `enrichmentStatuses(for:)` (OPEN-6), current retained bytes (OPEN-2), and `JournalAdminHistory` (OPEN-5). Omit dependent UI if an API is not admitted. |
| DC-09 | V2-03 | Reset `journalBytes` during rebase; distinguish legitimate empty bootstrap/rebase from accidental loss of the journal head; define a bounded deterministic `CollectionCacheLimits`/eviction policy and a concretely bounded `AffectedItemsBlobV1` decoder. *(2026-08-15: the `journalBytes = 0` reset is applied to the §9.2 rebase sequence; the other three items remain open.)* |
| DC-10 | V2-03 | If J1 is admitted only for reconnect, default the collection cache off until G2 evidence exists. Purpose-qualify journal versus thumbnail materializer-version methods and values. *(2026-08-15: `cacheEnabled` bootstrap default flipped to `false` in V2-03 §2.3, §4.6, and Record 5; the fixture at §17 that enables the cache now says so explicitly; the materializer-version qualification remains open.)* |
| DC-11 | V2-04 | Obtain explicit recorded review/product sign-off for the stamp-collision residual, the load-bearing single-flight join-key substitution, and materializer-version downgrade refusal, or redesign the keying. |
| DC-12 | V2-04 | Make cache insert APIs carry `contentVersion`/`builtAt`, specify C3 metrics collection, choose a concrete bounded disk wire format/decoder, and resolve whether C1 requires both G1 and G4 or G1 admits the internal S1 substrate. *(2026-08-15: the C1 `insert` signature now carries `contentVersion`/`builtAt`; the other three items remain open.)* |
| DC-13 | V2-03/V2-04 | Reconcile the cross-doc thumbnail-key description (`ContentVersion` versus source fingerprint) and map every V2-04 cache-law, collision, restart, joined-caller, corruption, sweep, and version-door obligation to the roadmap-owned stable fixtures. *(2026-08-15: the stable fixture IDs `V2-WS-C1-1/2`, `V2-WS-C2-1/2/3`, `V2-WS-C3-1` are now defined in V2-04 Record 4, so the roadmap's C.2–C.6 citations resolve; the thumbnail-key reconciliation remains open.)* |
| DC-14 | V2-05 | Reconcile deterministic unique `GrantRow.grantKey` with re-grant creating a new row. |
| DC-15 | V2-05 | Define audit compaction so the surviving suffix validates; the current first-survivor-only rehash leaves later links stale unless the boundary representation changes. |
| DC-16 | V2-05 | Make audit payload/DTOs represent optional commit positions and rebase range/reason; include every integrity-bearing column in the hash or narrow D36; provide a reachable recovery mode when normal `open` rejects a broken chain. |
| DC-17 | V2-06 P1 | Replace `readStartupCheckpoint() -> StartupCheckpointRow?` with an immutable `Sendable` snapshot so no `@Model` crosses a context/actor boundary. |
| DC-18 | V2-06 P2 | Define deterministic behavior when the system locale is outside the five supported fixture locales. |
| DC-19 | V2-06 P3 | Specify crash-resumable/idempotent eager migration, concrete commit/abort coordination for in-flight sidecars, and the actor-confined buffered stream that actually enforces the 256 KiB residency bound. |
| DC-20 | V2-06/V2-07 | Resolve OPEN-7: P3 is transparent in V2-07, or a separately designed post-V2 large-attachment consumer owns `BlobStreamingHistory`. Do not leave a dangling consumer claim. |
| DC-21 | V2-02 | Specify finite-value validation for `TimeInterval`, retain the `RET-PLATFORM-4` fallback if R3 and the v1 revision-byte hard bound use different measures, and resolve the new-item/coalesce byte-projection wording before fixtures freeze. |
| DC-22 | V2-05 | Reconcile “CredentialStore/Security is unbuilt and future-only” with §14’s statement that `X-PLATFORM-3` must pass for V2-05. Either remove the gate from X1/X2 completion or admit and specify the Keychain slice. |
| DC-23 | V2-00/V2-02/V2-07 | Decide whether R1/R2/R3 are one atomic retention bundle or independently admitted dimensions. Align trigger recording, public enums and policy fields, schema/defaults, implementation slices, and visible controls with that decision. |
| DC-24 | V2-02/V2-03 | Define ownership and release ordering for the shared Storage clock when J1 is admitted before or without retention. Do not make an independent J1 trigger silently reserve untriggered V2-02 public or schema surface. |
| DC-25 | V2-00/V2-03/V2-05 | Resolve the X1/X2 dependency on the V2-03 HCR substrate: either require independently admitted J1 or specify the exact HCR-only substrate that X subsumes, including schema, migration, reconnect visibility, and proof-gate consequences. |

The closure pass must also establish one total `SwiftDataHistory.open` bootstrap
order for all selected singletons, migrations, projection rebuilds, materializer
checks, compaction/rebase checks, Signature Index reconstruction/checkpointing,
and facade publication. Per-module “after the previous singleton” prose is not a
substitute for one executable order.

## 5. M1 — release-specific migration foundation

- **Status:** blocked on V2-0, DC-03, the migration blockers applicable to the
  first admitted graft, and that graft's admission.
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
| M1.5 | When P3 is admitted, run its separate eager blob-codec/sidecar migration. Preserve logical bytes and tokens; publish only after every row is V2-readable. | Crash-resume, worst-case duration/memory, missing-sidecar, rollback, and no-V1-read-fallback proofs pass. |

Migration inventory:

| Graft | Schema layer | Blob layer | Projection/files layer |
|---|---|---|---|
| V2-02 | `RetentionExpansionConfigRow`, `RetainedBytesRow` | none | mandatory byte-projection backfill |
| V2-01 | `EnrichmentRow`, `EnrichmentConfigRow` | new `EnrichmentBlobV1` only | no backfill; disabled and empty |
| V2-03 | `HistoryChangeRecordRow`, `JournalConfigRow` | new `AffectedItemsBlobV1` only | no historical backfill; HCR starts at the next commit |
| V2-04 C2 | `ThumbnailCacheConfigRow` | new disk-file codec only | empty cache directory; lazy population |
| V2-05 | `ConnectionRow`, `GrantRow`, `OperationRecordRow`, `GatewayConfigRow` | new audit codecs only | bootstrap one ungranted App Intents connection |
| P1 | `StartupCheckpointRow` | new checkpoint codec | rebuild on miss/corruption |
| P2 | `LocalizedSearchConfigRow` | none | query-time only; no search projection rebuild |
| P3 | no new SwiftData model | eager `CanonicalBlobV1→V2` and `RevisionStateBlobV1→V2` | sidecar spool plus orphan/in-flight recovery |

M1 is complete only when each admitted module’s migration proof gates pass,
including `E1-PLATFORM-1/4`, `RET-PLATFORM-1/1b`, `J1-PLATFORM-2`,
`X-PLATFORM-1`, `P1-PLATFORM-3`, and `P3-PLATFORM-3/5` as applicable.

## 6. V2-02 — retention expansion (R1/R2/R3)

- **Status:** blocked on V2-0, M1, DC-02, DC-04, DC-21, and DC-23; otherwise
  gated on approved product requirements.
- **Spec references:** `V2-02` §2–§12b; D23–D24.
- **Dependencies:** completed v1 mutations/revision preparation; Foundation +
  HistoryCore-only Domain; existing `HistoryAuthority`.
- **Recommended position:** first implementation graft because it has the least
  platform surface and establishes the Storage clock later reused by J1/X2.

### Retention slices

| Step | Deliverables | Exit proof |
|---|---|---|
| R.1 Core contract | Add only the retention policies, action/outcome surface, and capacity cases admitted under DC-23; validate their bounds and normalize a both-nil revision policy when R3 is included. Update all exhaustive switches and the public-symbol snapshot intentionally. | `RET-COMPILE-1/2`; policy-bound and failure-translation fixtures for every admitted dimension. |
| R.2 Pure Domain | Add complete expansion facts/summaries, `RetentionExpansionPlan`, `RevisionExpansionTarget`, `planItemRetentionExpansion`, `planRevisionRetentionExpansion`, `HistoryMutation.pruneRevisions`, `HistoryMutation.setRetentionPolicies`, and `PlannedOutcome.retentionPoliciesSet`. Implement deterministic R1 strict-age ordering, R1-before-R2 union, protected victims, checked bytes, and minimal oldest-inactive R3 pruning. | `RET-PRUNE-1/2`; deterministic and overflow fixtures; D23/D24 proofs. |
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
`RET-PRUNE-2`, `RET-CONCUR-1`, `RET-STAMP-1`, `RET-STAMP-2`,
`RET-PERF-1`, `RET-PERF-2`, `RET-PERF-3`, and `RET-SECURITY-1`.

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
| E.7 Search/status/toggle | Add scalar `enrichmentText` to internal search corpus only; enforce title→body→enrichment precedence and per-mode scan bounds; decode no content/enrichment blobs on common search; implement status and default-disabled/readback behavior selected under DC-08. | `E1-PERF-2/5`; disabled WS17 equivalence, snippets/ranges/ranking, stale-row exclusion, status, and toggle fixtures. |
| E.8 UX handoff | Add last-refresh status badges, OCR match presentation, settings, data-practice/lazy-deletion disclosures, accessibility, and localization. Do not add an OCR completion push or polling loop. | `UX-COMPILE-1/2`, `UX-PERF-1`, accessibility/product tests. |

All acceptance gates:

`E1-COMPILE-1`, `E1-COMPILE-2`, `E1-COMPILE-3`,
`E1-PLATFORM-1`, `E1-PLATFORM-2`, `E1-PLATFORM-3`,
`E1-PLATFORM-UTI`, `E1-PLATFORM-4`, `E1-PERF-1`,
`E1-PERF-2`, `E1-PERF-3`, `E1-PERF-4`, `E1-PERF-5`,
`E1-PERF-6`, `E1-PERF-7`, and `E1-SECURITY-1`.

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
| J.3 Atomic append | Add `HistoryChangeRecordPayload` and `StampedCommitPlan.hcrAppend`; thread clear scope; derive a total primary kind and sorted/deduplicated affected IDs; append exactly once inside every non-empty commit before the final position write; append none for no-op. | `J1-PLATFORM-1`, `J1-PERF-1`, `V2-WS-J1-1`, `1a`, `5`, and `7`; extended WS13 injection points. |
| J.4 Reconnect reader | Add `ChangeJournal` plus Authority reads. In one context/interval: validate store, generation, materializer, and compaction floor before a bounded ordered range fetch and head read. Preserve the retroactive-discard rule for a later-page rejection. | `J1-PLATFORM-3/4/5`, `V2-WS-J1-2/3`. |
| J.5 Compaction/recovery | Implement count/age/byte compaction, persisted floor/counter, startup and periodic triggers, head survival, materializer upgrade/downgrade handling, divergence rebase, generation bump, and cache flush in the resolved open order. | `J1-PLATFORM-2`, `J1-PERF-4/5`, `V2-WS-J1-6`. |
| J.6 Conservative collection cache | After separate G2 evidence, add a bounded deterministic first-page-only cache. Keep awaits outside the Authority interval; fence hits against position/materializer; continuation pages bypass. If admission was reconnect-only, remain disabled. | `J1-COMPILE-2`, `J1-PERF-2`, `V2-WS-J1-4`; cache-law, fence-race, capacity, and page-2 proofs. |
| J.7 Optional fine invalidation | Only when measured read/write behavior requires hits across commits, replace—not chain after—the blanket handler with HCR-scoped invalidation; paginate journal reads and flush on a true gap/typed expiry. | `J1-PERF-3`; starvation, contiguity, and no-thrash proofs. |
| J.8 Security/UX handoff | Surface metadata retention, resync, pull-only recently removed, and admitted admin controls. Preserve v1 live snapshot observation; add no TCC, entitlement, or OperationRecord. | `J1-SECURITY-1` plus corresponding `UX-*` gates. |

Stable journal fixtures are `V2-WS-J1-1`, `V2-WS-J1-1a`,
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

- **Status:** blocked on V2-0, M1, the HCR prerequisite resolved under DC-25,
  DC-01, DC-14 through DC-16, DC-22, and DC-25; otherwise gated on an approved
  X1 product spec and recorded fresh architecture review, whose review record
  includes the security analysis. X2 is mandatory with X1.
- **Spec references:** `V2-05` §2–§13; D32–D36.
- **Dependencies:** completed app composition; the HCR and Storage-clock
  substrate resolved under DC-24/DC-25; CryptoKit in HistoryStorage and
  AppIntents in ClipyApp only.
- **Security posture:** main app process only; one gateway/Authority; no App
  Intents extension, network enrollment, second writer, audit off-switch, or
  Keychain implementation in this V2 slice.

### Gateway slices

| Step | Deliverables | Exit proof |
|---|---|---|
| X.1 Platform/security spike | Durably verify main-process/TCC behavior, cold/warm `@Dependency` order and Swift 6 crash-freedom, parameter API, caller identity, and fixed rate/audit bounds. | `X-COMPILE-2/4`, `X-SECURITY-1/3/4`; architecture review. |
| X.2 Public contract | Add `ExternalHistory`, `GatewayAdminHistory`, identities/capabilities, requests/results, failures, connection/grant/audit DTOs, public `ExternalHistoryFacade`, and public `makeExternalHistoryFacade(for:)`. Leave every v1 closed enum/protocol unchanged. | `X-COMPILE-1/3`; public-symbol/import/escape-hatch gates. |
| X.3 Schema/codecs/bootstrap | Add four models, resolved audit codecs, and fixed limits. Bootstrap one durable active App Intents connection with no grants; validate singleton/connection/chain before facade publication; audit is always on. | `X-PLATFORM-1/2`; migration, corruption, missing-config-with-data, identity-persistence, and chain proofs. |
| X.4 Audit/admin substrate | Implement monotone sequence, checked bytes, append, full chain validation, resolved compaction/relink, explicit recovery-mode rebase, admin registry/grants, and atomic admin audit. Deny by default; manage implies browse, never readContent. | `X-SECURITY-2`, `X-PERF-1/2/4`; grant lifecycle, tamper matrix, compaction/rebase, and recovery reachability. |
| X.5 Gateway execution | Add `ExternalGateway` and `ConnectionRegistry`; rate-limit, validate, fast-precheck, then authoritative grant recheck. Map the safe write subset to existing v1 actions. Successful writes atomically commit item mutation, HCR, audit, and final position; reads/no-op/denials use the documented best-effort audit bound. | `X-PERF-1/2/3`; TOCTOU revoke, write atomicity, read-capability split, search two-interval, audit privacy, and failure-mapping proofs. |
| X.6 App Intents composition | In ClipyApp only, add the six intents/shortcuts provider; open history, obtain the baked-connection facade, register it once with the sole framework-owned `AppDependencyManager.shared` allowance, and resolve via `@Dependency`. | `X-COMPILE-2/3/4`; cold/warm Siri/Shortcuts integration and unresolved-dependency clean-denial tests. |
| X.7 UX handoff | Add enable/revoke, separate browse/read-content/manage controls, paginated audit, denial/failure/rebase/compaction state, shared-caller/quota disclosure, and audit-persistence disclosure. Pull-refresh only. | Corresponding `UX-*`, privacy, accessibility, and product tests. |

All acceptance gates:

`X-COMPILE-1`, `X-COMPILE-2`, `X-COMPILE-3`, `X-COMPILE-4`,
`X-PLATFORM-1`, `X-PLATFORM-2`, `X-PLATFORM-3` according to the
scope resolved under DC-22, `X-SECURITY-1`,
`X-SECURITY-2`, `X-SECURITY-3`, `X-SECURITY-4`, `X-PERF-1`,
`X-PERF-2`, `X-PERF-3`, and `X-PERF-4`.

## 11. V2-06 — independent platform grafts (P1/P2/P3)

The three grafts share a document, not an admission. Each may ship or remain
not applicable independently.

### P1 — persistent Signature Index checkpoint

- **Status:** blocked on V2-0, M1, and DC-17; gated on G5.
- **Dependencies:** completed authoritative Signature Index rebuild. If P3 also
  ships, P3 migration/reconstruction precedes checkpoint capture. P1 does not
  checkpoint the enrichment backlog or HCR.

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
| P2.3 | Add the internal predicate-change signal so active search re-queries at the same `ChangePosition`; recent observers ignore it. Add settings UI. |

Acceptance: `P2-COMPILE-1`, `P2-PLATFORM-1`, `P2-PLATFORM-2`,
`P2-PLATFORM-3`, `P2-PERF-1`, byte-for-byte disabled WS17, and
locale/region/empty-term/range/ordering/observer fixtures.

### P3 — sidecar blob store and streaming

- **Status:** blocked on V2-0, M1, DC-19, and DC-20; gated on G8.
- **Dependencies:** completed capture/revision preparation and detail/paste read
  paths. P3 is local only.

| Step | Deliverable |
|---|---|
| P3.1 | Add actor-confined `BlobStore`, limits, V2 canonical/revision codecs and handle values; resolve the public/internal `BlobStreamingHistory` surface and consumer. |
| P3.2 | Write ≥1 MiB representations to unique nonce-bearing, path-confined, fsynced sidecars during preparation; force `.memory` inline; track explicit in-flight ownership and commit/abort outcomes. |
| P3.3 | Commit only small handle codecs through Authority, mark handles durable after commit, and implement full materialization with length/path/fingerprint checks. |
| P3.4 | Implement a real bounded/Sendable stream adapter: fence `ContentVersion` at open, cap residency at 256 KiB, validate length before vending, and verify the whole-file fingerprint at end. |
| P3.5 | Implement crash-resumable eager V1→V2 migration and bounded orphan/in-flight cleanup. Treat `<storeURL>.blobs/` as inseparable from backup/restore; no inline or V1 fallback remains after migration. |

Acceptance: `P3-COMPILE-1`, `P3-PLATFORM-1`, `P3-PLATFORM-2`,
`P3-PLATFORM-3`, `P3-PLATFORM-4`, `P3-PLATFORM-5`, and
`P3-PERF-1`, including worst-case first-launch migration, capture/sweep race,
abort cleanup, path/symlink escape, missing-sidecar, stream integrity-window,
memory-residency, and backup-boundary proofs.

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
| UX.1 Composition shell | Main-actor `@Observable` state and conditional casts to the admitted distinct-concern protocols. A nil cast omits the section. | First user-facing V2 backend. |
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
   completeness does not replace or duplicate v1 transient snapshot observation.
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
