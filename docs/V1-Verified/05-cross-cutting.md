# Cross-Cutting V1 Verification — Security, API Surface, Test Coverage, Complexity, Gates/CI

> **Scope:** horizontal synthesis across the seven per-module reports (`01-historycore` … `04-perf-deps-stubs`). Distills the **systemic patterns** and **cross-module root causes** that the per-module findings instantiate, rather than re-listing every finding. Each item cites its source report(s) and `file:line`.
> **Aggregate counts (final):** **222 findings — 3 critical, 14 major, 112 minor, 93 nit**. `07-finding-dispositions.md` is the canonical completeness/status ledger.
> **Headline:** the architecture is sound and the code is unusually disciplined, but **three critical findings** (a process crash, a password-content leak, and a structurally invalid red performance-acceptance proof), **one systemic testability gap** (pure safety-critical algorithms are `private`, so the facade-only WS suite missed both product criticals), and **a small set of root causes** (a `§16 CapacityKind` gap, comment-overclaims treated as contracts, syntactic-proxy safety stories, per-`Character` `String` allocations) account for the majority of the severity.
>
> **Historical remediation closure (2026-08-11):** all then-active
> supported-proof-dependent findings were fixed by public-symbol workflow
> 31448087991 and code-head run 31449682036. A later complexity pass reopened
> the performance-evidence lane; the canonical ledger now has 111 fixed,
> 30 deferred, 1 in-progress, and no pending rows. Source-inclusive thumbnail
> hydration is fixed by supported run 31494740863.
> Present-tense defect and test-gap descriptions below describe the audited
> `8f316c9` baseline, not the remediated tree.

## 1. The "fix these first" list (severity-ranked, cross-module)

| # | Severity | Finding | Location | One-line |
|---|---|---|---|---|
| 1 | **critical** | `fuse-bitap-crash-and-corruption` | `SearchWorker.swift:577` | A ≥90-Character fuzzy query **traps the process** (`(1<<63)-1` under checked `-`); 65-89 silently returns empty. Spec's 256-char bound vs Fuse's 64-bit bitap. Fix: lower bound to 64. *(03c)* |
| 2 | **critical** | `concealed-type-leak-flat-schema` | `IngestPreparation.swift:172` | Password content in a sibling rep next to a `ConcealedType` marker is **retained, fingerprinted, indexed, and made searchable**. Root cause is the flat `ClipboardCapture` data model. Fix at the seam (`Capture.swift` flag) + drop-whole-capture. *(03d)* |
| 3 | **critical** | `wl8-currently-red-on-master-blocks-section9-acceptance` | `main.swift:856` / perf CI | WL8 measures Authority serialization rather than single-flight sharing, so the certifying gate is structurally red. *(04)* |
| 4 | major | `ws18-unpinned-continuation-pagination-contract-violation-cluster` | `HistoryAuthority.swift:1770` | Unpinned recent-browse pagination **strands later rows** when the anchor shares its `lastCopiedAt` with earlier-id siblings (tail-only exactness guard misses the head group). *(03b)* |
| 5 | major | `regex-overlapping-alternation-redos` | `SearchWorker.swift:423` | `containsRejectedPatternShape` has no `\|` case → `(a\|a)+` admitted → catastrophic backtracking **self-wedges the actor** (non-async `page()`). *(03c)* |
| 6 | major | `projection-title-searchbody-bounds-not-decode-verified` | `ContentProjector.swift:29` / `Schema.swift:67-68` | Spec §4 + comment + AUDIT claim decode re-verifies title/searchBody/projectionSchemaVersion bounds — **no path does**; an oversized row (corruption/migration) is served unbounded. *(03a)* |
| 7 | major | `search-corpus-materializes-full-inline-searchbody` | `Schema.swift:68` / `HistoryAuthority.swift:1862,1908` | `searchBody` is inline; corpus capture materializes up to **~1.22 GiB** of String per query, rebuilt every keystroke. *(03c, 03a)* |
| 8 | major | `projection-joins-full-body-before-truncation` | `ContentProjector.swift:109` | `project()` joins the full body (up to 128 MiB) **before** truncating to 256 KiB — pure waste inside the serialized Authority interval. *(03c)* |
| 9 | major | `domain-planners-have-no-direct-unit-tests` | `HistoryDomainTests/` | D1-D19 invariants + all 7 planners + dedup tie-breakers have **zero** direct coverage; only a 97-line smoke file exists. `PROGRESS.md` overstates it as delivered. *(02)* |
| 10 | major | `no-direct-unit-tests-for-search-projector-internals` | `SearchWorker.swift:423` | The frozen pure algorithms (regex guard, excerpt, UTF-16 translation, projector) are `private` → **zero** direct coverage — *why* the critical bitap defect shipped. *(03c)* |
| 11 | minor | `thumbnail-16mib-bound-misclassified` | `ThumbnailService.swift:304` | A 2048×2048 RGBA noise image exceeds the 16 MiB PNG bound → `.invariantViolation` on valid content. Reachable (perf runner has the fixture). *(03d)* |

*(Items 12-19: `thumbnail-pipeline-concurrency-design-latent`, `observe-phase1-recheck-unbounded`, `signatureindex-unit-test-coverage-thin`, `ingest-prep-rejection-and-transient-filter-untested`, `exact-body-excerpt-full-array`, `g8-trigger-does-not-cover-read-path-rss`, `progress-md-overstates-d19-suite-as-delivered`, `search-corpus-per-query-full-materialization-on-actor` — see per-module reports.)*

## 2. Security & privacy

- **Sensitive-data leak (critical #2):** concealed/password content survives ingest — see `03d`. The threat model (`AGENTS §9`: "clipboard content is sensitive") is violated by the data-model seam. **Defense-in-depth must-fix regardless of adapter timing.**
- **Process crash / DoS (critical #1):** the Fuse bitap trap is an **uncatchable** `fatalError` from ordinary user input (paste a long string) — both a reliability and an availability defect. A long fuzzy query is also a vector for a user to crash their own app (low-malice, but a paste of e.g. a 200-char token kills the process).
- **ReDoS self-wedge (major #5):** the regex guard is a hand-rolled syntactic predictor of ICU's NFA backtracking; it misses quantified-alternation-of-overlapping-arms (`(a|a)+`). Because `page()` is synchronous on the serialized `SearchWorker` actor, one bad pattern stalls **all** concurrent search/observe. The compilation backstop does **not** catch catastrophic backtracking.
- **Fail-closed codecs (strength):** all four blob codecs reject exhaustively and map to `.persistence(.corruptStoredValue)`; the envelope pre-decode gate bounds allocation before parsing (DoS defense). The decode discipline is genuinely strong — *for the blobs*. The weakness is the **projection scalars** (`title`/`searchBody`) sit outside any codec (major #6).
- **No network / no telemetry (strength):** confirmed — v1 has no network code. The import gate would catch AppKit leakage into the wrong target.
- **Cursor integrity:** `HistoryPageCursor` lacks cryptographic integrity, but the `processMarker` binding + position/shape recheck limits forgery impact to wrong pagination (not a security boundary). Low risk.

## 3. Public API surface & evolution safety

- **Strengths:** `HistoryCore` is Foundation-only, fully `Sendable`, with disciplined access control (`public` seam, `package` minting, `package` DTO inits so callers can't forge rows/pages/details). The closed `HistoryAction` enum forces exhaustive switches; identity types use checked arithmetic (no token wrap). The public symbol snapshot gate prevents accidental leakage.
- **`HistoryLimits.init?` was `public` but unused publicly at the audited
  baseline** (`01-historycore`): `SwiftDataHistory.open` hard-codes `.standard`
  and no public API accepts custom limits. It is now `package`; all 10 current
  production/test construction points use that seam, and symbol workflow
  31448087991 confirms the public surface retraction.
- **`HistoryLimits` range validation gap** (`01-historycore`): the baseline
  correctly required a `lower <= upper` failable check but incorrectly assumed
  an inverted `ClosedRange(uncheckedBounds:)` could reach it. Run 31449140919
  proved that construction traps first; the endpoint-based initializer now
  validates ordering before constructing ranges, and all rejection paths pass
  in run 31449682036.
- **Evolution:** the versioned blob codecs (`formatVersion: UInt16 = 1`) + `projectionSchemaVersion` give a clean forward path; `HistorySchemaV1` labels the migration stance (`05 §17`).

## 4. Test coverage (the dominant systemic gap)

**Recurring across every module:** the pure, safety-critical algorithms are `private`/`private static`, so the WS1-WS21 suite (facade-level, via real `SwiftDataHistory`) exercises them only indirectly through happy paths. The two **criticals** shipped precisely because the affected code paths are unreachable or unexercised through the facade:

- **HistoryDomain planners** — D1-D19 + 7 planners + dedup tie-breakers: zero direct tests (`02`). *The roadmap's own Acceptance blocker.*
- **SearchWorker pure helpers** — regex guard, `bodyExcerpt`, UTF-16 translation, `fuzzyMatch`: zero direct tests; the bitap boundary (63/64/65) and ≥90-crash range untested (`03c`). WS17 sweeps only facade-level modes.
- **SignatureIndex** — `apply()`'s 4 divergence paths, `build`/`validate` rejections, generation overflow: one assertion; unreachable end-to-end (serialized) so only injection tests them, none exists (`03d`, `02`).
- **IngestPreparation** — zero coverage of any `prepare()` rejection branch or the step-3 transient filter (where the critical leak lives) (`03d`).
- **PageCursorCodec** — zero tests; the 4 rejection cases + wire round-trip only indirectly via WS18's `.snapshotExpired` mapping (`03a`).
- **HistoryAuthority defensive guards** — `TransactionApplyRejection` cases + the fail-closed `.transaction` mapping: one injected case (`03b`).

**Recommendation (force-multiplier for the whole audit):** elevate the pure helpers to `internal` and add direct `@testable` suites. This single change would have caught both criticals pre-merge. Map each WS gate to the code paths it covers and name the gaps.

**Concurrency harness (strength):** the deterministic `ConcurrencyHarness` + transaction-injection seam + forced-collision fingerprint double are genuinely good infrastructure (WS12/WS13/WS15/WS20).

## 5. Complexity & efficiency (cross-module reductions)

The dominant theme: **work proportional to the whole retained set (N≤5000) or the whole body (≤256 KiB) is done where a bounded prefix or a cached snapshot would do**, often inside the serialized Authority interval.

- **`searchCorpusSnapshot` per-keystroke rebuild** (`03a`, `03b`, `03c`): full ≤5000-row fetch + sort + ~1.22 GiB inline materialization, **every** browse/observe-spin/continuation page. No `ChangePosition`-keyed cache. *The single highest-leverage fix.* → cache keyed by `ChangePosition`, invalidated on corpus-touching commits.
- **`projection-joins-full-body-before-truncation`** (`03c`): full-body join (≤128 MiB) then truncate to 256 KiB. → streaming truncation; skip the join on the revision path (only `.title` consumed).
- **`evictionOrdered` before `victimCount`** (`02`): full O(U log U) sort + 3 array rebuilds per capture, discarded when `victimCount==0` (common). → derive `victimCount` first, gate on it.
- **`validateFinalPinOrder` per commit** (`03b`): O(N) fetch + O(N log N) sort every commit. → `pinOrdinal != nil` predicate (O(P)); gate on plan content (amortized O(1) on capture/revision/retention).
- **`canonicalWinnerRanksBefore` recomputes byte equality** (`02`): O(R) per `min(by:)` comparison. → cache `(exactEquality, extraRepCount)` during the filter pass.
- **Per-`Character` `String(char).utf16.count` allocations** (`03c`): `utf16PrefixOffsets` allocates a `String` per Character of a ≤5000-char prefix. → iterate the string's `utf16` view once.
- **Read-path memory tax** (`01-historycore`, `03b`): `details()` hydrates the full revisionStateBlob (≤256 MiB) + re-projects every revision's title, though the DTO carries only lightweight `RevisionSummary`. G8 evidence gate doesn't cover the read path. → summary-only hydrate + `projectTitleOnly`.
- **Per-id fetches** (`03b`): clear/retention = N individual `SELECT`s; dedup candidates = one `fetchRow` per ID. → batched `id IN (...)`.

## 6. Concurrency & isolation

- **Strength:** the single-writer + OCC position-guard + non-suspending actor interval is genuinely well-conceived; the position guard converts actor-reentrancy double-commit into a *detected spurious rollback*, not corruption (`03b`). All five actors are `Sendable`-by-derivation; no `@unchecked Sendable`/`nonisolated(unsafe)` (gate-enforced).
- **Single-flight correctness:** `ThumbnailService` join-or-create is correct on the happy path, but creator cancellation doesn't cancel the unstructured decode `Task` → duplicate-decode under cancel (`03d`). `HistoryInvalidationPublisher` cancellation is idempotent and correct.
- **Cancellation is uniformly "remove bookkeeping, don't abort work"** (`03d`): ImageIO decode and synchronous `SearchWorker` evaluation are non-interruptible. Spec-conformant, but wasted-CPU-under-scroll is unanswered by the specs.
- **Serialization compounds:** `IngestPreparationActor`, `ThumbnailWorker`, and the Authority each serialize; individually defensible, but `ThumbnailWorker`'s single-actor serialization is what makes the unbounded-flights retention major (`03d`).

## 7. Gates & CI

- **Strength:** three layered gates — `import_gate.py` (per-target import confinement), `escape_hatch_scan.py` (`@unchecked Sendable`/`nonisolated(unsafe)`/service-locator ban), `public_symbol_snapshot.sh` (HistoryCore public-surface drift). All have fixture self-tests; CI self-scans logs and fails on any `warning:`/`error:` line. Strict and well-maintained.
- **Gap (minor): the gates are line-based regex, not AST-based** — explicitly acknowledged in-script ("occurrences inside comments or string literals are also flagged / would also be seen"). A banned import/construct placed inside a comment or via formatting tricks could evade. Mitigated by `AGENTS §9` ("do not work around a gate by reformatting code to evade a regex") + CI, but it's convention-backed, not structural. A SwiftSyntax-based gate would close it.
- **Gap: the perf runner cannot close the spec's own evidence gates** (`03b`, `03c`, `02`) — G2 (collection cache) and G5 (startup scan) need p95 at the bounds (5000 rows, 256 KiB body, on-disk external storage, durable fsync), but the runner uses in-memory stores, ≤400-1000 items, ~20-byte payloads, and skips per-commit fsync. So every "minor, deferred behind measured evidence" perf finding is currently **unfalsifiable**. **Extending the runner (on-disk, ≥1000-item, ≥64 KiB-body, p95 + RSS + fsync) is a force-multiplier for the whole review** and would resolve the three unverified platform assumptions (`propertiesToFetch` faulting, `ModelContext.transaction` durability mechanism, nil-coalescing optional-Int `#Predicate` translatability) that gate ~12-18 severity ratings (`03b`).

  **Post-closure remediation:** a dispatch-only 5,000 × 256 KiB persistent
  lane is now in pre-proof. It samples the tie fallback per public browse page,
  records worst-bound exact-search process RSS, and uses independent processes
  for warm-open tails. It deliberately does not claim fsync/crash durability,
  SwiftData no-fault behavior, an approved-minimum-hardware G5 result, or
  representative concurrent-call G8 residency/copy cost; those parts of the
  historical gap remain falsifiable only after their exact workloads are
  approved and measured.

## 8. Spec conformance / documentation drift

A striking pattern: **prose claims (comments, spec sections, `PROGRESS.md`) are treated as contracts the code doesn't fully uphold.** Each is a "paper guarantee":

- `SignatureIndex.swift:104-111` claims full-entry keying prunes postings "without ever dropping a true candidate" — false under stored-fingerprint corruption (D7 doesn't re-verify) (`02`).
- `ContentProjector.swift:29-30` + spec §4 line 225 + AUDIT S3-R4 claim decode re-verifies title/searchBody/projectionSchemaVersion bounds — no path does (`03a`).
- `§7.1 step 6` says verify "candidate IDs, retained IDs, and index **generation** agree" — `loadFacts` never reads generation (`03d`).
- `PROGRESS.md:81` lists the D1-D19 invariant suite as delivered — it's smoke-only; the roadmap and V2-roadmap both flag the overstatement (`02`).
- `IngestPreparation.swift:68-77` claims the transient filter prevents retaining password-manager content — it doesn't (sibling-UTI markers) (`03d`).
- The observe phase-1 "terminates because positions advance monotonically" comment is mathematically incomplete (`03d`).
- `StepDeferredError` is dead (zero throw sites) yet comments + `PROGRESS.md` still claim the thumbnail path raises it (`03b`, `03d`).

**Recommendation:** treat these as a batch — either bring the code up to the prose, or correct the prose. Several (`§16 CapacityKind` gap, the generation check, the projection bounds) are single-amendment multi-finding wins.

## 9. Cross-cutting root causes (the deepest layer)

1. **Syntactic proxies for semantic properties.** The regex guard predicts ICU NFA backtracking from textual inspection; the 256-char fuzzy bound is set without reference to the engine's bitap width. Both defenses are decoupled from the thing they protect → both have gaps (`03c`).
2. **`private` pure algorithms behind a facade-only test suite.** The structural reason both criticals shipped (`03c`, `02`, `03d`).
3. **A closed failure vocabulary (`§16 CapacityKind`) accumulating pressure it wasn't designed for** — one missing dimension causes 5+ misclassification findings (`03d`, `03a`).
4. **The `"Unreachable: steps 1-N enforce X"` cross-layer pattern** — fail-open/dead-state backstops that hold only while another layer's invariants stay a strict subset, with no canary when the subset relation breaks (`03d`).
5. **Inline-value memory tax** — content bytes carried in `Sendable` value DTOs / inline `String` columns, with no spec owner for the aggregate read-path RSS (`01-historycore`, `03b`, `03c`).
6. **The data-model seam drops pasteboard-level context** — the flat `ClipboardCapture` cannot carry concealed/transient flags, root-causing the privacy leak (`03d`).

---

*Cross-cutting synthesis of all seven final module reports. The per-module reports remain authoritative for detailed failure scenarios and recommendations; `07-finding-dispositions.md` is authoritative for the 222-ID completeness checksum and current status.*
