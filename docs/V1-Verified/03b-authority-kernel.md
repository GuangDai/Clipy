# HistoryStorage — HistoryAuthority Commit Kernel — V1 Verified

> **Module:** `Sources/HistoryStorage/HistoryAuthority.swift` (2,471 LOC — the single largest file) + `StampedPlan.swift` (418) + `HistoryInvalidation.swift` (168) + `ActorStubs.swift` (309). The sole mutation serializer, sole creator/user of writable `ModelContext`s, the §11 post-commit ordering owner, and the snapshot/observation registration point.
> **Method:** 3-cycle 审查→调研→批评 workflow — 22 agents, full 3 cycles (C3 resumed after a rate-cap interruption with cached-prefix replay), ~2.5M tokens, ~75 min total. Confirmed counts grew 36→35→38 across cycles (C3 deepened, not re-treaded).
> **Verdict:** strong, well-conceived correctness spine with **one real correctness bug** in unpinned-continuation pagination, plus a cluster of efficiency defects whose severity is *provisional* on three unverified platform assumptions. **0 critical, 1 major, 18 minor, 19 nit.**
>
> **Orchestrator cross-check (independently confirmed against source):**
> - **`ws18-unpinned-continuation-pagination-contract-violation-cluster` (MAJOR)** — directly confirmed by reading `HistoryAuthority.swift:1702-1737` + `:2370`: the exactness guard indexes `rows[param_limit-1]/rows[param_limit]` against the *parameter* limit, not the true post-anchor-drop page boundary (`anchorIndex+outer_limit`); the anchor's same-`lastCopiedAt` head-group is a second completeness location the guard never inspects, so continuations can orphan rows or silently trust `\.id` at the real boundary. C3 deepened this to three distinct manifestations and gave a precise fix (head-contiguous-same-date-count ≥ 2 trigger) + an adversarial WS18 fixture.
> - **`commit-tail-duplicated-cluster`** — the §11 post-commit order is hand-duplicated between `commitCapture` (518-546) and `executeStampedPlan` (565-603) with a stale justification comment; highest-value maintainability fix.
> - **C3 correction (provenance):** the prior-cycle nil-coalescing `#Predicate { ($0.pinOrdinal ?? -1) > anchorOrdinal }` fix for the pinned-continuation quadratic was **re-evaluated as not-translatable** (community consensus) — the deviation stands unless an on-device SDK test proves otherwise, or a schema change (non-optional mirror column) is made. This is exactly the 批评 cycle correcting an earlier view.
>
> Line numbers as-of HEAD `8f316c9`.

---

## 1. Executive summary

The HistoryAuthority commit kernel is **structurally sound** as a single-writer, OCC-guarded transaction engine: every mutation is funneled through one `context.transaction` closure, the singleton position is written last (D6), and pin contiguity, retained-count, content-version agreement, and OCC position are all re-derived inside the transaction before commit success. The headline defect is **a single correctness bug in unpinned-lane continuation pagination** (HistoryAuthority.swift:2370) — the exactness guard indexes the wrong slice slots relative to the true post-anchor-drop page boundary, orphaning older rows under same-`lastCopiedAt` head contamination (verified by trace; ships undetected because WS18 uses 1000-second-spaced timestamps). Everything else is efficiency and maintainability: the kernel pays an O(N) full-table scalar-scan tax on every commit to keep every invariant check out of the store (the §18 verify-against-the-SDK stance taken to its limit), the search corpus is rebuilt O(N log N) on every browse page and observation spin with no cache, and several severity ratings are parked behind measurements the perf runner cannot currently make (on-disk p99 / RSS / durable fsync timing).

## 2. Scope & method

**Files examined (Sources/HistoryStorage/, 4,617 LoC):** `HistoryAuthority.swift` (2,471 lines — the commit kernel, read paths, ordering, cursor codec seam), `FactLoaders.swift` (498 — ingest/mutation fact loading, signature index rebuild), `SwiftDataHistory.swift` (438 — facade adapter, observation dispatch), `StampedPlan.swift` (418 — commit-plan stamping), `ActorStubs.swift` (309 — RevisionPreparationActor, revert), `HistoryInvalidation.swift` (168 — publisher), `MutationFactLoaders.swift` (315).

**Spec sections cross-referenced:** `docs/05-authority-kernel.md` (§2 authority surface, §5 non-suspending interval, §6.2 preparation actor, §7.1 capture agreement proof, §7.3 retention, §9 commit flow / ≤limit+1 bound, §10 executor rules, §11 post-commit order, §12 divergence, §13 startup invariants, §14.1–§14.5 read paths, §16 failure vocabulary, §18 verify-against-the-SDK stance); `docs/04-coherence.md` (§4 invalidation, §6 continuation reaches all rows, §9 thumbnails); `docs/06-cross-cutting.md` (§3 G2/G5 measured-evidence gates, §7.1/§7.5 faulting, §8 WS12–WS21); `docs/02-domain.md` (D6/D12/D15/D18); `docs/01-architecture.md` §10.

**Process:** the user-mandated serial 3-cycle review-research-critique audit (full xhigh, ~68 min/module). Cycle 1 (review) produced candidate findings against source + spec. Cycle 2 (research) verified each against Apple's `propertiesToFetch` documentation, SwiftData `#Predicate` translation community findings (fatbobman, mjtsai, woodys-findings), and the actual call sites. Cycle 3 (critique) refuted over-broad framings, merged alias clusters, and corrected severities. Every load-bearing file:line citation was re-read against source before this report; the headline pagination defect was confirmed by a manual trace against HistoryAuthority.swift:1717, 1734, 1752–1755, 1770, 2368–2370.

## 3. Findings

### Critical (0)

None. The single-writer + OCC + in-transaction revalidation design holds; no data-corruption-without-recovery, no silent-double-commit, no unsafe-concurrency defect survived verification.

### Major (1)

| ID | Status | Location | Category | Summary | Recommendation | Spec |
|---|---|---|---|---|---|---|
| ws18-unpinned-continuation-pagination-contract-violation-cluster | **in-progress** (2026-08-11; run 31448195535 exposed a same-file access-control compile error; local repair applied, rerun pending) | HistoryAuthority.swift:2370 | Correctness | `orderUnpinnedLane`'s exactness guard indexes `rows[param_limit-1]`/`rows[param_limit]` against the **parameter** limit (= `outer_limit+1` for continuations at the call site line 1734), which does NOT align with the true post-anchor-drop page boundary (`anchorIndex+outer_limit`). Three manifestations: (a) **head contamination** — same-`lastCopiedAt` rows before the anchor consume the `limit+2` fetch budget without being the anchor, so after the anchor drop `merged.count <= limit` and `next = nil` (line 1770), orphaning all older rows from recent-browse (still searchable); (b) **bottom-tie-at-wrong-position** — a same-date group straddling the TRUE boundary is missed because the guard inspects the wrong slots, so `\.id` is silently trusted at the real boundary (violates §14.1) and the wrong row can become the next anchor; (c) **all-same-date traversal** re-fetches the whole lane every page. Verified by trace against code (limit=3, r1–r4@D1 / r5–r7@D0 continuation: page2 returns `[r4, r5]`, `next=nil`, r6/r7 unreachable). | The guard now sorts the bounded slice by the complete key, locates the real anchor, and safely re-fetches when already-consumed same-date siblings contaminate the head, the anchor is absent from a full slice, or the true post-anchor page/lookahead boundary ties. WS18 adds a seven-row same-time-head fixture and traverses every page, asserting exact order and no gap/overlap. The scalar row's validated immutable timestamp now uses the narrowest same-file access needed by the ordering extension. Pending supported-runner verification before `fixed`. | §14.1; 04 §6; 06 §8 WS18; V1V-03B-001 |

### Minor (18)

| ID | Location | Category | Summary | Recommendation | Spec |
|---|---|---|---|---|---|
| validate-final-pin-order-per-commit-cluster | HistoryAuthority.swift:773 | Efficiency | `validateFinalPinOrder` runs unconditionally inside every commit transaction (line 640), fetching all N retained rows' `pinOrdinal` (`fetchLimit=5001`), nil-filtering in memory, then O(N log N) sorting — even for capture/revision/retention/remove commits whose projected mutation set provably cannot perturb the pinned lane. | (a) Add `descriptor.predicate = #Predicate { $0.pinOrdinal != nil }` at line 774 — identical to the read-path predicate proven translatable at line 1656, transfers P rows not N (cheapest win in the review); (b) amend docs/05 §10 line 504 to gate `validateFinalPinOrder` on stamped plans containing `.create`/`.delete`-of-pinned/`.setPinOrdinal`. | §10 (line 504, D12), §7.2/§7.3 |
| search-corpus-rebuild-per-call-cluster | HistoryAuthority.swift:1857 | Efficiency / space | `searchCorpusSnapshot` fetches all N retained rows including <=256 KiB `searchBody`, rebuilds `SearchCorpusRow` per row, and O(N log N) sorts on EVERY call — recaptured on every `browse(.search)` page (SwiftDataHistory.swift:252) AND every `observe()` phase-1/phase-2 spin (SwiftDataHistory.swift:427), including the copy→capture-commit→invalidation hot path. Worst case 5000 × 256 KiB ≈ 1.28 GiB reallocated per page/commit. | Cache `SearchCorpusSnapshot` on the actor keyed by `ChangePosition`; invalidate on commits that change `title`/`searchBody`/`pinOrdinal`/`lastCopiedAt`. Separately capture a `title`+`pinOrdinal`+`lastCopiedAt`-only snapshot and let `SearchWorker` fetch `searchBody` per matched row (≈256× transient-space cut). Bound/debounce the `observe()` phase-1 spin. Spec §14.2/§9 bullet 7 explicitly defers the cache behind the G2 measured-evidence gate; PresentationUI (the per-keystroke caller) does not yet exist, so this is latent. | §14.2; 06 §3 G2, §9 |
| external-storage-blob-faulting-unverified-cluster | HistoryAuthority.swift:1618 | Verification gap | >=6 'O(N) scalar' ratings (startup index, `validateFinalPinOrder`, `fetchRetainedInventory`, `recentPage`, `searchCorpusSnapshot`, `ScalarReadRow`) assume `propertiesToFetch` suppresses faulting of the two `@Attribute(.externalStorage)` blobs. Apple's `propertiesToFetch` doc supports this (non-fetched attributes load lazily only on access) and `ScalarReadIsolationProofTests` proves no-DECODE, but no instrumented no-FAULT proof exists. (C3 overcalled this 'major'; honest severity is minor with high leverage.) | Add ONE instruments/DTrace trace on macOS 26 / pinned SDK proving `propertiesToFetch` suppresses faulting for scalar-only access on both SQLite and in-memory stores; fold the proof into `ScalarReadIsolationProofTests`. Until then, treat all 'O(N) scalar' ratings as conditional. | §13 (line 566), §18; 06 §7.5 |
| modelcontext-transaction-durability-cluster | HistoryAuthority.swift:632 | Verification gap (severity undetermined) | `context.transaction` runs synchronously inside the actor; its durability mechanism (SQLite WAL + async checkpoint = sub-ms non-blocking, vs caller-thread `fsync`/`F_FULLFSYNC` = tens of ms) is unverified. If fsync-on-caller, every commit blocks the actor AND its cooperative-pool thread, serializing all reads/observations and risking pool starvation. No custom serial executor exists. (Two open C3 findings rated this 'major'; that severity is entirely conditional on the unmeasured fsync question.) | Measure real durable p99 commit latency on a persistent 5000-row store (the runner currently cannot — extend it to on-disk fixtures with fsync timing). If fsync-on-caller, evaluate a dedicated serial executor for `HistoryAuthority` (Swift 6 custom executor) so blocking I/O no longer rides the default cooperative pool — without breaking the §5 non-suspending-interval proof. | §10 (line 510), §5; 01 §10; 06 §7.1 |
| pinned-continuation-quadratic-cluster | HistoryAuthority.swift:1670 | Complexity | `fetchLimit = (anchorOrdinal+1)+limit+1` makes a pinned continuation O(anchorOrdinal+limit), so a full P-pinned traversal aggregates O(P²/L) scalar reads (~625k for P=5000, L=20). Spec-acknowledged deviation tied to the unverified optional-Int `#Predicate` translation. **CORRECTION:** the prior critique's recommendation to use `#Predicate { ($0.pinOrdinal ?? -1) > anchorOrdinal }` and its claim of 'C1-proven translatable' is WRONG — community consensus is that nil-coalescing on optional Int does NOT translate to SwiftData's SQLite backend; the code deliberately uses only presence predicates per §18. | Real fix is either (a) an on-device SDK test proving the nil-coalescing value-comparison predicate DOES translate on macOS 26 (prior critique wrongly assumed this; community says no — neither is SDK-proven), restoring O(limit+1)/page, OR (b) a schema change: non-optional mirror column for `pinOrdinal` supporting a plain value-comparison predicate. Absent either, accept the documented deviation and correct the §9/§14.1 spec text. | §14.1, §9; 06 §7.5 |
| unpinned-exactness-guard-full-lane-refetch | HistoryAuthority.swift:2373 | Complexity | When the exactness guard fires, `orderUnpinnedLane` re-fetches the entire unpinned lane (`fetchLimit=5000`) and O(N log N) sorts in memory. Adversarially triggerable (high-frequency programmatic copies / `Date()` resolution); over an all-same-date traversal it fires every page → O((N/L)·N log N). Correctness IS preserved in the all-same-date case (the full re-fetch resolves ties); purely a performance cost. | Short-term: keep but bound the re-fetch to rows with `lastCopiedAt == boundaryDate` plus the existing slice (O(boundary-group) not O(N)), and fix the gating condition per the headline finding. Long-term: a cached corpus (search-corpus fix) dissolves it. | §14.1 |
| capture-interval-three-full-table-scans | HistoryAuthority.swift:311 | Efficiency | A capture commit runs three bounded full-table scalar scans over the same 5000-row table — `fetchRetainedIDs` (readiness), `fetchRetainedInventory` (retention summaries), `validateFinalPinOrder` (`pinOrdinal`). Separation is largely load-bearing (`fetchRetainedIDs` vs `fetchRetainedInventory` enables the §7.1 step-6 agreement check; `validateFinalPinOrder` is in-transaction), so the redundancy is the price of the proof. | Do NOT fuse `fetchRetainedIDs` and `fetchRetainedInventory` (the agreement proof is load-bearing). Reduce `validateFinalPinOrder` via the §10 gating amendment in the pin-order-cluster fix (skip for capture commits). | §7.1 steps 1/5/6, §10 |
| read-paths-decode-all-revisions | HistoryAuthority.swift:2156 | Efficiency | `details`/`pastePayload`/`thumbnailSource` call `hydrate` which decodes canonical + ALL revisions + active; thumbnail needs one representation's bytes, paste needs canonical+active. `details(for:)` additionally runs `ContentProjector.project` over every stored revision (O(R×projectionCost), R<=100) on the serial actor for a one-shot user query. | Give `RevisionStateBlobCodec` an active-only/scalar-view decode API (decode validates all revisions, but returns bytes for canonical+active only). Spec-conformant additive change; partly justified by the codec's all-revision validation. | §14.3, §14.5 |
| defensive-transaction-guards-and-cursor-codec-untested-cluster | HistoryAuthority.swift:56 | Test gap | `StorageInvariant.positionChanged` and all four `TransactionApplyRejection` cases (`missingRow`, `duplicateCreateID`, `contentVersionMismatch`, `finalPinOrderViolated`) have ZERO direct tests; the fail-closed `.persistence(.transaction)` mapping is verified only for the single WS13 `InjectedTransactionFailure.beforeSingletonUpdate` injection. Separately, `PageCursorCodec.decode`'s malformed/cross-process-input handling is reviewed for shape but NOT fuzzed — though the codec is in fact robust (do/catch→`malformedCursor`, `formatVersion`/`processMarker` guards, explicit nil-field guard-lets). | Add (a) tests constructing each `TransactionApplyRejection` + `positionChanged` via `@testable` row insertion or a corrupt fixture, verifying each maps to `.persistence(.transaction)`; a concurrency harness that forces divergence is the only way to cover these backstops. Add (b) a fuzz test over `PageCursorCodec.decode`'s malformed-input space asserting every case throws `PageCursorRejection`. | §10, §16; 04 §6; 06 WS13 |
| perf-runner-lacks-resident-set-p99-gates | HistoryAuthority.swift:325 | Meta verification gap | The §9 perf runner exercises complexity ratios against in-memory fixtures (<=1000 items, 64-byte bodies, medians) but lacks an on-disk, >=1000-item, >=64 KiB-`searchBody` fixture with resident-set and p99 measurement, so the spec's G2 (collection cache need) and G5 (startup scan cost) evidence gates cannot be answered and every deferred-behind-measured-evidence perf finding is unfalsifiable in CI today. | Extend `HistoryPerfRunner` to one on-disk, >=1000-item, >=64 KiB-`searchBody` fixture with resident-set-size, p99-latency, and durable-fsync measurement. This single infrastructure investment resolves the G2/G5 gates AND the fsync AND the no-FAULT open questions simultaneously. | 06 §3 G2/G5, §9; 05 §13 |
| clear-and-retention-n-individual-fetches | HistoryAuthority.swift:735 | Efficiency | `commitClear` and retention apply each `.delete` via `requireRow` (per-id `fetchLimit=2` SELECT) inside the transaction; clearing/retiring N rows is N individual business-ID fetches + N deletes. Spec-mandated (§10 'Delete fetches the actual row; no predicate delete over pending state'). Each fetch is an in-process call against the `@Attribute(.unique)` id index — microseconds, not network round-trips. | Optional: a batched `id IN (...)` fetch + identity-map delete could reduce call count while staying within the no-predicate-delete rule, IF the compound predicate translates (§18 unverified). Low priority — current shape is defensible. | §10, §7.3 |
| non-suspending-interval-convention-only | HistoryAuthority.swift:431 | Maintainability / isolation | The §5 'no `await` while a context/row/fact/plan is live' invariant — upholding the OCC single-writer proof — is enforced only by comment placement + the single WS12/WS20 entry seam, not by the compiler or lint. The 'silent double-commit' scenario was REFUTED (the §10 position guard detects interleaving → spurious rollback, not corruption); residual value is the SwiftData-isolation hazard (live `@Model` row across an `await`) which Swift 6 strict concurrency partially enforces via non-Sendable `ModelContext`. | Convert the §5 convention into a compiler-enforced mechanism where feasible: a synchronous (non-`async`) inner function taking the `ModelContext` as an argument so an `await` inside fails to compile, or a SwiftLint rule banning `await` within named commit-interval functions. | §5, §10 |
| per-candidate-fetch-row-loop-unbatched | FactLoaders.swift:367 | Efficiency | `IngestFactLoader.loadFacts` fetches each dedup candidate with a separate `fetchRow` (`fetchLimit=2`) in a loop rather than one batched `id IN (...)` fetch — O(K) store round-trips per capture. K is the signature-posting intersection; realistic clipboard workloads produce K=0–1 (copy coalescing collapses identical content). | Optional: one batched `id IN (...)` fetch IF the compound predicate is proven translatable on the supported runtime (§18 stance). Low priority given small realistic K. | §7.1 step 3 |
| capture-time-signature-index-rebuild | FactLoaders.swift:455 | Efficiency | When the Signature Index is unready at capture time, `rebuildSignatureIndex` fetches all 5000 rows' `canonicalSignatureBlob`, decodes, and builds the full posting map (O(N×R)) on the capture interval. `markUnready` fires only on internal-divergence assertions (never in healthy operation); the index is built at startup before the facade publishes, so the unready path amortizes to one rebuild per divergence. | No code change for v1; ensure the G5 startup-checkpoint gate (06 §3) actually delivers a ready index before the facade publishes, so the capture-time path stays divergence-only. | §7.1 step 1, §12, §13; 06 §3 G5 |
| encode-inside-transaction-misclassified | HistoryAuthority.swift:694 | Maintainability | `EffectiveTypeIdentifiersBlobCodec.encode` is invoked inside the transaction closure for `.create`/`.appendRevision`; any failure is folded into `.persistence(.transaction)` rather than the codec's own `.persistence(.invariantViolation)` §16 mapping. Academic — `encode` can only throw `.encodingFailed`, unreachable on a well-formed projection (`ContentProjector` bounds the type-identifier list first). | Encode `effectiveTypeIdentifiersBlob` at stamp time (in `CommitPlanStamper`) alongside the other blobs, moving its failure surface outside the transaction closure so it maps via the codec's own §16 vocabulary. | §10, §16 |
| thumbnail-source-full-image-copy | HistoryAuthority.swift:2186 | Efficiency | `thumbnailSource` returns the full-resolution Effective image bytes (`representation.bytes`) across the actor boundary; for large images this is a multi-MB `Data` materialization on every thumbnail request. Returned `Data` is independent of the `@Model` row (decoded from blob), so the spec §14.5 release-before-decode intent is honored. `ThumbnailService`'s single-flight table deduplicates only the off-Authority DECODE, not the source-byte materialization — so the full image is materialized on EVERY request, hit or miss. | If large-image thumbnails become hot, deduplicate source-byte materialization (extend `ThumbnailService`'s flight table to key on source bytes, or capture the source `Data` once and share). Spec-conformant today; defer unless measured. | §14.5; 04 §9 |
| scalar-property-list-triplicated | HistoryAuthority.swift:1618 | Maintainability | The 8-entry scalar projection list is enumerated three times (`recentPage.scalarProperties` 1618, `orderUnpinnedLane`'s exactness re-fetch 2384, `ScalarReadRow.init`'s field reads 2271) with no single source of truth. Adding a scalar column risks the exactness re-fetch omitting a field `ScalarReadRow.init` then reads. | Add one internal `let scalarProjectionProperties: [PartialKeyPath<HistoryItemRow>]` and a matching decoder shared by all three sites. | §14.1 |
| commit-tail-duplicated-cluster | HistoryAuthority.swift:536 | Maintainability | `commitCapture` (518–546) inlines the entire §11 post-commit tail (validate→transaction→index.apply→publish→`.committed`) verbatim instead of calling `executeStampedPlan` (565–603). **CORRECTION:** the prior 'commit spine duplicated across mutation commits' framing was over-broad — the 5 mutation commits (`commitPinnedPlacement`:1015, `commitUnpin`:1092, `commitRemove`:1173, `commitClear`:1246, `commitRetentionPolicy`:1493) DO share the tail via `executeStampedPlan`; only `commitCapture` inlines. The justifying doc comment (556–559) is STALE — the rebuild it cites runs earlier in `IngestFactLoader.loadFacts` (445–451). No functional impact today; silent drift hazard on the most safety-critical path. | After the §7.1 rebuild (445–451), planning (457), outcome switch (479), and stamp (500), end `commitCapture` with `return try executeStampedPlan(stamped, expectedPreviousPosition: currentPosition, in: context)`. Correct the stale 556–559 comment. Add one test asserting byte-identical §11 ordering on BOTH capture and mutation paths. Single dedup target (`commitCapture` only), not five-fold. | §9–§11 |

### Nit (19)

| ID | Location | Category | Summary | Recommendation | Spec |
|---|---|---|---|---|---|
| commitcapture-outcome-switch-and-noop-branch | HistoryAuthority.swift:479 | Maintainability | `commitCapture`'s switch on `mutationPlan.outcome` funnels non-inserted/coalesced through `default: throw invariantViolation` (NOT exhaustiveness-forced; the 'silent wrong receipt' divergence was refuted — `default` fails CLOSED). The `guard case .commit else { return .unchanged }` branch is dead (`planCapture` never returns `.unchanged`). Outcome is decoded twice (`commitCapture` + `CommitPlanStamper.receiptOutcome`) but the two switches serve genuinely different roles. | Comment the `default` branch as unreachable-from-capture and the `else`-branch as an exhaustiveness scaffold (only `planRetention` emits `.unchanged`). No code change. | §9; 02 §7 |
| mapcodecfailure-duplicated | HistoryAuthority.swift:2422 | Maintainability | `mapCodecFailure<T>` is defined byte-identically as a file-private func in FactLoaders.swift:32 and HistoryAuthority.swift:2422; Swift file-private scoping forces the re-declaration, so any §16 translation change must be made in two files. | Move `mapCodecFailure` to an internal (non-file-private) helper or an extension on a codec rejection type. One §16 owner. | §16 |
| orderpinnedlane-redundant-resort | HistoryAuthority.swift:2347 | Maintainability | `orderPinnedLane` re-sorts already store-sorted pinned rows by `pinOrdinal` in memory (the calling fetch predicate `pinOrdinal != nil` at 1656 guarantees non-nil, so `?? 0` is unreachable dead-default). D12 uniqueness makes the re-sort a no-op O(K log K) tax on every `recentPage`. (Only `orderPinnedLane` is a pure redundant re-sort; `orderUnpinnedLane`'s re-sort is LOAD-BEARING — it adds the id tie-break.) | Drop the re-sort (or gate behind a debug assertion) and drop the `?? 0` (`$0.pinOrdinal! < $1.pinOrdinal!` or remove). Saves O(K log K) per `recentPage` for free. | §14.1; §13 step 9 (D12) |
| range-array-alloc-contiguity-check | HistoryAuthority.swift:382 | Efficiency | Three sites allocate `Array(0..<count)` solely to compare element-wise against the just-sorted ordinals (HistoryAuthority.swift:382, :796; MutationFactLoaders.swift:95). | Replace all three with `zip(ordinals, 0...).allSatisfy { $0.0 == $0.1 }` and extract one helper. Drops 3 O(P) Int-array allocations per commit/startup. | §10, §13 |
| validate-final-pin-order-conflates-count-bound | HistoryAuthority.swift:783 | Labeling | `validateFinalPinOrder` also enforces the retained-count hard maximum (`rows.count <= hardMaximumRetainedItems`), conflating §10 pin-order revalidation with the §13 step-5 count bound; a planner bug over-stuffing the set surfaces mislabeled as `finalPinOrderViolated`→`.persistence(.transaction)` (transient-looking, retry-eligible) instead of `.persistence(.invariantViolation)` as the identical bound is mapped at startup (line 345) and in the loaders (FactLoaders.swift:204/421/469). | Move the retained-count check to a separately named guard or the planner's §7.3 responsibility with a distinct `TransactionApplyRejection` case mapping to `.invariantViolation`. | §10, §13 step 5, §16 |
| test-seams-compiled-into-production | HistoryAuthority.swift:910 | API-hygiene | `setSuspensionHandler` and `setTransactionFailureInjection` are compiled unconditionally (no `#if DEBUG`), reachable from same-module code (internal, not public). Deliberate, documented project stance (roadmap 03 step 5). Production disarms both (nil); `@testable` required cross-module. | Leave as-is (documented deliberate tradeoff); optionally add a comment quantifying risk. No `#if DEBUG` needed. | 06 §8; 05 §2, §5 |
| register-subscriber-unstructured-task | HistoryAuthority.swift:883 | Maintainability | `registerInvalidationSubscriber`'s `onTermination` spawns an unstructured, untracked `Task { await self.unregister... }` per stream termination; captures `[weak self]`, and `unregister` is idempotent. `finishAll` (the teardown path the finding imagined) has zero callers — so the Task fires only on per-observation cancellation where yield-on-terminated-stream is a no-op. | Add a comment documenting the weak-hop rationale (breaks publisher→closure→actor retain cycle), or model unregistration as a cancellation-aware structured task. | §14.4 |
| loadedContentVersion-linear-scan-for-winner-version | HistoryAuthority.swift:861 | Efficiency | `loadedContentVersion` resolves the coalesced winner's Content Version via `facts.candidates.items.first { $0.id == itemID }` — an O(K) linear scan. `CompleteDedupCandidates.items` is an `Array` with no dictionary materialization. K is bounded by the signature-match candidate intersection (typically 0–1); the common coalesce case returns O(1) via the `hintedItem?.id` check at line 858. | Genuinely O(K) but not hot. A dictionary would help only marginally given realistic K=0–1. Optionally expose candidates by id if a future workload widens K. | §7.1 |
| spec-section-9-does-not-note-pinned-continuation-exception | docs/05-authority-kernel.md:580 | Doc | The §14.1 spec line `fetch at most limit + 1 to determine continuation` is stated unconditionally; the pinned-continuation exception (`anchorOrdinal+limit+2`, acknowledged in PROGRESS.md:323–332 and the code comment at HistoryAuthority.swift:1665–1669) is not reflected in the §14.1/§9 spec text itself, so the authoritative spec overstates the bound for that lane. | Inline-note the pinned-continuation exception in §14.1 (and §9 if it restates the bound) so the authoritative spec is self-consistent. | §14.1, §9; PROGRESS.md:323–332 |
| commitcapture-inline-justification-inaccurate | HistoryAuthority.swift:556 | Maintainability | The doc comment justifying `commitCapture`'s inlined post-commit tail ('it additionally owns the unready-index rebuild of §7.1 step 1') is inaccurate — that rebuild happens earlier in `IngestFactLoader.loadFacts`, not in the inlined tail. | Correct the comment AND collapse the inline tail into an `executeStampedPlan` call (see commit-tail-duplicated-cluster). | §7.1 step 1, §9–§11 |
| recentpage-read-assumes-pin-ordinal-contiguity | HistoryAuthority.swift:1670 | Maintainability | `recentPage`'s pinned-continuation fetch math assumes pin ordinals are contiguous `0..<P` (D12), an invariant enforced only at commit time; the read path never re-validates. Defensible — the store is only ever written through this Authority. | Leave with a clearer comment that D12 is a commit-time invariant relied on at read time, OR apply the pinned-continuation predicate/schema fix which makes the read path robust to non-contiguity for free. | §14.1, §10 (D12) |
| readposition-second-context | HistoryAuthority.swift:2198 | Efficiency | On the cursor-decode-failure path, `recentPage`/`searchCorpusSnapshot` allocate a second operation-local `ModelContext` just to read the singleton position for the error's `current:` argument (main context not yet created). | Reorder so cursor decode happens after the main read context exists, then reuse its position read on failure. Error-path only. | §16 |
| stamp-existing-revisions-array-copy | StampedPlan.swift:316 | Efficiency | Each `.appendRevision` materializes `existingRevisions + [revision]` (fresh O(R) array copy) solely to feed the encoder, on every revision commit. Bounded by R<=100. | Give `RevisionStateBlobCodec.encode` an append-only or (existing, new) signature to avoid materializing existing+[revision]. Bounded by R<=100, low priority. | §9 |
| revision-prep-actor-serializes-stateless-work | ActorStubs.swift:122 | Maintainability | `RevisionPreparationActor` holds only immutable `HistoryLimits` yet is an actor, so concurrent `prepare(_:)` calls serialize needlessly; Sendability does not require an actor here, but §6.2 names the type as an actor. | Spec amendment: convert `RevisionPreparationActor` to a `Sendable` struct (`HistoryLimits` is `Sendable`) and expose `prepare` as a free function/static method, allowing parallel preparation. | §6.2 |
| thumbnail-image-set-hardcoded-subset | HistoryAuthority.swift:2081 | Scope | `thumbnailImageTypeIdentifiers` freezes 7 UTIs, excluding other ImageIO-decodable types (webp, icns, ico) and abstract `public.image`. Valid interpretation of an underspecified §9 (NOT a deviation) — category misapplied in the original finding. | Re-categorize as edge-case/scope. Optionally document the omission as deliberate v1 scope; consider adding `public.webp`/`icns` in a v1.x point release. | §14.5; 04 §9 |
| dead-step-deferred-error | SwiftDataHistory.swift:31 | Dead code | `StepDeferredError` is defined but never thrown; comments and PROGRESS.md still claim the step-8 thumbnail path raises it. Dead enum + stale docs across 5+ files. | Delete the enum and stale comment references (SwiftDataHistory.swift:9,23,53; ActorStubs.swift:17–21; HistoryAuthority.swift:2069; PROGRESS.md:356–365; WS6/WS8/WS14/WS16/WS21 test headers). | — |
| finishall-dead-code-cluster | HistoryInvalidation.swift:161 | Dead code | `finishAll()` (and `subscriptionCount`) have ZERO callers in Sources/ or Tests/; the doc claims Authority-teardown use but no `deinit`/`close` path exists. Observer streams finish only via per-subscriber unsubscribe or process teardown. | Either wire an Authority teardown path (`SwiftDataHistory.close()` that calls `finishAll`) or delete `finishAll` and `subscriptionCount` and correct their doc comments. | §14.4 |
| invalidation-publish-runs-in-post-commit-interval | HistoryInvalidation.swift:142 | Maintainability | `HistoryInvalidationPublisher.publish` iterates all registered continuations synchronously inside the §11 post-commit interval. `AsyncThrowingStream.Continuation.yield` is documented to 'return immediately without blocking', so the §11 non-suspending invariant holds; benign. | No change — yield is documented non-blocking. Optionally note the subscriber-count bound in a comment. | §11 |
| revert-revision-linear-scan | ActorStubs.swift:240 | Efficiency | revert-to-revision finds its target via O(R) linear scan; R<=100 (sub-microsecond), negligible. | No change — pre-indexing an immutable <=100-element list adds indirection for no gain. | §6.2 |

> **Remediation status (2026-08-09):**
> `pinned-continuation-quadratic-cluster` is **in-progress**. The read now uses
> the documented sorted-result `fetchOffset` at the anchor ordinal, fetches
> only anchor + page + lookahead, validates the complete anchor, and drops it.
> This is O(`limit`) per continuation without the unsupported optional-Int
> predicate. A malformed-anchor facade regression is present; macOS CI is
> pending. `spec-section-9-does-not-note-pinned-continuation-exception` is
> **documented** by the corrected Part V §14.1 / Part VI §9 `limit+2`
> continuation envelope. `dead-step-deferred-error` is **in-progress**: the
> zero-use type and contradictory source/test/progress comments are removed,
> and the production file has been renamed to
> `RevisionPreparationAndSearchCorpus.swift`; macOS build proof remains.
> `finishall-dead-code-cluster` is likewise **in-progress**: both unused
> publisher members are deleted rather than inventing a teardown contract;
> macOS build/observation proof remains.
> `register-subscriber-unstructured-task` is **documented**: the source now
> records why a synchronous termination callback needs the weak one-operation
> actor hop and why it has no joinable result. `invalidation-publish-runs-in-post-commit-interval`
> is **not-a-defect**: the synchronous newest-value yields are the specified
> non-suspending post-commit step and never apply state deltas.
>
> The V1V kernel-cleanup batch moves ten additional findings to
> **in-progress**: `validate-final-pin-order-per-commit-cluster`,
> `encode-inside-transaction-misclassified`,
> `scalar-property-list-triplicated`, `commit-tail-duplicated-cluster`,
> `commitcapture-outcome-switch-and-noop-branch`,
> `mapcodecfailure-duplicated`, `orderpinnedlane-redundant-resort`,
> `range-array-alloc-contiguity-check`,
> `commitcapture-inline-justification-inaccurate`, and
> `stamp-existing-revisions-array-copy`. The current tree gates the pinned
> check, pre-encodes stored projection bytes, owns one scalar-field list and
> one commit tail, removes impossible/default work, and avoids the extra
> revision lineage copy. All changes remain pending macOS build/WS proof.
>
> `defensive-transaction-guards-and-cursor-codec-untested-cluster` is
> **in-progress** toward `fixed`. Owner: HistoryStorage transaction/cursor
> tests + macOS CI. Verification trigger: `TransactionGuardInjectionTests`,
> `TransactionBoundaryProofTests`, WS13, and `PageCursorCodecTests` all pass on
> macOS 26 / Swift 6.2. The one-shot transaction seam now has a case consumed
> at each real defensive guard: singleton mismatch, non-create missing row,
> duplicate create ID, append-revision Content Version mismatch, and final D12
> pin-order rejection. Every test enters through a normal Authority commit,
> observes `.persistence(.transaction)`, and proves rows plus Change Position
> rolled back. Cursor tests separately cover round trips, malformed/truncated/
> over-envelope inputs, version/process-marker/known-field rejections, unknown
> wire kinds, and encode failure. Residual risk until the trigger is
> supported-platform compilation/runtime only. These transaction conditions
> cannot safely be manufactured by external durable corruption: the
> non-suspending single-writer interval forbids mid-commit row/position drift,
> and pre-transaction fact validation rejects malformed persisted pin state.
> The seam therefore changes only the matching guard's operation-local
> observation and throws the concrete production rejection; it does not expose
> the private executor or persist invalid fixtures.
>
> `capture-interval-three-full-table-scans` is a **duplicate** of canonical
> `capture-fact-load-fetches-same-table-2-3-times`. The target is in-progress,
> owned by HistoryStorage fact loading + macOS CI; its verification trigger is
> the capture suites and stale-ready-index regression on macOS 26 / Swift 6.2.
> The current healthy capture path performs one complete scalar inventory scan,
> derives retained-ID coverage from it, reuses its summaries, and skips the
> final-pin validator because capture cannot affect existing pin order. A
> stale/unready index adds the necessary signature-metadata rebuild scan.
> Residual risk until verification: the supported SwiftData compile/runtime
> behavior of the merged fetch has only portable source-gate/static evidence.
>
> The remaining kernel findings have explicit terminal dispositions
> (2026-08-11):
>
> - `external-storage-blob-faulting-unverified-cluster` is a **duplicate** of
>   canonical `scalar-reads-rely-on-unverified-externalstorage-faulting-suppression`,
>   which is deferred to R8. Owner: supported-platform persistence/performance
>   evidence. Trigger: trace
>   the persistent 5,000-row startup/recent/search/inventory/pin paths on macOS
>   26 before accepting any scalar-path resident-memory claim. Residual risk:
>   SwiftData may fault non-requested `.externalStorage` attributes even though
>   these paths never access or decode them, turning apparent O(N scalar) work
>   into O(N × blob bytes). This is the kernel-report alias of
>   `scalar-reads-rely-on-unverified-externalstorage-faulting-suppression` in
>   V1V-03C.
> - `modelcontext-transaction-durability-cluster` is **deferred**. Owner:
>   R8/macOS persistence-performance evidence. Trigger: a macOS 26 arm64
>   persistent-store run measures commit p99 and Authority queue wait and
>   determines whether `ModelContext.transaction` performs blocking durability
>   work on the caller; a queue-wait p95 above the G2 20 ms threshold opens the
>   executor review. Residual risk: the already atomic/visible synchronous
>   transaction may still block the cooperative executor; crash-level fsync
>   timing is not claimed by the current in-memory complexity runner.
> - `read-paths-decode-all-revisions` is **deferred** to G8. Owner: the
>   HistoryStorage read-path/schema graft. Trigger: representative details,
>   paste, or thumbnail hydration exceeds its memory budget or copy p95 under
>   the G8 peak-RSS/aggregate-DTO measurement. Residual risk: one bounded item
>   still decodes and validates up to 100 revisions / 256 MiB on the Authority.
>   A nominal active-only JSON API would not remove that cost while preserving
>   the exhaustive fail-closed validation rule; a measured schema/streaming
>   design is required.
> - `clear-and-retention-n-individual-fetches` is **documented** as the v1
>   implementation. Owner: HistoryStorage transaction execution / WL4. Trigger:
>   revisit only after the supported SDK proves a batched `ids.contains`
>   predicate translates and a representative clear/retention workload shows a
>   material constant-factor cost. Residual risk: each delete still fetches its
>   actual `@Attribute(.unique)` row as §10 requires, so a full clear performs N
>   bounded in-process lookups plus N deletes; the result remains O(retained
>   count), and WL4 owns the quadratic-sensitive scaling gate.
> - `non-suspending-interval-convention-only` is **deferred**. Owner:
>   architecture/source gates. Trigger: the next change to any Authority
>   commit/read interval must either extract its post-entry body into a
>   synchronous seam or land a reliable SwiftSyntax rule before adding an
>   `await`. Residual risk: today's tree has every suspension before context
>   creation, but an outer async method does not compiler-forbid a future live
>   `ModelContext` crossing a suspension; the OCC guard limits durable damage,
>   not SwiftData live-model misuse.
> - `capture-time-signature-index-rebuild` is **deferred** to G5. Owner:
>   SignatureIndex/startup performance. Trigger: a forced-unready 5,000-row
>   metadata rebuild exceeds G5's 250 ms p95 on the minimum supported hardware.
>   Residual risk: after the post-commit defensive index assertion marks the
>   value unready, one capture can pay O(retained signature metadata) while
>   isolated. Healthy startup publishes only after constructing a ready index,
>   so ordinary capture does not take this path.
> - `thumbnail-source-full-image-copy` is **deferred** to G8. Owner: thumbnail
>   source/materialization. Trigger: representative concurrent thumbnail reads
>   exceed the G8 transient-RSS budget or source-copy p95. Residual risk: each
>   request may materialize the full Effective image `Data` before the existing
>   decode-only single-flight joins callers.
> - `validate-final-pin-order-conflates-count-bound` is **not-a-defect** in the
>   current tree. Owner: none while the frozen §10/§16 contract stands. Trigger:
>   reconsider only if transaction failures gain action-specific public
>   vocabulary or the validator again runs for plans that cannot affect the
>   pinned lane. Residual risk: a pin-affecting plan still performs the bounded
>   O(P log P) D12 proof. The current validator fetches only
>   `pinOrdinal != nil` rows; its count guard is a defensive read, and every
>   transaction-closure failure intentionally maps uniformly to
>   `.persistence(.transaction)`.
> - `loadedContentVersion-linear-scan-for-winner-version` is
>   **not-a-defect**. Owner: none for the current bounded candidate facts.
>   Trigger: reconsider if another consumer already requires a candidate map or
>   measured K materially widens. Residual risk: the fallback remains O(K),
>   hard-bounded by retained count. Capture performs one lookup with the
>   lineage-hint O(1) fast path first; constructing a dictionary for that one
>   lookup is also O(K) and adds storage.
> - `readposition-second-context` is **not-a-defect**. Owner: none for the
>   current synchronous cursor-failure path. Trigger: reconsider if the helper
>   gains an `await`, retains a context, or control can continue into main
>   context construction. Residual risk: one short-lived context is created on
>   a rejected cursor. Today it is the request's only context, reads the current
>   position, and throws; actor isolation removes the alleged race window.
> - `unpinned-exactness-guard-full-lane-refetch` is **deferred** to G2. Owner:
>   HistoryStorage pagination. Trigger: a supported 5,000-row tie-heavy
>   traversal breaches the browse-page p95 budget or a journal/cache graft
>   opens. Residual risk: an exactness-ambiguous page falls back to fetching
>   and sorting the hard-bounded unpinned lane, so an all-same-timestamp full
>   traversal can approach O((N/L) × N log N). This is a correctness fallback,
>   not the normal `limit + 1/2` path; WS18 already pins complete ordered
>   coverage without overlap.

## 4. Complexity analysis

Per non-trivial function — current Big-O (time, space) and the reduction opportunity. N = retained items (≤5000), P = pinned count (P<<N, manual), R = revisions per item (≤100), K = dedup candidate intersection (typically 0–1), L = page limit.

| Function (location) | Current time | Current space | Reduction opportunity |
|---|---|---|---|
| `recentPage` unpinned continuation (HistoryAuthority.swift:1700–1784) | Fetch O(limit+2); **wrong-or-O(N)** when guard fires; orphan bug under head contamination | O(limit+2) rows | Rewrite guard to detect head contamination (head-contiguous same-`anchorDate` count ≥2) AND align bottom-tie check to true boundary `anchorIndex+outer_limit`; bounded re-fetch = O(boundary-group). Fixes orphan bug + drops all-same-date traversal from O((N/L)·N log N) to O((N/L)·group-size). |
| `orderUnpinnedLane` full re-fetch (HistoryAuthority.swift:2373–2402) | O(N) SQL + O(N log N) CPU per guard-trip | O(N) rows | Bound `fetchLimit` to rows with `lastCopiedAt == boundaryDate` + existing slice (O(group)). |
| `recentPage` pinned continuation (HistoryAuthority.swift:1670, 1700–1717) | O(anchorOrdinal+limit) per page; O(P²/L) per full traversal (~625k for P=5000,L=20) | O(anchorOrdinal+limit) rows | IF `#Predicate { ($0.pinOrdinal ?? -1) > anchorOrdinal }` translates (UNVERIFIED — prior 'C1-proven' claim retracted), O(limit+1)/page. Else schema change: non-optional `pinOrdinal` mirror column. |
| `validateFinalPinOrder` (HistoryAuthority.swift:748–778) | O(P log P), only for plans that may affect the pinned lane | O(P) ordinals | Remediated: the verified presence predicate transfers pinned rows only, and stamped-plan inspection skips capture, occurrence, revision, retention-only deletion, and policy mutations. |
| `searchCorpusSnapshot` (HistoryAuthority.swift:1857) | O(N log N) per call; recaptured per page + per observe() spin | O(N×≤256 KiB) ≈ 1.28 GiB worst case | Cache keyed by `ChangePosition`; invalidate on corpus-field commits → O(1) hit. Split `searchBody` out → ~256× transient-space cut. |
| `commitClear` / retention apply (HistoryAuthority.swift:735–739) | N × `fetchLimit=2` SELECT + N deletes | O(1) | Batched `id IN (...)` fetch IF compound predicate translates (§18). Modest — in-process index lookups. |
| Capture interval scans (`FactLoaders.swift`) | One O(N) scalar inventory scan on the healthy path; a stale/unready index adds one O(N×signatures) metadata rebuild | O(N) summaries/IDs; cold postings | Remediated: retained-ID coverage is derived from the duplicate-checked inventory, and capture plans no longer run the pin-order validator. The cold signature fetch remains separate so healthy capture never requests signature blobs for all rows. |
| `orderPinnedLane` (HistoryAuthority.swift:2347) | O(K log K) redundant re-sort per `recentPage` | O(K) | Drop re-sort (store already sorted; D12 makes it no-op) + drop dead `?? 0`. Free. |
| `details`/`hydrate` (HistoryAuthority.swift:2156) | O(R) decode-all-revisions + O(R×projectionCost) `ContentProjector.project` | O(R) | Active-only/scalar-view codec API → O(active) bytes returned, all-revision validation preserved. |
| `rebuildSignatureIndex` (FactLoaders.swift:455) | O(N×R) on capture interval (divergence-only) | O(N×R) posting map | No v1 code change; ensure G5 startup gate delivers ready index pre-publish. |
| `loadedContentVersion` (HistoryAuthority.swift:861) | O(K) linear scan (K≈0–1) | O(1) | Not hot; optional dictionary if K widens. |
| `revert`-to-revision (ActorStubs.swift:240) | O(R) linear scan, R≤100 | O(1) | Negligible; no change. |

## 5. Efficiency notes

- **The §9 ≤limit+1 bound is the spec's most-violated invariant.** Pinned continuations (documented O(anchorOrdinal+limit)), unpinned continuations (the headline orphan bug + O(N) full-lane rescue), and the search corpus (no cache, O(N log N) per page) all violate it; the spec states the bound unconditionally. Either the spec needs an explicit 'exceptions' subsection or the code needs to meet the claim (see nit `spec-section-9-does-not-note-pinned-continuation-exception`).
- **Every commit is O(N) even for a single-row capture.** `validateFinalPinOrder` (line 773) fetches all N retained rows' `pinOrdinal`; `fetchRetainedIDs` and `fetchRetainedInventory` add two more bounded full-table scans (line 311). This is the §18 verify-against-the-SDK stance taken to its limit — because optional-Int and value-comparison predicates are unproven on SwiftData, the code refuses to push any invariant check into the store. Correct but expensive.
- **Cheapest win in the review:** add `#Predicate { $0.pinOrdinal != nil }` at line 774. Identical to the read-path predicate proven translatable at line 1656; transfers P rows not N.
- **Highest transient-space risk:** `searchCorpusSnapshot` reallocating up to ~1.28 GiB per browse page / observe spin. Latent today (PresentationUI per-keystroke caller does not yet exist) but deferred behind the G2 measured-evidence gate.
- **Free micro-wins:** drop `orderPinnedLane`'s redundant re-sort + dead `?? 0`; replace three `Array(0..<count)` contiguity checks (HistoryAuthority.swift:382, :796; MutationFactLoaders.swift:95) with `zip(ordinals, 0...).allSatisfy { $0.0 == $0.1 }`.
- **'Deferred behind measured evidence' has become unfalsifiable.** G2/G5, the fsync question, and the no-FAULT question are all parked behind measurements the perf runner cannot make. See Open Questions.

## 6. Security & edge-case notes

- **Fail-closed transaction mapping is correct but under-tested.** Every `TransactionApplyRejection` case and `StorageInvariant.positionChanged` map to `.persistence(.transaction)`; verified only for the single WS13 `beforeSingletonUpdate` injection. No data-corruption path was found — `default: throw invariantViolation` fails closed, the §10 position guard converts interleaving to spurious rollback (not corruption), and the cursor codec refuses malformed input via `PageCursorRejection` (do/catch, `formatVersion`/`processMarker`/nil-field guards) rather than synthesizing an anchor.
- **Cursor codec robustness is unverified by fuzzing.** Reviewed for shape (correct), but a fuzz/property test over `PageCursorCodec.decode`'s malformed-input space (truncated `Data`, foreign `processMarker`, nil anchor id/score/`lastCopiedAt`, wrong `formatVersion`) would lock the contract.
- **`thumbnailImageTypeIdentifiers` freezes 7 UTIs**, excluding webp/icns/ico and abstract `public.image`. Valid interpretation of an underspecified §9, not a security gap.
- **Test seams (`setSuspensionHandler`, `setTransactionFailureInjection`) compile into production** unconditionally — deliberate, documented stance; production disarms both, `@testable` required cross-module. Practical internal-DoS risk is low (a same-module malicious caller already has more destructive capabilities).
- **No `\.id` is ever trusted to sort at the store level** (§14.1) — except the headline bug, where the wrong guard slot silently trusts `\.id` at the true boundary. That is the one place the §14.1 contract is violated today.

## 7. Concurrency / isolation notes

- **One actor serializes writes (commit + fsync), reads (`recentPage`/`search`/`details`/`paste`), and observation registration.** No read/write separation. Deliberate single-writer simplicity (makes the OCC proof tractable), but couples three different SLAs to one executor. If `context.transaction` fsyncs on the caller thread, every read and every observation queues behind the single writer. The Swift 6 custom-serial-executor escape hatch would let commit I/O ride a dedicated executor without breaking the §5 non-suspending-interval proof (§5 mandates synchronous-in-interval, not specifically the default cooperative executor) — but no such executor exists today.
- **The §5 'no `await` while a context/row/fact/plan is live' invariant is convention-only** (comment placement + the single WS12/WS20 entry seam). Swift 6 strict concurrency partially enforces the SwiftData-isolation hazard via non-Sendable `ModelContext`; recommend a compiler-enforced mechanism (synchronous inner function taking `ModelContext` as argument, or a SwiftLint rule).
- **`HistoryInvalidationPublisher.publish` runs synchronously inside the §11 post-commit interval** but `AsyncThrowingStream.Continuation.yield` is documented non-blocking, so the non-suspending invariant holds (benign).
- **`registerInvalidationSubscriber`'s `onTermination` spawns an unstructured `Task`** to unregister; captures `[weak self]`, `unregister` is idempotent, and the imagined teardown path (`finishAll`) has zero callers — risk lower than first framed.
- **`RevisionPreparationActor` serializes stateless work** — it holds only immutable `HistoryLimits` yet is an actor; a `Sendable` struct would allow parallel preparation (§6.2 spec amendment).

## 8. Test-coverage gaps

- **WS18 pagination uses artificially distinct data.** `WS18PaginationCursorTests.captureItems` uses `base + Double(index)*1_000` (1000-second spacing), so every row has a unique `lastCopiedAt` and neither the boundary-tie guard nor the head-contamination path is ever exercised. This is the root test-strategy defect behind the headline bug's shipment. Fix: adversarial same-timestamp copy-burst fixtures (folded into the headline recommendation).
- **Defensive transaction guards get exactly ONE injection test** (`beforeSingletonUpdate`). The four `TransactionApplyRejection` cases and `StorageInvariant.positionChanged` have ZERO direct tests; only a concurrency harness that forces divergence can cover these backstops.
- **`PageCursorCodec.decode` is reviewed for shape but not fuzzed.** Robust by construction, but a fuzz test would lock the malformed-input contract.
- **`commitCapture`'s inlined §11 tail has no byte-identical-ordering test against `executeStampedPlan`.** Silent drift hazard on the most safety-critical path.
- **The perf runner cannot answer G2/G5.** No on-disk ≥1000-item, ≥64 KiB-`searchBody` fixture; no RSS, p99, or durable-fsync measurement. Every deferred-behind-measured-evidence perf finding is unfalsifiable in CI today.

## 9. Notable REFUTED (provenance)

- **'Silent double-commit from interleaved `await`'** — REFUTED. The §10 singleton position guard (`meta.rawValue == expectedPreviousPosition.rawValue` at line 634) detects any interleaved commit and forces a spurious rollback to `.persistence(.transaction)`, not corruption. The §5 convention's residual value is the SwiftData-isolation hazard, not correctness.
- **`commitCapture` 'wrong receipt' from non-exhaustive switch** — REFUTED. The `default` branch throws `invariantViolation` (fails closed); `planCapture` emits only `.inserted`/`.coalesced`.
- **'Commit spine duplicated across all mutation commits'** — over-broad. The 5 mutation commits DO share the tail via `executeStampedPlan`; only `commitCapture` inlines. Dedup target is singular.
- **properties-to-fetch-blob-faulting-unproven as 'major'** — over-called. Apple's documented `propertiesToFetch` contract ('return values for only the specified key paths … accessing a nonfetched attribute incurs the additional overhead of fetching … from the persistent store') plus `ScalarReadIsolationProofTests`' no-DECODE proof strongly support no-FAULT; honest severity is minor with high leverage (residual gap is an instruments nicety).
- **'`finishAll` Task leak / unbounded unstructured-Task growth'** — over-framed. `finishAll` has zero callers; the unstructured Task fires only on per-observation cancellation where yield-on-terminated-stream is a no-op.
- **`thumbnailImageTypeIdentifiers` as a deviation** — mis-categorized. Valid interpretation of an underspecified §9; re-categorized as scope/edge-case.
- **PRIOR pinned-continuation nil-coalescing fix as 'C1-proven translatable'** — RETRACTED. Community consensus (fatbobman, mjtsai, woodys-findings) is that nil-coalescing on optional Int does NOT translate to SwiftData's SQLite backend; the honest state is UNVERIFIED-and-likely-non-translatable. Neither the prior 'yes' nor the community 'no' is SDK-proven.

## 10. Open questions / residual risk

1. **(Highest leverage) On macOS 26 / pinned SDK, with the configured persistent SQLite store URL, does `ModelContext.transaction` achieve durability via SQLite WAL + async checkpoint (sub-ms, non-blocking) or via synchronous `fsync`/`F_FULLFSYNC` on the calling thread?** Measure commit wall-clock p99 on a persistent 5000-row store and confirm whether the actor's cooperative-pool thread is blocked. This single answer confirms or dissolves the entire actor-blocking severity cluster.
2. **(Highest leverage) For BOTH SQLite-backed and in-memory `ModelContainer`, does `FetchDescriptor.propertiesToFetch` set to scalar keypaths prevent `@Attribute(.externalStorage)` `canonicalBlob`/`revisionStateBlob` from being FAULTED into resident memory when only scalar attributes are subsequently accessed?** Confirm with an instruments/allocation trace, not just decode-absence. If it faults, several minor O(N)-scalar ratings become major.
3. **Does `#Predicate { ($0.pinOrdinal ?? -1) > anchorOrdinal }` translate to SwiftData's SQLite store on the supported runtime?** If yes, both the pinned-continuation O(P²/L) and `validateFinalPinOrder`'s P-vs-N fetch get cheap fixes; if no, the documented deviations stand and a schema change (non-optional mirror column) is the only path. Capture the SQLite query plan.
4. **Is the unified exactness-guard rewrite (head-contamination detection via head-contiguous-same-`anchorDate` count ≥2 AND bottom-tie check aligned to `anchorIndex+outer_limit`) sufficient to restore the WS18 no-overlap/no-gap contract across ALL same-date distributions?** Prove with the adversarial fixture in the headline recommendation.

## 11. Prioritized recommendations (highest-ROI first)

1. **Fix the unpinned-continuation pagination orphan bug** (HistoryAuthority.swift:2370). Rewrite `needsFullFetch` to account for anchor position (head-contiguous same-`anchorDate` count ≥2 when `unpinnedAnchorActive`), align the bottom-tie check to `anchorIndex+outer_limit`, and add the adversarial WS18 fixture (limit=50, ≥53 eligible rows, anchor sharing `lastCopiedAt` with k=1 AND k=2 earlier-id siblings, boundary inside/outside the date group, multi-page no-overlap/no-gap assertion). This is the only confirmed correctness defect and ships undetected today.
2. **Add `#Predicate { $0.pinOrdinal != nil }` to `validateFinalPinOrder`** (HistoryAuthority.swift:774) and gate the call on pin-affecting stamped plans (§10 amendment). Cheapest win in the review; drops O(N=5000)-every-commit to O(P<<N)-pin-commits-only.
3. **Extend `HistoryPerfRunner` to one on-disk, ≥1000-item, ≥64 KiB-`searchBody` fixture with RSS + p99 + durable-fsync measurement.** Single infrastructure investment that resolves open questions 1–2 simultaneously and unblocks the G2/G5 gates.
4. **Cache `SearchCorpusSnapshot` on the actor keyed by `ChangePosition`**, invalidate on corpus-field commits; split `searchBody` out of the ranking snapshot (~256× transient-space cut). Latent today but the highest deferred-leverage change.
5. **Collapse `commitCapture`'s inlined §11 tail into `executeStampedPlan(...)`** (HistoryAuthority.swift:518–546), correct the stale 556–559 comment, and add a byte-identical-ordering test against the mutation path. Eliminates drift on the most safety-critical path.
6. **Bound the `orderUnpinnedLane` full re-fetch to `lastCopiedAt == boundaryDate` + slice** (HistoryAuthority.swift:2394) — O(group) not O(N); pairs with recommendation 1.
7. **Free micro-wins:** drop `orderPinnedLane`'s redundant re-sort + dead `?? 0` (line 2347); replace the three `Array(0..<count)` contiguity checks with `zip(ordinals, 0...).allSatisfy { … }`; deduplicate `mapCodecFailure` into one internal helper; consolidate the triplicated scalar-projection list into one shared constant.
8. **Add fuzz + concurrency-harness tests** for `PageCursorCodec.decode` malformed input and the four `TransactionApplyRejection` + `positionChanged` backstop paths.
9. **Address the §5 convention with a compiler-enforced mechanism** (synchronous inner function taking `ModelContext`, or SwiftLint rule) and evaluate a Swift 6 custom serial executor if recommendation 3's measurement shows fsync-on-caller.
10. **Delete dead code:** `StepDeferredError` (SwiftDataHistory.swift:31 + stale refs) and `finishAll`/`subscriptionCount` (HistoryInvalidation.swift:161), correcting their docs.
11. **Correct the spec:** inline-note the pinned-continuation exception in §14.1/§9; re-categorize `thumbnailImageTypeIdentifiers` as scope; relabel `validateFinalPinOrder`'s conflated count bound to `.invariantViolation`.
