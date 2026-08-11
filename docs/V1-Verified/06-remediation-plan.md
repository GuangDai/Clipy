# Clipy V1 — Verification Remediation Plan

> **Baseline:** the findings in `00-verification-summary.md` through
> `05-cross-cutting.md`, audited at `8f316c9`.
> **Started:** 2026-08-09.
> **Scope:** every reported finding is triaged. A finding may be closed by a
> verified implementation/test/documentation fix, by an evidence-backed
> `not-a-defect` decision, by an explicit deferred-graft decision with an owner
> and trigger, or as a duplicate of another tracked fix. Silence is not closure.
> `07-finding-dispositions.md` is the mechanically complete, authoritative
> status ledger for all 222 canonical source-report IDs; this plan orders the
> work and keeps only currently active items in its register.

## Status rules

| Status | Meaning |
|---|---|
| `pending` | Not yet reconciled with the current tree. |
| `in-progress` | Red test or other proving evidence exists; implementation and/or verification is underway. |
| `fixed` | Code/spec change is present, the relevant regression test or gate passes, and the source verification report records the evidence. |
| `documented` | The implementation was already correct or intentionally constrained; authoritative prose now states the decision and evidence. |
| `deferred` | Not a v1 change; the owning graft, trigger, and residual risk are recorded. |
| `not-a-defect` | The report recommendation is rejected with direct code/spec evidence. |
| `duplicate` | Closed by another finding; the canonical finding ID is recorded. |

`fixed` is deliberately strict: editing code alone is still `in-progress`.
Whenever one item reaches a terminal status, its row in the corresponding
module report is updated in the same change with status, date, and evidence.
The master summary is updated after each remediation batch.

## Ordered work list

| Batch | Priority | Scope | Exit condition | Status |
|---|---:|---|---|---|
| R0 | P0 | Inventory all seven module reports, reconcile duplicates, and classify every ID | Every report ID has one canonical disposition and owner | `documented` (`07-finding-dispositions.md`) |
| R1 | P0 | Three criticals: Fuse bitap ceiling; concealed/private capture leak; WL8 single-flight proof | Each has a regression proof, implementation/spec fix, and green macOS CI evidence | `in-progress` |
| R2 | P0 | Correctness/security majors: unpinned continuation date ties, regexp ReDoS, projection scalar validation, thumbnail output classification | Adversarial fixtures pass and failure vocabulary/spec agree | `in-progress` |
| R3 | P1 | Pure-core proof gaps: D1–D19 planners, codecs, page cursors, Signature Index, ingest rejection paths, search/projector helpers, Authority guards | Direct tests exist only at the documented seams and cover every named branch/invariant | `in-progress` |
| R4 | P1 | Bounded-memory/read-path work: streaming projection, excerpt slicing, details summary projection, search-corpus evidence and any justified cache/graft | Measured evidence decides each report claim; implemented optimizations meet the frozen semantics | `in-progress` |
| R5 | P1 | Performance/evidence gates: on-disk representative corpus, latency/RSS/durability measurements, WL fixtures and runner correctness | Part VI evidence claims are reproducible and CI gates only proven envelopes | `in-progress` |
| R6 | P2 | Failure-vocabulary, API-surface, liveness, injection, and dead-code/document-drift clusters | Code and Parts I–VI use one vocabulary; no stale scaffolding/overclaim remains | `in-progress` |
| R7 | P2 | Remaining minor/nit efficiency, coverage, and documentation items | Every item is `fixed`, `documented`, `deferred`, `not-a-defect`, or `duplicate` with evidence | `in-progress` — 0 untriaged; code/test items await supported proof |
| R8 | Gate | Full verification, independent code review, and commit | Source gates, SwiftPM/Xcode tests, perf proofs, symbol snapshot, and review are green | `in-progress` — portable gates green; macOS/review/commit pending |

## Active item register

| ID | Source report | Severity | Planned proof/fix | Status | Evidence |
|---|---|---:|---|---|---|
| `fuse-bitap-crash-and-corruption` | `03c-search-reads-observation.md` | critical | Public `browse(.fuzzy)` boundary sweep; lower the bound to Fuse 1.4.0's 64-bit ceiling; amend Parts III/VI | `in-progress` | Code/spec/WS17 sweep complete locally; macOS CI unavailable on this Linux host |
| `concealed-type-leak-flat-schema` | `03d-index-ingest-thumbnail-facade.md` | critical | Carry pasteboard-level concealment, reject the whole capture before hashing, retain marker defense, and pin adapter behavior | `in-progress` | Code/spec/tests complete locally; symbol regeneration and macOS CI pending |
| `wl8-currently-red-on-master-blocks-section9-acceptance` | `04-perf-deps-stubs.md` | critical | Measure `ThumbnailService` join-or-create directly from one prefetched source; verify current remote CI state | `in-progress` | Remote master red confirmed; isolated production-service measurement implemented; perf CI pending |
| `ws18-unpinned-continuation-pagination-contract-violation-cluster` | `03b-authority-kernel.md` | major | Adversarial WS18 multi-page same-date fixtures, then exactness-guard repair | `in-progress` | Guard and regression fixture implemented locally; macOS CI pending |
| `pinned-continuation-quadratic-cluster` | `03b-authority-kernel.md` | minor | Use a sorted-result offset without trusting it: fetch the anchor, validate its complete tuple, then drop it | `in-progress` | Offset/anchor repair plus malformed ID/ordinal and pinned→unpinned WS18 cases complete locally; macOS SwiftData proof pending |
| `projection-title-searchbody-bounds-not-decode-verified` | `03a-codecs.md` | major | Shared scalar projection validator plus persistent corruption fixtures at startup/recent/search/hydrate seams | `in-progress` | Code/spec/tests complete locally; macOS CI pending |
| `date-fields-not-finiteness-validated` | `03a-codecs.md` | minor | Validate revision/capture dates and recent/search/retention scalar date/count/source fields before ordering/projection | `in-progress` | Code plus mapping/corruption fixtures complete locally; macOS CI pending |
| `regex-overlapping-alternation-redos` | `03c-search-reads-observation.md` | major | Conservative quantified-alternation rejection and long-input facade regressions | `in-progress` | Code/spec/WS17 fixture complete locally; macOS CI pending |
| `exact-mode-no-term-guard` | `03c-search-reads-observation.md` | minor | Common UTF-8 admission before mode-specific Character bounds | `in-progress` | 4,096/4,097-byte three-mode fixtures complete locally; macOS CI pending |
| `projection-joins-full-body-before-truncation` | `03c-search-reads-observation.md` | major | Stream the joined projection under its byte budget; provide a title-only revision-summary path | `in-progress` | Bounded projector/title-only implementation and direct regressions complete locally; macOS CI pending |
| `contentprojector-whitespace-body-admitted` | `03c-search-reads-observation.md` | minor | Skip whitespace-only representations without altering admitted text bytes | `in-progress` | Canonical streaming projector fix plus direct whitespace regression complete locally; macOS CI pending |
| `exact-body-excerpt-full-array` | `03c-search-reads-observation.md` | major | Window with `String.Index`; directly pin edge redistribution, ellipses, clipping, and UTF-16 offsets | `in-progress` | Full-body `[Character]` copy removed; five direct worked examples added; macOS CI pending |
| `thumbnail-16mib-bound-misclassified` | `03d-index-ingest-thumbnail-facade.md` | minor | Add typed encoded-thumbnail output capacity | `in-progress` | Equality/one-byte-over and mapping regressions complete; symbol regeneration and macOS CI pending |
| `thumbnail-finalize-failure-misclassified` | `03d-index-ingest-thumbnail-facade.md` | minor | Unify destination/finalization as encode-side invariant failures | `in-progress` | Direct failure mapping regression complete; macOS CI pending |
| `median-helper-wrong-even-count-no-guard-mislabeled` | `04-perf-deps-stubs.md` | minor | Correct even median/empty input and stop labeling one-shot wall time as a median | `in-progress` | Helper and WL4/WL8 fixture shape corrected locally; macOS perf proof pending |
| `saferatio-zero-numerator-passes-trivially` | `04-perf-deps-stubs.md` | nit | Make every non-positive measurement fail finite ratio bounds | `in-progress` | Symmetric guard implemented locally; macOS perf proof pending |
| `perf-helpers-no-unit-tests-and-no-coverage-map` | `04-perf-deps-stubs.md` | minor | Add a runner helper-test target and machine-checked §9 workload/bullet map | `in-progress` | Median/ratio/duration, deletion/label drift, PNG CRC-32, xorshift32, and schema-v2 coverage recording are local; macOS executable-target import/tests remain |
| `bounds-magic-numbers-no-invariant-check` | `04-perf-deps-stubs.md` | minor | Make workload/bullet coverage structural, then declaratively bind corpus spans to bounds | `in-progress` | Every gated workload consumes one declarative scales/growth/bound/headroom table; preflight and direct malformed-table tests are local, with only macOS Swift/perf proof remaining |
| `wl4-retention-clear-bound-too-loose-to-catch-quadratic` | `04-perf-deps-stubs.md` | minor | Replace max-of-two noise with five samples and restore a quadratic-sensitive envelope | `in-progress` | One warmup + five timed samples and 6×-over-3× bound are local; perf CI pending |
| `wl1b-label-attributes-byte-scaling-to-candidate-work` | `04-perf-deps-stubs.md` | minor | Prebuild capture fixtures outside timing and name the measured end-to-end construct | `in-progress` | Six captures per size are prebuilt for 1+5 calls; macOS runner proof pending |
| `machine-metadata-missing-cpu-arch-chip-and-hostname-pii` | `04-perf-deps-stubs.md` | nit | Remove hostname and record reproducible non-PII machine/toolchain/schema facts | `in-progress` | Architecture/model/processor, actual xcrun Swift version, schema v2, and Sendable fixture values are local; macOS probes/build pending |
| `ci-selfscan-collides-with-failurefixture-prose` | `04-perf-deps-stubs.md` | minor | Remove the runner-owned `error:` collision while retaining the zero-warning runtime scan | `in-progress` | Failure prose changed to `workload threw`; CI regex deliberately unchanged; macOS log proof pending |

The active register is deliberately a work queue, not a completeness ledger.
`07-finding-dispositions.md` owns the 222-ID checksum, every current status,
duplicate target, and deferred owner/trigger. The seven source reports remain
authoritative for the detailed failure scenario and remediation evidence.
