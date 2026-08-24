# Design Audit & Change Log (traceability root)

> **Status:** living document. NOT part of the seven-file v1 specification
> (`00`–`06`). It records how the spec was audited, what was found, and every
> edit made to the spec so future development can trace *why* each line is the
> way it is. Authored 2026-07-19.
>
> Every spec edit MUST append a row to §3 (Change Log) referencing a Finding ID.

## 1. Method

Two independent verification tracks whose results are **merged** (cross-checked)
before any edit is trusted:

1. **Multi-agent workflow** (`clipboard-design-audit`): 4 rounds × ≤5 agents,
   Analyze → Investigate → Critique → Settle, over 5 stable slices:
   S1 cross-doc consistency, S2 Swift 6 concurrency, S3 SwiftData platform,
   S4 domain logic, S5 read/observation/search/thumbnail. Agents used Apple MCP
   and context7 where relevant.
2. **Direct primary-source verification** by the orchestrator (Apple docs MCP,
   the `krisk/fuse-swift` README, repo greps) of the load-bearing platform
   claims, so workflow verdicts are never trusted singly.

Any edit triggers a re-audit round (goal: "改后必再审，循环至干净").

### Finding ID scheme
`<source>-<NN>` where source is `IND` (independent/orchestrator) or
`WF-<slice>` (workflow slice). Severity: `critical | major | minor | nit`.
Verdict: `CONFIRMED` (real defect, fix) · `REFUTED` (looks wrong, is correct) ·
`OPEN` (needs more evidence).

## 2. Findings register

| ID | Sev | Location | One-line | Verdict | Status |
|---|---|---|---|---|---|
| IND-01 | minor | 00:11, 06:230 | `docs/greenfield/` path referenced but actual dir is `docs/` | CONFIRMED | fixed |
| IND-02 | minor | 00:66, 01:158, 04:68 | `CONTEXT.md` referenced 3× but file absent | CONFIRMED | fixed |
| IND-03 | major | 03 §8, 06 §2, 01 §4 | Fuse `maxPatternLength` default 32 vs 256-char fuzzy bound → long queries silently nil | CONFIRMED | fixed |
| IND-04 | minor | 03 §8, 01 §4 | Fuse `location`/`distance` (relevance-affecting) undiscussed | CONFIRMED | fixed |
| IND-05 | nit | 01 §4 | "Fuse 1.4.x" version unverified; dep not named precisely; Sendable-by-confinement implicit | REFUTED | fixed (repo named `krisk/fuse-swift`, 1.4.0 confirmed latest stable; non-Sendable confinement documented in Module 7) |
| IND-06 | minor | 06 §9 | 90-minute exact admission emitted no phase/sample progress; Debug-only source trace was not distinguished from canonical Release evidence | CONFIRMED | fixed |
| IND-07 | major | 03b §8; 04 §7/§12; 05 §14.2; 06 §3/§9 | Exact search invokes a general Unicode substring operation for each title/body after materializing up to 5,000 × 256 KiB bodies; the existing G2 result-cache graft does not define a conservative candidate-index seam | CONFIRMED | in-progress |
| WF-* | — | — | Historical workflow register; findings were merged into §4 and the design change log. | merged | historical |

### Design-correct confirmations (REFUTED-as-fine, kept for provenance)

| Claim | Evidence | Result |
|---|---|---|
| `ModelContext.transaction(_:)` commits on closure success w/o extra `save()` | Apple: "Runs the provided closure, and once it finishes, writes any pending inserts, changes, and deletes to the persistent storage." block = "closure to run **before performing a save operation**." `transaction(block:)` macOS 14+. | CORRECT (failure-case correctly gated as Part VI §7.1 proof) |
| `propertiesToFetch` limits scalar reads; blob access faults | Apple: "if you subsequently access a nonfetched attribute, you'll incur the additional overhead of fetching the corresponding value from the persistent storage." | CORRECT (design gates no-fault as Part VI §7.5 proof) |
| `registeredModel(for:)` is not a business-ID lookup | Apple: `func registeredModel<T>(for persistentModelID: PersistentIdentifier) -> T?`; returns model only if "known to the context; otherwise nil". | CORRECT |
| Fuse threshold 0.7 + score-lower-is-better | `krisk/fuse-swift` README: threshold 0.0–1.0 (default 0.6); example score 0.444, 0 = perfect. | CORRECT |
| `HistoryItemID`/`RevisionID` `<` via `UUID.uuid` bytes | `UUID.uuid` is a 16-byte tuple; `withUnsafeBytes(of:).lexicographicallyPrecedes` yields deterministic total order. | CORRECT |
| `@Attribute(.externalStorage)` is a hint, not a guarantee | No dedicated Apple page; standard Core Data/SwiftData behavior; design does not depend on it for correctness. | CORRECT (posture) |
| Part VI §10 deleted-vocabulary leakage | Repo grep: every hit is inside an explicit rejection/history statement or the gate's own list. | GATE PASSES |
| Part III ↔ Part VI §2 numeric bounds | Mechanical cross-check: regexp prefix 1,000, fuzzy prefix 5,000, snippet 322, regexp-pattern limit deferred to Part VI's 512, fuzzy-query/search-term bounds live only in Part VI. No Part III vs Part VI mismatch. | CONSISTENT (IND-03 maxPatternLength gap stands separately) |

## 3. Change log

Every spec edit appends here: `date | finding | file:section | old → new`.
Pass 1 (2026-07-19) — all 15 MAJORS + ~20 minors/nits; re-audit follows.

| Finding | File:§ | Change |
|---|---|---|
| REVIEW §4.1–§4.7 executable-leaf bundle (2026-08-24) | REVIEW frozen todo map + live ledger §21; PresentationUI/HistoryStorage | Batch 39 implements five bounded leaves across areas 4.1–4.4 and 4.7 without upgrading their parent areas: unified count+V2 retention presentation with exact no-change/raw-value draft semantics; an internal exact-credential Local Automation `browsePreview` route through the unique Gateway; four normally terminated retention-config owners; Search Clear/focus and an Accessibility-authorized public AXPress cell; and ThumbnailStore product-surface contraction. At the user's direction it removes both three proposed narrow regex/log checks and the pre-existing static-source, SwiftLint, dependency/vendor, generated-project, test-selection, and public-symbol machinery; correctness retains the actual SwiftPM and XcodeGen build/test jobs. PR #41 final macOS correctness is pending. This is not completion of frozen §4.1–§4.7. |
| REVIEW Card 3D revision-history disclosure (2026-08-24) | roadmap/05; REVIEW playbook §8 | Approved an explicit pre-Save warning that Save appends an immutable revision and previous/original content may remain in revision history. The product view renders the literal through one Presentation-owned value. PR #40 merged as `c89f2ba`; PR-head/master correctness 32698639889/32699272489 are green. The current macOS CI runner exposes the attached SwiftUI editor sheet only as an empty public AX `Dialog`, so literal/source proof is Partial and does not satisfy the required hosted-copy, dirty Esc/Cancel, focus, VoiceOver, or FKA gates. No destructive prune/redaction API is implied. |
| V2-05 F1 in-process credential authentication kernel (2026-08-24) | V2-05 §3.2; `LocalAutomationCredentialAuthenticator`; `GatewayAuthorization` | Added exact UUID16+secret32 parsing, server-custody lookup, fixed full-byte comparison, and a narrow unaudited wrapper over the canonical durable connection loader. Malformed/missing/wrong/orphan values publish no identity; exact active/revoked values return only the connection ID for a later unique Gateway. This is not an authenticated ingress, framing/peer proof, client custody, coordinator, transport, or CLI. |
| V2-05 F1 generic enrollment safety gate (2026-08-24) | V2-05 §3.2; `SwiftDataHistory+GatewayAdministration` | The public generic administration witness now rejects `.localAutomation` before Authority admission, audit, clock, ID minting, or durable mutation because it cannot carry the preassigned identifier or prove client/server custody readbacks. Internal Authority enrollment remains available only to storage semantic fixtures. This does not implement client custody, enrollment/revocation coordination, authentication, ingress, transport, or CLI. |
| REVIEW Card 14A/14D + first XCUI tracer (2026-08-24) | 01 §8; 06 test targets; REVIEW playbook §19–20 | Approved open=newest+search-focus, close=clear selection/details/preview but retain raw query, and AppDelegate as the sole panel-session observation owner. Added one DEBUG-only running-app envelope that substitutes a temp store and allowed pasteboard posture, then invokes `GlobalHotKey.fire()` and requires the same production panel/search/History/pasteboard/close tail. Final PR run 32691591462 passed the stronger beta→Down→alpha exact General-pasteboard + close discriminator. It cannot prove real Carbon delivery, TCC, actual IME composition, VoiceOver/FKA, Spaces, multiscreen, frontmost preservation, or signed runtime. |
| REVIEW Card 16A archive identity (2026-08-24) | `ClipyApp/project.yml`; `.github/workflows/release-archive.yml`; REVIEW playbook §21 | Froze the ordinary direct-distribution source identity as bundle `com.clipy.ClipyApp`, marketing/build `0.1.0`/`1`, utility category, explicit empty entitlements and original AppIcon. The manual workflow requires same-SHA correctness, a protected `release/<marketing>/<build>` tag, one exact checkout, and an unsigned ordinary archive validator. It adds no checksum, signature, notarization, staple, Gatekeeper, or publication machinery; without an actual protected-tag run Card 16A remains Partial. |
| REVIEW Card 9B + UI-16 bounded leaves (2026-08-24) | 01 §2/§8; V2-05 §3.2/§6.2/§6.5/§6.6; V2 roadmap X.7; roadmap/06 | Added one app-local `AppIntentHistoryIngress` around the unchanged public connection-bound facade. It strictly awaits Gateway success, then only for `.remove(id)` + `.removed(count > 0)` awaits exact purge publication and synchronous application on the one AppDelegate-owned real `HistoryPanelSurfaceState` before returning; reads, pin/unpin, no-op, and failure remain pass-through/silent. No Storage public API, change feed, global cache bus, or second writer is added. The same batch adds literal image-preview pixel dimensions and one content-free medium-priority panel-Remove announcement only after a committed receipt and real surface apply; true AX tree, VoiceOver/FKA, localization, and signed runtime remain open. |
| GOV-1 / exact+scale evidence liveness (2026-08-24) | 06 §9; `.github/workflows/{manual-evidence,correctness,exact-matcher,performance-admission}.yml`; `scripts/ci/run_performance_admission.sh`; `scripts/evidence_workflow_gate.py` | Added one `workflow_dispatch`-only caller that first requires the same-ref reusable correctness workflow, then runs exact-matcher A/B and 5,000-row scale evidence in parallel. Restored Actions-owned 5/10/45/15/90/45-minute phase guards, smoke/cleanliness/short-probe fail-closed routing, partial explicit artifact upload, and a portable source contract gate. The caller remains absent from push/PR triggers; its scale results remain record-only and do not establish approved-hardware, concurrent-call, fsync/crash, or general external-storage no-fault claims. |
| GOV-2b / `DEC-PREVIEW-TARGET` (2026-08-24) | 00 §2; 01 §1/§2/§4/§5.7/§6; 06 §5; roadmap README/05; V2-07 §11/§12 | Resolved the preview owner as one concrete package-only `ContentPreview` actor with closed common-caller presets, exact source selection/codecs, fixed resource profiles, eager bounded BGRA8/sRGB artifacts, and typed outcomes. PresentationUI retains History/reference/task/lifecycle fencing but blocks ImageIO and exposes no CGImage across state/actor/target seams. Thumbnail source/version/request/single-flight/cache ownership remains unchanged; only already-selected encoded PNG display materialization uses the renderer. Added exact UTF-8/PNG and deterministic A3/A4/A5 lifecycle proofs plus matching import gates. |
| GOV-2a / `DEC-RET-READ` (2026-08-24) | 03a §3; 03b §11; 05 §14.6; V2-02 §8.1a/§12; V2-07 §5/§7 | Resolved configured retention as a purpose-specific requirement on the existing public `ClipboardHistory` seam: one validated persisted count+policy snapshot from one Authority interval, with no live usage, model identity, or OCC token. Recorded the owned conformer source break and prohibited a default implementation that fabricates configuration. Hoisted Settings consumption to one panel-owned draft/read generation and added public persistent-reopen plus Presentation consumer proofs. |
| Card 6B physical-ENOSPC discovery (2026-08-23, dispatch runs 32632262141 → 32634051113) | 05 §16 | Core Data's external-storage save path returns no out-of-space error: creating the `_EXTERNAL_DATA` interim file on a full volume raises an uncaught `NSInternalInconsistencyException` (SIGABRT) before §16 translation runs. Added stamped-plan capacity admission before any durable write: a plan whose encoded `.externalStorage` payload total (`.create`/`.appendRevision`/`.pruneRevisions` bytes) plus a fixed 1 MiB margin exceeds the store volume's readable raw `volumeAvailableCapacity` is refused as `.temporarilyUnavailable(.insufficientDiskSpace)`; plans writing no new external bytes never refuse; unreadable capacity fails open. The capacity fact is the raw key, not the important-usage variant: run 32634051113 observed the important-usage fact return zero on the dedicated mounted probe volume (254 MiB free), refusing every capture — the OS maintains purgeable accounting only on the boot volume. Mid-transaction exhaustion that begins after admission passes remains an Apple-framework crash ceiling, not a typed failure. |
| S1-01/S1-02/S4-01 | 02 §5.5 | `maximumUnpinnedItemCount`→`maximumUnpinnedItems`; "non-negative"→"at least 1, matching Part VI 1–5,000; 0 rejected at boundary" |
| S4-02 | 02 §6, §11 | added `DomainRejection.corruptLineage`; full DomainRejection→HistoryFailure mapping table; step 2→staleContent, step 3→corruptLineage, step 4 = Domain invariants only (Storage enforces numeric bounds) |
| S4-08 | 02 §3.1 | lastSource = `incoming.sourceApplication ?? existing.lastSource` (no nil overwrite / source regression) |
| S4-06 | 02 §2.1 | normalized set forbids empty-bytes representations |
| S4-18 | 02 §14 D3 | strengthened to iff: `activeRevisionID==nil` ⟺ revisions empty |
| S4-05/S4-21 | 02 §3.2 | PinOrdinal explicit `<`; rawValue non-negative note |
| S4-03/S4-10/S4-11/S4-16 | 02 §13 | stamping-contract note; one-advance-per-plan promoted; overflow→`.coherenceToken`/`.copyCount` |
| S4-07 | 02 §14 | added D19 (retention floor ≥1) |
| S1-07 | 03 §5 | RevisionDecisionAction resolution semantics (.inheritCanonical/.replace/.hide; hide omits from Effective, retained in Canonical; all-hidden rejected) |
| S1-03/S5-15 | 03 §10 | added `InvalidInputReason.invalidRetentionPolicy`, `.invalidSearchTerm` |
| S5-04/S5-12/S5-14/S5-17/IND-04 | 03 §8 | regexp NSFA + 1,000/title-and-body; Fuse fixed params; maxPatternLength self-enforced (dead in 1.4.0); Fuse-range→UTF-16; fuzzy pinned-first |
| S3-01 | 05 §3.1 | revisionStateBlob active-bytes clarified for Canonical-state (nil active ⟺ empty list) |
| S2-15 | 05 §2 | SwiftDataHistory Sendable derivation comment (5 actor fields) |
| S1-08 | 05 §9 | stamping bullet for setRetentionPolicy |
| S1-06/S1-12/S1-13/S1-20/S5-07 | 05 §16 | failure translation: `.dedupIndexRebuild` vs `.factProof` split; `.transaction`/`.coherenceToken` producers; cursor→`.snapshotExpired` |
| S2-02/S2-04/S2-06/S2-07/S2-10/S5-10/S1-10 | 01 §6 | all background isolations declared `actor`; RevisionPreparationActor added; SearchWorker confines non-Sendable Fuse; ThumbnailService owns flight table; manual-ModelContext-off-main note |
| S1-04 | 06 WS9 | made reachable (planner-seam hard-bound test) |
| S1-05/S1-30/S1-31 | 06 | added WS16 (remove+notFound/placement), WS17 (search+ranges+failures), WS18 (pagination+snapshotExpired), WS19 (out-of-order monotonicity), WS20 (concurrent revision+coalesce) |
| S1-15 | 00 §1, 06 §10 | `docs/greenfield/`→`docs/` |
| S1-16 | 00 §5, 01 §5.5, 04 §4 | CONTEXT.md references → inline (no external-file dependency) |
| IND-06 | 06 §9 | added one-request Debug diagnostic trace, privacy boundary, fail-fast relationship to the unchanged 101-call Release evidence, and explicit non-evidence status |

Outstanding after Pass 1 → addressed in Pass 2 (same date):

| Finding | File:§ | Change |
|---|---|---|
| S1-26 | 06 §2 | declared `HistoryLimits` (+ `standard`); test-bounds injection at planner seam |
| S1-17/S3-12 | 05 §3 | defined `historySchemaV1` = `Schema(HistoryItemRow, LastChangePositionRow)`; clarifies ModelContainer registration |
| S2-05 | 05 §14.2 | declared `SearchCorpusSnapshot` + `SearchCorpusRow` (Sendable) |
| S1-18 | 03 §8 | `pinnedPosition` is 0-based, equals `PinOrdinal`, nil if unpinned |
| S1-19 | 05 §2 | `open` throws `HistoryFailure` (invalidRetentionPolicy / persistence openStore/corrupt/invariant) |
| S1-11 | 05 §9 | Domain `HistoryMutation` → `StampedMutation` rename table |
| S3-02/03/05/06/14/15 + S4-15 | 05 §4, 06 §7.4 | aligned exhaustive decode-check / corruption-rejection lists; active-ID nil semantics (D3); fingerprint coverage-only per D7; effectiveTypeIdentifiersBlob format |
| S5-03/05/06 | 03 §8 | excerpt clamp (body<320), conditional ellipsis offset; regexp rejects backreferences, permits non-capturing groups |
| S2-08 | 03 §3 | scripted preview adapter must be `Sendable` |
| S1-24 | 03 §12 | example `snapshot.historyItemID` annotated as adapter-decoded hint |
| S5-08 | 04 §9 | thumbnail step 2 is the version gate; step2→3 gap covered by old-reference tagging |
| S1-23 | 06 WS8 | "the middle" → "the item now occupying the middle position" |

Pass 3 (2026-07-19, re-audit-driven) — fixed the 28 issues the re-audit found
(most introduced by Pass 1/2). Re-audit #2 verifies.

| Finding | File:§ | Change |
|---|---|---|
| S4-N1/S4-R2-1/S3-R9/S4-R2-2 | 02 §2.5,§2.6,§14 D3,§11; 03 §5 | removed false `activeRevisionID==nil ⇔ Effective==Canonical` biconditional (revert-to-canonical is a counter-example); D3 iff is about the revision *list*; §2.5 Rule 1, §2.6, §11 step 3 enumerate both corrupt directions |
| S1-R1 | 06 §11 | `WS1–WS15` → `WS1–WS21` |
| S3-R1 | 06 WS21 | added WS21 (`setRetentionPolicy` + `retentionPolicySet` outcome) |
| S3-R7 | 02 §5.1 | fact-load failure splits `.factProof` vs `.dedupIndexRebuild` |
| S5NEW-01 | 04 §9 | thumbnail steps 2–3 are one non-suspending Authority interval; fence is the off-Authority decode |
| S5NEW-03 | 03 §8 | fuzzy: pinned rows by `pinOrdinal`, unpinned rows by Fuse score (removed "each bucket" contradiction) |
| S1-R2 | 06 WS16 | placement→`targetMissing` vs remove/unpin/revise→`notFound` is by-design |
| S1-R3 | 05 §3 | renamed binding `historySchemaV1`→`v1Schema` (no casing collision) |
| S2R2-N1 | 05 §6.2 | declared `RevisionPreparationSnapshot` |
| S2R2-N2 | 01 §4 | removed "may run on a dedicated actor" hedge |
| S2R2-N3/N4 | 01 §6 | `@ModelActor` option + corrected proof gate to Part VI §6 |
| S3-R2/R8 | 06 WS5/WS13 | pinned `.dedupIndexRebuild` / `.persistence(.transaction)` |
| S3-R3/R4/R5/R6 | 05 §4,§16 | `EffectiveTypeIdentifiersBlobV1` codec; projection/title/searchBody bounds; bidirectional signature coverage; transaction covers framework save-boundary |
| S4-R2-3/R2-4 | 02 §11 step 2/4 | named `.invalidRevisionDraft` for invariant failures |
| S5NEW-02 | 01 §6 | SwiftDataHistory stores 5 actors; ThumbnailWorker owned by ThumbnailService |
| S5NEW-04 | 03 §8 | excerpt context redistributed at body edges |
| S5NEW-05 | AUDIT §3 | S5-12 removed from "remaining" (fixed in Pass 1) |
| S5-R2-1/R2-2 | 03 §8 | regexp over-limit→`.invalidRegularExpression`; non-capturing groups permitted unless nested-quantifier |

Pass 4 (2026-07-20, post-02:20) — final verification CLEAN (go for split) + 3
clarity fixes + the doc-size split.

| Finding | File:§ | Change |
|---|---|---|
| verify-minor-1 | 02 §2.5 Rule 3 | "means" → "implies … (one direction; iff in D3)" |
| verify-minor-2 | 04 §9 | removed duplicate stale-before-step-2 sentences (Pass 3 editing artifact) |
| verify-minor-3 | 03 §8 | added `(a+\|b)+` example for quantified-alternation rejection |
| doc-split (§5) | 03 → 03a + 03b | split 736-line `03-instruction-set.md` into `03a` (§1–7, 348 lines) + `03b` (§8–12, 390 lines); updated 00 §4 (Part III = A+B), 00 §5 ("seven files" → Parts I–VI with III split), 06 §10 WS16 ref `Part III §10`→`Part III-B §10`; `03-instruction-set.md` filename now unreferenced |

Implementation Pass (2026-07-22, roadmap step 6) — spec defect found while
implementing `commitRemove`: `planRemove` could not preserve D12 when the
target was pinned (its facts carried no pinned order, so no planner could emit
the compaction shifts, and Part V §10's final-order revalidation would fail
every such transaction). Resolved by the only D12-consistent reading: removal
of a pinned item compacts the lane exactly as unpin does.

| Finding | File:§ | Change |
|---|---|---|
| IMP6-01 | 02 §5.4, §10; 05 §7.3 | `RemoveFacts` gains `pinnedOrder: CompletePinnedOrder`; remove-of-pinned emits `.assignPin` compaction shifts before `.retire` (clear needs none — v1 scopes are trivially contiguous); remove fact load includes the §7.2 pinned-order load |

V1 verification remediation (2026-08-09) — the post-implementation audit in
`docs/V1-Verified/` proved that the earlier IND-03 self-enforcement fix still
admitted patterns wider than Fuse 1.4.0's single-`Int` bitap.

Final closure (2026-08-11) — public-symbol workflow 31448087991 and supported
code-head run 31449682036 are green. The latter passed all source/lint gates,
314 tests in 41 suites, generated-app build/test, and all 13 release workloads.
The completion prefixes below supersede each retained pre-proof “pending” note;
V1V-03B-004 remains deliberately deferred under its recorded G2 trigger.

| Finding | File:§ | Change |
|---|---|---|
| V1V-03C-001 | 03b §8; 06 §2/WS17; `Limits.swift`; `SearchWorker.swift` | **Completed 2026-08-11:** public-symbol workflow 31448087991 and supported code-head run 31449682036 are green. **Pre-proof implementation record:** Fuzzy-query ceiling **256→64**; custom `HistoryLimits` values over 64 are rejected; WS17 sweeps 1/63/64 admitted and 65/89/90/100/200/256 rejected before Fuse. macOS CI evidence pending. |
| V1V-03B-001 | 05 §14.1; 04 §6; 06 WS18; `HistoryAuthority.swift` | **Completed 2026-08-11:** public-symbol workflow 31448087991 and supported code-head run 31449682036 are green. **Pre-proof implementation record:** Unpinned continuation exactness now uses the real sorted anchor index. A full bounded slice re-fetches when already-consumed same-date siblings occupy its head, the anchor is absent, or the true page/lookahead boundary ties. WS18 traverses a same-time burst plus older rows and asserts complete ordered coverage without overlap. macOS CI evidence pending. |
| V1V-03B-002 | 05 §14.1; 06 §9; roadmap/03; `HistoryAuthority.swift` | **Completed 2026-08-11:** public-symbol workflow 31448087991 and supported code-head run 31449682036 are green. **Pre-proof implementation record:** Pinned continuation uses the documented `FetchDescriptor.fetchOffset` subrange at `anchorOrdinal`, restoring O(`limit`) page work without an optional-Int predicate while fetching, validating, and dropping the complete anchor. Lane fetches consume only remaining page capacity. The authoritative envelope is `limit+1` for first pages and `limit+2` for either continuation, plus the hard-bounded UUID-tie correctness fallback. A malformed-anchor facade regression is present; macOS CI evidence pending. |
| V1V-03A-001 | 05 §4; 06 §7.4; `ContentProjector.swift`; `FactLoaders.swift`; `HistoryAuthority.swift` | **Completed 2026-08-11:** public-symbol workflow 31448087991 and supported code-head run 31449682036 are green. **Pre-proof implementation record:** Added one shared fail-closed validator for the durable projection schema/title/searchBody. Startup, recent, search, and full hydration validate exactly the scalars they consume; persistent corruption fixtures cover unknown schema and over-bound title/body without weakening scalar isolation. macOS CI evidence pending. |
| V1V-03A-002 | 03a §4; 03b §10; 05 §4/§6.1; 06 §7.4; `RevisionStateBlobCodec.swift` | **Completed 2026-08-11:** public-symbol workflow 31448087991 and supported code-head run 31449682036 are green. **Pre-proof implementation record:** Revision creation and occurrence dates now reject NaN/±infinity. The shared last-copy validator runs on recent/search/retention scalar paths before comparison; those row paths also validate copy count and source bounds. Caller-supplied non-finite capture time maps to `.invalidInput(.invalidTimestamp)` before fingerprinting. Direct codec, persistent scalar-corruption, and ingest regressions are present; symbol regeneration/macOS CI pending. |
| V1V-03A-003 | 04 §6; `CodecWireFormat.swift`; `PageCursorCodec.swift`; revision codec | **Completed 2026-08-11:** public-symbol workflow 31448087991 and supported code-head run 31449682036 are green. **Pre-proof implementation record:** Wire coders pin base64 Data/deferred Date; cursor decode has a `6× term + 2 KiB` envelope and strict known-field validation while tolerating inert unknown metadata. Revision/scalar failures now use one `CodecRejection` and exhaustive `mapCodecFailure`, removing paired catches. Active-ID validation reuses the unique-ID set; overflow diagnostics define the `Int.max` sentinel. macOS CI pending. |
| V1V-03C-002 | 03b §8; 06 WS17; `SearchWorker.swift` | **Completed 2026-08-11:** public-symbol workflow 31448087991 and supported code-head run 31449682036 are green. **Pre-proof implementation record:** Regexp admission now conservatively rejects every quantified group containing alternation, propagating the alternation flag through nested groups. Long-input facade regressions cover `(a\|a)+b` and `(a\|ab)+c`; unquantified alternation remains admitted. No uncancellable detached timeout is introduced. macOS CI evidence pending. |
| V1V-03C-003 | 03b §8; 06 §2/WS17; `SearchWorker.swift` | **Completed 2026-08-11:** public-symbol workflow 31448087991 and supported code-head run 31449682036 are green. **Pre-proof implementation record:** The 4,096-UTF-8-byte search-term envelope is enforced once at the worker entry for exact/regexp/fuzzy, before mode-specific Character admission. Wide-grapheme 4,096/4,097-byte fixtures pin precedence and public failures. macOS CI evidence pending. |
| V1V-03C-004 | 05 §15; 06 §9; `ContentProjector.swift`; `HistoryAuthority.swift` | **Completed 2026-08-11:** public-symbol workflow 31448087991 and supported code-head run 31449682036 are green. **Pre-proof implementation record:** Search-body projection now accumulates directly under the stored UTF-8 bound and stops at a Character boundary instead of joining up to the full capture envelope. Whitespace-only representations contribute neither bytes nor separators. Revision summaries call the title-only projector. Direct projector regressions are present; macOS CI evidence pending. |
| V1V-03C-005 | 03b §8; 06 §9; `SearchWorker.swift` | **Completed 2026-08-11:** public-symbol workflow 31448087991 and supported code-head run 31449682036 are green. **Pre-proof implementation record:** Exact search still scans the full bounded body, but excerpt construction no longer creates a full `[Character]` copy. It traverses with `String.Index` and owns only the at-most-320-Character window plus bounded UTF-16 offsets. Five direct worked examples pin both edge redistributions, both ellipses, long-match clipping, and supplementary-plane UTF-16 translation; macOS CI pending. |
| V1V-03D-002 | 03b §10; 05 §16; 06 WS15; `Failures.swift`; `ThumbnailService.swift` | **Completed 2026-08-11:** public-symbol workflow 31448087991 and supported code-head run 31449682036 are green. **Pre-proof implementation record:** Added `CapacityKind.thumbnailBytes`: valid PNG output over 16 MiB is now a typed capacity failure. Destination creation and finalization share the encode-side invariant mapping; a pure boundary regression pins equality/one-byte-over and prevents reclassification as stored corruption. Symbol regeneration and macOS CI pending. |
| V1V-03D-001 | 03a §4; 03b §10; 05 §6.1/§16; roadmap/04 | **Completed 2026-08-11:** public-symbol workflow 31448087991 and supported code-head run 31449682036 are green. **Pre-proof implementation record:** `ClipboardCapture.isConcealed` carries pasteboard-level privacy; six recognized sibling markers reject the whole capture as `.excludedFromHistory` before byte validation/fingerprinting; direct preparation and public-facade regressions prove no hash/commit/row. Symbol regeneration and macOS CI evidence pending. |
| V1V-04-001 | 06 §9; `ThumbnailService.swift`; `HistoryPerfRunner/main.swift` | **Completed 2026-08-11:** public-symbol workflow 31448087991 and supported code-head run 31449682036 are green. **Pre-proof implementation record:** WL8 keeps an untimed public-facade smoke, then times the package production `ThumbnailService` with one prefetched immutable source. The concurrent-8 ratio now isolates exact-key join/decode sharing instead of eight serialized Authority fetches. macOS perf CI evidence pending. |
| V1V-01-001 | 03a observation contract; 06 G8/§2; HistoryCore tests | **Completed 2026-08-11:** public-symbol workflow 31448087991 and supported code-head run 31449682036 are green. **Pre-proof implementation record:** Documentation closes G8 read-path RSS/copy evidence, validated custom-limit test profiles, and the intentionally untyped observation error ABI. Raw UUID order/trichotomy, `HistoryItemID.description`, the production comparator in WS support, and the `ActorStubs.swift`→`RevisionPreparationAndSearchCorpus.swift` rename are local and remain in-progress until macOS CI. |
| V1V-02-001 | 02 planner ownership/retention; direct Domain tests | **Completed 2026-08-11:** public-symbol workflow 31448087991 and supported code-head run 31449682036 are green. **Pre-proof implementation record:** Capture avoids eviction sorting when victim count is zero; clear uses an exhaustive `ClearScope` switch; dead `revisionNotFound` Domain vocabulary is removed and revert-ID lookup remains Storage-owned. Storage's 1...5,000 retention admission boundary is documented and WS21 covers zero/over-bound inputs. Code/test proof remains in-progress pending macOS CI. |
| V1V-03C-006 | 04 observation; 05 post-commit interval; publisher implementation | **Completed 2026-08-11:** public-symbol workflow 31448087991 and supported code-head run 31449682036 are green. **Pre-proof implementation record:** Synchronous termination owns one weak, idempotent actor hop (`documented`); newest-value `yield` remains the specified non-suspending post-commit publication (`not-a-defect`). Zero-use `StepDeferredError`, contradictory scaffolding prose, and publisher `subscriptionCount`/`finishAll` helpers are removed; macOS observation/build proof remains. |
| V1V-04-002 | 06 §9; `HistoryPerfRunner/main.swift`; `HistoryPerfRunnerTests` | **Completed 2026-08-11:** public-symbol workflow 31448087991 and supported code-head run 31449682036 are green. **Pre-proof implementation record:** Median handles odd/even samples and rejects empty input; every non-positive ratio fails finite bounds; WL4 uses 1+5 samples and a quadratic-sensitive 6×/3× envelope; WL1b prebuilds inputs; comments name the capture interval accurately. A declarative workload/bullet map is runtime-asserted and recorded in fixture schema v2. PNG CRC/RNG helper coverage plus macOS tests/perf proof remain. |
| V1V-04-003 | 06 §9 fixture governance; `HistoryPerfRunner/main.swift` | **Completed 2026-08-11:** public-symbol workflow 31448087991 and supported code-head run 31449682036 are green. **Pre-proof implementation record:** Fixture values are `Sendable`; hostname PII is removed; architecture/hardware/processor and actual `xcrun swift --version` are recorded; the duration divisor is named. Dead `searchNoMatch`, `lengthDigest`, and redundant WL2 scopes are gone. Strict-concurrency/macOS runner proof remains. |
| V1V-04-004 | 03b §8; 06 WS17/§9; CI zero-warning policy | **Completed 2026-08-11:** public-symbol workflow 31448087991 and supported code-head run 31449682036 are green. **Pre-proof implementation record:** U+0130 WS17 now proves lowercase scalar expansion without Character-offset drift and verifies original-title UTF-16 ranges. Runner failure prose no longer collides with `error:` self-scan tokens; the unexcluded-diagnostic scan and narrow AppIntents/autoShortcut exceptions are unchanged. macOS tests/log proof remains. |
| V1V-ALL-001 | `docs/V1-Verified/06`–`07` | **Completed 2026-08-11:** public-symbol workflow 31448087991 and supported code-head run 31449682036 are green. **Pre-proof implementation record:** Added the mechanically complete 222-ID disposition ledger and remediation work queue. Every canonical ID has one terminal/current status; duplicates name an existing target; every deferred item records owner, trigger, and residual risk. Portable ledger checks pass; behavior items remain `in-progress` until macOS proof. |
| V1V-02-002 | 02 §2.1/§9; Domain content tests | **Completed 2026-08-11:** public-symbol workflow 31448087991 and supported code-head run 31449682036 are green. **Pre-proof implementation record:** Corrected the equality contract to canonical-equivalent Swift `String` identifiers plus byte-exact payload `Data`, without rewriting stored spelling. Non-adjacent decomposed/precomposed duplicate coverage is local; macOS proof remains. |
| V1V-02-003 | 02 §14; `HistoryDomainTests` | **Completed 2026-08-11:** public-symbol workflow 31448087991 and supported code-head run 31449682036 are green. **Pre-proof implementation record:** Added a 47-test direct suite covering all seven planners across commit/no-op, planner-owned rejection, capacity, ordering, and complete payloads. `DomainSmokeTests` maps D1–D19 to their runtime, Storage-stamping, or structural proof owner. macOS `swift test` remains. |
| V1V-03B-003 | 05 §9/§16; `HistoryAuthority.swift`; transaction-guard tests | **Completed 2026-08-11:** public-symbol workflow 31448087991 and supported code-head run 31449682036 are green. **Pre-proof implementation record:** Extended one-shot transaction injection to the position guard and all four concrete apply guards. Normal public actions now prove uniform `.persistence(.transaction)` mapping and rollback of both rows and Change Position; macOS SwiftData proof remains. |
| V1V-03C-007 | 03b §8; 06 WS17; `SearchWorker.swift` | **Completed 2026-08-11:** public-symbol workflow 31448087991 and supported code-head run 31449682036 are green. **Pre-proof implementation record:** Regexp preflight now tracks nested/POSIX sets and ICU `\Q…\E` quoting, and conservatively rejects inline activation of comments/free-spacing mode. Direct parser and supplementary/combining UTF-16 regressions supplement WS17; macOS proof remains. |
| V1V-03C-008 | 04 §5/§7; `SearchWorker.swift`; observation tests | **Completed 2026-08-11:** public-symbol workflow 31448087991 and supported code-head run 31449682036 are green. **Pre-proof implementation record:** Added a nil-in-production SearchWorker evaluation suspension point. A deterministic test captures an old immutable corpus, commits while evaluation is parked, and requires the first visible page to be recomputed at exactly the new position. Static actor/deadlock review passed; macOS observation proof remains. |
| V1V-03C-009 | 05 §7.1/§14; fact loaders; WS5 | **Completed 2026-08-11:** public-symbol workflow 31448087991 and supported code-head run 31449682036 are green. **Pre-proof implementation record:** Capture now derives retained-ID coverage and retention facts from one duplicate-checked scalar inventory on the healthy path; explicit proof-purpose mapping preserves ordinary durable-state failure versus capture's `.dedupIndexRebuild`. New over-bound, D12 gap/duplicate, and stale-ready regressions await macOS SwiftData proof. |
| V1V-03D-003 | 05 §6.1; ingest preparation tests | **Completed 2026-08-11:** public-symbol workflow 31448087991 and supported code-head run 31449682036 are green. **Pre-proof implementation record:** Direct admission, normalization, privacy, marker, and timestamp tests cover the preparation branch matrix, including no-fingerprint/no-commit proof for concealed captures. macOS actor/facade proof remains. |
| V1V-04-005 | 06 §9; `HistoryPerfRunner`; helper tests | **Completed 2026-08-11:** public-symbol workflow 31448087991 and supported code-head run 31449682036 are green. **Pre-proof implementation record:** Every gated fixture consumes one declarative scales/growth/bound/headroom table; preflight derives theoretical ratios, enforces finite bounds and the 1.5× floor, and allows only WL1a's named 1.2× exception. Extracted production CRC-32/xorshift32 helpers have independent KATs; macOS executable import/tests and release perf remain. |
| V1V-03B-004 | 06 §9; V1V disposition ledger | Removed an unimplemented claim that the normal-case runner records unpinned exactness-fallback incidence. WS18 owns correctness. A separate 5,000-row same-timestamp, per-public-page admission workload is now in pre-proof; until supported artifacts exist and its p95 is evaluated against the exact G2 trigger, the canonical optimization remains deferred. The normal-case browse envelope still cannot close it. |
| V1V-01-002 | 06 §2; `Limits.swift`; HistoryCore tests | **Completed 2026-08-11:** public-symbol workflow 31448087991 and supported code-head run 31449682036 are green. **Pre-proof implementation record:** Run 31449140919 disproved the audit's assumption that inverted `ClosedRange(uncheckedBounds:)` survives on Xcode 26.6. The package initializer now accepts scalar endpoints, rejects invalid ordering, and constructs all three ranges only after validation; the source report records the supported-runtime correction and keeps the finding in progress pending rerun. |
| V1V-03B-005 | 04 §9; 05 §14.5; 06 §9; `ThumbnailService.swift`; WS15 | **Completed 2026-08-11:** supported run [31494740863](https://github.com/GuangDai/Clipy/actions/runs/31494740863) passed source/lint gates, strict SwiftPM build/tests, app build/test, and all 13 release workloads. **Pre-proof implementation record:** The exact-key flight now owns source hydration through ImageIO decode. Concurrent joiners run scalar dimension/existence/version fences, reducing C overlapping identical requests from C full lineage/source hydrations to one full hydration plus at most C−1 scalar reads. A failed stale join does not cancel the creator. The creator still owns complete fail-closed lineage/projection/codec validation; when an already-corrupt store and a stale reference coexist, the public contract intentionally does not freeze which typed failure wins, but no path returns current bytes under an old key. |
| V1V-04-006 | 06 §3/§9; `HistoryPerfRunner/Admission.swift`; `macos26-arm-ci.yml` | **Pre-proof implementation record:** Added a dispatch-only persistent 5,000 × 256 KiB admission lane after source and SwiftPM correctness gates. Versioned fixtures separate setup phase duration from 101-sample nearest-rank p50/p95/p99. Tie-heavy latency is sampled per public page, exact-search RSS is labeled a worst-bound process ceiling rather than complete G8 evidence, and warm opens run in independently terminated child processes after a full-corpus validation warmup. Diagnostic run 31498144173 exposed two setup defects: only 1,500/5,000 rows completed and 599 CoreData external-data clone attempts referenced missing `.interim` files. The replacement keeps the Authority as sole writer and changes fixture construction from 5,000 public captures/cumulative O(N²) inventory work to 79 bounded create transactions. Runs 31527425658 and 31597596383 proved that lexical release and then process separation still allowed an intermittent external clone during full validation. The follow-up bounds startup/capture/recent context-backed objects with operation-local autorelease pools, emits fixed prepare-phase and opt-in Debug storage-lifecycle checkpoints, preserves short diagnostics after a clean-log failure while skipping long measurements, and isolates every WL2 population/open in a child process whose sample excludes launch/teardown. A fixed 1,000-row same-size smoke and exact CoreData log rejection remain unchanged. Results remain record-only; approved-minimum-hardware G5, representative concurrent-call G8, fsync/crash, and general external-storage no-fault evidence remain outside its claims. Historical supported runs 31795729218 (scale) and 31806199483 (exact A/B) are green; Batch 32 current-master manual run 32685185124 attempt 2 is green for same-SHA correctness, all 13 exact cases, and every scale mode. |

### Deferred exact-search complexity review (2026-08-12)

IND-07 was opened after the manual admission trace reported approximately 125
seconds for each absent-term exact request. That trace is diagnostic rather
than canonical G2/G8 evidence, but the source path independently proves the
structural amplification: one validation, one warmup, and 101 samples can each
materialize the complete 5,000 × 256 KiB body envelope, or about 125.7 GiB of
logical body values across the process lifetime.

A throwaway, deterministic candidate-filter prototype was run and removed
after recording these results:

- the artificial admission corpus is eliminated entirely by a case-folded
  128-bit ASCII byte-presence proof (0/5,000 candidates; about 80 KiB total
  row metadata), so that corpus alone must not choose the production shape;
- 3,201 planted-substring/case differential checks produced zero false
  negatives under the prototype's ASCII-only coverage rule;
- a one-hash trigram bitset over a high-entropy 256 KiB row is approximately
  98.2%, 86.5%, 63.2%, and 39.3% occupied at 8, 16, 32, and 64 KiB per row.
  Thus 8 KiB is effectively saturated, while 32 KiB is the first tested size
  near a 65% occupancy target (156.25 MiB for 5,000 rows).

The implementation order under review is deliberately layered:

1. compile one matcher per public request; use linear KMP for the eligible
   ASCII subset (excluding CRLF-coordinate ambiguity) and preserve Foundation
   as the complete fallback semantic oracle;
2. propose a separate G9 conservative exact-candidate-index graft rather than
   misclassifying it as G2's result/collection cache; Part VI must admit it
   before implementation;
3. test a byte-presence front filter plus one-hash trigrams against
   representative text, source, high-entropy, repeated-prefix, Unicode, and
   forced-collision corpora before choosing fixed or adaptive storage;
4. permit exclusion only for complete, current, proven-ASCII coverage. Short,
   Unicode, missing, stale, corrupt, or unready evidence fails open to full
   candidate hydration; Foundation decides every fallback comparison, while
   the eligible-ASCII matcher is differential-tested against that oracle.

The first matcher step establishes a linear ASCII baseline and reusable needle
preprocessing. Whether it improves Release latency or allocation over
Foundation remains a measurement question; it does **not** close
`search-corpus-materializes-full-inline-searchbody`. Avoiding the 1.22 GiB
per-request hydration requires the separately reviewed, provisionally named G9
seam.

The dispatch-only matcher screen fixes that decision rule before observing its
result. It compares equal four-coordinate outputs over a 32 MiB corpus in two
warmups plus 11 adjacent AB/BA pairs. The primary admission-absent case must be
at least 20% faster (`paired median <= 0.80`), every representative/adversarial
case may regress by at most 10%, and each Foundation fallback may regress by at
most 25%. The 13 cases include early/middle/late hits, source-shaped and
high-entropy ASCII, short/long absent needles, a repeated-prefix adversary, and
Unicode/CR fallbacks. Even a complete pass only admits a subsequent one-to-three
call same-store Release comparison; it cannot establish G2/G8 or candidate-index
evidence and does not justify the 101-sample lane by itself.

**2026-08-14 matcher step 2 (word-prefilter scan + measurement budget):** the
eligible-ASCII matcher's scan now follows the scalar shape glibc/musl `memmem`
and Rust `memchr::memmem` use (verified against their sources plus simdjson and
Arm NEON movemask literature): one 8-byte SWAR sweep per word answers
all-ASCII eligibility, no-CR eligibility, and case-folded needle-head presence;
candidate offsets pay a folded verification that re-checks every needle byte;
and a 256-failed-verification budget switches adversary-shaped corpora to the
linear KMP automaton, preserving the O(n + m) worst case. Case comparison
accepts exactly each letter's two ASCII cases (never a blanket `| 0x20` fold,
which collides distinct bytes); Foundation remains the complete semantic
oracle. Eligibility is prefix-scoped: a `.caseInsensitive + .literal` match
has exactly the needle's length, so proving `[0, s + m)` all-ASCII and CR-free
suffices for an accelerated result at `s` — an earlier Foundation-visible
match (including one relying on non-ASCII folds such as U+212A) would lie
wholly inside that prefix, and both coordinates are prefix-determined. Hit
rows therefore stop at the match end like Foundation instead of proving the
whole body; absent rows still prove every byte before the accelerated nil
verdict. New differential tests lock word-boundary/decoy layouts and
non-ASCII/CR fallback layouts against that oracle. A NEON
`SIMD16` port was evaluated against the researched pure-Swift idioms and
deferred: the published `((a^b) &- 1) &>> 7` equality idiom has false
positives (e.g. `a^b = 0x81`), so the UInt64 SWAR form ships first and the
same A/B lane quantifies any later vector port. The exact-search admission
budget is reduced from 101 to 11 samples (frozen by test; fixture note and
workflow jq updated): at roughly 125 s per absent-term request, the 101-sample
budget needed about 3.6 hours against the lane's 90-minute step ceiling, while
thirteen total requests land near half an hour; at n = 11 the nearest-rank
p95/p99 both select the sample maximum. Supported admission run
[31795729218](https://github.com/GuangDai/Clipy/actions/runs/31795729218)
then completed the whole 5,000-row dispatch lane for the first time: the
absent-term worst-bound request measured p50 1.59 s / p95 2.39 s over the
5,000 × 256 KiB corpus (11 samples) against the ~125 s Foundation diagnostic
trace that opened IND-07 — roughly 79× on p50 — with the exact-search step
finishing in 24.4 s and 1.59 GiB peak process RSS (worst-bound ceiling,
record-only; still not G2/G8 evidence, and the per-request 1.22 GiB corpus
hydration remains until the G9 seam). Follow-ups the same day: a Debug-only
route-instrumentation suite pins the matcher's compiled/Foundation routing
(word alignments, prefix-scoped finish mode, adversary switch, randomized
sweep), the worker probe's title/body route accounting and 250-row progress
cadence are locked by tests, and admission percentiles are now per-rank
support-gated — p50 needs n ≥ 3, p95 n ≥ 20, p99 n ≥ 100 (ceil(p·n) < n),
otherwise the rank encodes as JSON null instead of a disguised sample
maximum — with the matcher A/B lane carrying per-case corpus sizes (the
repeated-prefix adversary runs 2 bodies — instrumented runs measured its
Foundation side near 12 s per 256 KiB body, an O(n·m) NSString pathology, so
the case proves the compiled side's linearity at a size its fallback can
finish) plus one unbuffered stderr progress line per case so a
stalled dispatch shows exactly where its budget went. The completed screen
([31806199483](https://github.com/GuangDai/Clipy/actions/runs/31806199483))
passed all 13 cases: every eligible-ASCII case's paired median came in at
0.000x–0.036x of Foundation, and the three Foundation-fallback cases at
0.98x–1.02x (gate overhead is free), so `productionIntegrationEligible` is
true — which admits the subsequent one-to-three-call same-store Release
comparison, not G2/G8 evidence.

**2026-08-14 complexity pass (search-worker scan budget, deferred
presentations, fused excerpt walk, capture-path byte-hashing):** a
three-lane algorithm audit (HistoryDomain pure planners, HistoryStorage
search/read paths, authority/codec/runner) found no remaining quadratic
planner — pin compaction is dictionary-indexed O(m), dedup candidates pay
byte confirmation once, `effectiveContent` is a single O(k) walk, and
eviction already uses a bounded heap below the quarter threshold — so the
pass targeted the search evaluator and the capture path's constant factors:
(1) order-preserving lanes now carry the page's scan directive — after the
continuation anchor, at most `limit + 1` matched rows can still influence
the page or its `next` cursor, so exact/regexp scans stop there and the
recent-equivalent lane materializes only the bounded window (a deep
continuation still scans fully until its anchor; a missing anchor still
expires the cursor); (2) matched-row presentations defer to page
materialization — excerpt text, UTF-16 translation, and the scan-prefix
re-derivation are paid only for returned rows, never for the rows a bounded
page drops and never rebuilt per continuation page; (3) the frozen 03b §8
excerpt window is computed by a fused walk — at most `windowCapacity + 1`
Characters decide the whole-body branch, one forward walk to the pre-clamp
upper bound records the window indices, and the rare end-clamp pays a
bounded ≤ windowCapacity backward step, replacing the full-body `count`
walk plus up to two `index(offsetBy:)` walks per excerpt (semantics proven
identical against the existing worked examples plus new capacity-edge,
zero-length-match, and multi-scalar-grapheme cases); (4) the fuzzy lane
slices its 5,000-Character body prefix as a `Substring` with the Character
count derived from the same pass (one bounded copy for Fuse, no per-row
title prefix copy — titles are ≤ 1,024 UTF-8 bytes and the whole title is
provably the scanned prefix), and (5) capture lane-1 byte-set equality now
builds `typeIdentifier → bytes` dictionaries instead of hashing every
clipboard byte into a `Set` — the exact shape `canonicalContains` already
documented as correct one lane below — while `ContentProjector.project`
stops decoding further representations once the title and the 256-KiB body
budget are both complete (a later representation can contribute neither).
The runner's PNG checksum is table-driven and incremental (no ~3 MiB
concatenation per chunk) and its scanlines build one reserved `[UInt8]`
converted in a single `Data` init. Debug instrumentation now covers every
search lane — fuzzy and regexp gained begin/progress/complete events with
separate title/body accounting, locked by tests alongside the exact lane's
— and new boundary tests pin the eviction heap/sort quarter-threshold
agreement, 100-revision lineage resolution/rejection, multi-representation
lane-1 equality (positive and one-byte-different negative), the projector's
budget-complete skip, and the prefix-slice Character bound. HistoryDomain
itself stays probe-free by design: its purity rules (no I/O, actors,
clocks, or mutable statics) ban hook-style instrumentation, so its
observability remains its fully self-describing plan values plus these
boundary tests. The dispatch-only admission workflow's strict log scans now
prefilter the known-benign CoreData external-storage clone race (runs
[31808691118](https://github.com/GuangDai/Clipy/actions/runs/31808691118),
[31809994808](https://github.com/GuangDai/Clipy/actions/runs/31809994808);
same runner image as the green run) — a later transaction in the same
process attempts to clone an earlier batch's external record from its
already-consumed `.interim` staging name, logs the failure, and CoreData's
copy fallback completes the save — stripping only those multi-line error
blocks while every other warning/error or missing-file line stays fatal and
the per-phase jq row/position/transaction assertions remain the
data-integrity gate. Supported full-scope run
[31815028830](https://github.com/GuangDai/Clipy/actions/runs/31815028830)
is green end to end — gates, SwiftPM (384 tests), app build/test, §9
proofs, and the 5,000-row evidence lane completing cleanly under the
prefilter for the first time since the race began reproducing; the
matcher A/B lane remains separately scoped (green at 31806199483).

All remaining findings and their explicit owners/triggers are tracked in
`docs/V1-Verified/07-finding-dispositions.md`. The supported CI, performance,
symbol-surface, and independent completion-review prerequisites are complete.
The post-closure complexity pass has reopened three evidence/complexity rows:
the canonical
ledger currently has 111 fixed, 28 deferred, and 3 in-progress rows with no pending
rows. Every remaining deferred item retains an explicit owner, trigger, and
residual risk.

### Roadmap (2026-07-20)

Built `docs/roadmap/` (README + 7 module files), **covering all 8 Part I §2 targets** (xxh3+Fuse co-documented in Module 7)
(HistoryCore, HistoryDomain, HistoryStorage, PasteboardAdapter, PresentationUI,
ClipyApp, xxh3+Fuse), ordered by Part VI §5. Each module doc: Status · Spec-ref ·
Dependencies · Deliverables · Acceptance (WS#/Part VI proof) · Risks. A semantic
1:1 verification agent returned no invented content; 4 citation/scope nits
fixed: (a) `03-historystorage` WS range → WS1–WS21 + added WS15; (b) same file
Deliverables added `PreparedRevisionBundle`/`SearchCorpusSnapshot`/`SearchCorpusRow`;
(c) `06-clipyapp` XcodeGen gate ref → Part I §9.6; (d) README §3 de-duplicated
WS11/WS12 between steps 5–6. Mechanical self-check passed (all spec-refs resolve,
all internal links resolve, all cited types exist in spec).

**Design → roadmap → code traceability chain is now complete and reversible:**
any spec section → its module (README §2 map) → its WS/proof gate; any code →
its spec section + gate via the module doc + this change log.

### Roadmap critique + revision (2026-07-20)

A 4-round × ≤5-agent roadmap-critique workflow judged the first roadmap draft
**NOT SOUND** on completeness and ordering (66 confirmed / 5 refuted / 0 open).
Load-bearing findings, all fixed in this revision:

- **No Phase-0 scaffold** (RC1-01/04): README §3 started at HistoryCore with no
  step to create the package/target graph/XcodeGen/import-gate/symbol-snapshot
  that HistoryCore's own Acceptance invokes, and no owner for the Part VI §6
  graph-level proofs. **Fix:** added step 0 (scaffold) owning the §6 graph proofs.
- **xxh3 + Fuse unsequenced — both are step-4 compile deps** (RC1-05, RC2-01/10,
  RC4-05): `SwiftDataHistory.searchWorker` is a stored field initialized by
  `open`, so Fuse (not just xxh3) is needed at step 4. **Fix:** added step 3
  (integrate xxh3 + Fuse before step 4).
- **9/21 WS gates mis-steped** (RC2-02..09, RC3-02, RC4-08, RC5-01): gates at
  steps 5–6 carried public-read/observation clauses checkable only at step 7/9b;
  WS14 (restart) was unplaced. **Fix:** WS-clause-phasing note + WS14 placed at
  step 6; full suite re-runs at step 9b.
- **State-3 product concerns unowned** (RC1-02, RC4-09, RC5-02). **Fix:** §5
  state-3 deferral note (separate acceptance per Part VI §11).
- **HistoryLimits type unowned** (RC1-03). **Fix:** Module 1 Deliverables +
  AUDIT flag (spec does not locate the type; HistoryCore is the natural home).
- **Hierarchy**: added Phase 0/M1/M2/M3 phases, module-owner prefixes, step-9 split
  (9a/9b) (RC4-03/04/07); HistoryStorage sub-steps 4–8 (RC4-06); Test-target
  line on every module (RC1-06/RC4-13); import-confinement Acceptance on
  Modules 2–5 (RC1-09/RC5-15/17); HistoryStorage BLOCKER risk flags for §7.1/§7.2
  + concurrency-harness prerequisite (RC5-04/07/08/18); spec-ref completions
  (RC3-05/11/12); Module 7 renamed "Dependencies" with Deliverables (RC4-02/11);
  §9 added to completion gating (RC3-01/RC5-03); traceability §4 softened for
  cross-cutting edits (RC3-10/RC5-06); "1:1" wording corrected to "covers all 8
  targets" (RC3-07/RC4-01); Foundation-dep column made consistent (RC3-03/13).

Post-revision self-check passed (WS1–WS21 all cited; steps 0/3 + phases present;
every module has a Test target; no broken links; §9 in completion gating).

### Roadmap Round B — fresh-lens verification + fixes (2026-07-20)

5 fresh-lens agents (developer-simulation / verbatim-fact / mechanical /
adversarial / completeness). Verdict converged: **no critical; sound on
architecture, isolation, single-writer, graft-promises, stub-actor `Sendable`,
and step-order topology**. Load-bearing fixes applied:

- **MAJOR — concurrency harness unscheduled** (3 agents; adversarial raised to
  MAJOR): WS12/13/15/20 need a deterministic concurrency harness + (WS13) a
  transaction-injection seam, neither in the spec. **Fix:** scaffolded at step 0,
  finished at step 5; added as Module 3 Deliverable (test infrastructure); §5
  notes state-2 requires it delivered.
- **MAJOR — phasing note mis-stated WS2 + omitted WS5:** WS2 has no observed-page
  clause (only WS1); WS5's no-row/no-position/no-invalidation clauses need step 7.
  **Fix:** dropped WS2, added WS5; clarified **state 2 closes at step 8** (all WS
  via direct `SwiftDataHistory`, reads at step 7, harness at step 5); step 9b is
  M3 re-verification, not a state-2 requirement.
- **A1 (unanimous, 5 agents) — "1:1 with Part VI §5" false:** Part VI §5 lists 7
  targets incl xxh3 but NOT Fuse (external SPM). **Fix:** reworded — Part I §2
  lists both; Part VI §5 lists xxh3, Fuse is external.
- **A2 — step-0 build break:** "create exactly Part I §1 graph" included the
  HistoryStorage→Fuse edge, unresolved until step 3. **Fix:** step 0 declares
  placeholder/stub targets, HistoryStorage WITHOUT the Fuse edge, xxh3 with
  placeholder source; step 3 adds the real xxh3 + the Fuse edge.
- **WS19 mis-steped (step 6 → step 5):** WS19 is capture/coalesce occurrence
  monotonicity, not a mutation. Moved.
- Plus: M↔state mapping; M2 arrow includes step 3; "7 production = 6 SwiftPM +
  ClipyApp via XcodeGen"; "(7+6) Part VI §5" citation; "every module … where
  applicable"; manifest-convention softened; `.factProof` attributed to Storage
  boundary (not planner); snapshot package-init clarified; §7.2 moved to step 7
  (read-side); §7 proofs phased by step; §7.5 projection-redesign fallback;
  Module 6 second-open citation + state-2 wording; `HistoryLimits` sanctioned in
  06 §2 (HistoryCore home); xxh3 collision-double = Storage-only; AUDIT register
  statuses refreshed (no stale "open"); `8a/8b`→`9a/9b`; ClipyApp→HistoryCore
  edge footnoted; "Part I §9 item 6" (not §9.6); Step label on every module.

### Roadmap Round C — adversarial re-verify + fixes (2026-07-20)

Single adversarial agent found a propagation blocker: §7.2 had been moved to
step 7 in the module doc but NOT in README (step 5 still claimed it — an
impossible BLOCKER proof). Fixed: §7.2 now only at step 7 across README + 03;
§7.4 added to step 4; "Part I §9 item 6" (not §9.6); step-7 deferral list
broadened; xxh3/Fuse incremental-convention wording aligned; §9 perf-runner
scheduled (step 0 scaffold); `ClipyIntegrationTests` XcodeGen-hosted note.

### Roadmap Round D — full 4-round verify + fixes (2026-07-20)

4-round × ≤5-agent workflow (5 fresh angles). **Architecture confirmed SOUND by
all angles** (chain compiles step-by-step, `swift package resolve`@step0,
stub-actor `Sendable`, WS partition exact = 5@5+10@6+5@7+1@8, state-2 reachable
@step8). 1 MAJOR + ~13 MINOR found — all documentation precision, not
architecture. **MAJOR fixed: Fuse first-used timing** — README/07 said
"Fuse@step5" but 03 (architecturally correct) says the step-5 `SearchWorker` is
a stub; **Fuse is first USED at step 7** (WS17 is its sole consumer). Split to
xxh3@5 / Fuse@7 (both pinned step 3). Minors fixed: WS2/WS21 added to step-7
deferral lists; WS4 removed from the step-5-6 example; M2 arrow prepends
`deps (xxh3+Fuse) →`; §9 release-runner added to M2 closure; `HistoryConfiguration`
→ `HistoryAction` in the ClipyApp→HistoryCore footnote; module-shape adds `Step`;
§7.7/§7.8 + §9 phased by step; xxh3-double timing (step 3 created / step 5
exercised); `HistoryLimits` parenthetical (06 §2 now sanctions); Pasteboard-
AdapterTests overclaim removed; Module 6 second-open positive gate; 00-overview
"1:1"→"covering all 8". Round E verification follows.

## 4. Workflow final verdicts (merged with independent verification)

`clipboard-design-audit` complete: 20 agents, 4 rounds (Analyze→Investigate→
Critique→Settle). **108 unique issues → 97 CONFIRMED / 18 REFUTED / 0 OPEN.**
Per-defect detail: journal at
`…/subagents/workflows/wf_88c66729-323/journal.jsonl` (one `result` line per
agent); aggregated output captured 2026-07-19.

> Independent cross-check caught an R1 over-claim that R2–R4 also refuted:
> `S2-concurrency-01` ("fuse-swift HEAD = 2.0.0-dev, different API") — actually
> latest stable tag = **1.4.0** (design pin correct); 2.0.0-rc.1 is pre-release.
> This is why fixes waited for verified verdicts, not R1 alone.

### 4b. Critical independent resolutions (load-bearing)

| Item | Workflow raised | Independent verdict | Action |
|---|---|---|---|
| Fuse version "1.4.x" | S2-01 (major: wrong version/API) | **REFUTED** — 1.4.0 is the latest stable tag; 2.0.0-rc.1 is pre-release. Design pin is correct. | none (keep 1.4.x); possibly name repo `krisk/fuse-swift` for traceability |
| Fuse `maxPatternLength` | S5-02 + IND-03, **deepened by S5-17 (major)** | **CONFIRMED** — Fuse 1.4.0 source shows `maxPatternLength` is a DEAD param (never read; "return nil" unimplemented). So the bound cannot be delegated to Fuse. | **fix in the design, not Fuse**: 03 §8 enforces the 256-char fuzzy-query bound itself (reject >256 pre-Fuse via `invalidInput`); do not claim Fuse enforces it |
| Fuse `location`/`distance` | IND-04 | **CONFIRMED gap** — relevance-affecting, undiscussed | fix: fix+fixture in 03 §8 / 01 §4 |
| Fuse non-Sendable (Swift 5 class) | S5-01, S2-02 | **CONFIRMED** — confinement to SearchWorker is correct design, but SearchWorker's `actor` declaration is missing → `SwiftDataHistory: Sendable` not provable | fix: declare `actor SearchWorker` (and ThumbnailService isolation) |
| `ModelContext` main-actor? | S2-10 (major) | **NOT fatal** — only the SwiftUI-environment context is main-actor-bound; manual `ModelContext(container)` is usable off-main (SwiftData `@ModelActor`/`ConcurrencySupport` exists for exactly this). | fix: 01 §6 / 05 §5 must state non-use of env context + gate Swift-6 compilability + evaluate `@ModelActor` (cross-ref S2-04) |
| `transaction(_:)` closure sync? | S2-03 (major) | **RESOLVED** — Apple signature `func transaction(block: () throws -> Void) throws`; synchronous non-Sendable closure ⇒ no-await interval is type-system-enforced | none (cite signature) |

### 4c. CONFIRMED defects by severity (97 total; fix pass in §3/§6 order)

**MAJOR (15)** — S2-15 `SwiftDataHistory: Sendable` unprovable (SearchWorker /
ThumbnailService fields); S3-01 "active bytes always present" false for
Canonical-state items; S5-17 Fuse `maxPatternLength` dead param (see 4b);
S1-01 retention two field names; S1-02 retention range contradicts (Part II
"non-negative" vs Part VI "1–5,000"); S1-03 no `InvalidInputReason` for
out-of-range retention; S1-04 WS9 failure unreachable at fixed 5,000 bound;
S1-05 included behaviors with no WS path; S1-06 `UnavailableReason
.dedupIndexRebuild` no producer; S1-07 `RevisionDecisionAction.hide` no
semantics; S1-08 Part V §9 stamping omits `setRetentionPolicy`; S2-02
SearchWorker not declared `actor`; S4-01 (=S1-02) retention floor; S4-02
`effectiveContent` corrupt-lineage throw has no `DomainRejection` corruption
case + §11 step 3 contradicts §6; S5-14 Fuse ranges are Character-indices into
a lowercased copy, violating the UTF-16 `matchedRanges` contract.

**MINOR (54)** — S1-10/11/12/13/14/15/16/17/18/19/20/26/30/31; S2-04/05/06/07/
08/12/13/16; S3-02/03/04/05/06/07/11/12/14/15/16; S4-03/04/05/06/07/08/10/11/
13/16/17/18; S5-01/02/03/04/05/06/07/08/15/18. (Locations in workflow output.)

**NIT (14)** + **QUESTION (14)** — wording / traceability; resolved in the fix
pass with one-line clarifications or explicit "out of v1 scope" notes.

### 4d. Notable REFUTED (18) — looks wrong, is correct (kept for provenance)

S2-01 (Fuse 1.4.x is correct); S2-09 (`Data` is Sendable); S2-03 (`transaction`
closure is synchronous); S2-10 (manual ModelContext usable off-main); S1-09 /
S1-13 / S1-27 / S1-28 / S1-29 (role-prose ≠ type-name; documented synonyms;
field order semantically irrelevant; intentional layer seams are not gate
violations); + remainder in workflow output. Do not re-flag these.

## 5. Doc-size analysis & split proposal

Per-section line counts (measured 2026-07-19). Goal target: ≤ ~300 lines/file.

**02-domain.md (598 lines)** — candidate 3-way split along sub-domains:
- 02a Content lineage & state (§1–§3): 201 lines
- 02b Facts, rejection & mutation plan (§4–§7): 203 lines
- 02c Planners → invariants (§8–§14): 191 lines

**03-instruction-set.md (726 lines, largest)** — candidate 4-way split:
- 03a Identity, protocol & capture (§1–§4): 165
- 03b Actions, receipts & browse/search (§5–§7): 173
- 03c DTOs (§8–§9): 234
- 03d Failures, guarantees & examples (§10–§12): 151

**05-authority-kernel.md (609 lines)** — candidate 3-way split:
- 05a Adapter, schema & codecs (§1–§4): 211
- 05b Context, preparation, facts & dispatch (§5–§8): 141
- 05c Plan → platform anchors (§9–§18): 257

Small docs stay as-is: 00 (67), 01 (240), 04 (192), 06 (265).

**Split cost:** the spec cross-references heavily ("Part V §10", "see
02-domain.md"). Splitting forces a cross-ref cascade and contradicts
00-overview §5 ("these seven files") + the Part I–VI framing. Decision
deferred to §6 sequencing — correctness first, structure second.

## 6. Sequencing & roadmap plan

Ordered to minimize risk (each gate re-audited before the next):

1. **Merge** workflow findings into §2 (dedup vs IND-*). *(blocked on workflow)*
2. **Fix in place** — every CONFIRMED defect edited in the current 7-file
   structure; each edit logged in §3 with Finding ID + old→new.
3. **Re-audit #1** — fresh analyze→critique round over the edited docs; loop
   2–3 until no CONFIRMED regression.
4. **Split** (if still warranted after §5) — apply the chosen split, update
   every cross-ref mechanically, update 00-overview §5 file count.
5. **Re-audit #2** — confirm cross-ref integrity post-split.
6. **Roadmap** — modular, **covering all 8 design modules** (7 docs; xxh3+Fuse
   co-documented in Module 7), each roadmap module cross-links its source spec
   sections and its WS/proof gates (Part VI). Re-audited for full correspondence.

Roadmap shape (drafted here, finalized post-split): per module —
`status · dependencies · deliverables · acceptance (WS#/proof) · spec-ref`.
Modules mirror Part I targets: HistoryCore, HistoryDomain, HistoryStorage,
PasteboardAdapter, PresentationUI, ClipyApp, plus xxh3/Fuse integration notes,
ordered by Part VI §5 recommended implementation order.
