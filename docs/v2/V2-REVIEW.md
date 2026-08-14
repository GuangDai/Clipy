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
