# HistoryStorage — Codecs & Schema — V1 Verified

> **Module:** `Sources/HistoryStorage/` codecs + schema (7 files, ~1,560 LOC): `CanonicalBlobCodec`, `SignatureBlobCodec`, `EffectiveTypeIdentifiersBlobCodec`, `RevisionStateBlobCodec`, `CodecRejection`, `PageCursorCodec`, `Schema`.
> **Method:** 3-cycle 审查(Review)→调研(Research)→批评(Critique) workflow — 22 agents, ~47 min (resumed after a 5h-rate-cap interruption at C1-Research; 4 C1 agents cached+replayed), 1.75M tokens, 576 tool calls. Confirmed counts grew 20→26→29 across the three cycles (deepening, not re-treading).
> **Verdict:** codecs are well-built but the decode contract is **shattered across four entry points with inconsistent coverage**. **0 critical, 2 major, 15 minor, 12 nit.** The two majors are a spec/comment overclaim with a real missing-validation gap, and a per-keystroke full-corpus rebuild on the serial actor.
>
> **Orchestrator cross-check (independently confirmed against source):**
> - `projection-title-searchbody-bounds-not-decode-verified` (MAJOR) — verified: `Schema.swift:67-68` makes `title`/`searchBody` plain inline `String` columns; `FactLoaders.hydrate` (`:106-154`) checks `contentVersion`/`occurrence`/`pinOrdinal` but NOT `projectionSchemaVersion`/title/searchBody; `RevisionStateBlobCodec.decodeOccurrence` (`:340-349`) DOES bound-check source observations — the asymmetry is real and the spec/comment overclaim stands.
> - `revisionstate-dual-rejection-enum-paired-catch-hazard` — verified: `RevisionStateBlobCodec.swift:57` declares a second `RevisionStateCodecRejection` enum alongside `CodecRejection`; `FactLoaders.mapCodecFailure` catches both. The file's own `:56` note flags the pending fold.
> - `search-corpus-per-query-full-materialization-on-actor` (MAJOR) — structurally sound from the facade (`SwiftDataHistory.browse` calls `searchCorpusSnapshot` + `searchWorker.page` per request, no cache); full confirmation at `HistoryAuthority.swift:1805` pending the authority-module pass.
>
> **Framing note (from C3-Critique):** the codec layer itself is uniform and correct (envelope→decodeWire→version→count→per-element-validate→Domain-backstop, exhaustive §16 mapping). The defects concentrate at the *edges* — the row-scalar projection fields (`title`/`searchBody`/`projectionSchemaVersion`) sit outside any codec, so they bypass the §4 decode discipline the four blobs enforce. This is the "split-trust schema" root: blobs are codec-gated, scalars are trust-the-writer.
>
> Line numbers as-of HEAD `8f316c9` (2026-08-02).
>
> **Pagination remediation chronology (2026-08-09):**
> `fuzzy-cursor-anchor-resume-untested` was **in-progress**. The shared
> public-facade pagination suite now traverses fuzzy results across three
> pages and pins missing-anchor plus post-commit expiry behavior. Run
> 31448531234 compiled production code and then exposed ambiguous literal
> inference inside the Swift Testing page-count assertion; explicit `[Int]`
> operands are now present. The corrected suite passes in run 31449682036;
> detailed fixtures are tracked in the 03c source report.

> **Final supported-runner closure (2026-08-11):** every remediation item in
> this report that was awaiting supported macOS, symbol-surface, or release-perf
> proof is now `fixed`. Public-symbol workflow
> [31448087991](https://github.com/GuangDai/Clipy/actions/runs/31448087991)
> and final code-head run
> [31449682036](https://github.com/GuangDai/Clipy/actions/runs/31449682036)
> are green. The latter passed all source/lint gates, strict-concurrency builds,
> 314 tests in 41 suites, generated-app build/test, all 13 release workloads,
> and the workflow's diagnostic self-scans; no unexcluded warning/error
> diagnostic remained. The narrow AppIntents-metadata and headless
> `com.apple.linkd.autoShortcut` exclusions remain documented. Detailed
> `in-progress`/`pending` wording below is retained only as pre-proof
> chronology; current per-finding
> status is authoritative in `07-finding-dispositions.md`. Deferred, duplicate,
> documented, and not-a-defect findings are unchanged.

---

## 1. Executive summary

HistoryStorage's four blob codecs (canonical, revision-state, signature, effective-type-identifiers) and the page-cursor codec are individually well-built — each blob codec has a dedicated one-rejection-per-§4-check test suite, pre-parse byte envelopes gate every durable decode, and the spec-mandated single-writer fence (§5) is correctly observed. The module is structurally sound for v1 greenfield operation. **The headline is a shattered decode contract:** spec §4 line 225, the `ContentProjector.swift:29-30` doc comment, and `AUDIT.md S3-R4` all assert that decode re-verifies `projectionSchemaVersion==v1` and the stored `title` (≤1,024 UTF-8 bytes) / `searchBody` (≤256 KiB) bounds, yet **no read or codec path enforces any of the three** — the structurally-identical source-observation bound *is* decode-enforced at `RevisionStateBlobCodec.swift:340-349`, proving this is an unintentional gap, not deferred trust-the-writer design. The second major is a hot-path performance defect: `searchCorpusSnapshot` rebuilds a full up-to-5000-row corpus on the serial Authority actor on every keystroke, page, and observe wake, with zero position-keyed cache. Beyond these, the residual is 15 minor and 12 nit findings — refactor debt the code itself names, a cursor codec mislabeled as §4-style, and a cluster of test-coverage and wire-format-stability gaps.

## 2. Scope & method

**Files examined (Sources/HistoryStorage/):** `CanonicalBlobCodec.swift`, `SignatureBlobCodec.swift`, `RevisionStateBlobCodec.swift`, `EffectiveTypeIdentifiersBlobCodec.swift`, `PageCursorCodec.swift`, `CodecRejection.swift`, `Schema.swift`, `ContentProjector.swift`, `FactLoaders.swift`, `MutationFactLoaders.swift`, `HistoryAuthority.swift`, `SwiftDataHistory.swift`, `SearchWorker.swift`, `SignatureIndex.swift`, `StampedPlan.swift`, `HistoryInvalidation.swift`, `IngestPreparation.swift`, `ThumbnailService.swift`, `Configuration.swift`, `ActorStubs.swift`. Domain/core cross-references: `HistoryDomain` (`Content.swift`), `HistoryCore/Limits.swift`.

**Spec sections governing this module:** `docs/05-authority-kernel.md` §3.1 (HistoryItemRow projection columns), §4 (decode contract — the per-row bound table lines 216/220/222/225), §5 (single-writer version fence), §6/§6.1 (cursor process marker; ContentProjection), §7.3/§7 (hydrate), §13 (signature index), §14.1/§14.2/§14.3 (lane ordering, two-step snapshot, paste/thumbnail), §15 (projection rules), §16 (rejection→HistoryFailure mapping); `docs/04-coherence.md` §2 (non-suspension interval), §6 (cursor generation/shape/position); `docs/06-cross-cutting.md` §2 (Part VI limits), §7.3/§7.4 (round-trip, corruption rejection); `docs/02-domain.md` §2.3 vs §2.4 (Domain validators vs value types).

**Process:** three cycles of review → research → critique. The review cycle enumerated decode-surface, cache, and complexity concerns; the research cycle verified each against source, spec, and tests (load-bearing line numbers re-confirmed this pass: `ContentProjector.swift:29-30`, `RevisionStateBlobCodec.swift:340-349`, `FactLoaders.swift:106-154`, `Schema.swift:79-111`, `HistoryAuthority.swift:1805`); the critique cycle merged duplicates, downgraded overstated severities (notably `hydrate-decodes-full-revision-blob` major→minor), refuted incorrect tightening proposals (the exactness-guard predicate), and corrected impact framing (memory figures restated as worst-case upper bounds). Findings that the prior cycle had already settled (uint64-fingerprint round-trip, revision-decode-peak-memory severity) were re-confirmed rather than re-litigated.

## 3. Findings

**Severity counts:** 0 critical · 2 major · 15 minor · 12 nit (29 confirmed).

### Critical
None. The module has no correctness, security, or data-loss defect that fires on the v1 hermetic write path under spec-conformant input.

### Major

| ID | Status | file:line | category | summary | recommendation | spec ref |
|---|---|---|---|---|---|---|
| `projection-title-searchbody-bounds-not-decode-verified` | **fixed** (2026-08-11; supported proof green in run 31449682036) | `ContentProjector.swift:29` | decode-contract | Spec §4 line 225, the `:29-30` doc comment, and `AUDIT.md S3-R4` all assert decode re-verifies `projectionSchemaVersion==v1`, stored `title` (≤1,024 UTF-8 B), `searchBody` (≤256 KiB). **No read/codec path enforces any of the three.** hydrate (`FactLoaders.swift:106-154`) checks contentVersion/occurrence/pinOrdinal but not these; `ScalarReadRow.init` (`HistoryAuthority.swift:2271-2284`) copies `title` verbatim; `searchCorpusSnapshot` (`:1907-1908`) copies `title`+`searchBody` verbatim; `buildSignatureIndexAtStartup` (`:363`) checks projectionSchemaVersion only at launch. The sibling bound IS decode-enforced at `RevisionStateBlobCodec.swift:340-349`. | Implemented one shared fail-closed projection validator with explicit `CodecRejection` cases. Startup validates schema; recent validates schema/title; search and full hydration validate schema/title/body. Persistent corruption fixtures cover all three and preserve recent's no-searchBody isolation. Pending supported-runner verification before `fixed`. | §4 line 225; 06 §7.4; `AUDIT.md` V1V-03A-001 |
| `search-corpus-per-query-full-materialization-on-actor` | `duplicate` → `search-corpus-materializes-full-inline-searchbody` | `HistoryAuthority.swift:1805` | performance / cache | `searchCorpusSnapshot` runs once per `browse(.search)`/observe page (`SwiftDataHistory.swift:252,427`), fetches ALL retained rows (`fetchLimit=5001`) with `title`+`searchBody` materialized inline (no `.externalStorage`), builds a full `[SearchCorpusRow]` copy, sorts O(N log N) on the serial Authority actor — then discards and rebuilds on every keystroke, every continuation page, every observe wake/invalidation. Zero position-keyed cache at either layer. Worst-case ~1.25 GiB inline String held during build (COW → ~1×, not 2×). | Canonical target `search-corpus-materializes-full-inline-searchbody` owns the G2/projection-schema evidence gate, trigger, and residual memory risk; no unmeasured v1 cache is added. | §14.2 (two-step shape), §5; 00 §2; 04 §12; 06 G2 |

### Minor

| ID | file:line | category | summary | recommendation | spec ref |
|---|---|---|---|---|---|
| `hydrate-decodes-full-revision-blob-for-paste-and-thumbnail` | `FactLoaders.swift:106` | decode-waste | `pastePayload` (`:2042`→`:2046 effectiveContent(of:)`) and `thumbnailSource` (`:2156`) consume only the active revision, yet hydrate decodes the entire `revisionStateBlob` (256 MiB cap) materializing every revision's `EffectiveContent`. *(Downgraded from major this cycle: pathological trigger, per-paste not per-keystroke, on-actor fence cost mandated by §5 and unchanged by the fix.)* | Prefer the corpus-cache fix first (paste latency is dominated by being on-actor, not per-item decode). If an active-only decode path is added, gate it behind the same `CodecRejection` (after the dual-enum fold) and reuse active-revision selection (`Content.swift:218-241`). | §7.3, §14.3, §5 |
| `exactness-guard-refetches-entire-unpinned-lane-on-tie` | `HistoryAuthority.swift:2360` | complexity | `orderUnpinnedLane`'s exactness guard, on a tie at the page boundary, re-fetches the ENTIRE unpinned lane (`fetchLimit=5000`) with full scalar projection and re-sorts in memory by `(lastCopiedAt DESC, id ASC)`. Correct (store-level sort is non-deterministic within a tie group); worst-case O(N) re-fetch + O(N log N) re-sort per continuation page. | No cheap predicate-tightening exists. Real reduction requires a STORED deterministic tie-break (stored monotonic ordinal or SQLite COLLATE) — a schema change; defer unless tie-heavy workloads appear. **Do NOT** pursue `lastCopiedAt == tieDate` (incorrect — misses tie groups above the boundary). | §14.1 |
| `revisionstate-dual-rejection-enum-paired-catch-hazard` | `RevisionStateBlobCodec.swift:57` | refactor-debt | `RevisionStateCodecRejection` is a second parallel rejection enum; decode throws a MIX of it and `CodecRejection`. The dual `mapCodecFailure` is duplicated file-private in `FactLoaders.swift:32` AND `HistoryAuthority.swift:2422` (identical 9-line bodies). Safe only because every decode routes through `mapCodecFailure` while 7 stamp catch sites catch only `CodecRejection` (stamp is encode-only). File flags the pending fold at `:56`. | Fold `RevisionStateCodecRejection` into `CodecRejection` (per-case §16 mapping already tested at `RevisionStateBlobCodecTests.swift:633-669`); delete one `mapCodecFailure` and promote the other to `internal`. Removes convention coupling + drift-prone duplication in one change. | §4, §16 |
| `pagecursorcodec-no-unit-tests` | `PageCursorCodec.swift:126` | test-coverage | ZERO test references to `PageCursorCodec`/`PageCursorRejection`/`malformedCursor`/`unknownCursorVersion`/`processMarkerMismatch` in the Tests/ tree. Rejection cases, wire round-trip, and unknown-kind branches exercised only indirectly via WS18's facade (asserts only the mapped `.snapshotExpired`). | Add `Tests/HistoryStorageTests/PageCursorCodecTests.swift`: round-trip all 4 `StoredQueryShape×StoredOrderingAnchor` combos; `malformedCursor` via garbage; `unknownCursorVersion` via hand-crafted formatVersion; `processMarkerMismatch` via encode(A)/decode(B); unknown-kind defaults; encode-impossible→empty-payload→`malformedCursor`. Pre-req: `PageCursorRejection: Equatable`. | 06 §7.3, §7.4; 04 §6, §16 |
| `fuzzy-cursor-anchor-resume-untested` | `PageCursorCodec.swift:99` | test-coverage | `.fuzzyUnpinned` is produced in production (`SearchWorker.swift:671-676`) and the resume loop exists (`SearchWorker.swift:139-145`), but grep for `kind:.search` + `after:` returns ZERO matches — WS18 paginates only `.recent`, WS17 does single-page fuzzy. The `.fuzzyUnpinned`/exact/regexp encode→decode→resume loop is live and uncovered. | Add `browse(.search(text:, mode: .fuzzy, limit: N, after: cursor))` page-2 assertions; same for exact/regexp. | 04 §6; 03b §8 |
| `wire-format-unpinned-jsonencoder-strategies` | `CodecRejection.swift:220` | wire-format / determinism | `CodecWireFormat.makeEncoder` pins `outputFormatting=[.sortedKeys]` but leaves `dateEncodingStrategy`/`dataEncodingStrategy` at JSONEncoder defaults for a versioned durable wire format that must be byte-stable forever. Carries `Date` (`StoredRevisionV1.createdAt`; cursor anchor `lastCopiedAt`) and `Data`. Stable only because Apple/corelibs Foundations happen to share defaults. **The most important minor.** | Pin `dataEncodingStrategy = .base64` and `dateEncodingStrategy = .deferredToDate` in `makeEncoder` and the matching strategies in `makeDecoder`; add one test asserting byte-identical encode of a fixed Date+Data fixture across runs. | §4 ("Encode ... is deterministic") |
| `pagecursor-encode-swallows-failure-as-empty-payload` | `PageCursorCodec.swift:294` | error-handling | `encode` catches the (theoretically unreachable) encoding failure and returns `HistoryPageCursor(payload: Data())`; decode maps it to `.malformedCursor`→`.snapshotExpired`. A regression would surface to every paginated request as silent cursor expiry with NO `.invariantViolation`. `PageCursorRejection.encodingFailed` declared but never thrown; `:270-273` header doc contradicts behavior. | Delete `encodingFailed` (unreachable) or make `encode` throw it; fix `:270-273` to match the swallow-and-empty behavior `:285-291` already documents. Optionally add a debug assert/runtimeWarning on the catch. | 04 §6; §16 |
| `count-bound-enforced-after-json-allocation` | `CanonicalBlobCodec.swift:101` | dos-envelope | In every blob codec the count guard runs AFTER `decodeWire` parses the whole container, so a sub-envelope blob of maximally-many minimal entries allocates a large transient `[StoredXxx]` before the count≤bound check. The byte envelope IS pre-checked and transitively bounds the allocation; count guard is semantic (≤32). | Accept for v1 (byte envelope is the primary DoS gate; JSON counts can't be cheaply pre-scanned). Document the asymmetry as intentional, or cap via a streaming reader. | §4 line 216 |
| `canonical-decode-three-passes` | `CanonicalBlobCodec.swift:134` | complexity | `decode` validates reps (loop), transcribes via `.map`, then `CanonicalContent(representations:)` re-validates as a defensive backstop. Three O(N) passes where a validating fold + Domain backstop is two. | Fold `:134` transcription into the `:108` validation loop so it emits `CanonicalRepresentation` values directly, then pass to `CanonicalContent`. | §4 |
| `date-fields-not-finiteness-validated` | `RevisionStateBlobCodec.swift:326` | validation | `Date` fields from `decodeOccurrence` and `StoredRevisionV1.createdAt` are not finiteness-checked. NaN partially self-protects (`lastCopiedAt >= firstCopiedAt` false → throws), but a NaN `createdAt` survives decode and corrupts sort ordering. `firstCopiedAt`/`lastCopiedAt` are native SwiftData `Date` columns (bypass JSON). | `guard row.firstCopiedAt.isFinite && row.lastCopiedAt.isFinite` (and per-revision `createdAt`) throwing a `corruptStoredValue` case, OR document that §4 doesn't require Date finiteness and NaN self-protection suffices. | §4 line 222; D11 |
| `processmarker-no-schema-binding` | `HistoryAuthority.swift:178` | schema-binding | `cursorProcessMarker` is a random per-process `UUID()` with no schema component, so §6's "process/schema generation" marker is half-implemented and the `:172-175` doc over-claims. Harmless for v1; a schema change without incrementing `HistorySchemaV1` wouldn't invalidate cursors. | Fold a schema-generation component (e.g. v1Schema hash) into the marker, OR soften §6 step 2's wording AND fix the `:172-175` comment to match the UUID-only implementation. | 04 §6 step 2 |
| `revision-effectivecontent-no-domain-backstop` | `RevisionStateBlobCodec.swift:282` | maintainability | Reconstructs each revision's `EffectiveContent` via the non-throwing memberwise init (`Content.swift:174`); decode depends entirely on its own pre-checks with NO Domain backstop, unlike `CanonicalBlobCodec`. Intentional (§2.4 has no validator), but a future edit weakening a pre-check has no safety net. | One-line comment at `:282` noting `EffectiveContent` has no Domain validator by design (§2.4), so the codec's pre-checks ARE the validation. | §4; 02 §2.3 vs §2.4 |
| `revision-empty-list-nonnil-active-id-untested` | `RevisionStateBlobCodec.swift:301` | test-coverage | The corruption case `revisions==[]` with non-nil `activeRevisionID` (rejected by the `contains` fallthrough at `:301`) has no dedicated test — `decodeRejectsActiveIDNamingNoStoredRevision` covers only one-revision + foreign UUID. | Add a test with `revisions==[]` + non-nil `activeRevisionID` asserting `activeRevisionIDNamesNoStoredRevision`. | §4 line 220; 06 §7.4 |
| `revision-decode-peak-memory-full-snapshot` | `RevisionStateBlobCodec.swift:174` | memory / peak | For one maxed-out item, decode holds wire `[StoredRevisionV1]` (256 MiB), built `[ContentRevision]` (COW-shares buffers), and in hydrate the 128 MiB `CanonicalContent` simultaneously; Darwin JSONDecoder materializes the full base64 text tree (~4/3 payload), so a 256 MiB revision blob peaks ~600-780 MiB transiently on-actor. 2× envelope is documented headroom (`:374`). | Release wire `[StoredRevisionV1]` after the `[ContentRevision]` build, or build incrementally dropping each buffer as consumed. Streaming JSON only if Darwin measurement (open question 2) shows it's unacceptable. | §4; `Schema.swift:61`; `HistoryCore/Limits.swift:190,193` |
| `blob-decode-runs-on-authority-actor` | `RevisionStateBlobCodec.swift:174` | concurrency (deliberate) | RECORDED as deliberate, not actionable. Blob decode (≤128 MiB canonical / 256 MiB revision JSON) runs synchronously on the HistoryAuthority actor inside the non-suspending interval (hydrate at `HistoryAuthority.swift:1285/1949/2042/2156`; no `Task.detached`/`async let`). Spec-MANDATED by §5's fence. | No change. If large-item latency appears: pre-decode blobs into values off-actor, perform only the fence check on-actor — only after a review confirms fence compatibility (open question 3). | §4, §5, §7.3, §13; 04 §2 |

> **Remediation status (2026-08-09):** `pagecursorcodec-no-unit-tests`,
> `pagecursor-encode-swallows-failure-as-empty-payload`,
> `date-fields-not-finiteness-validated`, and
> `revision-empty-list-nonnil-active-id-untested` are **in-progress**.
> Cursor round trips/rejections now have a direct suite and encode failure is
> surfaced at minting as an invariant. Revision/occurrence dates reject NaN
> and infinities; recent/search/retention validate consumed scalar dates before
> sorting or planning, and a public capture rejects a non-finite `observedAt`
> before fingerprinting. Persistent scalar-corruption and empty-list/active-ID
> regressions are present. `wire-format-unpinned-jsonencoder-strategies`,
> `pagecursor-decode-has-no-pre-parse-envelope`,
> `cursor-anchor-decode-leniency`, and
> `pagecursor-rejection-not-equatable` are also **in-progress**: the shared
> wire format pins Date/Data strategies with fixed bytes, cursor decode gates
> worst-case escaped input before JSON allocation, validates every known
> mutually-exclusive/bounded anchor/query field, and explicitly tolerates only
> semantically inert unknown metadata under v1. Direct regressions are present.
> `revision-active-id-linear-scan` is **in-progress** because decode now reuses
> its already-proven unique-ID set. `overflow-branch-reports-intmax-found` is
> **documented**: `Int.max` is explicitly the checked-overflow diagnostic
> sentinel, not a claimed mathematical total.
> `revisionstate-dual-rejection-enum-paired-catch-hazard` is **in-progress**:
> revision/scalar cases now live in the single `CodecRejection`, every test
> asserts that vocabulary, and one module-wide `mapCodecFailure` replaces the
> two paired catches. macOS CI and the public symbol snapshot are pending.
>
> **Codec-cleanup disposition (2026-08-09):**
>
> - `canonical-decode-three-passes`,
>   `revision-decode-repeated-representation-passes`,
>   `validatecoverage-double-collection`, and
>   `decode-envelope-magic-numbers-duplicated` are **in-progress**. Canonical
>   transcription now occurs inside its validating pass; revision decode
>   validates/transcribes each stored representation once and reuses one type
>   list; signature coverage builds its lookup during the orphan check; and
>   `CodecDecodeEnvelope` is the single owner of all four formulas/constants.
>   Existing rejection-order and round-trip suites cover these behavior-neutral
>   refactors; macOS Swift 6 build/test remains required before `fixed`.
> - `revision-effectivecontent-no-domain-backstop` is **documented**.
>   `EffectiveContent` intentionally has no throwing validator (02 §2.4); the
>   revision codec now marks its pre-checks as the complete persisted-state
>   boundary immediately before construction.
> - `processmarker-no-schema-binding` is **not-a-defect**. The authoritative
>   pagination spec and code comments now say process-instance marker. A schema
>   deployment necessarily replaces the process/Authority and therefore mints
>   a new UUID; v1 has no in-process schema transition, so adding a second
>   schema component would not invalidate any cursor the process UUID permits.
> - `count-bound-enforced-after-json-allocation` is **deferred** to a v2 wire
>   format, owned by HistoryStorage. The byte envelope is the intentional
>   pre-allocation gate; Foundation JSON must materialize arrays before semantic
>   count checks. Trigger: supported-runner allocation evidence breaches Part
>   VI gates, or an untrusted import makes store bytes adversarial. Residual
>   risk: a corrupt but sub-envelope local blob can transiently allocate more
>   elements than the semantic count bound before failing closed.
> - `fresh-jsondecoder-decoder-per-call` is **deferred**, owned by the
>   HistoryStorage performance pass. Fresh mutable coders avoid unsafe sharing
>   across static codec calls/actors. Trigger: profiling attributes material
>   wall time or allocation pressure to coder construction. Residual risk is
>   bounded allocation churn; parse and payload allocation remain dominant.

### Nit

| ID | file:line | category | summary | recommendation | spec ref |
|---|---|---|---|---|---|
| `pagecursor-decode-has-no-pre-parse-envelope` | `PageCursorCodec.swift:312` | dos-envelope / defense-in-depth | `decode` passes `payload` straight to JSONDecoder with no envelope pre-check, unlike the 4 blob codecs. Cursor is in-memory, package-scoped (`Requests.swift:30-34`), per-process UUID cannot survive restart, every failure → `.snapshotExpired`. DoS surface is theoretical. | Optional: add `cursor.payload.count <= <small fixed bound>` for parity, or document the categorical §6 exemption. Do NOT re-flag as a public-API hole. | 04 §6 |
| `cursor-anchor-decode-leniency` | `PageCursorCodec.swift:216` | validation / defense-in-depth | `StoredOrderingAnchor.init(fromWire:)` accepts a negative `pinnedOrdinal` on a defaultOrder anchor and silently ignores fields of the other anchor kind; `StoredQueryShape` accepts any Int limit/text length. Not exploitable: process-marker binding + trusted read paths + `StoredQueryShape.matches` make cursor bounds redundant. | Cosmetic. Optionally add parity checks (pinOrdinal ≥0, contradictory-field rejection); cover via the new round-trip tests. | 04 §6 |
| `pagecursor-rejection-not-equatable` | `PageCursorCodec.swift:108` | api / test-enabling | `PageCursorRejection` is `Error, Sendable` but not `Equatable`, unlike both blob rejection enums. Blocks `#expect(throws: PageCursorRejection.xxx)` case assertions. | Add `Equatable` (synthesized conformance is trivial). | — |
| `fresh-jsondecoder-decoder-per-call` | `CodecRejection.swift:220` | efficiency | `makeDecoder()` returns a fresh `JSONDecoder()` per call — up to 5000/search + per exactness-guard re-fetch. Corrected: the "construction dominates parse" claim is unverified and likely backwards; factual core (no reuse) is right, impact marginal. | Acceptable. If profiling shows it matters, cache one encoder/decoder on the actor (single-writer = race-free). Do NOT assume construction dominates. | §4 |
| `overflow-branch-reports-intmax-found` | `CanonicalBlobCodec.swift:122` | error-reporting | At three sites (`CanonicalBlobCodec.swift:122`, `RevisionStateBlobCodec.swift:237/254`) the checked-arithmetic overflow branch throws `totalBytesExceedBound(found: Int.max)` instead of the actual overshot total. Cosmetic; bound drives the reject, branch near-unreachable. | Report the pre-overflow local, or document the branch unreachable for sub-envelope input. | 06 §2 |
| `revision-active-id-linear-scan` | `RevisionStateBlobCodec.swift:301` | complexity | `decode` ends with `revisions.contains(where:)` — O(R), R≤100 — when `seenRevisionIDs` (Set built at `:201`, uniqueness proved at `:275`) answers in O(1). | `seenRevisionIDs.contains(activeRevisionID)` — type-correct, semantically equivalent. | §4, D3 |
| `revision-decode-repeated-representation-passes` | `RevisionStateBlobCodec.swift:266` | complexity | Per revision, walks `stored.representations` four times and allocates a fresh `[String]`. Bounded (100 revs × 32 reps); `SignatureBlobCodec.swift:127` does the same ephemeral `.map(\.typeIdentifier)`. | Fuse into one accumulating pass: validate+accumulate `revisionBytes`, collect type-id `[String]` once (reused for order check AND containment), build `ContentRepresentation` in-loop. | §4 |
| `validatecoverage-double-collection` | `SignatureBlobCodec.swift:163` | complexity | `validateCoverage` builds a `canonicalTypes` Set AND `entriesByType` Dict, iterates entries twice (orphan check, dict build) + canonical reps twice. Bounded by 32; constant-factor. | Fuse the orphan-check loop and dict-build loop into one entries-side pass. | §4 |
| `decodewire-internal-test-seam-bypasses-envelope` | `CanonicalBlobCodec.swift:196` | api-surface / defense-in-depth | `decodeWire`/`encodeWire` are internal (documented test-only seams); nothing in the type system prevents a future same-module caller from invoking `decodeWire` on attacker-influenced durable bytes, skipping `blobExceedsDecodeEnvelope`. No current bypass. | Acceptable; optionally gate behind `@_spi(Testing)` to make the seam explicit. | §4 |
| `decode-envelope-magic-numbers-duplicated` | `CanonicalBlobCodec.swift:161` | maintainability | `maximumBlobBytes` envelope arithmetic (multipliers 2×, 8×; constants 256/128/4096) is re-derived with separate prose in 4 codecs (`CanonicalBlobCodec.swift:161`, `SignatureBlobCodec.swift:207`, `EffectiveTypeIdentifiersBlobCodec.swift:106`, `RevisionStateBlobCodec.swift:385`). A Part VI table change needs four coordinated edits; under-size rejects valid blobs, over-size weakens the DoS gate. | Derive all four from one `HistoryLimits`-parameterized helper, or centralize the per-codec constants in one named block referencing Part VI. | §4; 06 §2 |
| `effective-type-identifiers-blob-inline-decoded-on-actor` | `Schema.swift:69` | NON-ISSUE (recorded) | `effectiveTypeIdentifiersBlob` is inline (no `.externalStorage`), JSON-decoded per row on the actor. Inline is CORRECT for a ≤32-identifier blob; per-row micro-parse negligible. | No change; optionally add a Schema comment noting inline is deliberate for small read-on-actor blobs. | §3.1, §14.1 |
| `canonicalsignatureblob-also-inline-no-externalstorage` | `Schema.swift:64` | NON-ISSUE (recorded) | `canonicalSignatureBlob` also inline, decoded on actor at startup (`buildSignatureIndexAtStartup`) and capture-path rebuild. Inline is correct for a small scanned blob. | No change. | §13, §3.1 |

## 4. Complexity analysis

| Function (file:line) | Current cost | Reduction opportunity |
|---|---|---|
| `searchCorpusSnapshot` (`HistoryAuthority.swift:1805`) | Time: O(N) fetch + O(N) per-row codec decode + O(N log N) in-memory sort, **rebuilt every request** (N≤5000); Space: O(N) inline String copy (~1.25 GiB worst case). | O(delta) amortized on `ChangePosition`-keyed invalidation + O(1) on cache hit, via a position-keyed snapshot cache at the Authority/SwiftDataHistory layer. **Highest-leverage reduction in the module.** |
| `orderUnpinnedLane` exactness guard (`HistoryAuthority.swift:2360`) | Time: O(N) re-fetch + O(N log N) re-sort on a page-boundary tie. | No cheap predicate fix exists (see refuted). Real reduction requires a STORED deterministic tie-break (monotonic ordinal / SQLite COLLATE) so in-memory re-sort is never needed — a schema change. |
| `RevisionStateBlobCodec.decode` active-revision lookup (`:301`) | Time: O(R) `revisions.contains(where:)` per decode (R≤100). | O(1) via `seenRevisionIDs.contains(activeRevisionID)`, reusing the Set built at `:201` (uniqueness proved `:275`). |
| `RevisionStateBlobCodec.decode` per-revision reps | **Remediated, macOS verification pending:** one stored-representation pass validates bytes, accumulates totals, transcribes Domain values, and collects one reusable type list. | No further reduction justified under the 100×32 bounds without profiling. |
| `CanonicalBlobCodec.decode` | **Remediated, macOS verification pending:** one validation/transcription pass plus the Domain validator's defensive pass. | Keep the Domain backstop; it catches invariant drift. |
| `SignatureBlobCodec.validateCoverage` | **Remediated, macOS verification pending:** the orphan check and `entriesByType` construction share one entries-side pass. | Canonical type-set construction and final coverage validation have distinct purposes. |
| `hydrate` (`FactLoaders.swift:106`) | Time/Space: decodes full revision blob (≤256 MiB) per item even when only the active revision is consumed by paste/thumbnail. | Active-only decode path (deferred — gated by the dual-enum fold; secondary to the corpus cache). |

## 5. Efficiency notes

- **Highest leverage:** add a `ChangePosition`-keyed `SearchCorpusSnapshot` cache. Eliminates the per-keystroke / per-page / per-observe-wake full rebuild — currently fetch + scalar copy + sort of up to 5000 rows on the serial writer, discarded every time.
- **Fresh JSON coders (deferred pending measurement):** static codec entry points may execute under different actors, while Foundation coders are mutable. Do not introduce shared coder state merely to remove an unmeasured cheap allocation; profile first, then place any cache behind an explicit isolated owner.
- **Ephemeral type-id arrays (remediated):** revision decode now collects one bounded type list while validating/transcribing and reuses it for normalization and containment.
- **Set-reuse:** `seenRevisionIDs.contains(activeRevisionID)` at `RevisionStateBlobCodec.swift:301` reuses the already-built Set and removes 100 UUID unwraps per worst-case decode.
- **Pass fusion (remediated):** Canonical decode is two passes including its Domain backstop; signature coverage performs one entries-side pass.
- **Off-actor build (conditional):** if/when a §5-compatible snapshot indirection is confirmed (open question 3), move the `searchCorpusSnapshot` BUILD off-actor, leaving only the fence check on the serial writer — unblocks capture/pin/revision during corpus construction.

## 6. Security & edge-case notes

- **Pre-parse envelope coverage:** the 4 blob codecs all gate durable decode behind `blobExceedsDecodeEnvelope` checked BEFORE `decodeWire` (`CanonicalBlobCodec.swift:161`, `SignatureBlobCodec.swift:207`, `EffectiveTypeIdentifiersBlobCodec.swift:106`, `RevisionStateBlobCodec.swift:385`). This is the primary DoS surface and it is correctly defended; the count-after-parse allocation (`count-bound-enforced-after-json-allocation`) is bounded transitively by the byte envelope. The `PageCursorCodec` has **no** envelope — categorically exempt (in-memory, package-scoped, per-process, every failure → `.snapshotExpired`); record, do not re-flag.
- **Decode-surface test seam:** `decodeWire`/`encodeWire` are `internal` with nothing in the type system preventing a future same-module caller from skipping the envelope on attacker-influenced durable bytes. No current bypass; consider `@_spi(Testing)` to make intent explicit.
- **NaN/Infinity Dates:** native SwiftData `Date` columns bypass JSON, so a corrupt store can carry NaN/Infinity `firstCopiedAt`/`lastCopiedAt`/`createdAt` into `decodeOccurrence`. NaN self-protects on the ordering check; a NaN revision `createdAt` survives and corrupts sort (`date-fields-not-finiteness-validated`).
- **Process-marker binding:** cursor forgery across processes is blocked by the per-process UUID marker; within-process, request-side limit/text validation plus `StoredQueryShape.matches` defend shape parity. A schema deployment necessarily replaces the process and Authority, so the new random UUID also invalidates every pre-deployment cursor; v1 has no in-process schema transition.
- **Silent encode regression:** `PageCursorCodec.encode` swallows failure to an empty payload that decodes as `.snapshotExpired` — invisible at the invariant layer; a debug assert would make a regression audible (`pagecursor-encode-swallows-failure-as-empty-payload`).

## 7. Concurrency / isolation notes

- **Single-writer fence (§5) is correctly observed and load-bearing.** All blob decode (≤128 MiB canonical / 256 MiB revision JSON) runs synchronously on the HistoryAuthority actor inside the non-suspending read interval; no `Task.detached`/`async let` exists on the decode path. This is spec-mandated — `blob-decode-runs-on-authority-actor` is RECORDED deliberate, not an oversight; do not re-flag.
- **The actor does double duty — fence AND computation venue.** §5 mandates the fence on-actor (correct). The implementation ALSO runs O(N) corpus materialization (`searchCorpusSnapshot`: fetch + per-row decode + O(N log N) sort) and O(R) blob decode (hydrate) on the same serial writer. The fence needs the actor; the materialization does not. §14.2 sanctions a two-step snapshot-then-check shape, but the code collapsed both onto the actor, so a 5000-row corpus rebuild blocks every capture/pin/revision. The cache absence compounds it.
- **`searchCorpusSnapshot` has exactly one legal suspension point** (`suspendIfRequested(.readEntry)` at `:1810`) before any context is live — the WS12 seam. Cache reuse must not introduce a suspension while a fetched row/complete fact is live, or it violates the fence (open question 3).
- **Cached JSON coder on-actor is race-free** precisely because of single-writer — the only safe place to share mutable coder state.

## 8. Test-coverage gaps

- **`PageCursorCodec` — zero unit tests.** No test references `PageCursorCodec`, `PageCursorRejection`, `malformedCursor`, `unknownCursorVersion`, or `processMarkerMismatch` anywhere in Tests/. The 4 rejection cases, wire round-trip, and unknown-kind branches are exercised only indirectly via WS18's facade (asserts only the mapped `.snapshotExpired`). The 4 blob codecs each have a dedicated one-rejection-per-§4-check suite — the asymmetry is stark. Blocked in part by `PageCursorRejection` not being `Equatable`.
- **`.fuzzyUnpinned` cursor resume — live and uncovered.** The anchor is produced (`SearchWorker.swift:671-676`) and the resume loop exists (`SearchWorker.swift:139-145`), but no test combines `kind:.search` with `after:`. WS18 paginates only `.recent`; WS17 does single-page fuzzy.
- **`revisions==[]` + non-nil `activeRevisionID`** — rejected by the `contains` fallthrough at `RevisionStateBlobCodec.swift:301` but has no dedicated test (existing case is one-revision + foreign UUID). A regression moving the `contains` inside a non-empty guard would pass the suite.
- **Wire-format byte-stability** — no test asserts that `Date`+`Data` fixtures encode byte-identically across runs or across Darwin/Linux (`wire-format-unpinned-jsonencoder-strategies`). A contributor flipping `dateEncodingStrategy` to `.iso8601` would not be caught.

## 9. Notable REFUTED (provenance)

- **Exactness-guard predicate tightening (refuted).** The finding floated `lastCopiedAt == tieDate` as a tightening to bound the re-fetched set; the finding's own evidence flags this as wrong (it misses tie groups entirely above the boundary). Carried further: the only correct tighter predicate (`lastCopiedAt >= tieDate` within the anchor scope) does NOT improve the all-rows-tie worst case either. There is **no** cheap predicate-based complexity reduction here; the real fix is a stored deterministic tie-break — a schema change.
- **Per-row `JSONDecoder` cost-dominance (corrected).** The finding asserts construction "dominates per-call cost vs the actual JSON parse"; this is unverified and likely backwards — parsing dominates, construction is a cheap allocation. The factual core (no reuse, per-row allocation, up to 5000/search) is correct and the cached-decoder micro-optimization is still valid; impact is smaller than implied. Kept at nit.
- **`searchCorpusSnapshot` memory framing (corrected).** ~1.25 GiB assumes 5000 rows EACH at the 256 KiB `searchBody` cap. Real stores have small `searchBody`s and `userMaximumUnpinnedItems=200` default. The architectural defect (no cache, Authority-bound, full rebuild per keystroke/page/wake) is real, hot-path, and stands at major — but the figure is a worst-case upper bound, not an expectation. Same caveat for the hydrate ~600-780 MiB transient (single maxed-out item).
- **`hydrate` full-revision-blob severity (downgraded).** Verified `pastePayload` (`HistoryAuthority.swift:2046`) calls `effectiveContent(of:)` selecting only the active revision — the wasted-decode claim is correct, but the prior cycle already downgraded the structurally-identical `revision-decode-peak-memory` to minor with the same logic; the on-actor fence cost (the actually scary part) is mandated by §5 and unchanged by the fix; trigger is pathological; fires per-paste not per-keystroke. Major→minor.
- **UInt64 fingerprint JSON round-trip (not re-flagged).** Correctly refuted last cycle — `CanonicalBlobCodecTests.swift:33-57` and `SignatureBlobCodecTests.swift:28,111` assert `UInt64.max` fingerprints with byte-level encode→decode→re-encode equality on Darwin CI. Confirmed not worth re-flagging.

## 10. Open questions / residual risk

1. **Contract decision (resolves the headline cluster — must be MADE, not re-discovered).** Is the v1 contract for projection scalars "decode re-verifies" (add `CodecValidation.validateProjectionScalars` called from all four entry points, mirroring `decodeOccurrence:340-349`) OR "projection bounds are write-side-only" (retreat §4 line 225 to §15 scope, delete the false `ContentProjector.swift:29-30` sentence, fix `AUDIT S3-R4`)? The current state satisfies NEITHER — spec, code comment, and audit all assert a check that does not exist.
2. **Darwin measurement (sets the severity floor for the corpus-cache major and the headline's memory amplification).** What is the measured peak-RSS and wall-clock of one `searchCorpusSnapshot` at 5000 retained rows — with realistic `searchBody` sizes AND worst-case 256 KiB bodies — and does SwiftData eagerly materialize inline String columns under `propertiesToFetch=[title, searchBody]`? Without this, the major efficiency finding rests on a structural upper bound.
3. **Fence-compatible off-actor build (gates the highest-leverage fix).** Does a §5-compatible snapshot indirection exist that lets `searchCorpusSnapshot`'s BUILD (fetch + scalar copy + sort) run off-actor, with only the version-fence check on the HistoryAuthority writer? Does §14.2's two-step shape actually require the full build on the serial writer, or is that an implementation collapse?
4. **Write-path forecast (sets whether the headline stays defense-in-depth or rises toward critical).** Is ANY non-test, non-`ContentProjector` write path planned for v1.x/v2 (migration-import, backup-restore, XPC relay, direct SQLite, dedup-resurrect) that would make the unguarded `HistoryItemRow.init` + missing projection-scalar decode checks an ACTIVE rather than defense-in-depth risk?

## 11. Prioritized recommendations (highest-ROI first)

1. **Resolve the projection-scalar contract (open question 1), then implement to match.** Preferred: add `CodecValidation.validateProjectionScalars(title:searchBody:schemaVersion:limits:)` + a `CodecRejection` case, called from all four entry points via ONE shared helper; AND add a precondition/guard in `HistoryItemRow.init` (`Schema.swift:79`) as the write-side single owner. This collapses the headline major AND its five duplicate findings AND the structural root cause in one coherent change. If the team instead chooses write-side-only, delete the false claims in §4/`ContentProjector.swift:29-30`/`AUDIT.md S3-R4` — do not leave a documented invariant with no owner.
2. **Add a `ChangePosition`-keyed `SearchCorpusSnapshot` cache** at the Authority or SwiftDataHistory layer (invalidated only when `ChangePosition` advances). Single highest-leverage efficiency fix in the module; removes the per-keystroke/page/observe full rebuild from the serial writer.
3. **Pin the wire-format coder strategies.** In `CodecRejection.swift:220` `makeEncoder`/`makeDecoder`, explicitly set `dataEncodingStrategy = .base64` and `dateEncodingStrategy = .deferredToDate`, and add one byte-stability test. Costs nothing; prevents the silent-durable-corruption class on a versioned format.
4. **Fold `RevisionStateCodecRejection` into `CodecRejection`** and consolidate the duplicated `mapCodecFailure`. Removes convention-based coupling and the drift-prone duplication the code itself flags as pending — pays the named refactor debt.
5. **Add `PageCursorCodecTests.swift`** (round-trip all 4 shape×anchor combos; the 4 rejection cases; unknown-kind defaults; `.fuzzyUnpinned`/exact/regexp resume page-2) and make `PageCursorRejection: Equatable`. Closes the most glaring coverage asymmetry vs the blob codecs and covers live, currently-untested production code.
6. **Fix `PageCursorCodec.encode` failure handling** (delete unreachable `encodingFailed` or make `encode` throw it; reconcile the `:270-273` header doc with the `:285-291` inline behavior) so a regression is not invisible at the invariant layer.
7. **Targeted low-risk reductions (implemented; macOS verification pending):** unique-ID set reuse, Canonical two-pass decode, one-pass signature entry indexing, fused revision representation processing, and centralized envelope formulas.
8. **Defer unless workload demands:** the `exactness-guard` stored tie-break, a streaming/count-prefixed durable wire format, and isolated JSON coder reuse. Each now has an owner, measurement trigger, and residual-risk statement above.
