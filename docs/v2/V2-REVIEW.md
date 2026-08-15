# V2 Planning Documents — Multi-Round Review Record (2026-08-15)

> **What this is:** the record of a five-plus-round 审查 (review: read the code
> and docs to find problems) → 调查 (investigate: verify platform claims
> against Apple documentation and primary sources) → 批评 (critique: correct
> the documents and self-criticize) pass over the V2 planning set
> (`V2-00` … `V2-07`, `V2-facts`, `V2-roadmap`) against the **landed v1
> implementation** (`Sources/`), the **v1 design docs** (`docs/00`–`06`), and
> the **v1 verification record** (`docs/V1-Verified/`).
>
> **Ground truth at review time:** branch `codex/deferred-complexity-batch1`,
> HEAD `4c5622c`; v1 steps 0–8 landed and audited (run 31815028830 green;
> V1-Verified final closure run 31449682036, 314 tests); step 9 still
> scaffold. `docs/v2/` was already committed and tracked.
>
> **Disposition rule:** fact-level errors and dead references were fixed
> directly in the owning document (the diffs of this pass are the itemized
> record). Genuine open design decisions were *not* silently decided here —
> they stay in the `V2-roadmap` §4 DC ledger, now annotated where this pass
> applied the doc-side half of a mandated closure.

## Round 1 — 审查: cross-reference and fact audit (V2 vs v1 code/docs)

Method: four parallel read-only audit agents (V2-01+02, V2-03+04, V2-05+06+07,
seam inventory), each instructed to verify every §-citation, every v1 code/spec
fact, and each doc's internal consistency, marking findings already covered by
DC-01..DC-25 as `[known-DC]`. Every HIGH/MD finding was then **personally
re-verified against the exact source lines** before any edit.

Results: **51 findings — 1 HIGH, 11 MD, 39 LOW; ≈42 new** (beyond the 25 known
DC blockers), against ≈300 verified-correct claims. The highest-severity items:

1. **HIGH — V2-05 §6.5 control 1** claimed "`ClipyApp` constructs
   `HistoryAuthority` locally (as v1 does, `05` §2)" — contradicted by v1
   (the Authority is constructed inside `SwiftDataHistory.open`, `05` §2),
   by V2-05's own later text, and by ClipyAppMain being a step-0 scaffold.
   Fixed.
2. **MD — V2-02 §8.1** reproduced the v1 `CapacityKind` enum **omitting the
   v1 `thumbnailBytes` case** while claiming "v1 cases unchanged" (the real
   enum carries it, `03b` §10 / `Failures.swift`). Fixed — an implementer
   copying the doc's list would have hit an exhaustive-switch surprise.
3. **MD — V2-06** cited a nonexistent codec name `CanonicalSignatureBlobV1`
   (v1 owns `SignatureBlobV1`, `05` §4). Fixed.
4. **MD — V2-06/V2-00** restated the G8 trigger **dropping v1's read-path
   arm** ("capture- **or read-path** workload … read-path evidence includes
   peak transient hydration RSS and aggregate resident DTO bytes",
   `06` §3 G8). Both restorations fixed (V2-06 §5.1 + Record 1, V2-00 §3).
5. **MD — V2-04 vs roadmap**: the roadmap's C.2–C.6 slices cite stable fixture
   IDs (`V2-WS-C1-1/2`, `V2-WS-C2-1/2/3`, `V2-WS-C3-1`) that V2-04 never
   defined (0 occurrences). Fixed by defining the six IDs in V2-04 Record 4.
6. **MD — dead registry pointer**: V2-03 §16 and V2-04 §14 cite a "`V2-00` §4
   global D-invariant registry" that does not exist there; the registry lives
   in `V2-roadmap` §14. Both fixed; V2-00 §8 gained item (j) naming the
   registry's home.
7. **MD — stale baseline**: `V2-roadmap` §2 said v1 steps 6–8 "pending" and
   the tree "contains only `DomainSmokeTests`" — both false against the
   landed, audited tree. §2 re-baselined with run references.
8. The long tail (39 LOW): quote-attribution errors (e.g. the v1 fence quote
   lives in `04` §9's *closing paragraph*, not "step 6" — 7 sites fixed in
   V2-04; the "process-instance/schema marker" is process-scoped only — 3
   sites), mis-scoped invariant citations (D9/D14/D16), an over-broad reading
   of `V2-00` §8(h) as sanctioning addition to *any* v1 enum (it names six),
   the stale "OPEN question" restatement in V2-03 §6.3 (§8(h) resolved it),
   `.memory`-is-for-tests misattribution, fuzzy-ranking wording dropping
   pinned-first, a mis-sized migration worst case (32×64 MiB vs the reachable
   ≤128 MiB canonical + 256 MiB revisions), and the §2.1 lifecycle summary
   omitting the `.published` state. All fixed.

Known-DC findings re-confirmed with fresh evidence: DC-01 (V2-03/V2-04/V2-06
platform facts exist only in `.tmp` sidecars; the "and the shared
`docs/v2/V2-facts.md`" claim in V2-03 §14 was false for its History-surface
facts), DC-14/15/16/17/18/19/20/22 (all verified present as described).

## Round 2 — 审查: architecture and depth review

Method: full inventory of V2's public-surface growth (one audit agent plus
direct reads of the interface sections), evaluated with the deep-module
vocabulary (module / interface / seam / adapter / depth / leverage / locality).

Inventory: v1's entire caller seam is **one protocol, 6 methods**
(`ClipboardHistory`). V2 adds **7 new public protocols** (+1 reserved
`JournalAdminHistory`), **1 public facade + factory** (`ExternalHistoryFacade`
/ `makeExternalHistoryFacade`), and **~32 public types** (≈19 from V2-05
alone), plus enum-case additions to three frozen public enums, 11 config/table
singletons, ~16 versioned codecs, 10 new actors, ~25 new Authority methods.

Assessment (recorded as critique, not edits — these are recorded design
decisions with stated rationale, several already owned by DC items):

- **The one-protocol-per-capability pattern is defensible but is a
  hypothetical-seam multiplication.** Each protocol has exactly one adapter
  (`SwiftDataHistory`) plus a caller-side `as?` nil-cast; nothing *substitutes*
  across these seams (the codebase-design test: one adapter = hypothetical
  seam). What actually varies is *presence* (capability gating), which the
  pattern serves cleanly and which keeps "a v1 caller that ignores V2 behaves
  exactly as on v1" true. Verdict: keep, but the growth is now an
  order-of-magnitude seam expansion over v1 — future grafts should justify
  each new protocol against a "does anything vary here?" bar, and prefer
  extending an existing V2 protocol family where the concern is not distinct.
- **`GatewayAdminHistory.enrollConnection(kind:displayName:credential: Data?)`
  pre-reserves surface for an unbuilt world** (CRIT-M11). The `credential`
  parameter is nil-for-`.appIntents` today; every credential-bearing
  enrollment kind is a commented-out reserved case, and `CredentialStore` is
  explicitly unbuilt (DC-22). V2-00 §4 forbids reserving v1 surface; V2 should
  hold itself to the same bar. Adding the parameter later alongside a real
  credential-bearing kind is a sanctioned additive overload, not a protocol
  break. Recommendation: drop the parameter until DC-22 admits the Keychain
  slice (non-blocking; recorded here because the doc's own rationale is
  internally consistent).
- **Per-item `enrichmentStatus(for:)` forces an N-hop fan-out per rendered
  page** (V2-07 §9, `UX-PERF-1` bounds it honestly). The batch
  `enrichmentStatuses(for:)` (OPEN-6) collapses it to one read; the same shape
  recurs as V2-02's OPEN-2 retained-bytes read. Recommendation: DC-08 should
  default to admitting both batch reads rather than carrying bounded fan-out
  as permanent interface cost.
- **Depth positives worth keeping as the model:** `ReconnectCursor` (opaque,
  callers only persist it; expiry is typed), `ExternalRequest`/`ExternalRead`
  closed enums at the trust boundary (deep: the safe-subset policy is
  invisible to callers), and the facade baking connection identity so no
  external caller can forget it.
- **Hidden coupling worth a default direction:** X1/X2 depend on V2-03's
  always-on HCR append even when J1 itself is untriggered (DC-25). That makes
  every v1-shaped commit pay the journal append for an external-access graft.
  Recommended default: X1/X2 require an independently admitted J1; an
  HCR-substrate-only admission is the exception that must carry its own
  overhead evidence. Recorded for the DC-25 resolution; not decided here.
- **No global field-count ledger**: each doc asserts its own
  `SwiftDataHistory` field-set extension; V2-06 even asserted a global "five →
  six" count that is false when other grafts compose. Fixed locally (M1 field
  ledger named as the superseding record).

## Round 3 — 调查: Apple documentation verification (Sosumi + primary sources)

Verified and durably recorded as **`V2-facts.md` cycle 5** (advancing DC-01):

1. `AppDependencyManager` — AppIntents, `final class`, macOS 13.0+, has
   `.shared` + `add(key:dependency:)` → the single sanctioned framework-owned
   `.shared` registration is real API.
2. The previously **uncited** V2-05 "Swift 6 crash" platform claim now has its
   primary source: forums.swift.org/t/73226 (queue-assertion crash when any
   `@Dependency` is used in an `AppIntent`); citation added in V2-05 §6.5.
3. `NSString.range(of:options:range:locale:)` — exact signature, macOS 10.5+,
   nil-locale = system locale → grounds P2's query-time branch.
4. `CompareOptions.widthInsensitive` / `.diacriticInsensitive` (macOS 10.0+)
   → grounds P2's Japanese width folding and diacritic-insensitive posture.
5. `URLResourceKey.isExcludedFromBackupKey` (macOS 10.8+) — including the
   load-bearing "set each time you save … file operations cause this property
   to reset to `false`" caveat → grounds C2's reassertion-on-replace rule.
6. `Actor.unownedExecutor` (`nonisolated var: UnownedSerialExecutor`,
   macOS 10.15+, same-executor requirement; SE-0392 mechanism) → grounds
   V2-01's custom non-cooperative executor for blocking `perform(_:)`.
7. Two symbols stayed OPEN with retained proof gates (`@Dependency` wrapper
   declaration → `X-COMPILE-2`; `Locale.Language.LanguageCode` direct URL →
   `P2-COMPILE-1`; V2-06's code comment now cites cycle 5 instead of claiming
   "MCP-verified").

Spot re-verification of the strongest pre-existing facts (migration-stage,
transaction, fetch-surface, Vision-revision facts in cycles 1–4) was performed
by the Round-1 agents against the v1 docs and code and held up.

## Round 4 — 审查 (concurrency / data-safety / edge / data flow)

Targeted reads of the load-bearing windows:

- **HCR append atomicity (V2-03 §5.1)**: the same-transaction, singleton-last
  analysis is correct; one wording defect fixed — `appendHistoryChangeRow` was
  described as "non-throwing" when it may throw (codec encode), which aborts
  the whole commit per `05` §10 (the same fail-closed behavior as v1's own
  commit-path codec encodes). Now stated as non-*suspending*.
- **Journal rebase (V2-03 §9.2)**: the sequence deleted all rows without
  resetting the running `JournalConfigRow.journalBytes` counter, leaving a
  durable counter that outlives the rows it summed (the DC-9 item). The
  `journalBytes = 0` reset is now an explicit rebase step. Crash-consistency
  direction (rebase-not-reconstruct, cursor expiry via generation bump, cache
  flush, writes stay enabled) verified sound against decisions §14/§15.
- **C3 publish fence (V2-04 §7.2–7.3)**: the six-state machine, per-call fence
  key vs single-flight join key, terminal-state reaping, and
  superseded-bytes-still-cacheable semantics are internally consistent; the
  §2.1 summary that omitted `.published` was fixed. The remaining exposure is
  exactly DC-11's recorded sign-off items.
- **Checked arithmetic (V2-02 §4)**: correctly cites and honors `06` §2's
  "No arithmetic counter or byte-count calculation may wrap"; Int64 sizing for
  the 1.83-TiB worst case holds.
- **Best-effort audit bound (V2-05)**: denial/no-op audit is honestly bounded
  (D34 at-most-one, crash may drop); successful writes are atomic with the
  mutation + HCR + position. No new exposure beyond DC-15/16.
- **Invalidation fan-out (V2-01)**: v1's invalidation registry is genuinely
  multi-continuation (`HistoryInvalidation` dictionary keyed by subscription
  token), so "registering the scheduler adds exactly one more non-blocking
  yield" is structurally true in the *code*, not just the doc — verified in
  `Sources/HistoryStorage/HistoryInvalidation.swift`.

## Round 5 — 批评: corrections applied + self-critique

**Corrections applied (62 edit sites across 9 files + this record):**
V2-00 ×2 (G8 read-path arm; §8(j) registry home) · V2-01 ×3 · V2-02 ×11
(incl. `CapacityKind.thumbnailBytes`, `itemID: UUID`, §13
lightweight+custom reconciliation, D19 header qualification) · V2-03 ×16
(incl. cache default off ×3 sites + fixture flag, rebase `journalBytes` reset,
"non-suspending" wording) · V2-04 ×18 (incl. six stable fixture IDs, insert
signature `contentVersion`/`builtAt`, seven fence-quote attributions) ·
V2-05 ×7 (incl. the HIGH control-1 rewrite, D32 scoping, forums citation) ·
V2-06 ×11 (incl. `SignatureBlobV1`, G8 arm ×2, §8(h) scope, field-ledger
wording) · V2-07 ×4 · V2-facts (cycle 5, 6 verified + 2 OPEN) · V2-roadmap ×8
(re-baseline blockquote, §2 table, V2-0 status, DC-04/09/10/12/13
annotations). Every hunk was re-read in the commit diff before commit.

**Self-criticism (what this review itself got wrong or must not overclaim):**

1. **One agent finding was refuted on verification**: the claimed imprecise
   `05` §14.5 quote in V2-04 ("returns immutable source bytes" without
   "image") does not exist in the file — every occurrence is verbatim-correct.
   The edit was dropped. Lesson enforced: no agent-reported defect reaches a
   doc without a direct source-line check (this was the policy for all
   HIGH/MD items and it caught exactly one false positive).
2. **Coverage honesty**: Rounds 1–4 verified ≈300 claims with four audit
   agents plus targeted personal reads; they did **not** re-derive every line
   of the ~13.3k-line part documents. LOW-severity citation fixes were
   applied from agent quotes whose line numbers and surrounding text were
   spot-checked, not all individually re-read pre-edit (all were re-read in
   the final diff). Residual risk concentrates in prose sections no agent
   quoted.
3. **Scope discipline**: this pass fixed facts and dead references, applied
   the doc-side half of DC-mandated closures, and recorded advisory critiques
   — it deliberately did **not** decide open design questions (DC-02's stage
   topology proof, DC-03's shipping consolidation, DC-11 sign-off, DC-14..16,
   DC-18..25, the Round-2 recommendations). Those remain owned by the ledger
   and the roadmap's rule that blockers are fixed in owning docs with their
   proof gates, not by a review pass.
4. **The re-baselined roadmap rows cite v1 evidence** (V1-Verified, runs
   31449682036/31815028830) — if v1 moves again, §2 must move with it; the
   row now says so by pointing at V1-Verified as the authority.

## Verification of this pass

- All 62 scripted edits applied under exact-count assertions (2 failures were
  diagnosed to blockquote/comment token interleaving and re-applied; 1
  intended edit voided by refutation).
- `git diff` of the full pass re-read before commit; portable source gates
  re-run (no `Sources/` or `Tests/` file was touched — docs-only).

# Part II — Iterative 审查→调查→批评 loops (2026-08-15, restructured per directive)

> Directive: one round = one full 审查 (review) → 调查 (investigate) → 批评
> (critique/correct) loop; phases run strictly in sequence; **each phase uses
> three concurrent subagents**; every modification is applied with the Edit
> tool. Round 1 below is the first such loop; it re-reviews the documents as
> amended by Part I, so its findings are all new relative to Part I and the
> DC ledger.

## Loop R1 — Invariant semantics under composition (D20–D39 vs D1–D19)

- **审查 (3 concurrent reviewers: V2-01/02, V2-03/04, V2-05/06):** 21
  candidate findings (5 + 7 + 8) + 14 checked-and-sound.
- **调查 (3 concurrent investigators, skeptic-default):** 20 CONFIRMED, 1
  REFUTED (B3 "generation bump on schema migration unwired" — Record 5
  :2433-2436 already wires the codec-bump case, and no V2-03 migration exists
  while `configSchemaVersion` fails closed). C6 split PARTIAL (the "never
  reaches the Authority" contradiction confirmed; the alleged raw-0 fail-closed
  hole is only under-specification — both derivable at step 0).
- **批评 (3 concurrent correctors, disjoint file partitions, Edit tool only)
  + coordinator sweep:** 32 planned edits, 30 applied by correctors, 2 skipped
  with reasons (§16 has no field-level type list to extend; premise absent),
  plus 8 coordinator residue fixes. Highlights:
  - **HIGH (B1):** V2-01's non-commit corpus writes (persistEnrichment /
    setEnrichmentEnabled) falsified D27 — a position-only collection-cache
    fence serves stale search pages indefinitely. Fixed with an in-memory
    Authority `enrichmentCorpusEpoch` carried in the §7.1 fence and the
    §7.2 key (four-element match), bump-on-write specified in both owning
    docs. Alternatives shown unsound during 调查: a runtime
    materializerVersion bump would trip the open-time downgrade refusal
    (§4.6 step 4 compares a compiled-in constant); a bare `flush()` cannot
    close the fence race (lookup that passed step 1 still passes step 3).
  - **MD (A1):** V2-02's invariant ledger said "D19 alone is extended" while
    its own D23 extends D4 — reclassified (D4 and D19 extended; D24 title
    corrected to "restates …; extends D19").
  - **MD (A2):** RET-PRUNE-1(a) "minimal set" was jointly unsatisfiable with
    (b) oldest-inactive-first for byte-only budgets (minimal {r1} vs prefix
    {r0,r1}) — restated as "shortest append-order prefix".
  - **MD (A3):** the enrichment drain had no row-current no-op skip, so every
    coalesce/pin commit (CV unchanged) re-OCR'd, contradicting §6.5 — a
    no-op skip added to §4 and cross-referenced from §6.5.
  - **MD (B2):** no cursor reject above the journal head — same-store backup
    restore loops `isCaughtUp == false` forever and silently misses reused
    sequences; reject step 5b added, §4.6's backup-restore claim scoped.
  - **MD (B4/B5):** the DC-12 insert signature had landed at only one of six
    V2-04 sites (C1/C2 actors + all call sites + promote-path provenance via
    provenance-returning `lookup`s now aligned); shared fence-table entries
    vs per-call reap contradiction resolved by a sharer-count discipline.
  - **MD (C1–C5, C7):** read-side `.noOp` was unreachable (v1 reads throw or
    return; removed at three sites); P1's `.ready(generation:)` referenced a
    v1 `State` payload that does not exist (05 §7.1 deliberately has no
    counter — reverted to bare `.ready` with position freshness); §4.6 chain
    validation scoped to `[compactionFloor, head]` so rebase-quarantined rows
    don't brick every later open; failed-read catcher unified on
    `performExternalRead`; the Storage-clock witness explicitly handed to the
    gateway at construction; the §5.1 ASCII grant re-fetch relocated into the
    transaction closure it claims to live in.
  - **NEW-DC:** DC-26 (GatewayConfigRow.generation write-only; cross-ref
    fixed, keep-vs-drop recorded for decision).
  - **LOW:** A4 revise-path expansion gate coverage (RET-PERF-1 extended),
    A5 `contentVersionRaw` semantics (current-at, not derived-at), B6
    "expiring all live cursors" vs mandatory head survival, B7 cancelled
    decode's bytes (inserts moved into the flight task body).
- **Self-critique (loop-level):** the 调查 phase refuted one 审查 finding and
  downgraded another — the loop's skeptic stage is load-bearing, not
  ceremony. The B1 fix is a semantic design change made to repair a falsified
  invariant rather than a ledger row; the alternatives-rejected rationale is
  recorded above so a future reviewer can re-open it as a decision if the
  epoch mechanism is contested. One corrector residue (unbound
  `diskHitProvenance`) was introduced by the batch edit and caught in the
  coordinator sweep — batch edits need an immediate binding check.

## Loop R2 — Data flow & boundary conditions

- **审查 (3 concurrent reviewers):** 21 candidates (8 + 5 + 7) + 14
  checked-and-sound. Two candidates targeted defects in loop R1's own fixes
  (the no-op skip; the corpusEpoch fence operand) — the loop structure
  self-corrects earlier rounds.
- **调查 (3 concurrent investigators):** 20 CONFIRMED, 1 PARTIAL (B5: the
  disk-cap trigger's *input* is genuinely unspecified, but the eviction pass's
  directory listing recomputes footprint and the open-armed sweep bounds
  exposure — fixed as a definitional sentence). Two NEW-DC dispositions:
  DC-27 (R3 unsatisfiability veto runs before R1/R2 selection, rejecting
  combined threshold-lowerings R2 would satisfy) and DC-28 (R1 capture-lane
  `now` is unvalidated caller `observedAt`; a finite future date mass-retires).
- **批评 (3 concurrent correctors + coordinator sweep):** 29 corrector edits
  applied, 7 coordinator residue fixes. Highlights:
  - **HIGH (B1):** loop R1's corpusEpoch fence had no left-hand operand —
    `lookup` returned no epoch and `insert` accepted none, so insert-time
    capture re-opened the stale-serve race. Fixed by reading
    `E_current` inside the step-2 Authority interval (with `P_current`) and
    threading the epoch through both signatures (`builtAtEpoch` return,
    `corpusEpoch:` parameter, both occurrences).
  - **HIGH (C1):** the audit `recordHash` was computed at stamping over an
    `auditSequence` minted only in-closure — every succeeded write would be
    flagged as chain corruption at read. Fixed: stamping reads
    `nextAuditSequence` as N, hashes over N, the closure consumes N and
    writes the successor.
  - **MD (A1):** loop R1's no-op skip sat after the fetch it claimed to avoid
    and read row fields that never cross the actor boundary — moved into
    step 1's Authority interval behind a new `EnrichmentSourceOutcome` enum
    (`.selection`/`.rowCurrent`/`.notApplicable`), prose reconciled.
  - **MD (A2/A3):** persist-path missing-item branch specified (discard,
    sweep owns the row); retry counter now increments inside the persist
    transaction on fence-fail discards (row created if absent), so
    pre-first-persist churn is bounded.
  - **MD (B2/B3):** journal primary-kind rule (b) no longer misfires on the
    V2-02 revise+R2 plan (rule (a) precedence stated + a dedicated mapping
    row); the affected-ID union cap got encode-side semantics
    (deterministic smallest-ID truncation, best-effort disclosure,
    5,001-union reachability recorded) and the §4.5 clear-payload
    contradiction fixed.
  - **MD (C2–C4):** rate-limit denial audits coalesce per refill window
    (never debiting the bucket; X-SECURITY-3 reworded); the token bucket
    refills on monotonic process uptime, never the Storage-clock witness;
    P2 predicate changes now expire in-flight search cursors (mint-predicate
    equality; `.snapshotExpired`), closing the mixed-predicate page-2 hole.
  - **LOW (A5/A7/A8, B4/B5, C5–C7):** RetainedBytesRow 1:1 checked both
    directions; retired-ID enqueue-only semantics; `seen` set drains on
    cycle completion; C2 non-crash write failures degrade-to-miss (+ gate
    sentence); disk-cap trigger input defined (directory listing);
    readChunkSize reframed as a residency *target* with a chunked-adapter
    fallback; blob nonce mechanized (injected ID source + exclusive create
    + retry); P1 checkpoint write timing reconciled (rebuild-only, upsert).
- **Self-critique (loop-level):** loop R1 introduced two of loop R2's three
  HIGH/MD-most findings — fixes must be reviewed with the same rigor as
  original text, and the investigators' mechanism-level analysis (where does
  the fence operand come from? when is the hash input minted?) is what
  catches them. Corrector-B noted it diffed mentally against the working
  tree, not HEAD — uncommitted multi-loop state is a hazard the coordinator
  must keep checking via git diff after every loop.

## Loop R3 — Platform-claim verification & durable promotion

- **审查 (3 concurrent reviewers):** claim inventories per partition —
  9 + 14 + 20 concrete platform claims not covered by cycles 1–5, plus 4
  intra-doc defects, notably the **systemic C1**: V2-05 cites
  "`V2-facts.md` cycle 5, fact/OPEN N" at 27 sites using the
  `.tmp/v2-research/V2-05-facts.md` numbering that was never promoted (the
  durable cycle 5 contains different facts).
- **调查 (3 concurrent investigators, sosumi + web):** every load-bearing
  claim verified or classed; headline outcomes: `topCandidates(_:)` does
  NOT throw but **may return an empty array** (the doc's `[0]` traps);
  `VNRequest.results` ordering is **undocumented** (D9 pins index order
  only); "cross-module enums are non-exhaustive by default" is **refuted**
  (SE-0192: only library-evolution builds; ordinary builds are frozen —
  V2-02's safety rests on RET-COMPILE-2); `.ifExistingAtomicReplace`
  **does not exist** (ItemReplacementOptions has exactly two cases — this
  also refuted an option name a loop-R2 investigator had suggested);
  NSFileCoordinator accessors take NSErrorPointer, not Swift throws;
  `Locale.Language.LanguageCode` verified via its parent property page
  (the 404 mystery resolved); DispatchTime monotonicity undocumented (the
  clamp is the defense); Caches-vs-Time-Machine undocumented (hedged);
  POSIX `O_EXCL` and unlink semantics LOCATED with primary sources.
- **批评 (3 concurrent correctors + coordinator):** 29 corrector edits
  (V2-01 ordering/`.first`/`.unique`/variant-equivalence fixes; V2-02
  SE-0192 rewrite + two `.unique` notes; V2-04 replaceItem spelling +
  first-write `moveItem` split + verified accessor spellings + size-API
  pair + cooperative-coordination caveats ×3 + Caches hedge; V2-05 27×
  cycle-5→6 repoints + clamp reframe; V2-06 O_EXCL mechanism + §2 label
  qualifications + import-list substrate fix + LanguageCode/unlink
  citations; V2-07 two pointer swaps) + 4 coordinator residue fixes.
  **`V2-facts.md` cycle 6 appended**: the V2-05 sidecar promoted verbatim
  (facts 1–7, OPEN 1–4 — closing the DC-01 promotion gap for V2-05) plus
  22 loop-R3 verified facts (8–29) and 2 new OPENs (MigrationStage
  timing; results ordering).
- **Self-critique (loop-level):** the loop's own investigators were
  caught once (a suggested-but-nonexistent option name) — verification
  cuts both ways and every proposed fix must itself be platform-checked
  before landing. The Part I review record over-claimed "cycle 5 advances
  DC-01"; loop R3 exposed that the V2-05 sidecar had never actually been
  promoted — durable promotion now done, and the review record corrected
  by this entry.

## Loop R4 — Architecture & interface depth (deep-module lens)

- **审查 (3 concurrent reviewers, codebase-design vocabulary):** 23
  findings (7 + 8 + 7) + 14 checked-and-sound; dispositions 15 FIX-TEXT /
  7 ADVISORY / 1 FIX-TEXT-with-NEW-DC-alternative.
- **调查 (3 concurrent investigators):** 22/23 confirmed with final
  texts (one advisory downgraded to note). Gate-ID collision checks clean
  (`E1-BEHAVIOR-1`, `RET-SELECT-1` free); the v1 failure inventory
  enumerated from Sources (10 `HistoryFailure` cases, `UnavailableReason`
  — not "TemporarilyUnavailable" — with `.factProof`/`.dedupIndexRebuild`)
  grounding the loop's largest deliverable.
- **批评 (3 concurrent correctors + coordinator):** 16 corrector edits +
  the roadmap P3.1 follow-on. Highlights:
  - **Missing behavioral gates minted:** `E1-BEHAVIOR-1`
    (EnrichmentHistory public-contract mapping — the only prior gate
    asserted *mechanism*, never mapping) and `RET-SELECT-1` (R1/R2
    victim selection — previously owned by no gate while §6.4's clock
    seam was justified by tests no gate admitted).
  - **§7.3.1 complete v1-failure → ExternalFailure mapping** added to
    V2-05: three precedence rules (sibling-wins; transient-reason
    mapping `.factProof`→`.storeLocked`; audit-only reclassification),
    a producible-case table, a not-producible list verified against
    Sources, and the deliberate WS16 absent-target asymmetry recorded.
  - **Error/contract gaps closed:** `setEnrichmentEnabled` failure
    translation (previously unspecified while V2-07 swallowed it with
    `try?`); `clearDiskThumbnailCache` extent + throws-for-precondition-
    only; retention policy surface's write-only posture recorded with
    the DC-08 sibling-read candidate; `ReconnectFailure` mismatch
    payloads labeled diagnostics-only with one uniform recovery;
    `JournalEntryKind` raw values declared storage-encoding-not-contract
    (first raw-typed public enum vs 17 raw-free v1 ones; raw-free
    alternative noted); `currentReconnectAnchor()` derivability +
    `isCaughtUp` exactly-full-batch boundary; `ThumbnailCacheStatus`
    field comments (0-until-sweep; diagnostics-only materializerVersion);
    V2-03 §13's unshippable advanced-settings controls now carry the
    OPEN-5/DC-08 deferral; V2-07's composition shell now includes the
    facade registration (admission-by-registration, not cast);
    V2-06 §5.1/roadmap P3.1 aligned to C-M2's public decision.
  - **Advisories recorded (no edits):** A3 `RevisionRetention` both-nil
    normalization + one-scalar wrappers (deletion test), A4 the
    `.setRetentionPolicy`/`.setRetentionPolicies` homograph pair, A7
    `RetentionExpansion*` vs v1 `Retained*` naming drift, B3 one-way-door
    refuse typed as `.persistence(.invariantViolation)` (version policy,
    not corruption — frozen-v1 vocabulary), B7-drop the consumer-less
    public `materializerVersion` field (DC-08 material), C3
    `GatewayAdminHistory`'s three-concern bundle + Void returns, C4 the
    singleton-kind `makeExternalHistoryFacade(for:)` parameter, C6
    `BlobReadStream.bytes` pinning a gate-contingent platform type, C7
    `.invalidSearchTerm` overload vs centralized error consumers.
- **Self-critique (loop-level):** the strongest findings were
  *absences* (gates that don't exist, mappings never written) rather
  than wrong text — depth review needs to hunt for what ISN'T in the
  doc, which is harder to verify than what is; investigators compensated
  by enumerating ground-truth inventories (Sources' failure cases,
  raw-free v1 enums) as completeness oracles.

## Loop R5 — Implementability, testability & roadmap coherence (final loop)

- **审查 (3 concurrent reviewers):** 21 findings (5 + 5 + 8) + 15
  checked-and-sound — dominated by **integration drift introduced by the
  loops themselves**: the roadmap's acceptance lists and slice rows did not
  contain the R4-minted gates (`E1-BEHAVIOR-1`, `RET-SELECT-1`); D27 and
  Record 4 still described the pre-R1 three-element cache key while §7.2
  mandates four (the R1-HIGH fix had not propagated to the invariant text
  an implementer builds to); reject step 5b, the epoch fence arms, the
  revise+R2 mapping row, and the encode-cap semantics were owned by no
  gate/fixture; §7.3.1's mapping had no owning gate; per-module "total
  order" step lists each ended in their own "publish the facade" step
  (unsatisfiable when composed); DC-19 contradicted R2's residency-target
  reframing; V2-05's gate-family roll-up missed the new gate.
- **调查 (3 concurrent investigators):** 21/21 confirmed with final texts
  (one finding merged as a duplicate of A1's). Notable verdicts: V2-01's
  E1-PERF-1/3/6 demanded internal measurements (OCR p95, persist duration,
  pool starvation) that `06` §9's runner discipline cannot sanction from
  the two-method public seam — reworded to public envelopes (baseline-delta
  user-commit/search p95) with one explicitly named internal-workload
  admission for OCR p95; V2-facts now has three numbered OPEN namespaces
  (global 1–8, cycle-3 1–2, cycle-6 1–6), so V2-01's six bare "OPEN N"
  citations were qualified to "OPEN questions item N"; Record-3 gate
  ordering kept (PERF-5/BEHAVIOR-1 adjacency is deliberate) with a
  placement note instead of churn.
- **批评 (3 concurrent correctors — one hit a usage cap after applying all
  its edits; verified 12/12 landed — + coordinator roadmap batch of 17):**
  doc-side: E1-PERF gate rewordings ×3, six OPEN qualifications, D27 +
  Record 4 + §7.4 four-element amendments, D26 (e)/J1-PLATFORM-4/J1-3 5b
  arms, J1-4 epoch + insert-window arms, J1-7 revise+R2 arm, new fixture
  `V2-WS-J1-1b` (encode-side cap truncation), both per-module publish steps
  demoted to segments of the single `05` §13 step-10 open order,
  `X-BEHAVIOR-1` gate minted (mapping end-to-end) + roll-up updated, P2
  Record 3 list completed, P2-PLATFORM-2 cursor-expiry property, P3-PLATFORM-2
  adapter branch; roadmap-side: RET-SELECT-1/E1-BEHAVIOR-1/X-BEHAVIOR-1 into
  all lists + R.2/E.7/J.3/X.5 cells, R.2 prune wording, J.4 head-bound
  cursors, J.6 corpus epoch, §13 item-5 enrichment×cache composition,
  stable-fixture list + J1-1b, P2.3 + acceptance cursor expiry, P3.4 target
  wording + O_EXCL collision proof, DC-19 annotation, UX.1 registration
  sentence.
- **Advisories recorded:** mint stable E/R fixture IDs before fixtures
  freeze (A5); X-SECURITY-2 positive N-mint leg (C8).
- **Self-critique (series-level):** R5's biggest finding class was damage
  the four earlier loops left behind — every loop that mints a gate,
  fixture, invariant clause, or mechanism owes the roadmap, the invariant
  text, and the fixture inventory an integration edit in the same loop, or
  the next loop pays for it. The one corrector that hit a usage cap had
  silently completed all 12 edits before failing — verified, not assumed
  (its report never returned), which is exactly why every loop ends with a
  coordinator diff-verification against the intended edit list.
