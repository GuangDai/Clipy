# HistoryStorage — Search, Reads & Observation, Fact Loaders — V1 Verified

> **Module:** `Sources/HistoryStorage/` search + reads + observation + fact loaders (4 files, ~1,925 LOC): `SearchWorker.swift` (880), `ContentProjector.swift` (232), `FactLoaders.swift` (498), `MutationFactLoaders.swift` (315).
> **Method:** 3-cycle 审查→调研→批评 workflow — 22 agents, ~92 min, 2.53M tokens, 601 tool calls. Full 3 cycles completed (no cap interruption). Confirmed counts grew 30→32→37 across cycles.
> **Verdict:** the **most severe module in the audit**. **1 critical, 8 major, 21 minor, 7 nit.** A process-crash bug from ordinary user input, a ReDoS self-DoS gap, and a cluster of multi-gigabyte memory-materialization defects — most rooted in the pinned Fuse 1.4.0 dependency and in pure-algorithm helpers that are `private` (hence untested, which is *why* the critical shipped).
>
> **Orchestrator cross-check (independently confirmed):**
> - **`fuse-bitap-crash-and-corruption` (CRITICAL)** — confirmed via Swift language semantics (the Fuse source isn't checked out on this Linux host, but the defect follows deterministically): `<<` is a *masking* shift, so `1 << (len-1)` wraps to a wrong low bit for `len > 64` (corrupt mask → wrong/empty matches for len 65-89); and `(1 << 63) - 1` = `Int.min - 1` **traps** under Swift's overflow-checking `-` (uncatchable process crash for len ≥ 90, reachable by pasting a ≥90-char string). `SearchWorker.swift:577` enforces a 256-char bound the pinned 64-bit bitap cannot represent. The fix (lower `maximumFuzzyQueryCharacters` 256→64) is correct.
> - **`regex-overlapping-alternation-redos` (MAJOR)** — confirmed from my prior read of `containsRejectedPatternShape` (423-509): the switch has no `|` case and the reject condition requires `isQuantified && bodyContainsQuantifier`, so `(a|a)+` / `(a|ab)+` (quantified alternation of literals) is admitted despite being textbook catastrophic backtracking; the non-`async` `page()` has no cancellation → actor self-wedge.
> - **`search-corpus-materializes-full-inline-searchbody` (MAJOR)** — confirmed: `Schema.swift:68` `searchBody` is a plain inline `String` (no `.externalStorage`, unlike the blobs); `SearchCorpusRow` binds it → up to ~1.22 GiB inline materialization per corpus capture.
> - **`projection-joins-full-body-before-truncation` (MAJOR)** — confirmed from `ContentProjector.project` (`:109`): `bodyParts.joined(separator:"\n")` materializes the full body (up to 128 MiB) before `truncatedToUTF8ByteLimit` discards ~99.8%.
>
> **Framing note (from C3-Critique):** the pinned Fuse 1.4.0 is the single root of four distinct clusters — (1) correctness (64-bit bitap vs 256-char bound), (2) throughput (its non-Sendability mandates the `SearchWorker` actor, serializing all evaluation), (3) DoS amplification (that serialization turns a slow regex into an actor-wedge), and (4) the bitap width cap on fuzzy usefulness. The module's two safety stories (the regex guard, the 256-char bound) are *syntactic proxies for semantic properties*, decoupled from the engine they protect.
>
> Line numbers as-of HEAD `8f316c9`.
>
> **Remediation tracking (2026-08-09):** findings remain historical audit
> evidence; the `Status` column records work against the current tree. A code
> change is not marked `fixed` until its macOS regression test is green.

---

## HistoryStorage — Search, Reads & Observation, Fact Loaders (V1-Verified)

> Verification artifact for `Sources/HistoryStorage/` (search worker, read/observation facade, fact loaders, content projection, schema). Full xhigh, 3-cycle review-research-critique. All file:line citations and the bitap / ReDoS / inline-column mechanisms below were re-verified against source during report synthesis.

### 1. Executive summary

The module's **architecture is sound** — the two-step value pipeline (capture a Sendable scalar snapshot in one non-suspending Authority interval, then evaluate off-actor) correctly isolates both the non-Sendable Fuse matcher and the non-Sendable `@Model` rows, and the WS12 suspension-gate seam is well-placed. **The headline is a single critical correctness defect**: the 256-Character fuzzy-query bound (`SearchWorker.swift:577`) admits patterns the pinned **Fuse 1.4.0** 64-bit-Int bitap cannot represent — query length 65–89 silently returns empty results, and length ≥90 makes Fuse's bitap reach `(1<<63)-1` which **traps** under Swift checked arithmetic, an **uncatchable process crash** from ordinary user input (paste a 200-char string). A second **major** issue is an incomplete ReDoS guard that admits textbook catastrophic-backtracking alternations (`(a|a)+`, `(a|ab)+`). The remaining findings are efficiency (a 1.22 GiB inline-`searchBody` materialization on the read path, a 128 MiB join-before-truncate in the projector, full-`Array(body)` excerpting in exact mode), test-coverage (the frozen pure helpers are all `private`, so the facade-only tests never exercised the bitap boundary), and a cluster of minor fail-closed/robustness hairline cracks. One architectural move — replacing Fuse with a Sendable, >64-bit-word or chunked matcher — dissolves four finding clusters at once.

### 2. Scope & method

**Files examined (all under `/lzcapp/document/Projects/ClipboardManager/`):**
- `Sources/HistoryStorage/SearchWorker.swift` (actor; exact/regexp/fuzzy evaluation; `containsRejectedPatternShape`; `bodyExcerpt`; UTF-16 translation)
- `Sources/HistoryStorage/ContentProjector.swift` (textual eligibility, decoding precedence, newline normalization, truncation, fallback title)
- `Sources/HistoryStorage/FactLoaders.swift` + `MutationFactLoaders.swift` (capture/pin/mutation fact loading; scalar isolation; invariant producers)
- `Sources/HistoryStorage/SwiftDataHistory.swift` (facade: `browse`/`observe` routing, search observation producer)
- `Sources/HistoryStorage/HistoryAuthority.swift` (scalar snapshots: `searchCorpusSnapshot`, `recentPage`, revision projection)
- `Sources/HistoryStorage/Schema.swift` (row shape; `@Attribute(.externalStorage)` placement)
- `Sources/HistoryStorage/PageCursorCodec.swift` (cursor anchor encoding)
- `Tests/HistoryStorageTests/WS17SearchModesTests.swift`, `WS18*`, `WS12ObservationRaceTests`, `ScalarReadIsolationProofTests`
- `Package.swift` (Fuse pin: `krisk/fuse-swift@26ba868`, Fuse 1.4.0)

**Spec sections cross-referenced:** `docs/03b-instruction-set.md §8` (search instruction set), `docs/04-coherence.md §5/§6/§7` (observation, cursor, coherence), `docs/05-authority-kernel.md §7.1/§12/§13/§14.2/§15/§16` (fact loading, no-blob-decode proof, snapshots, projection, failure mapping), `docs/06-cross-cutting.md §2/§7.5/§8/§9` (limits, scalar-isolation gate, WS contracts, cache law), `docs/02-domain.md §2.1/§3.2/§5.1-5.5` (type-identifier invariant, D8/D9/D12), `docs/AUDIT.md §4b` (IND-03, S5 series).

**Process:** serial 3-cycle review → research → critique at xhigh effort (~68 min/module). Cycle 1 surfaced the bitap/ReDoS/inline-column candidates; cycle 2 (research) pinned the exact bitap failure modes against Swift's smart-shift `<<` semantics, refuted the `1<<99` "bit-wrap" claim, downgraded `search-reeval-per-page` from major→minor against the explicit no-cache spec language, and corrected the ReDoS impact scope (`.recent` browse bypasses the worker); cycle 3 (critique) merged ~25 sub-findings into the ranked clusters below and verified every file:line citation against source.

### 3. Findings

#### Critical

| ID | Status | file:line | category | summary | recommendation | spec ref |
|---|---|---|---|---|---|---|
| `fuse-bitap-crash-and-corruption` | **in-progress** (2026-08-09; macOS CI pending) | `SearchWorker.swift:577` | correctness / DoS | The 256-Character fuzzy-query bound admits patterns the pinned Fuse 1.4.0's 64-bit-Int bitap cannot represent: query length 65–89 silently yields empty results (Swift smart-shift `<<` returns 0 for shift ≥ bitWidth, so mask=0 and the completion check never fires), and length ≥90 makes `Fuse._search` reach `i=63` where `(1<<63)-1 = Int.min-1` **traps** under Swift checked arithmetic — an **uncatchable process crash** (not a thrown `Error`) from ordinary user input. Corruption is deterministic and uniform (`createPattern` runs once at `:585` and is reused across all rows). | Lowered `HistoryLimits.maximumFuzzyQueryCharacters` from 256 → **64**, made custom profiles over 64 invalid, amended `03b §8` / `06 §2` / WS17, and added the public-facade sweep `[1,63,64,65,89,90,100,200,256]`. Pending supported-runner verification before `fixed`. | `docs/03b §8`; `docs/06 §2`; `AUDIT.md` V1V-03C-001 |

#### Major

| ID | file:line | category | summary | recommendation | spec ref |
|---|---|---|---|---|---|
| `regex-overlapping-alternation-redos` | `SearchWorker.swift:423` | security / DoS | `containsRejectedPatternShape`'s switch (`:449-506`) has **no `|` case** (falls to default) and the reject condition is `isQuantified && bodyContainsQuantifier` (`:482`), so quantified alternation of overlapping/identical arms with no inner quantifier (`(a|a)+`, `(a|ab)+`, `(.|a)+`, `(a|a)*`) is **admitted** despite being textbook catastrophic-backtracking shapes. Against the 1,000-char prefix × up-to-5,000 rows, ICU's NFA explores ~2^n paths and the non-async `page()` has no cancellation, wedging the actor and stalling every concurrent/observe search (self-DoS). `.recent` browse is unaffected — it bypasses the worker (`SwiftDataHistory.swift:246-250`). | Either (a) over-reject ALL quantified alternation: add a `|` arm that `markInnermostGroup()`s, then reject any quantified group whose body contained alternation (simple, rejects some safe patterns like `(a|b)+`); or (b) the only **complete** fix — since Foundation/ICU expose no step-limit/cancellation on `NSRegularExpression`, wrap `firstMatch` in a cooperative watchdog on a detached `Task` with a timeout. (b) is **blocked** by `page()` being synchronous (`:103`): it requires making `page()` async, propagating to `SwiftDataHistory.browse` and the observe producer. Add a regression test with `(a|a)+b` / `(a|ab)+c` against a long all-`a` body asserting bounded completion. File a spec clarification: `03b §8`'s enumerated rejection list is provably incomplete vs its own "features that risk catastrophic backtracking" prose. | `docs/03b §8`; `AUDIT.md` S5-R2-1/R2-2 |
| `search-corpus-materializes-full-inline-searchbody` | `SearchWorker.swift:105` (builder `HistoryAuthority.swift:1908`; storage `Schema.swift:68`) | efficiency / memory | `searchBody` is stored **INLINE** (`Schema.swift:68` has no `@Attribute(.externalStorage)`, unlike `canonicalBlob:58`/`revisionStateBlob:61`), and `searchCorpusSnapshot` lists `\.searchBody` in `propertiesToFetch` (`HistoryAuthority.swift:1862`) and binds `row.searchBody` into every `SearchCorpusRow` (`:1908`) held across `page()` — so the read path materializes up to **5,000 × 256 KiB ≈ 1.22 GiB** of inline String bytes even though only ≤1,000/≤5,000-Character prefixes are ever scanned. The §7.5 "no blob decode" gate explicitly does not cover inline-value memory. | Either (a) pre-truncate `searchBody` to the longest mode prefix (5,000 chars) at capture time in the `SearchCorpusRow` builder (needs a spec nod since `05 §14.2` fixes the row shape with full `searchBody`), OR (b) move `searchBody` to `@Attribute(.externalStorage)`. Add a memory-footprint test under the 5000×256 KiB corpus. Materialization is definite (access forced at `:1908`); the open question is whether SwiftData faults eagerly (see open questions). | `docs/05 §14.2`; `docs/06 §2`, §7.5 |
| `projection-joins-full-body-before-truncation` | `ContentProjector.swift:109` | efficiency / memory | `project()` materializes `bodyParts.joined(separator:"\n")` — the FULL concatenated normalized body (up to the **128 MiB** capture-byte bound across representations) — and only then passes it to `truncatedToUTF8ByteLimit` (`:109`), discarding ~99.8% past 256 KiB. On the **revision path** (`HistoryAuthority.swift:1983`) only `.title` is consumed (`ContentProjector.project(...).title`), so the entire join+truncate is **pure waste inside the serialized Authority interval**. | Replace the joined+truncate with a **streaming truncation**: iterate `bodyParts`, append each (with separator accounting) to a buffer, STOP once `maximumStoredSearchBodyUTF8Bytes` is reached. On the revision path, skip the body join entirely. Cap retained buffer at `maximumStoredSearchBodyUTF8Bytes`. | `docs/06 §2`; `docs/05 §15` |
| `exact-body-excerpt-full-array` | `SearchWorker.swift:273` | efficiency / memory | `evaluateExact` calls `bodyExcerpt` with the FULL ≤256 KiB `searchBody` (`:274`, no scan prefix — spec-mandated per `03b §8`) and `bodyExcerpt:768` runs `Array(body)`; a broad exact match over 5,000 max-size rows allocates on the order of **4 MB × 5000 ≈ 20 GB** of churned `[Character]` storage per page eval though the snippet window is ≤322 chars. Fuzzy/regexp modes (5,000-char prefix) pay ~80 KB/row, far less. | Rewrite `bodyExcerpt` to accept the caller's already-computed Character-offset range (or `String.Index` bounds) and build the ≤322-char window via `String.Index` `distance` + `Substring`, with a single bounded-window Character materialization for O(1) offset indexing. Derive both Character bounds in one `String.index` walk in `evaluateExact`. Add a broad-match test (`' '` over a max-size body, ~5000 rows) asserting bounded transient allocation. | `docs/03b §8`; `docs/06 §2` |
| `no-direct-unit-tests-for-search-projector-internals` | `SearchWorker.swift:423` | test-coverage (meta) | The frozen pure algorithms (`containsRejectedPatternShape`, `bodyExcerpt`, `fuzzyMatch`, `utf16Ranges`, `utf16PrefixOffsets`, `ContentProjector.project`/`decodedText`/`truncatedToUTF8ByteLimit`/`firstContentLine`) are all `private`/`private static`, so WS17 exercises them ONLY through the `SwiftDataHistory` facade — **zero direct coverage** of the unsafe-regexp rejection table, the excerpt edge-redistribution, the UTF-16 translation, the projector decode precedence, or the Fuse long-pattern boundary. This structural visibility choice is **why the critical bitap defect shipped undetected**. | Elevate the pure helpers to `internal` (`containsRejectedPatternShape`, `isQuantifierToken`, `intervalQuantifierEnd`, `bodyExcerpt`, `fuzzyMatch`'s translation half, `utf16Ranges`, `utf16PrefixOffsets`, `ContentProjector.project`/`decodedText`/`firstContentLine`/`typeBasedFallbackTitle`) — the `Fuse.Pattern` half of `fuzzyMatch` must stay actor-isolated (Fuse is non-Sendable). Add direct `@testable` assertions for each guard branch, `bodyExcerpt`'s six frozen steps, UTF-16 translation (BMP + supplementary-plane), and the projector decoding precedence. | `docs/03b §8`; `docs/06 §8` (WS17 facade-only stance) |
| `fuzzy-bound-test-misses-entire-corruption-range` | `WS17SearchModesTests.swift:372` | test-coverage | WS17's only fuzzy-boundary assertion is `String(repeating:"a", count:257)` (the over-bound rejection); the entire 64–256 range — and specifically the 65–89 silent-empty and ≥90 trap windows — has **zero coverage**, so the critical defect above is invisible to CI and any future regression of the bound/Fuse integration passes undetected. | Add a fuzzy-boundary sweep test exercising lengths 63/64/65 (the bitap boundary) and a ≥90 no-substring crash case (asserting bounded completion / no trap), plus 100/200/256. Best implemented after elevating helpers to `internal`. | `docs/03b §8`; finding `fuse-bitap-crash-and-corruption` |
| `test-gap-excerpt-edge-redistribution-untested` | `SearchWorker.swift:763` | test-coverage | The frozen `bodyExcerpt`'s body>320 branches (centering, before/after split with extra-AFTER, edge-overflow redistribution at `:796-803`, leading/trailing ellipsis placement, later-range clipping with UTF-16 shift at `:824-842`) are exercised by **no test** — the only body-match fixture (gamma) is ~42 chars hitting the whole-body (<320) branch. | Add fixtures: body >320 chars with the match near start / near end / exactly at a corner; a match longer than 320 chars; a snippet requiring both leading+trailing ellipsis; a multi-range fuzzy body match. Assert window bounds, before/after split, ellipsis presence, and UTF-16 offset shift. | `docs/03b §8`; `AUDIT.md` S5-03/S5-06 |
| `search-observation-path-untested` | `SwiftDataHistory.swift:430` | test-coverage | `04 §7` search-observation coherence (capture `SearchCorpusSnapshot` → evaluate off-actor → discard+recompute when an invalidation newer than the page position arrives mid-evaluation, plus the commit-during-evaluation stale-labeling property) is exercised by **no test**; `WS12ObservationRaceTests` only observes `.recent` (grep finds 0 `observe(.search)` in `Tests/`). | Add a test calling `history.observe(HistoryObservationRequest(kind:.search(...)))` consuming the `AsyncStream` across an intervening commit; assert the discard+recompute when an invalidation newer than the page position arrives mid-evaluation. Add a WS12-style SuspensionGate test driving a commit during `SearchWorker` evaluation asserting the returned page is labeled with its older position. | `docs/04 §7` |

> **Remediation status (2026-08-09):**
> `regex-overlapping-alternation-redos` is **in-progress**. The worker now
> conservatively rejects every quantified group containing alternation and
> WS17 drives `(a|a)+b` / `(a|ab)+c` against a long all-`a` row before scan;
> macOS CI is pending. The report's detached-timeout alternative is rejected:
> synchronous Foundation regexp evaluation is not cooperatively cancellable,
> so a timeout would abandon continued CPU work. `fuzzy-bound-test-misses-
> entire-corruption-range` is a **duplicate** of the critical fuzzy fix.
>
> `projection-joins-full-body-before-truncation` is **in-progress**. The
> projector now appends directly into a UTF-8-bounded accumulator and stops at
> a Character boundary; revision summaries use `projectTitle` and never build
> the search body. `ContentProjectorTests` pins the exact separator/grapheme
> boundary. macOS CI is pending.
>
> `exact-body-excerpt-full-array` is **in-progress**; its dependent
> `test-gap-excerpt-edge-redistribution-untested` is a **duplicate** of that
> canonical target. Exact
> matching converts the found bounds without a second prefix walk, and the
> excerpt helper traverses the original `String` while owning only the bounded
> retained window rather than `Array(body)`. Five direct `@testable` worked
> examples cover near-start/near-end redistribution, both ellipses, a match
> longer than the window, and supplementary-plane UTF-16 offsets. macOS CI is
> pending (`AUDIT.md` V1V-03C-005).
>
> `search-observation-path-untested` is **in-progress** only for macOS proof.
> One public-facade fixture uses the WS12 `positionRecheckEntry` seam to commit
> after an old evaluation. A second nil-in-production SearchWorker entry seam
> parks after the immutable old-position corpus is captured, commits during
> evaluation, and proves the first yield is recomputed at the exact newer
> position with the matching row. No timing-based substitute is used.

#### Minor

| ID | file:line | category | summary | recommendation | spec ref |
|---|---|---|---|---|---|
| `exact-mode-no-term-guard` | `SearchWorker.swift:228` | correctness (dead bound) | `evaluateExact` applies NO term-length guard (regexp caps at 512 Chars `:310`, fuzzy at 256 `:577`); `HistoryLimits.maximumSearchTermUTF8Bytes` (4,096) is **never enforced** against a search term anywhere in production Sources — the documented admission bound is effectively dead, and exact mode runs `range(of: hugeTerm)` over the full 256 KiB `searchBody` of every row. | Add a term-length guard at the top of `evaluateExact`, OR enforce `maximumSearchTermUTF8Bytes` at the public API (`HistoryBrowseRequest.init` / `SwiftDataHistory.browse`) symmetrically with regexp/fuzzy. Confirm whether the bound is intended to live at the UI/adapter layer. | `docs/06 §2`; `docs/03b §8` |
| `search-reeval-per-page` *(downgraded major→minor)* | `SwiftDataHistory.swift:252` | efficiency | Every continuation page re-captures all ≤5,000 scalar rows, re-sorts, re-evaluates the full corpus, then locates the anchor via O(N) `firstIndex` (`SearchWorker.swift:140`) before slicing; the cursor's existing position-recheck (`HistoryAuthority.swift:1849-1853`) already **proves** the corpus is unchanged across an unchanged position. Spec-sanctioned v1 design (`06 §9`; `04 §1/§6`), NOT a defect — the optimization belongs to the G2 graft era. Kept minor because the re-eval re-hangs a malicious regex/bitap query on every page (amplification of the ReDoS/bitap defects). | Do NOT add a v1 cache. For the G2 era: cache the captured `SearchCorpusSnapshot` keyed by `currentPosition`; emit an `[anchor:index]` dictionary alongside the evaluated array so each continuation resumes in O(1) instead of O(N) `firstIndex`. | `docs/04 §6/§7/§12`; `docs/06 §9/§3` |
| `searchworker-actor-serializes` | `SearchWorker.swift:33` | concurrency / efficiency | `SearchWorker` is an actor whose only isolated state is the Fuse matcher (non-Sendable pre-concurrency class, so confinement is Swift-6-mandated); `createPattern`/`search` are pure w.r.t. the immutable config, so the serialization of every `.search` browse and observation is **conservative throughput loss**, not a correctness need — AND it is the head-of-line-blocking amplifier that lets one slow ReDoS/bitap query stall every concurrent search. | Either expose a nonisolated evaluation (wrapping Fuse config reads safely) or maintain a small Fuse instance pool on a cooperative queue. Verify `createPattern`/`search` are truly instance-pure across the frozen parameter set. Swift 6 mandates SOME isolation for the non-Sendable Fuse — measure before committing. | `docs/01 §6`; `docs/04 §7`; `AUDIT.md §4b` |
| `capture-fact-load-fetches-same-table-2-3-times` | `FactLoaders.swift:311` | efficiency | `IngestFactLoader.loadFacts` issues 2–3 bounded full-table scans of `HistoryItemRow` in one serialized interval (`fetchRetainedIDs` id-only `:311`, `fetchRetainedInventory` id/lastCopiedAt/pinOrdinal `:326`, and on the rebuild path `rebuildSignatureIndex` id+signatureBlob `:316`); the id-only and inventory scans overlap completely (`retainedIDs` is derivable as `Set(inventory.map(\.id))`), and a third `Set` rebuild at `:330` exists solely to prove they agree. | Collapse the two scalar fetches on both paths: derive the readiness ID set from the inventory fetch (`retainedIDs == Set(inventory.map(\.id))`). On the rebuild path, additionally merge the blob fetch (blobs legitimately faulted there). | `docs/05 §7.1` steps 1/5, §12/§13 |
| `candidate-hydration-n-plus-1-queries` | `FactLoaders.swift:367` | efficiency | `loadFacts` hydrates each dedup candidate with a separate `fetchRow` (`fetchLimit:2 id==uuid`) inside a loop, so C candidates produce C individual SwiftData round-trips plus C heavy blob decodes per capture (the N+1 pattern). Typical C is 0–2 so realistic saving is negligible, but a pathological common-snippet C benefits. | Batch the candidate fetch: SwiftData `#Predicate` supports `ids.contains(row.id)` with a bounded set, collapsing C round-trips to 1. Semantics preserved (duplicate IDs still trapped by hydrate's coverage check). | `docs/05 §7.1` step 3, §5 |
| `fuzzy-double-lowercase` | `SearchWorker.swift:710` | efficiency | `fuzzyMatch`'s alignment guard `scanned.lowercased().count == scanned.count` (`:710`) allocates a full lowercased copy of the ≤5,000-char prefix per row purely to prove Character-count invariance (then discards all but `.count`), and `Fuse._search` lowercases the same string AGAIN internally (`Fuse.swift:151`, byte-identical) — two full O(prefixLen) lowercase passes per scanned title/body per row × 5,000 rows × every continuation page. | Either (a) lowercase once and thread the copy through to a Fuse entry point that skips its internal lowercasing (verify Fuse 1.4.0 honors `isCaseSensitive==true` to skip `text=text.lowercased()` at `Fuse.swift:151`), or (b) replace the runtime guard with a documented invariant + debug-assert (the REFUTED unicode findings confirm no current scalar shifts Character count under `lowercased()`). | `docs/03b §8` |
| `scalar-reads-rely-on-unverified-externalstorage-faulting-suppression` | `FactLoaders.swift:196` | verification gap (perf) | `fetchRetainedInventory`/`fetchRetainedIDs`/`recentPage`/`searchCorpusSnapshot`/`validateFinalPinOrder` all set `propertiesToFetch` to keep scalar reads blob-free, and `ScalarReadIsolationProofTests` corrupts the blobs to prove no DECODE dependency — but whether SwiftData honors `propertiesToFetch` to suppress `.externalStorage` **FAULTING** (not just decode) is **unverified**; if it faults, these bounded scalar loads become O(N × blob-bytes). This is the highest-leverage open perf question in the module, gating ≥6 perf ratings. | Run ONE Instruments/DTrace trace of the scalar read paths under the 5,000-row corpus and observe whether `canonicalBlob`/`revisionStateBlob` bytes are faulted. If suppressed, downgrade the related perf findings; if faulted, several ratings rise. This single measurement should gate v1 sign-off. | `docs/05 §13/§14.1`; `docs/06 §7.5` |
| `fuzzy-score-in-cursor-anchor-is-brittle` | `SearchWorker.swift:671` | robustness (coupling) | The continuation cursor binds `.fuzzyUnpinned(score:lastCopiedAt:id:)` (`PageCursorCodec.swift:99`), embedding the internal Fuse `Double` score in the ordering anchor; pagination then depends on bit-exact reproduction of that Double via synthesized `Equatable` (`SearchWorker.swift:140-144`). No CURRENT bug (Fuse is deterministic; a tampered cursor can only force `.snapshotExpired` or correct resumption), but the design COUPLES pagination stability to floating-point determinism — any future perturbation (Fuse upgrade, lowercasing revision, cross-arch FP variance) silently mass-expires in-flight fuzzy cursors mid-pagination. | Key the fuzzy-unpinned anchor on `(lastCopiedAt, id)` plus a stable position in the sorted unpinned list, or store an ordinal — decoupling pagination from FP determinism while preserving the `04 §7` tie-breaker tail. Fail-closed today, so this is hardening. | `docs/04 §6/§7`; `docs/03b §8` line 91 |
| `fuzzy-body-match-wastes-full-prefix-utf16-walk` | `SearchWorker.swift:728` | efficiency | `fuzzyMatch` always computes `utf16Ranges` via `utf16PrefixOffsets` over the full ≤5,000-Character scanned prefix (`:728`), but the body-match caller discards it (`:617` passes only `characterRanges` to `bodyExcerpt`, which recomputes UTF-16 offsets over the ≤322-Character window) — so every fuzzy body match pays a wasted full-prefix O(N) walk plus its `[Int]` offsets-array allocation. Only the title lane consumes the result. | Split `fuzzyMatch` so `utf16Ranges` is computed only on the title-match lane (`:605` consumes it); the body-match lane (`:617`) needs only `characterRanges`. | `docs/03b §8` |
| `test-gap-fuzzy-nonascii-utf16-untested` | `SearchWorker.swift:702` | test-coverage | No fuzzy test exercises non-ASCII Characters (combining marks, supplementary-plane/emoji, U+0130) through the `lowercased().count==count` alignment guard (`:710`) and the per-Character UTF-16 prefix-sum translation; the only fuzzy fixture uses ASCII, leaving the load-bearing S5-14 UTF-16 contract for fuzzy mode with no non-ASCII coverage. | Add fuzzy fixtures: a supplementary-plane Character (emoji, 2 UTF-16 units), an expanding-case U+0130, and a multi-scalar EGC (flag emoji). Assert `matchedRanges` UTF-16 offsets and snippet correctness. | `docs/03b §8`; `docs/04 §7`; `AUDIT.md` S5-14 |
| `test-gap-search-cursor-pagination-untested` | `SearchWorker.swift:174` | test-coverage | The search-mode cursor mint path (`.fuzzyUnpinned`/`.defaultOrder` anchor + `survivors.count>limit` gate `:174`) and resume path (`firstIndex` anchor lookup → `.snapshotExpired` when the anchor names no row, `:140-148`) are untested; WS18 paginates only `.recent` and uses `.search` solely as the shape-mismatch counterpart. Fail-closed analysis is sound, so this is a coverage gap, not an oracle risk. | Add a test that mints a `.search` cursor, follows `next` across ≥2 pages, asserts no skip/repeat, mutates the corpus, and asserts `.snapshotExpired` when the anchor names no row. Cover both `.fuzzyUnpinned` and `.defaultOrder` anchor families. | `docs/04 §6`; `docs/05 §14.2`; `AUDIT.md` S5 (WS18) |
| `test-gap-regexp-body-mode-untested` | `SearchWorker.swift:356` | test-coverage | The regexp body-match path (title miss → `bodyPrefix` scan → `NSRange`→`Range` → `distance()` → `bodyExcerpt` over prefix) has NO test; the sole regexp WS17 fixture (`'Alpha'`) asserts only a title match. | Add a regexp fixture with a pattern present in a row's body but absent from every title; assert snippet non-emptiness and snippet-relative UTF-16 ranges for the body lane. | `docs/03b §8`; `AUDIT.md` S5-04 |
| `regexp-fuzzy-ellipsis-relative-to-prefix-not-body` | `SearchWorker.swift:357` | correctness (UX) | `evaluateRegexp` (`:384`) and `evaluateFuzzy` (`:619`) pass the scanned PREFIX as `bodyExcerpt`'s `body` argument, but `evaluateExact` (`:274`) passes the FULL `searchBody`; so the leading/trailing-ellipsis decision is relative to the ≤1,000/≤5,000-Character prefix in regexp/fuzzy, not the full body — a match near the prefix end of a much longer body shows NO trailing ellipsis in regexp/fuzzy but DOES in exact mode. | Either pass the full body length to `bodyExcerpt` as a separate parameter so the trailing-ellipsis decision reflects body extent, or amend `docs/03b §8` line 94 to explicitly define "the body" as the scanned prefix in regexp/fuzzy modes (the current defensible reading). | `docs/03b §8` line 94 (ambiguous) |
| `utf16-fallback-can-project-mojibake` | `ContentProjector.swift:151` | correctness (fail-closed) | `decodedText`'s UTF-8 → UTF-16 fallback relies on `String(data:encoding:.utf16)`, which is **lenient** (no-BOM native byte order, tolerant of unpaired surrogates in common deployments), so a textual-typed representation (e.g. `public.html`) carrying even-length non-text bytes that fail UTF-8 falls through to UTF-16 and decodes as **mojibake** into title/searchBody — weaker fail-closed behavior than the "skipped rather than projected as mojibake" doc claim at `:139`. | Either tighten `decodedText` to strict UTF-8-only for non-utf16 UTIs (drop the lenient UTF-16 fallback), or add a malformed-surrogate rejection. Update the doc comment. Add a projector test with even-length non-text bytes under `public.html` asserting skip-not-mojibake. | `docs/05 §15` |
| `over-bound-retained-set-maps-to-two-different-failures` | `FactLoaders.swift:421` | correctness (robustness) | An over-bound retained set maps to `.temporarilyUnavailable(.dedupIndexRebuild)` when detected by `fetchRetainedIDs` (`:421-423`, the WS5 producer) but to `.persistence(.invariantViolation)` when detected by `fetchRetainedInventory` (`:204-206`); the same durable condition yields two different public failures depending on which fetch runs first, and no test pins both mappings. | Add a regression test that injects an over-bound retained set via direct `ModelContext` access and asserts BOTH mappings so a future fetch reorder cannot silently change the public failure vocabulary. | `docs/05 §7.1/§16`; `docs/06 §8` WS5 |
| `fact-loader-defensive-invariant-paths-untested` | `FactLoaders.swift:204` | test-coverage | The `.persistence(.invariantViolation)` producers in the loaders (over-bound inventory, duplicate business ID, index/store divergence, candidate-not-retained, malformed/non-contiguous D12 pin order) require injected durable corruption unreachable through facade-driven WS tests; a regression (e.g. D12 array-equality → `Set==`, or a fetch reorder) would pass undetected. | Add an injected-corruption test harness (direct `ModelContext` access bypassing the facade) that writes duplicate IDs, non-contiguous pin ordinals, over-bound retained counts, and candidate∖retained sets, then invokes the loaders asserting `.persistence(.invariantViolation)` and the precise dedupIndexRebuild-vs-invariantViolation split. | `docs/05 §7.1-§7.3, §12`; `docs/02 §5.1-§5.5`; `AUDIT.md` S5-15/IND-03 |
| `contentprojector-whitespace-body-admitted` | `ContentProjector.swift:99` | correctness (UX) | The body-build guard `!normalized.isEmpty` (`:99`) admits whitespace-only texts into `searchBody`, contradicting the projector's own docstring ("Whitespace-only texts contribute nothing") and the title side (`firstContentLine` trims+skips whitespace-only lines). | Either change the guard to `let trimmed = normalized.trimmingCharacters(in:.whitespacesAndNewlines); guard !trimmed.isEmpty` (symmetric with `firstContentLine`), or update the docstring to match the include-verbatim behavior. | `docs/05 §15`; `docs/06 §2` |
| `html-rtf-representations-indexed-as-raw-markup` | `ContentProjector.swift:124` | UX (spec-confirmation) | `textualTypeIdentifiers` includes `public.rtf` and `public.html` (`:130-131`) and `decodedText` decodes them as raw UTF-8/UTF-16 with no markup stripping (`:150-154`), so HTML/RTF tag soup becomes the title (e.g. `<!DOCTYPE html>`) and searchable body. Spec-frozen (`§15` does not enumerate the set), but a user-visible quality regression versus typical clipboard managers. | Confirm with the spec author whether raw-markup indexing is the intended v1 UX. If not, either drop `public.html`/`public.rtf` from `textualTypeIdentifiers` or strip markup before projection in a future schema version. | `docs/05 §15`; `docs/03b §8` |
| `ws17-fuzzy-unpinned-ordering-untested` | `WS17SearchModesTests.swift:360` | test-coverage | WS17's fuzzy test never constructs a multi-unpinned-hit scenario and asserts the second row only conditionally (`if page.rows.count >= 2`), so the fuzzy unpinned ordering (ascending Fuse score, then `lastCopiedAt` descending, then ID ascending) is not actually verified — a regression that inverted the score comparison or broke the ID tie-break would pass WS17. | Construct ≥2 same-title unpinned matches that fuzzy-match the same term with DIFFERENT Fuse scores, and assert the ordering unconditionally (remove the `if page.rows.count >= 2` guard or make it fail-loud). | `docs/03b §8`; `docs/06 §8` WS17 |
| `regex-posix-class-scanner-desync` | `SearchWorker.swift:438` | correctness (false-positive only) | `containsRejectedPatternShape`'s in-class scanner closes the class on the first `]`, desynchronizing on ICU POSIX classes like `[[:alpha:]]` — VERIFIED direction is **false-positive only** (e.g. `([[:alpha:]+])+` is rejected though ICU executes it linearly); the scanner exits early so it cannot hide a real inner quantifier (false-negative direction not achievable). | Extend the in-class scanner (`:438-447`) to recognize ICU POSIX bracket expressions `[[:alpha:]]` and set operations `[a&&b]` by counting the inner `[: :]` / `&&` delimiters before closing on the final `]`. Add a regression test with `([[:alpha:]+])+` asserting admission. | `docs/03b §8` |
| `cursor-anchor-item-existence-oracle` | `SearchWorker.swift:175` | security (weak oracle) | The continuation anchor is matched by value-equality against the recomputed order; because the cursor payload embeds the `processMarker` (extractable from any legitimately-minted cursor) and the current position is public, a holder of one valid cursor can craft cursors that probe whether a specific `(id, lastCopiedAt, pinOrdinal[, score])` triple corresponds to a real retained row by observing `.snapshotExpired` vs a returned page. Constrained: attacker must guess the full triple AND the position must equal current durable position; process-local and ephemeral. | None required for v1 (weak process-local oracle, single-user product). Document the threat-model assumption that cursors are ephemeral and caller-private; revisit if cursor persistence/restore ever lands. | `docs/04 §6`; `docs/05 §16` |

> **Remediation status (2026-08-09):** `exact-mode-no-term-guard` is
> **in-progress**. The 4,096-byte envelope now lives once at
> `SearchWorker.page`, before all mode-specific admission, with 4,096/4,097
> wide-grapheme public-facade boundaries for exact/regexp/fuzzy. macOS CI is
> pending.
>
> `contentprojector-whitespace-body-admitted` is **in-progress** as part of
> the same bounded projector change. Whitespace-only representations are
> skipped, with a direct regression proving they introduce neither corpus
> bytes nor a separator. macOS CI is pending.
>
> `test-gap-search-cursor-pagination-untested` is **in-progress**. New
> public-facade tests follow exact, fuzzy, and regexp searches over three pages
> with no gap/repeat, covering both `.defaultOrder` and `.fuzzyUnpinned`
> anchors; each mode also expires a structurally valid missing-row anchor at an
> unchanged position and expires its old cursor after an intervening commit.
> This also covers the `fuzzy-cursor-anchor-resume-untested` gap recorded by
> the codec audit. macOS CI is pending.
>
> `test-gap-regexp-body-mode-untested`,
> `ws17-fuzzy-unpinned-ordering-untested`, and
> `test-gap-fuzzy-nonascii-utf16-untested` are **in-progress**. The new
> fixtures pin a body-only regexp's snippet-relative UTF-16 range, fuzzy score
> then recency then ID ordering with four unconditional unpinned hits, and
> original-string UTF-16 widths for a supplementary-plane emoji, a flag body
> EGC, and a decomposed combining EGC. Together with WS17's separately-owned
> U+0130 expanding-case fixture, the requested non-ASCII set is represented.
> macOS CI is pending.
>
> Projector/read micro-remediation is also current: `utf16-fallback-can-project-mojibake`,
> `normalizing-newlines-two-pass`, `firstline-splits-all`, and
> `d12-alloc-array-equality` are **in-progress** with type-strict decoding,
> one-pass newline folding, index-based first-line selection, and
> zero-allocation D12 checks plus direct fixtures. macOS CI is pending.
> `body-excerpt-boundary-count-eq-windowcapacity` is **documented** by the
> corrected “320 Characters or shorter” §8 wording.
>
> **Search hot-path remediation (2026-08-11):**
> `fuzzy-double-lowercase`,
> `fuzzy-body-match-wastes-full-prefix-utf16-walk`,
> `regexp-fuzzy-ellipsis-relative-to-prefix-not-body`,
> `regex-posix-class-scanner-desync`, and
> `utf16-prefix-offsets-rebuilt-per-match` are **in-progress**. The worker
> makes one aligned lowercase copy and reuses it through an equivalent
> case-sensitive Fuse executor; body hits no longer construct discarded
> full-prefix UTF-16 ranges; regexp/fuzzy excerpts carry a bounded
> “stored suffix omitted” flag; the regexp preflight tracks nested ICU/POSIX
> character classes and quoted literals; and UTF-16 prefix sums stop at the
> furthest retained match boundary. U+0130/emoji/flag/combining-mark,
> POSIX/nested-class safety, quoted literals inside and outside sets,
> comments-mode rejection, regexp scan-boundary ellipsis, and pure excerpt
> fixtures preserve behavior. `no-direct-unit-tests-for-search-projector-internals`
> is likewise **in-progress** only for supported-runner proof: regexp preflight,
> original-string UTF-16 translation, excerpting, and projection are directly
> `@testable`; the non-Sendable Fuse half remains actor-confined and is covered
> through the public fuzzy boundary/Unicode fixtures. macOS Swift 6.2 tests
> remain before `fixed`.
>
> `search-observation-path-untested` is **in-progress** only for macOS proof.
> The existing position-recheck fixture commits after an old evaluation; a
> second deterministic SearchWorker entry seam now parks after the immutable
> old-position corpus is captured, commits during evaluation, and proves that
> the facade discards that old-position result before the subscriber's first
> yield. The seam carries only Sendable values and is nil in production.
>
> `observe-phase1-recheck-unbounded` is **documented**. A fixed retry cap
> followed by yielding a page already proved stale would contradict Part IV
> §5 step 4. V1 deliberately waits for one query/recheck interval with no
> intervening commit, checks cancellation between requeries, and records the
> freshness/liveness tradeoff in `docs/04-coherence.md` §5. Trigger for a
> future policy change: a supported product workload demonstrates first-page
> starvation. Residual risk: an infinite sustained writer can delay the first
> emission until cancellation.
>
> `search-corpus-materializes-full-inline-searchbody` is **deferred** to the
> G2/projection-schema graft, owned by HistoryStorage + Performance. Trigger:
> a supported 5,000-row representative-body workload breaches the agreed RSS
> or copy-cost budget and supplies the evidence needed to choose an external,
> separately fetched, or otherwise bounded stored projection. Residual risk:
> one search snapshot may still materialize every inline bounded body (worst
> structural envelope about 1.28 GiB). V1 does not invent an unmeasured cache
> or pre-release schema migration; exact correctness remains bounded and
> fail-closed.
>
> **Fact-loader/scalar-read remediation (2026-08-11):**
>
> - `capture-fact-load-fetches-same-table-2-3-times` is **in-progress** toward
>   `fixed`. Owner: HistoryStorage fact loading + macOS CI. Verification trigger:
>   the regular capture suites and the stale-ready-index regression pass on the
>   supported macOS 26 / Swift 6.2 runner. Capture now performs one complete
>   scalar inventory fetch, derives the already duplicate-checked retained-ID
>   set from it, and reuses the same summaries as the retention fact. The
>   healthy path drops from two overlapping table scans to one; a cold/stale
>   index retains one additional signature-blob scan because readiness cannot
>   be known before comparing the inventory's set. Residual risk until that
>   trigger: the SwiftData fetch shape and new regression have only portable
>   source-gate/static review, not supported-platform compile/runtime proof.
> - `over-bound-retained-set-maps-to-two-different-failures` is
>   **in-progress** toward `fixed`. Owner: HistoryStorage fact loading + macOS
>   CI. Verification trigger: both the existing public WS5 proof and the new
>   direct default-inventory proof pass on the supported runner.
>   `fetchRetainedInventory` now takes an explicit proof purpose: ordinary
>   mutation facts retain the durable-state
>   `.persistence(.invariantViolation)` mapping, while capture candidacy uses
>   WS5's `.temporarilyUnavailable(.dedupIndexRebuild)` for an unavailable or
>   over-bound inventory. Residual risk until that trigger: a SwiftData runtime
>   difference could expose an uncompiled fetch/mapping path even though both
>   source-level branches are now explicit.
> - `fact-loader-defensive-invariant-paths-untested` is **in-progress** toward
>   `fixed`. Owner: HistoryStorage invariant fixtures + macOS CI. Verification
>   trigger: the new default-bound, D12 gap/duplicate, and stale-ready-index
>   tests pass on the supported runner. Direct durable fixtures cover those
>   reachable paths. The two requested remaining corrupt shapes are not
>   constructible through production values: `@Attribute(.unique)` owns
>   duplicate business-ID exclusion, while `SignatureIndex.build`/prevalidated
>   `apply` maintain postings and `itemIDs` together and `loadFacts` proves
>   `index.itemIDs == retainedIDs` before candidacy. Existing
>   `SignatureIndexTests` exercise every constructible malformed delta; no
>   test-only initializer was added that would weaken those private invariants.
>   Residual risk until the trigger: the new SwiftData corruption fixtures have
>   not executed on the supported platform; afterward the deliberately
>   unconstructible guards remain defense-in-depth rather than fixture targets.
> - `candidate-hydration-n-plus-1-queries` is **deferred**. Owner:
>   HistoryStorage fact loading/performance. Trigger: macOS 26 proves a bounded
>   `[UUID].contains(row.id)` SwiftData predicate compiles and translates, and a
>   forced-collision workload with at least 64 candidates shows material
>   capture p95 or Authority queue wait. Residual risk: pathological common
>   signatures still cause O(K) unique-ID fetches and full hydrations; normal
>   clipboard candidacy remains K≈0–1 and K is hard-bounded by retained count.
> - `scalar-reads-rely-on-unverified-externalstorage-faulting-suppression` is
>   **deferred** to the R8 supported-platform evidence owner. Trigger: before
>   accepting any scalar-path resident-memory claim, trace the 5,000-row
>   persistent startup/recent/search/inventory/pin paths on macOS 26 with
>   Instruments or equivalent SQL/allocation evidence. Residual risk: if
>   SwiftData faults the non-requested `.externalStorage` attributes, an
>   apparent O(N scalar) load can retain O(N × blob bytes). Source and test
>   comments now claim only no attribute access/decode, not unmeasured
>   no-fault behavior.

#### Nit

| ID | file:line | category | summary | recommendation | spec ref |
|---|---|---|---|---|---|
| `fuzzy-sort-nan-score-instability` | `SearchWorker.swift:658` | correctness (defensive) | The fuzzy unpinned sort comparator `lhs.score != rhs.score ? lhs.score < rhs.score` (`:658`) is not NaN-safe; a hypothetical NaN Fuse score would yield a non-transitive ordering. Fuse scores are in [0,1] and never NaN in 1.4.0 — purely a defensive gap. | Treat NaN defensively (`if lhs.score.isNaN { return true }; if rhs.score.isNaN { return false }`) before the comparison, or guard at `FuzzyHit` construction. | `docs/04 §7` |
| `normalizing-newlines-two-pass` | `ContentProjector.swift:163` | efficiency | Cluster of bounded redundant passes: `normalizingNewlines` chains two NSString-bridged `replacingOccurrences` (CRLF→LF then CR→LF); `truncatedToUTF8ByteLimit` runs `utf8.count` then a Character loop; `utf16PrefixOffsets` allocates a throwaway `String(character)` per Character (`:875`). All correct, all minor waste. | Collapse `normalizingNewlines` into one forward Character sweep emitting `\n` for both `\r\n` and lone `\r` (CRLF-first ordering is NOT load-bearing). Optionally fold `truncatedToUTF8ByteLimit`'s `utf8.count` gate into the Character loop. In `utf16PrefixOffsets`, iterate the snippet's `UTF16View` instead of allocating `String(character)` per Character. | `docs/05 §15`; `docs/06 §2` |
| `firstline-splits-all` | `ContentProjector.swift:172` | efficiency | `firstContentLine` uses `String.split` over the whole normalized text (before truncation, up to 64 MiB across representations), materializing the full `[Substring]` line array eagerly before returning the first non-empty trimmed line. | Replace with a lazy line walk (`enumerateSubstrings(.byLines)` or an index-based `\n` scan) returning at the first non-empty trimmed line. | `docs/05 §15` |
| `body-excerpt-boundary-count-eq-windowcapacity` | `SearchWorker.swift:777` | docs | `bodyExcerpt` uses `count <= windowCapacity` (`:777`) where the spec literally says "shorter than 320" (`<320`); the two are outcome-equivalent at `count==320`, so it is a pure literal phrasing deviation. | Reword `docs/03b §8` line 94 from "shorter than 320 Characters" to "320 Characters or shorter". | `docs/03b §8` line 94 |
| `d12-alloc-array-equality` | `MutationFactLoaders.swift:95` | efficiency | `loadCompletePinnedOrder` verifies D12 contiguity via `pinned.map(\.ordinal) == Array(0..<pinned.count)`, allocating two `[Int]` after a sort that already proves the property in place. | Use `enumerated().allSatisfy { $0.offset == $0.element.ordinal }` — zero allocation. | `docs/02 §3.2/§5.2` (D12) |
| `projector-trusts-typeidentifier-set-invariant` | `ContentProjector.swift:89` | correctness (defense-in-depth) | `project()` sets `effectiveTypeIdentifiers` directly from `content.representations.map(\.typeIdentifier)` with no sort/dedupe/non-empty check, a deliberate trust-rather-than-verify stance on the `02 §2.1` normalized-set invariant. | Optional: sort+dedupe+non-empty-check `typeIdentifiers` at projection so an upstream breach fails locally with a clearer stack. Not required by spec. | `docs/05 §15`; `docs/02 §2.1` |
| `typebased-fallback-force-indexes-typeidentifiers0` | `ContentProjector.swift:207` | correctness (fail-closed) | `typeBasedFallbackTitle` reaches `return typeIdentifiers[0]` (`:207`) with no bounds check; a TEST helper or future caller constructing an empty representation set would crash (Swift trap) rather than yield a typed failure — inconsistent with the §4 "never repairs, drops, or guesses" stance. | Make `project()` fail closed (fixed placeholder or `preconditionFailure` with a typed message) on an empty representation set instead of trapping on array access. | `docs/05 §15` |

### 4. Complexity analysis

| Function (site) | Current Big-O (time / space) | Reduction opportunity |
|---|---|---|
| `bodyExcerpt` (`SearchWorker.swift:768`) | **O(\|body\|)** time+space via `Array(body)` to index a ≤322-Character window (exact mode \|body\| = 256 KiB → ~4 MB `[Character]` per matching row) | **O(window)** via `String.Index distance(from:to:)` + `index(after:)` offsetting on the original body, materializing only the windowed `Substring`. Largest single complexity win in the module. |
| Per-page re-evaluation (`SwiftDataHistory.swift:252` + `SearchWorker.swift:120`) | **O(pages × N × P × T)** across a pagination (re-capture N rows + re-evaluate over prefix P × text T on every continuation page) | **O(N × P × T)** total + **O(1)** per continuation via a `ChangePosition`-keyed corpus cache (G2 era, §12-admissible) + an `[anchor:index]` dictionary replacing the O(N) `firstIndex` scan. |
| `utf16PrefixOffsets` (`SearchWorker.swift:869`) | **O(N)** time with a throwaway `String(character)` allocation per Character (`:875`) | **O(N)** zero-allocation by iterating `text.utf16` / `unicodeScalars` while tracking grapheme-cluster boundaries (Character width = accumulated UTF-16 unit count per cluster). |
| `fuzzyMatch` alignment guard (`SearchWorker.swift:710`) | **O(N)** lowercase copy per row purely to read `.count` (then Fuse lowercases again → 2× O(N)) | **O(1)** via a documented invariant (no current scalar shifts Character count under `lowercased()` — confirmed by the REFUTED unicode findings) + debug-assert, OR **O(N) once** by pre-lowercasing and threading the copy to a Fuse entry point that skips its internal lowercase. |
| Capture fact-load scans (`FactLoaders.swift`) | **1** bounded O(N) scalar inventory scan on the healthy path; **2** when stale/unready state requires the signature-blob rebuild | Remediated: derive readiness IDs from the inventory's duplicate-checked summaries. The cold signature scan stays separate so the healthy path never requests every signature blob. |
| Candidate hydration (`FactLoaders.swift:367`) | **O(C)** individual `id==uuid` fetches (N+1 pattern) | **O(1)** batched `ids.contains(row.id)` fetch via `#Predicate` when C is large. Realistic C is 0–2 (pathological-only win). |
| Retained-ID agreement (`FactLoaders.swift`) | **O(N)** constructing the one retained-ID set directly from the already duplicate-checked inventory | Remediated: the second table fetch and second Set reconstruction were removed; actor isolation/no suspension supplies the same-interval proof. |
| `firstContentLine` (`ContentProjector.swift:172`) | **O(numLines)** space materializing the full `[Substring]` line array via eager `split` before returning the first non-empty line | **O(firstLine)** via `enumerateSubstrings(.byLines)` or index-based `\n` scan with early return. |
| `project` body path (`ContentProjector.swift:109`) | **O(\|full body\|)** space (~128 MiB) for the `joined` then truncate | **O(256 KiB)** via streaming truncation that stops at `maximumStoredSearchBodyUTF8Bytes`. |
| `containsRejectedPatternShape` (`SearchWorker.swift:423`) | **O(pattern)** time, O(depth) space (correct) | Complexity is fine; the gap is *coverage* (no `\|` arm) — see findings. |

### 5. Efficiency notes

- **bodyExcerpt** — drop `let characters = Array(body)` (`:768`); exact mode passes the full 256 KiB body, so this is ~4 MB of `[Character]` per matching row materialized to index a ≤322-char window. Use `String.Index` offsetting; materialize only the window.
- **fuzzyMatch** — drop the discarded guard lowercased copy (`:710`). Pre-lowercase once and thread to a Fuse entry point that skips its internal lowercase, or replace with a documented invariant. Saves one full O(prefixLen) lowercase pass per row × 5,000 rows × pages.
- **fuzzyMatch body lane** — split so `utf16Ranges` is NOT computed for body matches (`:728`); the body-match caller discards it (`:617`). Saves a full-prefix O(N) walk + `[Int]` allocation per fuzzy body hit.
- **utf16PrefixOffsets** — replace `String(character).utf16.count` (`:875`) with direct `unicodeScalar`/`utf16` iteration. Removes a throwaway String allocation per Character; called twice per fuzzy body match.
- **ContentProjector.project** — replace `bodyParts.joined(separator:"\n")` then truncate (`:109-112`) with streaming truncation that stops at `maximumStoredSearchBodyUTF8Bytes`. On the revision path (`HistoryAuthority.swift:1983`), skip the body join entirely (only `.title` consumed).
- **normalizingNewlines** — collapse two `replacingOccurrences` passes (`:163-166`) into one forward Character sweep (CRLF-first ordering is NOT load-bearing).
- **firstContentLine** — replace eager `String.split` (`:172`) with a lazy `enumerateSubstrings(.byLines)` returning at the first non-empty trimmed line.
- **FactLoaders.loadFacts** — remediated: the complete scalar inventory now
  supplies the duplicate-checked retained-ID set and retention fact in one
  fetch; cold/stale index recovery alone performs the additional signature
  metadata scan.
- **MutationFactLoaders** — replace `pinned.map(\.ordinal)==Array(0..<pinned.count)` (`:95`) with `enumerated().allSatisfy{ $0.offset == $0.element.ordinal }` — two `[Int]` allocations dropped to zero.
- **searchCorpusSnapshot** — if the Instruments trace confirms eager faulting, pre-truncate `searchBody` to 5,000 chars in the `SearchCorpusRow` builder (`HistoryAuthority.swift:1904-1914`) — drops the held corpus from ~1.2 GiB to ~24 MiB.

### 6. Security & edge-case notes

- **Uncatchable crash from user input** (`fuse-bitap-crash-and-corruption`): a pasted string ≥90 chars used as a fuzzy query traps the process. Severity is critical not because of data corruption (the corruption at 65–89 is "merely" silent-empty) but because the failure is *outside* Swift's error-handling domain — no `catch` can intercept a checked-arith overflow trap.
- **Self-DoS via admitted ReDoS** (`regex-overlapping-alternation-redos`): `(a|a)+b` against a long all-`a` body wedges the `SearchWorker` actor. Scope (verified): only the `.search` lane is blocked — `.recent` browse routes through `authority.recentPage` (`SwiftDataHistory.swift:246-250`), NOT the worker. So the cross-lane starvation argument is weaker than initial findings suggested, but the search-lane self-DoS stands.
- **Adjacent-quantifier complexity (corrected)**: `a*a*a*a*X` is **polynomial of attacker-controlled degree** (compositions C(m+k-1, k-1)), NOT exponential — but with k bounded only by the 512-Character pattern cap it is still an effective hard hang. The exponential class is the overlapping-alternation form `(a|ab)+`/`(a|a)+`.
- **Weak cursor oracle** (`cursor-anchor-item-existence-oracle`): process-local, single-user, ephemeral — a constrained row-existence probe, not a cross-boundary concern. Documented threat-model assumption suffices for v1.
- **Mojibake fail-closed crack** (`utf16-fallback-can-project-mojibake`): the projector's otherwise-disciplined "never guess" stance slips on the lenient UTF-16 fallback. This is the one place mojibake can enter the durable projection.
- **Force-index trap** (`typebased-fallback-force-indexes-typeidentifiers0`): `typeIdentifiers[0]` with no bounds check — unreachable in production (IngestPreparation rejects empty captures) but a Swift trap rather than a typed failure if ever reached.
- **Raw-markup indexing** (`html-rtf-representations-indexed-as-raw-markup`): `public.html`/`public.rtf` bodies become tag soup titles — a UX quality issue to confirm with the spec author, not a security issue.

### 7. Concurrency / isolation notes

- **The two-step value pipeline is architecturally sound** (preserved-through-refactor): capture a Sendable scalar snapshot (`SearchCorpusSnapshot`) inside one non-suspending Authority interval, then evaluate off-actor. This correctly isolates BOTH the non-Sendable Fuse AND the non-Sendable `@Model` rows. The WS12 suspension-gate seam is well-placed. Defects are in the pipeline's *details* (how much the snapshot captures, how the matcher works internally), not the architecture.
- **SearchWorker actor confinement** (`searchworker-actor-serializes`): the actor's only isolated state is the non-Sendable Fuse class, so Swift 6 mandates confinement; `createPattern`/`search` are pure w.r.t. immutable config, so the serialization is conservative throughput loss. Incidental benefit: serialization bounds peak `matchMaskArr`+`bitArr` allocation. Head-of-line-blocking amplifier for the ReDoS/bitap defects.
- **`page()` is synchronous** (`SearchWorker.swift:103`): this is the hard blocker for the only complete ReDoS fix (a cooperative watchdog). Making `page()` async propagates to `SwiftDataHistory.browse` (`:253`) and the observe producer (`:285+`).
- **`.recent` lane bypasses the worker** (`SwiftDataHistory.swift:246-250`): verified — so the search worker's defects never block a `.recent` browse; the DoS blast radius is the `.search` lane only.
- **Search observation producer** (`SwiftDataHistory.swift:285-299`): subscribe-before-query ordering (§5 step 1) is correct; cancellation abandons the in-flight `SearchWorker` evaluation with the producer task. The coherence property (discard+recompute on a mid-eval invalidation newer than the page position) is untested (see §8).
- **Single-writer Authority + serialized fact loads** (`FactLoaders.swift`): fact loading runs inside one non-suspending interval, so mid-load drift is impossible by construction — the candidate-generation index used for candidacy is the one returned with the facts (verified at `:389-400`).

### 8. Test-coverage gaps

- **`no-direct-unit-tests-for-search-projector-internals`** (meta, major): the frozen pure helpers are all `private`, so the facade-only WS tests never exercised the bitap boundary, the regexp rejection table, the excerpt edge-redistribution, the UTF-16 translation, or the projector decode precedence. This is the structural root cause of the critical defect shipping undetected. **Highest-ROI coverage win: elevate to `internal` + add `@testable` tests.**
- **`fuzzy-bound-test-misses-entire-corruption-range`** (major): the entire 64–256 fuzzy range — including both failure windows — is uncovered. The one boundary test is `count:257` (the over-bound rejection).
- **`test-gap-excerpt-edge-redistribution-untested`** (major): `bodyExcerpt`'s body>320 branches are exercised by no test; the only body fixture (~42 chars) hits the whole-body branch.
- **`search-observation-path-untested`** (major): zero `observe(.search)` in `Tests/`; the `04 §7` coherence property is unverified.
- Minor gaps: `test-gap-fuzzy-nonascii-utf16-untested`, `test-gap-search-cursor-pagination-untested`, `test-gap-regexp-body-mode-untested`, `ws17-fuzzy-unpinned-ordering-untested`, `fact-loader-defensive-invariant-paths-untested`, `over-bound-retained-set-maps-to-two-different-failures` (the dual-mapping pin).

### 9. Notable REFUTED (provenance)

- **Bitap mechanism corrected (critical stands, examples fixed)**: several cycle-1 findings claimed Swift's `<<` is a *masking* shift that wraps (`1<<99 → 1<<35`; `len=256 → bit0`). Ground truth: Swift `<<` is a **smart shift** returning 0 for shift count ≥ bitWidth. So the actual failure modes are L=65..89 **silently EMPTY** (mask=0, completion check never fires) and L≥90 **TRAP** (loop reaches `i=63` where `(1<<63)-1 = Int.min-1` overflows under checked arithmetic). The headline (256 bound unsound → crash/empty on valid input) and CRITICAL severity are correct; the specific bit-wrap examples were miscalculated. Additionally **L=64 is the MAX CORRECT length** (not a crash): `mask=1<<63=Int.min` is valid, selecting bit 63 as the legitimate completion flag, and the threshold break fires at `i≈44` before the trap site.
- **Per-page re-eval downgraded major→minor**: the prior critique promoted `search-reeval-per-page` to major with a recommendation to add a v1 `ChangePosition`-keyed cache. Cycle-2 research **refutes** that as a v1 defect: `06 §9` L256 ("no cache without G2 evidence"), `04 §1` L5 ("no search-result cache"), `04 §6` L108 ("intentionally favors simple, explicit snapshot semantics"). Adding a cache in v1 would DEVIATE from the spec; the optimization belongs to the G2 graft era.
- **ReDoS impact scope corrected**: findings claimed a hung regexp broadly "starves observe/browse pagination." Verified: `SwiftDataHistory.browse` routes `.recent` through `authority.recentPage`, NOT the worker (`:246-250`), so a hung regexp blocks only the `.search` lane. The DoS is real but narrower than stated; this weakens the cross-lane starvation argument but not the self-DoS severity on the search lane.
- **Adjacent-quantifier complexity corrected**: `a*a*a*a*X` is polynomial of attacker-controlled degree, NOT exponential. The exponential class is the overlapping-alternation form.
- **Double-lowercase necessity nuanced**: the `lowercased().count` guard is not pure waste — it proves Fuse's working-copy Character indices align 1:1 with the original's, which is load-bearing for the UTF-16 range translation. The fix is to THREAD the pre-lowercased copy into Fuse (skip its internal lowercase), not simply delete the guard; deletion requires accepting Unicode-count-invariance as a documented invariant. (The REFUTED corruption findings confirm no current scalar shifts count under `lowercased()`.)

### 10. Open questions / residual risk

1. **Bitap ceiling + UX** — Is `maximumFuzzyQueryCharacters=64` (or lower, e.g. Fuse's documented default of 32) acceptable to the spec author? The bitap is provably correct only for len 1..64. If 64 is acceptable, the critical cluster collapses to a one-line limit change + `docs/06 §2` + `docs/03b §8` edit. If the author needs >64, Fuse MUST be replaced. **Single highest-leverage decision — pin the author.**
2. **ReDoS fix shape** — Does `docs/03b §8` intend `containsRejectedPatternShape` to be a COMPLETE ReDoS defense (option a — then it must also reject quantified overlapping-alternation, broadening the guard and admitting false positives on safe patterns), or is a cooperative runtime watchdog the intended complement (option b)? Option (b) requires making `page()` async (`:103`) — propagates to `SwiftDataHistory.browse` and the observe producer. **Pin the spec author — the answer reshapes the entire guard.**
3. **SwiftData faulting** — Does `propertiesToFetch` suppress eager FAULTING (not just decode) of inline String columns (`searchBody`) and `@Attribute(.externalStorage)` blobs? ONE Instruments/DTrace trace of the scalar read paths under the 5,000-row corpus resolves BOTH the 1.28 GiB inline-`searchBody` figure AND the scalar-read-isolation cluster (≥6 ratings). **This single measurement should gate v1 sign-off.**
4. **Facade-only test stance** — Is the WS17 facade-driven, helpers-private testing stance a deliberate FROZEN contract (integration-as-correctness-proof) or an accident of how WS17 was written? If accidental, elevating the pure helpers to `internal` is the cheapest broad coverage win and would have caught the critical bitap defect directly. **Pin the testing author's intent before refactoring.**

### 11. Prioritized recommendations (highest-ROI first)

1. **Fix the bitap ceiling (critical).** Lower `maximumFuzzyQueryCharacters` 256 → 64 OR replace Fuse with a Sendable >64-bit-word/chunked matcher (the latter is the systemic move — see #2). Amend `docs/03b §8` + `docs/06 §2`. Add a length-sweep regression test `[1,63,64,65,89,90,100,200,256]`. *(Resolves `fuse-bitap-crash-and-corruption`.)*
2. **Evaluate replacing Fuse outright.** The pinned Fuse 1.4.0 is the single root cause behind FOUR clusters: correctness (word-width ceiling), throughput (non-Sendability mandates the actor), DoS amplification (actor head-of-line blocking), allocation (sync `search(pattern:in:String)` forces per-row copies). Replacing it is the one architectural move that dissolves all four simultaneously. Every other fix is local; this one is systemic.
3. **Close the ReDoS guard.** Decide option (a) over-reject quantified alternation vs option (b) cooperative watchdog, per the spec-author pin. At minimum, add the `|` arm to `containsRejectedPatternShape`. Add `(a|a)+b` / `(a|ab)+c` regression tests. *(Resolves `regex-overlapping-alternation-redos`.)*
4. **Run the SwiftData faulting trace (gates ≥6 perf ratings).** One Instruments/DTrace pass under the 5,000-row corpus on the scalar read paths. Decides pre-truncate-at-capture vs move-to-`externalStorage` for `searchBody`, and bounds (or confirms) the 1.28 GiB inline figure. *(Resolves the open question #3 and rates `scalar-reads-rely-on-unverified-externalstorage-faulting-suppression`, `search-corpus-materializes-full-inline-searchbody`.)*
5. **Streaming truncation in `ContentProjector.project`** (`:109`) and **skip the body join on the revision path** (`HistoryAuthority.swift:1983`). Avoids materializing up to 128 MiB to discard 99.8%, inside the serialized Authority interval. *(Resolves `projection-joins-full-body-before-truncation`.)*
6. **Rewrite `bodyExcerpt` on `String.Index`.** Accept caller-computed offsets; drop `Array(body)`. Largest single complexity win (256 KiB → ~5 KB per matching row in exact mode). *(Resolves `exact-body-excerpt-full-array`.)*
7. **Elevate the pure helpers to `internal` + add `@testable` tests** for the regexp rejection table (every branch), `bodyExcerpt`'s six frozen steps, UTF-16 translation (BMP + supplementary-plane), the projector decode precedence, and the fuzzy length boundary. Single refactor closes ~10 coverage gaps and would have caught the bitap defect directly. *(Resolves `no-direct-unit-tests-for-search-projector-internals` and the dependent test-gap majors/minors.)*
8. **Add the four missing test fixtures:** search observation coherence (`observe(.search)` across a commit), fuzzy non-ASCII UTF-16, search cursor pagination (mint+resume+`snapshotExpired`), regexp body mode. *(Resolves the remaining major test gaps.)*
9. **Enforce or remove the dead `maximumSearchTermUTF8Bytes` bound**, symmetrically across modes (or move it to the UI/adapter layer and document). *(Resolves `exact-mode-no-term-guard`.)*
10. **Tighten the projector's fail-closed posture**: strict UTF-8 (drop lenient UTF-16 fallback or add surrogate rejection), whitespace-only body guard symmetric with `firstContentLine`, typed failure on empty `typeIdentifiers`. *(Resolves the three ContentProjector minor/nit fail-closed cracks.)*
11. **Minor efficiency sweep** (post-v1 or in the same pass if cheap): derive `retainedIDs` from inventory, replace the Set-equality rebuild with `count + allSatisfy`, drop the fuzzy double-lowercase, split `fuzzyMatch` to skip the wasted UTF-16 walk on body matches, collapse `normalizingNewlines`, lazy `firstContentLine`, `enumerated().allSatisfy` for D12.
12. **G2-era graft** (explicitly NOT v1): `ChangePosition`-keyed corpus cache + `[anchor:index]` dictionary for O(1) continuation; decouple the fuzzy cursor anchor from the FP score. *(Captures `search-reeval-per-page` and `fuzzy-score-in-cursor-anchor-is-brittle` cleanly without deviating from the v1 no-cache spec.)*
