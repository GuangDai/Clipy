# Clipy V1 — Canonical Finding Dispositions

> **Baseline:** seven module reports audited at `8f316c9`.
> **Inventory date:** 2026-08-09.
> **Purpose:** this is the mechanically complete status ledger for all 222
> canonical finding IDs in `01-historycore.md` through
> `04-perf-deps-stubs.md`. The module reports retain the detailed analysis;
> this file is authoritative for inventory completeness, canonical duplicate
> relationships, deferred ownership/triggers, and current remediation status.

Statuses have exactly the meanings defined in `06-remediation-plan.md`.
In particular, code or tests present in this Linux worktree remain
`in-progress` until the relevant macOS 26 / Swift 6.2 proof is green and the
source report records it. The sole current `fixed` item is a comment-only
correction proved by the portable gates; behavior changes remain
`in-progress` until supported-runner evidence lands.

## Inventory checksum

| Report | Critical | Major | Minor | Nit | Total |
|---|---:|---:|---:|---:|---:|
| `01-historycore.md` | 0 | 0 | 9 | 11 | 20 |
| `02-historydomain.md` | 0 | 2 | 19 | 12 | 33 |
| `03a-codecs.md` | 0 | 2 | 15 | 12 | 29 |
| `03b-authority-kernel.md` | 0 | 1 | 18 | 19 | 38 |
| `03c-search-reads-observation.md` | 1 | 8 | 21 | 7 | 37 |
| `03d-index-ingest-thumbnail-facade.md` | 1 | 0 | 11 | 18 | 30 |
| `04-perf-deps-stubs.md` | 1 | 1 | 19 | 14 | 35 |
| **Total** | **3** | **14** | **112** | **93** | **222** |

Current dispositions: 109 `in-progress`, 32 `deferred`, 31 `duplicate`,
30 `not-a-defect`, 19 `documented`, 1 `fixed`, and 0 `pending`.

## `01-historycore.md` — HistoryCore (20)

### Minor (9)

| Canonical finding ID | Status | Evidence / canonical relationship / next action |
|---|---|---|
| `g8-trigger-does-not-cover-read-path-rss` | `documented` | Part VI G8 now names representative capture **or read** RSS/copy evidence, including transient hydration and aggregate concurrent DTO residency. |
| `details-materializes-all-revisions-for-title` | `duplicate` | Canonical target: `read-paths-decode-all-revisions`. That item owns incremental/summary-only revision hydration. |
| `details-revision-searchbody-discarded` | `duplicate` | Canonical target: `projection-joins-full-body-before-truncation`. Its title-only path removes this discarded work; macOS proof remains on the target. |
| `concurrent-rss-unbounded` | `duplicate` | Canonical target: `history-details-eager-full-lineage`. The same G8-gated eager inline-value design owns aggregate caller-retention risk. |
| `history-details-eager-full-lineage` | `deferred` | Owner: HistoryCore/architecture. Trigger: G8 opens when a representative read-path RSS or copy-cost workload breaches budget. Residual risk is multiplicative resident memory across retained DTOs. |
| `historylimits-public-init-exceeds-spec-surface` | `in-progress` | Initializer is now `package`; public symbol regeneration and macOS symbol-snapshot/CI proof remain. |
| `limits-failable-init-rejection-paths-untested` | `in-progress` | Parameterized rejection coverage is present, including consistency/equality boundaries; macOS Swift test proof remains. |
| `limits-pageRow-thumbnail-range-silent-malformed` | `in-progress` | Explicit lower/upper ordering guards and malformed-range cases are present; macOS proof remains. |
| `limits-doccomment-custom-construction-drift` | `documented` | HistoryCore/Part VI now distinguish `.standard` production use from package-owned fully validated custom codec/storage test profiles. |

### Nit (11)

| Canonical finding ID | Status | Evidence / canonical relationship / next action |
|---|---|---|
| `identity-comparable-untested` | `in-progress` | Known raw-UUID ordering, equality, and trichotomy tests for both ID types are local; macOS Swift proof remains. |
| `id-comparator-byte-wise-uuid` | `deferred` | Owner: HistoryCore. Trigger: a tie-heavy profile attributes material time to the byte comparator. Residual risk: default-order tie-heavy sorts retain a small constant-factor byte-comparison cost; behavior is correct. |
| `hashable-on-byte-payload-dtos` | `deferred` | Owner: HistoryCore API. Trigger: a v2 surface revision or first measured whole-payload hashing/key use. Residual risk is accidental O(bytes) hashing. |
| `observe-stream-untyped-error` | `documented` | Part III-A now states the intentionally untyped `AsyncThrowingStream<HistorySnapshot, Error>` ABI and caller downcast contract; no API change was invented. |
| `actions-receipts-not-equatable-test-gap` | `not-a-defect` | The locked specification intentionally requires `Sendable` only; field-wise test assertions are adequate and no runtime invariant is missing. |
| `limits-representation-vs-revision-bytes-cross-bound-unchecked` | `in-progress` | The cross-bound guard and a rejection test are present; macOS proof remains. |
| `contentversion-zero-and-max-mintable` | `not-a-defect` | Durable decode rejects zero before minting and `successor()` handles max as typed capacity; no live producer violates the invariant. |
| `historyitemid-description-untested-revisionid-asymmetry` | `in-progress` | Public `HistoryItemID.description` coverage is local; the spec-mandated `RevisionID` asymmetry remains unchanged and macOS proof remains. |
| `actorstubs-misleading-filename` | `in-progress` | The live actors moved from `ActorStubs.swift` to `RevisionPreparationAndSearchCorpus.swift`; macOS package/build reference proof remains. |
| `ws-support-sort-by-uuidstring-not-historyitemid` | `in-progress` | Walking-skeleton support now sorts with production `HistoryItemID.<`; macOS test proof remains. |
| `package-dto-init-spans-whole-package` | `not-a-defect` | This is Swift `package` access semantics, not an escape from the public seam; stronger isolation would require a package split. |

## `02-historydomain.md` — HistoryDomain (33)

### Major (2)

| Canonical finding ID | Status | Evidence / canonical relationship / next action |
|---|---|---|
| `domain-planners-have-no-direct-unit-tests` | `in-progress` | The 47-test Domain suite now drives all seven planners directly across commit/no-op, planner-owned rejection, deterministic ordering, capacity, and complete-payload cases. `DomainSmokeTests` records the D1–D19 ownership matrix, including the Storage-owned D5/D6 stamping and structural D8/D17 proofs; macOS Swift tests remain. |
| `progress-md-overstates-d19-suite-as-delivered` | `documented` | `PROGRESS.md` now distinguishes landed smoke/integration coverage from the still-open dedicated D1–D19 acceptance proof. |

### Minor (19)

| Canonical finding ID | Status | Evidence / canonical relationship / next action |
|---|---|---|
| `signatureindex-doc-claim-false-under-corruption` | `fixed` | The posting-key comment now scopes no-false-exclusion to correctly derived metadata and records the silent-corruption exception; the portable gates prove this comment-only correction. |
| `signature-index-false-exclusion-yields-duplicate-item` | `documented` | V1 accepts one recoverable duplicate after stored-fingerprint corruption; byte confirmation still prevents false matches. Owner: HistoryStorage repair/migration. Trigger: checksum migration design or observed signature corruption. Residual risk: duplicate retained content until removal. |
| `d8-candidacy-rests-on-unaudited-signatureindex-candidateids` | `duplicate` | Canonical target: `signatureindex-unit-test-coverage-thin`, which owns direct candidate/intersection/divergence proofs. |
| `signature-index-gate-completeness-depends-on-d2` | `deferred` | Owner: HistoryDomain + Signature Index. Trigger: any new Canonical-source mutation/graft. Residual risk is a new mutation bypassing the D2 coverage premise. |
| `effectivecontent-corrupt-lineage-untested` | `duplicate` | Canonical target: `domain-planners-have-no-direct-unit-tests`; new direct corrupt-lineage cases are present, pending macOS proof. |
| `canonical-winner-tiers-and-total-order-untested` | `duplicate` | Canonical target: `domain-planners-have-no-direct-unit-tests`; new winner-tier/input-order cases are present. |
| `victim-selection-arithmetic-untested-at-divergence` | `duplicate` | Canonical target: `domain-planners-have-no-direct-unit-tests`; the direct projected-recency victim fixture is present. |
| `copycount-overflow-untested` | `duplicate` | Canonical target: `domain-planners-have-no-direct-unit-tests`; a direct overflow rejection case is present. |
| `revision-revalidation-untested` | `duplicate` | Canonical target: `domain-planners-have-no-direct-unit-tests`; direct stale-base/foreign-type/normalization cases are present. |
| `placement-anchor-failures-untested` | `duplicate` | Canonical target: `domain-planners-have-no-direct-unit-tests`; invalid target/anchor relationships are exercised directly. |
| `unpin-already-unpinned-noop-untested` | `duplicate` | Canonical target: `domain-planners-have-no-direct-unit-tests`; direct unchanged proof is present. |
| `pinshift-middle-last-pinned-remove-untested` | `duplicate` | Canonical target: `domain-planners-have-no-direct-unit-tests`; middle and last removal cases are present. |
| `revisioncount-capacity-path-untested-at-preparation-actor` | `in-progress` | A package-seam capacity regression is present; macOS actor/test proof remains. |
| `domain-trusts-retention-floor-zero-policy-counterexample` | `documented` | Storage owns the 1...5,000 admission invariant at open, durable-row decode, and action boundaries; WS21 pins zero/over-bound rejection before Domain facts are formed. |
| `planners-run-on-authority-actor` | `deferred` | Owner: HistoryStorage. Trigger: WL/p95 evidence shows planner work materially extends the serialized interval, or retained bounds rise. Residual risk: bounded pure planning still contributes to serialized Authority latency. |
| `plancapture-unconditional-eviction-sort` | `in-progress` | Capture computes victim count first and performs no candidate allocation/sort for zero victims; direct unchanged/insert/coalesce regressions are local, macOS proof pending. |
| `canonicalwinner-byte-equality-in-min` | `in-progress` | Lane 2 caches exact-match and extra-representation rank facts once per confirmed candidate; existing tier/input-order regressions cover semantics and macOS proof remains. |
| `dedup-candidates-over-hydrate-revisions` | `deferred` | Owner: HistoryStorage + Performance. Trigger: candidate-heavy evidence shows revision decode materially extends the Authority interval and a spec-approved lean fact preserves corruption checks. Residual risk: bounded candidate revision decode/RSS cost. |
| `perf-cap-blindspot` | `deferred` | Owner: Performance runner. Trigger: a dedicated/nightly or pre-release 5,000-row candidate-lane workload. Residual risk: a high-constant/contention cliff between 1,000 rows and the hard cap remains unmeasured. |

### Nit (12)

| Canonical finding ID | Status | Evidence / canonical relationship / next action |
|---|---|---|
| `planclear-ignores-scope-no-switch` | `in-progress` | Planner now exhaustively switches `ClearScope` and direct clear tests pin both cases; macOS proof pending. |
| `planretention-sort-before-noop-shortcut` | `in-progress` | The unchanged policy/count fast path now precedes eviction sort and has a direct test; macOS proof remains. |
| `canonicalcontains-per-candidate-set-rebuild` | `not-a-defect` | The varying existing Canonical set is the only set built per candidate; hoisting an incoming set would add work rather than remove the bounded lookup. |
| `lane1-hint-equality-double-set-rebuild` | `duplicate` | Canonical target: `canonicalcontains-per-candidate-set-rebuild`; both are the same repeated-set construction root. |
| `lane2-candidate-count-distribution-unmeasured` | `deferred` | Owner: Perf + Signature Index. Trigger: representative p95 candidate count makes lane-2 work material. Residual risk is unmeasured pathological common signatures. |
| `canonicalcontent-init-accepts-empty-typeidentifier` | `not-a-defect` | Preparation owns type-identifier admission and rejects empty values before Domain construction; this layer split is intentional. |
| `effectivecontent-nonvalidating-init` | `not-a-defect` | The package value is constructed from already-validated lineage; duplicating all normalization checks here is not part of the Domain contract. |
| `contentrepresentation-byte-exact-claim-realized-as-string-canon-equiv` | `in-progress` | Authoritative §2.1/§9 now match the implementation: type identifiers use Swift canonical-equivalent `String` equality without rewriting stored spelling, while payload `Data` remains byte-exact. The decomposed/precomposed duplicate regression pins the boundary; macOS proof remains. |
| `ingestprep-step4-adjacent-dedup-misses-canon-equiv-pair` | `in-progress` | Preparation now uses a global `Set` and direct non-adjacent canonical-equivalence regression; macOS proof remains. |
| `synthesized-internal-memberwise-inits-on-plan-payload-types` | `not-a-defect` | Synthesized inits remain internal implementation vocabulary and expose no caller seam. |
| `perf-runner-retention-clear-median-of-two` | `duplicate` | Canonical target: `median-helper-wrong-even-count-no-guard-mislabeled`. WL4 now records five timed samples, but the generic helper item remains open. |
| `domainrejection-revisionnotfound-dead-case-and-ownership-doc` | `in-progress` | Dead Domain rejection/mapping removed; Part II now assigns revert-ID resolution to Storage before planner entry. macOS build proof remains. |

## `03a-codecs.md` — codecs and schema (29)

### Major (2)

| Canonical finding ID | Status | Evidence / canonical relationship / next action |
|---|---|---|
| `projection-title-searchbody-bounds-not-decode-verified` | `in-progress` | Shared projection validation and persistent corruption fixtures cover startup/recent/search/hydration; macOS Swift tests remain. |
| `search-corpus-per-query-full-materialization-on-actor` | `duplicate` | Canonical target: `search-corpus-materializes-full-inline-searchbody`, which owns the inline corpus shape and representative-memory decision. |

### Minor (15)

| Canonical finding ID | Status | Evidence / canonical relationship / next action |
|---|---|---|
| `hydrate-decodes-full-revision-blob-for-paste-and-thumbnail` | `duplicate` | Canonical target: `read-paths-decode-all-revisions`; that item owns purpose-specific hydration. |
| `exactness-guard-refetches-entire-unpinned-lane-on-tie` | `duplicate` | Canonical target: `unpinned-exactness-guard-full-lane-refetch`; that item owns the explicitly deferred, hard-bounded correctness fallback. |
| `revisionstate-dual-rejection-enum-paired-catch-hazard` | `in-progress` | Revision/scalar failures now share `CodecRejection` and one exhaustive `mapCodecFailure`; paired private catches are gone and expectations updated. macOS compile/test proof remains. |
| `pagecursorcodec-no-unit-tests` | `in-progress` | Round-trip, malformed, version/query/anchor/mode/marker/missing-field and encode-failure tests are present; macOS proof remains. |
| `fuzzy-cursor-anchor-resume-untested` | `in-progress` | A deterministic three-page fuzzy traversal plus missing-anchor and post-commit expiry cases are present; macOS proof remains. |
| `wire-format-unpinned-jsonencoder-strategies` | `in-progress` | Shared wire format explicitly pins base64 Data and deferred-to-Date strategies; fixed Date+Data bytes and direct round trips are local, macOS proof pending. |
| `pagecursor-encode-swallows-failure-as-empty-payload` | `in-progress` | Encode now throws and minting maps it to invariant failure; direct NaN failure coverage is present, pending macOS proof. |
| `count-bound-enforced-after-json-allocation` | `deferred` | Owner: HistoryStorage wire format. Trigger: supported allocation evidence breaches Part VI gates or an untrusted import path appears. The byte envelope remains the pre-parse defense; residual risk is sub-envelope transient element allocation before semantic count rejection. |
| `canonical-decode-three-passes` | `in-progress` | Canonical validation and transcription now share one pass before the Domain validator backstop; rejection-order/round-trip tests exist and macOS proof remains. |
| `date-fields-not-finiteness-validated` | `in-progress` | Revision/capture timestamps and recent/search/retention scalars now validate finite dates plus copy/source fields, with mapping/corruption tests; macOS proof remains. |
| `processmarker-no-schema-binding` | `not-a-defect` | Spec/comments now name a process-instance marker; every schema deployment creates a new process/Authority UUID and v1 has no in-process schema transition. |
| `revision-effectivecontent-no-domain-backstop` | `documented` | `EffectiveContent` intentionally has no throwing Domain validator; the revision codec now documents its prechecks as the complete persisted-state boundary. |
| `revision-empty-list-nonnil-active-id-untested` | `in-progress` | The malformed active-ID/empty-list case and mapping are now covered; macOS proof remains. |
| `revision-decode-peak-memory-full-snapshot` | `duplicate` | Canonical target: `read-paths-decode-all-revisions`; incremental/purpose-specific decoding owns this peak. |
| `blob-decode-runs-on-authority-actor` | `duplicate` | Canonical target: `read-paths-decode-all-revisions`; measurement should decide both decode volume and serialized-interval impact together. |

### Nit (12)

| Canonical finding ID | Status | Evidence / canonical relationship / next action |
|---|---|---|
| `pagecursor-decode-has-no-pre-parse-envelope` | `in-progress` | Cursor decode rejects beyond `6× maximum term bytes + 2 KiB` before JSON allocation, with equality/one-over direct coverage; macOS proof pending. |
| `cursor-anchor-decode-leniency` | `in-progress` | Known query/anchor fields now validate limit, term, exclusivity, ordinal, and finite values; inert unknown metadata is explicitly tolerated and fixture-pinned. macOS proof pending. |
| `pagecursor-rejection-not-equatable` | `in-progress` | Internal rejection now conforms to `Equatable` and direct tests assert precise codec reasons without widening the public seam; macOS proof pending. |
| `fresh-jsondecoder-decoder-per-call` | `deferred` | Owner: HistoryStorage performance. Trigger: profiling attributes material time/allocation pressure to coder construction. Fresh mutable coders avoid cross-actor sharing; residual risk is bounded allocation churn. |
| `overflow-branch-reports-intmax-found` | `documented` | `CodecRejection` now documents `Int.max` as the checked-overflow sentinel used only when the mathematical total is unrepresentable, not a fabricated wire value. |
| `revision-active-id-linear-scan` | `in-progress` | Revision decode now reuses the already-built, uniqueness-proved `seenRevisionIDs` set for active-ID membership; macOS codec proof pending. |
| `revision-decode-repeated-representation-passes` | `in-progress` | Revision decode validates/transcribes each representation once and reuses one type list; existing rejection-order/round-trip tests await macOS proof. |
| `validatecoverage-double-collection` | `in-progress` | Signature coverage now builds its type lookup during the orphan-check pass; codec tests await macOS proof. |
| `decodewire-internal-test-seam-bypasses-envelope` | `not-a-defect` | The seam is internal and intentionally test-only; every durable production caller enters through the envelope-checked decoder. |
| `decode-envelope-magic-numbers-duplicated` | `in-progress` | `CodecDecodeEnvelope` centrally owns all four formulas/constants and codec tests use the named helpers; macOS proof remains. |
| `effective-type-identifiers-blob-inline-decoded-on-actor` | `not-a-defect` | The blob is deliberately small/bounded and not an external-storage payload; no material risk was demonstrated. |
| `canonicalsignatureblob-also-inline-no-externalstorage` | `not-a-defect` | The signature blob is a bounded scalar/index aid by design; external storage would work against its access pattern. |

## `03b-authority-kernel.md` — HistoryAuthority kernel (38)

### Major (1)

| Canonical finding ID | Status | Evidence / canonical relationship / next action |
|---|---|---|
| `ws18-unpinned-continuation-pagination-contract-violation-cluster` | `in-progress` | Anchor-index/tie exactness repair and adversarial same-date multi-page WS18 fixture are present. Run 31448195535 exposed a same-file `private` access error in that guard; the scalar timestamp now uses the narrowest valid `fileprivate` access and the macOS rerun remains. |

### Minor (18)

| Canonical finding ID | Status | Evidence / canonical relationship / next action |
|---|---|---|
| `validate-final-pin-order-per-commit-cluster` | `in-progress` | D12 revalidation now runs only for plans that may affect pins and fetches only `pinOrdinal != nil` rows through the already-used optional predicate; macOS SwiftData proof remains. |
| `search-corpus-rebuild-per-call-cluster` | `duplicate` | Canonical target: `search-reeval-per-page`, which owns the G2-gated snapshot/cache decision. |
| `external-storage-blob-faulting-unverified-cluster` | `duplicate` | Canonical target: `scalar-reads-rely-on-unverified-externalstorage-faulting-suppression`; one supported-platform trace should decide both. |
| `modelcontext-transaction-durability-cluster` | `deferred` | Owner: Part VI persistence evidence/HistoryStorage. Trigger: a supported persistent-store test or platform contract exposes synchronous fsync/crash semantics, or Authority transaction p95 exceeds 20 ms. Residual risk: `ModelContext.transaction` proves atomic framework commit, not a crash-to-stable-storage instant. |
| `pinned-continuation-quadratic-cluster` | `in-progress` | `fetchOffset` starts at the anchor, validates the complete anchor, then drops it; malformed ID/ordinal and multi-page pinned→unpinned regressions are present, pending macOS SwiftData proof. |
| `unpinned-exactness-guard-full-lane-refetch` | `deferred` | Owner: G2/HistoryStorage pagination. Trigger: a supported 5,000-row tie-heavy traversal measures incidence/cost and breaches the browse-page p95 budget, or a journal/cache graft opens. Residual risk: the correctness-only ambiguity fallback fetches and sorts the hard-bounded unpinned lane, so an all-same-timestamp traversal can approach O((N/L) × N log N). Normal pages remain `limit + 1/2`; WS18 pins complete, non-overlapping results, while Part VI §9 now explicitly forbids citing the normal-case runner as fallback evidence. |
| `capture-interval-three-full-table-scans` | `duplicate` | Canonical target: `capture-fact-load-fetches-same-table-2-3-times`. |
| `read-paths-decode-all-revisions` | `deferred` | Owner: G8/read-schema graft. Trigger: representative details/paste/thumbnail RSS or copy-cost p95 breaches the Part VI budget. Residual risk: one-item reads remain O(full bounded lineage) and execute their decode on Authority. |
| `defensive-transaction-guards-and-cursor-codec-untested-cluster` | `in-progress` | Guard-specific one-shot cases exercise `StorageInvariant.positionChanged` and all four concrete `TransactionApplyRejection` producers through normal commit APIs; every case maps to `.persistence(.transaction)` and proves row/Change Position rollback. `PageCursorCodecTests` covers cursor wire/rejection branches. macOS SwiftData proof remains. |
| `perf-runner-lacks-resident-set-p99-gates` | `deferred` | Owner: v2 performance-evidence step. Trigger: J1/P1/P3 or G2/G5/G8 admits an absolute latency/RSS claim; the fixture must then pin supported hardware, adequate p50/p95/p99 samples, and RSS/copy measurement. Residual risk: per-PR CI currently proves complexity envelopes, not tail latency or resident memory. |
| `clear-and-retention-n-individual-fetches` | `documented` | Part V §10 deliberately requires each named business ID to resolve to exactly one actual row before deletion; predicate-delete would weaken complete-fact/duplicate checks. The loop is bounded O(N), and WL4's 3× corpus/6× gate remains quadratic-sensitive. Revisit only with a supported `ids.contains` translation and equivalent fail-closed proof. |
| `non-suspending-interval-convention-only` | `deferred` | Owner: architecture/source-gate tooling. Trigger: the next commit-interval refactor or availability of a reliable SwiftSyntax rule that can prove no live `ModelContext`/`@Model` crosses an `await`. Residual risk: a future edit could violate the convention; the current intervals contain no suspension and OCC/tests guard behavior. A brittle regex lint was not added. |
| `per-candidate-fetch-row-loop-unbatched` | `duplicate` | Canonical target: `candidate-hydration-n-plus-1-queries`. |
| `capture-time-signature-index-rebuild` | `deferred` | Owner: G5/Signature Index. Trigger: a forced-unready 5,000-row metadata rebuild exceeds 250 ms p95 on the supported runner or is observed frequently in production diagnostics. Residual risk: the rare repair path performs bounded O(N × representations) work before capture planning. |
| `encode-inside-transaction-misclassified` | `in-progress` | Effective-type blobs are now encoded during stamping and carried in immutable stored payloads, so codec failure precedes the transaction; macOS proof remains. |
| `thumbnail-source-full-image-copy` | `deferred` | Owner: G8/thumbnail read graft. Trigger: a supported persistent-store RSS/copy trace breaches the representative thumbnail budget. Residual risk: concurrent callers may materialize the same bounded source `Data` before the service's decode single-flight seam. |
| `scalar-property-list-triplicated` | `in-progress` | One helper now owns the common recent/search/exactness-fallback scalar list and search adds only `searchBody`; macOS proof remains. |
| `commit-tail-duplicated-cluster` | `in-progress` | Capture now joins the same validate→transaction→index→publish→receipt tail as all mutations; walking-skeleton ordering proofs await macOS. |

### Nit (19)

| Canonical finding ID | Status | Evidence / canonical relationship / next action |
|---|---|---|
| `commitcapture-outcome-switch-and-noop-branch` | `in-progress` | The planner-impossible `.unchanged` branch now fails closed as an invariant while inserted/coalesced outcome handling remains explicit; direct planner tests exist and macOS proof remains. |
| `mapcodecfailure-duplicated` | `in-progress` | All codec boundary catches now use the single module-wide `mapCodecFailure`; macOS proof remains. |
| `orderpinnedlane-redundant-resort` | `in-progress` | Recent pinned rows now retain the descriptor's ordinal order; D12 removes all ties and the redundant in-memory sort/default are gone. macOS proof remains. |
| `range-array-alloc-contiguity-check` | `in-progress` | All three D12 checks use `enumerated().allSatisfy` rather than materializing expected ranges; macOS proof remains. |
| `validate-final-pin-order-conflates-count-bound` | `not-a-defect` | Final D12 validation now runs only for pin-affecting plans and fetches pinned rows only; exceeding the retained bound there is durable pin-state corruption. Part V §16 intentionally maps every transaction-closure invariant failure to the same public persistence failure, so a new caller-visible capacity split would be false precision. |
| `test-seams-compiled-into-production` | `not-a-defect` | The internal seams are deliberately documented, nil in production, and require same-module access; no public capability leaks. |
| `register-subscriber-unstructured-task` | `documented` | The synchronous stream-termination callback can only weakly capture state and enqueue one idempotent actor hop; source docs now state that bounded lifecycle and why no joinable result exists. |
| `loadedContentVersion-linear-scan-for-winner-version` | `not-a-defect` | Capture computes the winner version once over the already-loaded bounded inventory; a dictionary would retain the same O(N) scan plus memory, while the Signature Index hint remains the O(1) candidate gate. No second durable fetch or repeated hot-loop scan exists. |
| `spec-section-9-does-not-note-pinned-continuation-exception` | `documented` | Part V/VI now document `fetchOffset` pinned continuation and the `limit + 1` normal fetch envelope. |
| `commitcapture-inline-justification-inaccurate` | `in-progress` | The stale inline-tail rationale is removed; capture's rebuild is documented before planning and the common tail afterward. macOS proof remains. |
| `recentpage-read-assumes-pin-ordinal-contiguity` | `not-a-defect` | D12 is a startup/commit invariant of the sole writer and is intentionally relied on by reads; the new offset path has explicit guards. |
| `readposition-second-context` | `not-a-defect` | Cursor validation creates exactly one short context and throws before the main page context is created; a successful first-page read never takes that path. The two contexts are sequential fail-fast validation, not a split successful snapshot or race window. |
| `stamp-existing-revisions-array-copy` | `in-progress` | Revision encoding accepts one appended revision and builds the wire array directly, removing the intermediate Domain lineage copy; macOS proof remains. |
| `revision-prep-actor-serializes-stateless-work` | `deferred` | Owner: HistoryStorage. Trigger: a concurrent revision consumer plus measured queueing. Residual risk is avoidable head-of-line latency. |
| `thumbnail-image-set-hardcoded-subset` | `not-a-defect` | The seven-UTI v1 image set is a valid frozen interpretation of the underspecified product scope. |
| `dead-step-deferred-error` | `in-progress` | Zero-use enum and contradictory Sources/Tests/PROGRESS comments were removed; macOS build proof remains. |
| `finishall-dead-code-cluster` | `in-progress` | Zero-call `subscriptionCount`/`finishAll` publisher helpers were removed without inventing an Authority teardown API; observation/build proof remains. |
| `invalidation-publish-runs-in-post-commit-interval` | `not-a-defect` | Newest-value `continuation.yield` is the specified synchronous, non-suspending post-commit publication step; source docs now make the interval ownership explicit. |
| `revert-revision-linear-scan` | `not-a-defect` | Revision count is hard-bounded at 100; a linear immutable-list lookup is simpler and negligible. |

## `03c-search-reads-observation.md` — search, reads, and observation (37)

### Critical (1)

| Canonical finding ID | Status | Evidence / canonical relationship / next action |
|---|---|---|
| `fuse-bitap-crash-and-corruption` | `in-progress` | All profiles now cap fuzzy terms at Fuse 1.4.0's 64-bit ceiling and WS17 sweeps both failure windows; macOS test/symbol proof remains. |

### Major (8)

| Canonical finding ID | Status | Evidence / canonical relationship / next action |
|---|---|---|
| `regex-overlapping-alternation-redos` | `in-progress` | Quantified-alternation shapes are conservatively rejected and long-input facade regressions are present; macOS proof remains. |
| `search-corpus-materializes-full-inline-searchbody` | `deferred` | Owner: G2/HistoryStorage projection schema + Performance. Trigger: a supported 5,000-row representative-body workload breaches RSS/copy budget and selects a bounded storage/fetch shape. Residual risk: one snapshot may materialize the full ~1.28-GiB structural envelope; no unmeasured cache is added. |
| `projection-joins-full-body-before-truncation` | `in-progress` | Projection now streams into the byte envelope and revision summaries use a title-only path; direct regressions exist, pending macOS proof. |
| `exact-body-excerpt-full-array` | `in-progress` | Full `[Character]` materialization was replaced with `String.Index` traversal and a bounded window; five direct worked examples await macOS proof. |
| `no-direct-unit-tests-for-search-projector-internals` | `in-progress` | Projector, excerpt, regexp preflight, and original-string UTF-16 translation now have direct `@testable` suites; actor-confined Fuse behavior is covered through public fuzzy boundary/Unicode fixtures. The direct matrix includes nested quantifiers/alternation, backreferences, nested/POSIX sets, quoted literals inside/outside sets, comments-mode admission, ellipses, clipping, and supplementary/combining UTF-16 widths. macOS proof remains. |
| `fuzzy-bound-test-misses-entire-corruption-range` | `duplicate` | Canonical target: `fuse-bitap-crash-and-corruption`; its public boundary sweep owns the proof. |
| `test-gap-excerpt-edge-redistribution-untested` | `duplicate` | Canonical target: `exact-body-excerpt-full-array`; direct near-start/end, centered, long-match, and UTF-16 examples are present. |
| `search-observation-path-untested` | `in-progress` | Two deterministic proofs now cover both sides of the race: one commits after old evaluation but before position recheck, and one parks at SearchWorker evaluation entry after the immutable old-position corpus is captured, commits, then proves the first visible page is recomputed at the newer position. macOS observation proof remains. |

### Minor (21)

| Canonical finding ID | Status | Evidence / canonical relationship / next action |
|---|---|---|
| `exact-mode-no-term-guard` | `in-progress` | One common 4,096-byte admission now precedes all modes and 4,096/4,097 fixtures exist; macOS proof remains. |
| `search-reeval-per-page` | `deferred` | Owner: G2/HistoryStorage. Trigger: measured search-pagination cost admits the journal/cache graft. Residual risk is repeated O(corpus) evaluation. |
| `searchworker-actor-serializes` | `deferred` | Owner: HistoryStorage. Trigger: after ReDoS closure, measured concurrent-search head-of-line blocking exceeds budget. Residual risk: concurrent searches can queue behind one bounded 5,000-row scan. |
| `capture-fact-load-fetches-same-table-2-3-times` | `in-progress` | Capture now derives retained-ID coverage from one duplicate-checked scalar inventory and reuses it as the retention fact: the healthy path performs one table scan, while stale/unready state adds only the necessary signature-metadata rebuild. A stale-ready-index regression is local; macOS SwiftData proof remains. |
| `candidate-hydration-n-plus-1-queries` | `deferred` | Owner: G5/fact-loader performance graft. Trigger: supported SwiftData proves a business-ID `contains` predicate with equivalent duplicate/missing-row checks and candidate count K ≥ 64 breaches capture p95. Residual risk: forced-collision or dense-signature buckets perform O(K) indexed fetch/hydrate operations. |
| `fuzzy-double-lowercase` | `in-progress` | One aligned lowercase copy is reused through an equivalent case-sensitive Fuse executor; U+0130/emoji/flag/combining fixtures preserve original UTF-16 ranges, pending macOS proof. |
| `scalar-reads-rely-on-unverified-externalstorage-faulting-suppression` | `deferred` | Owner: G8/HistoryStorage measurement. Trigger: a 5,000-row persistent-store Instruments/SQL trace shows external-storage blobs fault during scalar-only inventory/recent/search reads or breaches RSS/copy budget. Residual risk: the selected scalar property list is structurally narrow, but SwiftData faulting behavior is not proved on this Linux host. |
| `fuzzy-score-in-cursor-anchor-is-brittle` | `deferred` | Owner: HistoryStorage v2. Trigger: Fuse upgrade, ordering change, or cross-architecture score nondeterminism. Residual risk: an otherwise current fuzzy cursor may expire after such a change; current decode fails closed. |
| `fuzzy-body-match-wastes-full-prefix-utf16-walk` | `in-progress` | Fuzzy match returns Character ranges only; title performs UTF-16 translation while body passes them directly to the bounded excerpt, pending macOS proof. |
| `test-gap-fuzzy-nonascii-utf16-untested` | `in-progress` | Emoji, flag, decomposed-combining, and separately-owned U+0130 fixtures now pin original-string UTF-16 ranges; macOS proof remains. |
| `test-gap-search-cursor-pagination-untested` | `in-progress` | Exact/fuzzy/regexp three-page traversals, both anchor-shape missing cases, and all-mode mutation expiry are present; macOS proof remains. |
| `test-gap-regexp-body-mode-untested` | `in-progress` | A body-only regexp fixture pins snippet-relative UTF-16 location/length; macOS proof remains. |
| `regexp-fuzzy-ellipsis-relative-to-prefix-not-body` | `in-progress` | Bounded regexp/fuzzy prefixes carry an omitted-stored-suffix flag into excerpt construction; a regexp boundary fixture pins the trailing ellipsis and macOS proof remains. |
| `utf16-fallback-can-project-mojibake` | `in-progress` | Projection is now type-strict (explicit UTF-16 UTI only; all other frozen text UTIs UTF-8 only), with malformed even-byte and positive UTF-16 canaries; macOS proof remains. |
| `over-bound-retained-set-maps-to-two-different-failures` | `in-progress` | Explicit inventory purpose makes ordinary over-bound durable state `.persistence(.invariantViolation)` and capture's unavailable candidacy proof `.temporarilyUnavailable(.dedupIndexRebuild)`; a direct default-purpose test plus public WS5 pin the intentional action-specific outcomes. macOS proof remains. |
| `fact-loader-defensive-invariant-paths-untested` | `in-progress` | Direct durable fixtures cover default over-bound inventory, D12 ordinal gap/duplicate, and stale-ready-index rebuild. Duplicate business IDs and candidate∖retained are structurally unconstructible through the unique schema and private lockstep index maps; existing Signature Index delta-rejection tests cover constructible divergence without an invariant-weakening initializer. macOS proof remains. |
| `contentprojector-whitespace-body-admitted` | `in-progress` | Whitespace-only representations are skipped without adding separators; direct regression exists, pending macOS proof. |
| `html-rtf-representations-indexed-as-raw-markup` | `deferred` | Owner: product + projection schema. Trigger: a UX requirement to render or strip markup. Residual risk is low-quality titles/search text. |
| `ws17-fuzzy-unpinned-ordering-untested` | `in-progress` | Four unconditional unpinned hits pin score, recency, then ID ordering; macOS proof remains. |
| `regex-posix-class-scanner-desync` | `in-progress` | The preflight scanner tracks nested ICU/POSIX classes, honors `\\Q…\\E` inside and outside sets, and conservatively rejects inline ICU `x` mode so `#` comments cannot desynchronize structural proof. Direct and facade fixtures pin safe/unsafe sets, quoted brackets, and global/scoped comments-mode bypasses; macOS proof remains. |
| `cursor-anchor-item-existence-oracle` | `not-a-defect` | Cursors are ephemeral process-local caller values; exploiting the weak oracle requires a valid marker, current position, and full anchor tuple. |

### Nit (7)

| Canonical finding ID | Status | Evidence / canonical relationship / next action |
|---|---|---|
| `fuzzy-sort-nan-score-instability` | `not-a-defect` | Pinned Fuse 1.4.0 produces finite scores in `[0,1]`; no NaN producer crosses the `FuzzyHit` seam. |
| `normalizing-newlines-two-pass` | `in-progress` | Newline folding is one Character pass and a CRLF/lone-CR projection regression is present; macOS proof remains. |
| `firstline-splits-all` | `in-progress` | Title selection now walks newline indices and returns on the first nonempty trimmed slice without materializing every line; macOS proof remains. |
| `body-excerpt-boundary-count-eq-windowcapacity` | `documented` | Authoritative §8 now says “320 Characters or shorter,” matching the outcome-equivalent implementation boundary. |
| `d12-alloc-array-equality` | `in-progress` | All three persisted pin-order checks now use zero-allocation `enumerated().allSatisfy`; macOS proof remains. |
| `projector-trusts-typeidentifier-set-invariant` | `not-a-defect` | Projection accepts only normalized `EffectiveContent` from validated preparation/lineage; revalidating would duplicate the owning invariant. |
| `typebased-fallback-force-indexes-typeidentifiers0` | `not-a-defect` | Every production caller supplies non-empty normalized Effective Content, so the empty test-only construction is outside the function precondition. |

## `03d-index-ingest-thumbnail-facade.md` — index, ingest, thumbnail, and facade (30)

### Critical (1)

| Canonical finding ID | Status | Evidence / canonical relationship / next action |
|---|---|---|
| `concealed-type-leak-flat-schema` | `in-progress` | Pasteboard-level concealment and six whole-capture exclusion markers now reject before hashing; no-hash/no-commit tests exist, pending symbol regeneration and macOS proof. |

### Minor (11)

| Canonical finding ID | Status | Evidence / canonical relationship / next action |
|---|---|---|
| `ingest-prep-rejection-and-transient-filter-untested` | `in-progress` | Admission, normalization, and privacy suites now cover empty capture, representation count, total/per-representation bytes, source/type bounds, duplicate/canonically-equivalent identifiers, non-finite timestamps, pasteboard concealment, and all six exclusion markers. Implementation coverage is complete; macOS Swift tests remain. |
| `observe-phase1-recheck-unbounded` | `documented` | Part IV §5 now records the deliberate fresh-first-page/liveness tradeoff and the loop checks cancellation between retries. A fixed retry cap would knowingly yield stale state. Trigger: supported product evidence of observer-start starvation; residual risk is delay under an infinite writer. |
| `signatureindex-generation-cargo-state` | `in-progress` | Cargo generation state is removed; §7.1/§12 now pin the non-suspending Authority interval plus exact retained-ID coverage as the interleaving proof. macOS compile/test proof remains. |
| `thumbnail-16mib-bound-misclassified` | `in-progress` | Over-envelope valid output now maps to `.capacityExceeded(.thumbnailBytes)` with equality/one-byte-over tests; symbol/macOS proof remains. |
| `thumbnail-finalize-failure-misclassified` | `in-progress` | Destination/finalization encode failures now share `.persistence(.invariantViolation)` and direct mapping coverage; macOS proof remains. |
| `xxh3-cross-version-determinism-unverified` | `in-progress` | Four empty/non-empty v0.8.3 known-answer vectors now call the exact production C wrapper; macOS arm64 test proof remains. |
| `candidate-and-revision-id-not-injected` | `in-progress` | Both preparation actors now accept package-only `@Sendable` identity/clock sources with fixed-ID/date tests; production retains UUID/Date defaults and the public seam is unchanged. macOS proof remains. |
| `signatureindex-unit-test-coverage-thin` | `in-progress` | Focused pure-value tests cover lifecycle, malformed build/deltas, fail-closed apply, empty/missing/intersection lookup, and valid map updates; obsolete generation-overflow coverage disappeared with the cargo counter. macOS proof remains. |
| `signatureindex-validate-apply-duplication` | `in-progress` | `validate` and spec-mandated post-commit revalidation now share one `checkDelta` implementation; macOS proof remains. |
| `thumbnail-pipeline-concurrency-design-latent` | `deferred` | Owner: PresentationUI + HistoryStorage. Trigger: first real thumbnail consumer plus measured scroll cancellation/concurrency. Residual risk is retained source bytes/wasted decode. |
| `ingest-prep-actor-serializes-prep` | `deferred` | Owner: HistoryStorage. Trigger: measured preparation queueing or p95 capture-budget breach. Residual risk: concurrent captures can incur preparation head-of-line latency; current serialization bounds peak memory. |

### Nit (18)

| Canonical finding ID | Status | Evidence / canonical relationship / next action |
|---|---|---|
| `section16-vocabulary-wording-phantom-deviation` | `documented` | §16 now distinguishes caller input/size failures from durable capacities and the new thumbnail-output capacity. |
| `empty-bytes-vocabulary-precision` | `documented` | The closed v1 vocabulary now defines `.byteLimit` as the capture-input bucket for empty or over-envelope payloads, with direct admission coverage. |
| `oversized-typeid-vocabulary-precision` | `documented` | The closed v1 vocabulary now defines `.unsupportedRepresentationType` to include empty and over-envelope identifiers, with direct admission coverage. |
| `stepdeferrederror-dead-code-cluster` | `duplicate` | Canonical target: `dead-step-deferred-error`; delete the type and contradictory comments once. |
| `sigindex-itemids-set-materialization` | `in-progress` | A cached retained-ID set is maintained across build/apply/mark-unready and directly covered; macOS proof remains. |
| `sigindex-build-postings-no-reserve` | `in-progress` | Build reserves the complete bounded posting-entry count before insertion; macOS proof remains. |
| `sigindex-candidateids-empty-defensive` | `in-progress` | Empty incoming signatures now return `nil` as unprovable and have direct lifecycle coverage; macOS proof remains. |
| `signatureindex-checkentrylist-typeid-gap` | `in-progress` | Build/delta checks reject a repeated Canonical type even when its fingerprint/count differs, with direct rejection coverage; macOS proof remains. |
| `signatureindex-apply-revalidates-full-delta` | `not-a-defect` | Full validate-before-apply is explicitly required by §11 as the non-suspending defensive assertion. |
| `thumbnail-multiframe-first-frame-only` | `deferred` | Owner: product/thumbnail. Trigger: a multi-frame representative-frame requirement. Residual risk is cosmetic first-frame-only output. |
| `thumbnail-cgimagesource-index-zero-no-count-check` | `not-a-defect` | ImageIO returns nil for a degenerate zero-frame source and the path already fails closed as corrupt stored input. |
| `facade-actor-fields-internal-not-private` | `documented` | `PROGRESS.md` records the internal visibility required by the deterministic concurrency harness; cross-target/public surface is unchanged. |
| `observe-producer-task-captures-self-comment` | `documented` | The comment now distinguishes the producer's immutable Sendable-facade capture from the termination handler's actor-only capture. |
| `ingest-prep-double-scan-representations` | `not-a-defect` | The bounded two-pass shape preserves the spec-frozen rejection precedence; fusing it would change public failure selection. |
| `defensive-canonicalcontent-catch-masks-future` | `in-progress` | Domain now instructs every new Canonical invariant to add an ingest pre-proof/canary; direct admission tests cover every current invariant and normalized sort. macOS proof remains. |
| `thumbnail-bound-magic-number-duplicated-in-tests` | `in-progress` | Codec tests now derive their bounds from `HistoryLimits.standard`; macOS proof remains. |
| `currentposition-fresh-modelcontext-per-recheck` | `not-a-defect` | A fresh context is required by the one-context-per-isolated-operation rule and the recheck occurs after off-actor search evaluation; reusing the page context across suspension would violate the architecture. |
| `fuzzy-double-lowercased-allocation` | `duplicate` | Canonical target: `fuzzy-double-lowercase`. |

## `04-perf-deps-stubs.md` — performance, dependencies, and stubs (35)

### Critical (1)

| Canonical finding ID | Status | Evidence / canonical relationship / next action |
|---|---|---|
| `wl8-currently-red-on-master-blocks-section9-acceptance` | `in-progress` | Remote run `30734778016` proves the audited failure; WL8 now isolates the production service after one prefetch, pending release-runner proof. |

### Major (1)

| Canonical finding ID | Status | Evidence / canonical relationship / next action |
|---|---|---|
| `wl8-proof-measures-authority-serialization-not-single-flight` | `in-progress` | Timed calls now exercise `ThumbnailService` directly while one untimed facade call preserves wiring smoke; perf CI remains. |

### Minor (19)

| Canonical finding ID | Status | Evidence / canonical relationship / next action |
|---|---|---|
| `wl2-measures-full-open-not-just-index-rebuild` | `in-progress` | WL2 now honestly names warm persistent-store-open scaling across container/open/singleton/startup/index work; map/tests/spec are aligned and macOS perf proof remains. |
| `wl2-implicit-dealloc-no-deterministic-seam` | `deferred` | Owner: Performance + SwiftData platform evidence. Trigger: deterministic teardown API availability or repeated-open variance/flakes. Residual risk: framework teardown and cache warmth perturb samples, so WL2 is not cold-start evidence. |
| `median-helper-wrong-even-count-no-guard-mislabeled` | `in-progress` | Even samples average both middle values, empty input fails explicitly, WL4 uses five timed samples, WL8 separates wall time, and odd/even tests are local; macOS perf proof remains. |
| `bounds-magic-numbers-no-invariant-check` | `in-progress` | Every gated workload now consumes one declarative scales/growth/bound/headroom table. Preflight and direct tests prove positive increasing scales, derived linear/constant ratios, finite bounds, the standard 1.5× floor, and WL1a's sole named 1.2× exception; macOS Swift/perf proof remains. |
| `wl4-retention-clear-bound-too-loose-to-catch-quadratic` | `in-progress` | WL4 now uses one warmup plus five timed samples and a 6× bound over a 3× corpus, rejecting nominal quadratic 9× scaling; perf CI remains. |
| `capture-measured-interval-includes-fingerprinting` | `documented` | Runner comments now correctly distinguish end-to-end `perform` timing from the construction-proved off-Authority fingerprint exclusion. |
| `wl1b-label-attributes-byte-scaling-to-candidate-work` | `in-progress` | Six captures per size are prebuilt outside the 1+5 timed operations and the note names end-to-end History capture work; macOS proof remains. |
| `wl6-measures-exact-only-fuzzy-uncharacterized` | `in-progress` | WL6 reuses each 100/400-row corpus for exact, fuzzy, and regexp fixtures; each requires the planted match and an 8× gate over the 4× span, pending macOS perf proof. |
| `xxh3-no-kat-test-in-suite` | `duplicate` | Canonical target: `xxh3-cross-version-determinism-unverified`; real wrapper KATs close both. |
| `vendored-sha-not-reverified-in-ci` | `in-progress` | The new portable vendor-integrity gate recomputes both pinned sha256 values in `run_gates.sh`; local proof is green and macOS CI remains. |
| `fuse-offset-invariant-untested` | `in-progress` | WS17 now proves U+0130 expands scalars but not Characters, fuzzy-matches, and maps the range into original UTF-16; macOS proof remains. |
| `perf-helpers-no-unit-tests-and-no-coverage-map` | `in-progress` | The runner test target covers median/ratio/duration, workload/envelope drift, CRC-32's published check and PNG IHDR vectors, and fixed xorshift32 state/byte streams. The extracted helpers are used by `makeNoisePNG`; macOS executable-target import/tests remain. |
| `ci-selfscan-collides-with-failurefixture-prose` | `in-progress` | Runner-owned failure prose no longer emits literal `error:`; the zero-warning scan is intentionally unchanged and macOS log proof remains. |
| `ci-selfscan-false-positive` | `not-a-defect` | The repository explicitly fails on runtime warning/error lines; weakening that scan would violate the zero-warning gate, so framework diagnostics must be eliminated at source. |
| `xxh3-symbol-pollution-default-visibility` | `in-progress` | SwiftPM defines `XXH_INLINE_ALL`; the object-level source gate proves only `clipy_xxh3_64bits` is global locally. macOS build/KAT proof remains. |
| `fuzzy-double-lowercase-per-row` | `duplicate` | Canonical target: `fuzzy-double-lowercase`. |
| `utf16-prefix-offsets-rebuilt-per-match` | `in-progress` | UTF-16 prefix sums now stop at the maximum matched/clipped upper bound and use `Character.utf16` directly; Unicode fixtures await macOS proof. |
| `searchworker-actor-serializes-all-search-evaluations` | `duplicate` | Canonical target: `searchworker-actor-serializes`. |
| `makenoisepng-crc32-concat-and-byte-at-a-time-fill` | `deferred` | Owner: Performance runner. Trigger: profiling attributes at least 5%/1 s of job time or material peak RSS to the helper, or the job approaches timeout. Residual risk: one extra ~3 MiB concat and high-constant setup outside timed production work. |

### Nit (14)

| Canonical finding ID | Status | Evidence / canonical relationship / next action |
|---|---|---|
| `xxh3-wrapper-null-input-ub` | `not-a-defect` | The sole Swift `Data.withUnsafeBytes` caller never passes null with positive length; no public C caller exists. |
| `deterministic-text-capture-small-body-contract-drift` | `not-a-defect` | Every current fixture requests a body larger than the deterministic prefix; the latent helper edge is unreachable in the accepted workloads. |
| `saferatio-zero-numerator-passes-trivially` | `in-progress` | Non-positive numerator or denominator returns infinity; direct symmetry tests are local and macOS perf proof remains. |
| `machine-metadata-missing-cpu-arch-chip-and-hostname-pii` | `in-progress` | Hostname was removed and non-PII architecture/hardware/processor facts are probed locally; macOS metadata proof remains. |
| `perf-swift-version-dead-branches-coarse-metadata` | `in-progress` | Runner now records `/usr/bin/xcrun swift --version`; macOS process/build proof remains. |
| `json-schema-unversioned` | `in-progress` | Perf fixture schema is explicitly version 2 and records coverage issues; encoded-fixture proof remains. |
| `fixture-structs-not-sendable` | `in-progress` | All three value-only fixture structs now conform to `Sendable`; strict-concurrency build remains. |
| `durationtoms-unlabeled-magic-divisor` | `in-progress` | The conversion divisor is named and fractional-millisecond coverage is local; macOS proof remains. |
| `wl2-redundant-inner-do` | `in-progress` | No-op warmup/timed inner scopes were removed; macOS runner proof remains. |
| `pin-reorder-setup-quadratic` | `deferred` | Owner: perf runner. Trigger: fixture pin count scales enough to affect CI wall clock. Residual risk: untimed fixture setup grows quadratically and can lengthen CI even though the recorded reorder interval is unaffected. |
| `scaffold-public-enum-undocumented-surface` | `deferred` | Owner: Step 9 PasteboardAdapter/PresentationUI. Trigger: real target implementations land; remove scaffolds and snapshot their public surfaces then. Residual risk: placeholder public symbols remain discoverable and can be mistaken for supported product API until step 9. |
| `bodyexcerpt-materializes-array-single-On` | `duplicate` | Canonical target: `exact-body-excerpt-full-array`; the full array is removed and direct tests await macOS proof. |
| `perferror-searchnomatch-dead-enum-case` | `in-progress` | Zero-use enum case deleted; macOS build remains. |
| `lengthdigest-is-dead-code-never-called` | `in-progress` | Zero-use helper and misleading comment deleted; macOS test build remains. |
