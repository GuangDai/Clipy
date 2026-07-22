## Part VI — Cross-cutting Gates and Deferred Grafts

### 1. Status boundary

This Part distinguishes three states:

1. **Design consolidated:** Parts 00–06 contain one semantic v1 and no known competing rule.
2. **Executable specification:** the public scaffold compiles and every proof/walking-skeleton gate below passes on the supported macOS runner.
3. **Product implementation complete:** UI, pasteboard behavior, packaging, accessibility, localization, and non-skeleton product tests pass.

This document set may reach state 1 without claiming states 2 or 3. At the time of this revision, no greenfield implementation exists.

### 2. Fixed v1 safety bounds

These are admission and resource-safety constraints, not caches or user-facing retention features. The scaffold must encode them in one validated `HistoryLimits.standard` value so tests and production cannot silently choose different bounds.

```swift
public struct HistoryLimits: Sendable, Hashable {
    // One immutable field per row of the table below, plus a checked
    // initializer that rejects out-of-range or inconsistent combinations.
    public static let standard: HistoryLimits   // exactly the table values
}
```

`HistoryLimits` lives in `HistoryCore` (its Foundation-only home; the only production/value type defined in Part VI §2). `HistoryLimits.standard` is the only value production and the `SwiftDataHistory` walking-skeleton tests use. A test that needs a different hard bound (e.g. WS9's reduced retained-item count) injects the bound at the Domain planner seam (`planCapture(... hardMaximumRetainedItems:)`), not by altering `HistoryLimits`.

| Bound | v1 value |
|---|---:|
| Representations per capture/revision | 32 |
| UTF-8 bytes in one type identifier | 512 |
| Bytes in one representation | 64 MiB |
| Total bytes in one capture | 128 MiB |
| Total bytes in one proposed revision | 64 MiB |
| Revisions per History Item | 100 |
| Total revision bytes per History Item | 256 MiB |
| Hard retained History Item count | 5,000 |
| User maximum-unpinned range | 1–5,000 |
| Default maximum unpinned items | 200 |
| UTF-8 bytes in one source-application observation | 1,024 |
| Stored title UTF-8 bytes | 1,024 |
| Stored search body UTF-8 bytes per item | 256 KiB |
| Page/observation row limit | 1–500 |
| Search term UTF-8 bytes | 4,096 |
| Regexp pattern Characters | 512 |
| Fuzzy query Characters | 256 |
| Fuzzy title/body prefix | 5,000 Characters each |
| Regexp title/body prefix | 1,000 Characters each |
| Body search snippet | 322 Characters including ellipses |
| Thumbnail dimension | 1–2,048 pixels per axis |
| Encoded thumbnail output | 16 MiB |

Rules:

- MiB/KiB use binary units.
- Bounds are checked before expensive allocation or decode when the input length is knowable.
- Truncating title/search projection is allowed at a deterministic Unicode boundary; truncating Canonical, revision, paste, or thumbnail source bytes is not.
- Pinned items are exempt from the user maximum-unpinned policy but still count toward the hard retained-item maximum.
- When capacity cannot be restored atomically by eligible retention victims, the increasing action fails.
- No arithmetic counter or byte-count calculation may wrap.
- Changing these values is a reviewed specification/configuration change with boundary tests, not a runtime cache tuning knob.

### 3. Deferred G1–G8 grafts

None of these types, tables, protocols, or state machines belongs to v1. The trigger opens a new design review; it does not authorize inserting the feature directly.

| ID | Deferred graft | Evidence required before design work starts |
|---|---|---|
| G1 | Shared in-memory completed-thumbnail cache | Representative scrolling shows thumbnail decode p95 above 16 ms and at least 30% identical completed requests within the measurement window. |
| G2 | Collection cache plus durable History Change Record journal | At the hard retained bound, recent/search p95 exceeds 50 ms or Authority queue wait p95 exceeds 20 ms under the agreed workload; alternatively, a real replay/reconnect product requirement is approved. |
| G3 | Disk thumbnail cache | G1 is already justified, measured cross-launch reuse is substantial, and a structural decoder/materializer fingerprint is specified and fixture-proved. |
| G4 | Per-purpose content subversions/source stamps | Profiling shows material work repeatedly invalidated by Effective Content changes that provably leave that purpose's source bytes unchanged. |
| G5 | Persistent startup checkpoint | Metadata-only startup/index rebuild p95 exceeds 250 ms at 5,000 items on the minimum supported hardware profile. |
| G6 | Multi-state materialization lifecycle/publish fence | At least 20% of thumbnail work is measured as superseded or discarded despite cancellation and single-flight. |
| G7 | Localized search projection | Product requirements specify locale-sensitive matching and migration behavior; fixtures define normalization and ordering for supported locales. |
| G8 | Blob-store handle/streaming content abstraction | A representative workload exceeds the capture-path memory budget or shows p95 copy cost that cannot be solved within the bounded inline-value design. |

Every admitted cache must satisfy the Part IV cache law. G2 must define durable record schema, retention, cursor expiration, crash consistency, and replay completeness before any collection cache can depend on it.

### 4. Product-deferred capabilities

The following are not performance grafts and are not implied by G1–G8:

- Enrichment/OCR and enrichment-derived search corpus.
- ExternalGateway, external connection enrollment/grants, App Intents, or third-party writes.
- Operation Record auditing and Audit/Connections domains.
- Automatic revision retention.
- Age-based or storage-byte user retention.
- External synchronization or multi-process writers.

Each requires an approved product specification and a fresh architecture review. v1 reserves no public case, protocol, table, token, or empty target for it.

### 5. Scaffold file and target plan

The first implementation work must create only these production targets:

```text
HistoryCore
HistoryDomain
HistoryStorage
PasteboardAdapter
PresentationUI
ClipyApp
xxh3
```

Test targets mirror the owner target:

```text
HistoryCoreTests
HistoryDomainTests
HistoryStorageTests
PasteboardAdapterTests
PresentationUITests
ClipyIntegrationTests
```

The scaffold must not add an implementation target for a deferred feature. `HistoryStorageTests` uses both persistent temporary stores and the same implementation's in-memory configuration.

Recommended implementation order:

1. Compile `HistoryCore` public values/interface and lock its symbol surface.
2. Compile pure `HistoryDomain` values, facts, planners, and focused invariant tests.
3. Compile SwiftData schema/codecs and prove round trips.
4. Implement Authority open, position singleton, Signature Index rebuild, and capture insert/coalesce.
5. Add pin order, revision, remove/clear, and retention through the same plan/transaction path.
6. Add purpose-specific reads and observation.
7. Add thumbnail single-flight.
8. Wire Pasteboard/UI/App only after the History walking skeleton passes.

This sequence is a future implementation plan, not evidence that any step exists today.

### 6. Compile and dependency proofs

Before “executable specification”:

- The exact Part I target graph builds in Swift 6 complete concurrency mode on macOS 26 deployment settings.
- A deliberate forbidden edge fails to compile or fails the import gate.
- `HistoryCore` imports only Foundation.
- `HistoryDomain` imports only Foundation and `HistoryCore`.
- `import SwiftData` appears only in `HistoryStorage`; AppKit only in its adapter; SwiftUI only in Presentation.
- No public symbol mentions Canonical Content, Domain facts/plans, SwiftData types, AppKit objects, fingerprints, or internal invalidations.
- No `@unchecked Sendable`, `nonisolated(unsafe)`, mutable service locator, or second writer exists.
- Every public struct shown with public construction has a real public initializer; every declared protocol conformance compiles rather than relying on prose synthesis.

### 7. Schema and platform proofs

The macOS runner must prove:

1. **Transaction boundary:** closure success durably commits item mutations and singleton position once; closure failure commits neither. No extra `save()` is required.
2. **Fresh-context visibility:** after a committed receipt, a newly created serialized read context sees the commit immediately.
3. **Codec round trip:** Canonical bytes/fingerprints, full revisions including the active revision, active ID, occurrence first/last source, pin ordinal, and projections survive restart.
4. **Corruption rejection:** the Part V §4 decode checks are exhaustive and each fails closed as `.persistence(.corruptStoredValue)` or `.persistence(.invariantViolation)`: unknown blob version; unbounded or oversize byte/count values; duplicate or unnormalized type identifiers, or an empty-bytes representation; a Canonical representation lacking fingerprint/signature coverage; duplicate revision IDs or revision-history overflow; a non-nil active ID naming no stored revision, or a non-empty revision list with a nil active ID; revision content that is empty, non-normalized, or contains a non-Canonical type; a zero or invalid Content Version; invalid occurrence values; a negative pin ordinal; and an `effectiveTypeIdentifiersBlob` that is not a valid versioned sorted-unique list.
5. **Scalar read isolation:** recent/search/startup paths do not decode Canonical or revision blobs. If SwiftData cannot prove no fault, the performance claim is removed and an alternative projection schema is designed; correctness tests must still pass.
6. **Signature completeness:** startup postings cover every retained Canonical signature entry; forced xxh3 collision still requires byte confirmation.
7. **No invalid platform API:** business-ID lookup uses a fetch, not `registeredModel(for:)`; no undocumented refresh method appears.
8. **Deployment floor:** all APIs are available on macOS 26 or correctly availability-gated and tested.

### 8. Walking skeleton

Each path crosses the public `ClipboardHistory` interface and real `SwiftDataHistory` implementation. Domain unit tests supplement these paths but do not replace them.

#### WS1 — Raw capture insert

Submit normalized raw text capture to an empty store. Expect one row, Content Version 1, Change Position 1, full Canonical bytes, correct initial occurrence/projection, `.inserted(reference)`, and an observed page containing the same reference.

#### WS2 — Copy Coalescing

Submit the same capture again. Expect the same History Item ID and Content Version, occurrence count 2, monotone last-copied time, Change Position 2, `.coalesced`, and no second row.

#### WS3 — Rich-to-plain containment and collision safety

Insert rich+plain content, then submit matching plain-only content. Expect coalescing into the richer Canonical item. Repeat with forced equal fingerprints but different bytes and expect a new item.

#### WS4 — Lineage hint for revised Effective Content

Revise an item, export its paste payload, and capture that payload with its hint. Exact Effective Content equality must coalesce into the hinted item while preserving Canonical Content and Content Version.

#### WS5 — Candidate proof unavailable

Force Signature Index state unready and rebuild failure. Capture must return `.temporarilyUnavailable(.dedupIndexRebuild)`; no row, position, receipt, or invalidation is produced.

#### WS6 — Revision OCC and append-only revert

Create an item, append a changing revision, then submit a stale draft and expect `.staleContent` with no commit. Revert from the current version to Canonical or an earlier revision; expect a new Revision ID, old revisions unchanged, Effective-derived title/search/paste updated, and one successor Content Version.

#### WS7 — Same-content revision no-op

Submit a replace or revert whose proposed Effective Content equals current bytes. Expect `.unchanged`, no appended revision, no Content Version/Change Position advance, and no observation emission.

#### WS8 — Pin order

Pin three items, move the last before the first, then unpin the item now occupying the middle position. After each receipt, restart and assert public order plus stored ordinals are unique and exactly `0 ..< count`. Content Versions remain unchanged; each non-no-op action advances Change Position once.

#### WS9 — Retention in the primary commit

Configure maximum unpinned count 2 and insert three unpinned items through `SwiftDataHistory`; expect the oldest eligible item retired in the third insert's same History Commit, leaving two unpinned items, and assert the retired ID is gone and `ChangePosition` advanced once. Exercise the hard-bound capacity failure at the planner seam: call `planCapture` with an injected `hardMaximumRetainedItems` equal to the current retained count where every item is pinned, and assert the plan is `capacityExceeded(.retainedItems)` rather than retiring a pinned item or the primary. (The fixed 5,000-item `HistoryLimits.standard` bound makes a full end-to-end all-pinned-at-hard-bound store impractical to construct, so the capacity-failure path is proved at the Domain planner seam, where the bound is a parameter.)

#### WS10 — Clear atomicity

Create pinned and unpinned items. `.clear(.unpinned)` removes the complete unpinned set in one commit and preserves pins; `.clear(.all)` removes all remaining rows in one later commit. No partial page is observable.

#### WS11 — Receipt read-after-write

After every committed outcome family, immediately call the relevant public read. Its position/reference/state must include that commit without notification waiting or manual refresh.

#### WS12 — Observation registration race

Pause an observer between registration and first query, commit a change, then resume. Its first yielded page must include the commit or be replaced before yield. Coalesce several later invalidations and verify one fresh page reaches the latest position.

#### WS13 — Transaction failure

Inject failure after row mutation but before singleton update inside the transaction. Expect unchanged durable rows and position, unchanged Signature Index, no invalidation, no receipt, and the caller observes `.persistence(.transaction)` — the documented producer for a `ModelContext.transaction` closure failure (Part V §16).

#### WS14 — Restart reconstruction

After insert, coalesce, pin reorder, and multiple revisions, reopen the store. Assert complete Signature Index, current position, Effective Content, projections, occurrences, and pin order match pre-restart public results.

#### WS15 — Thumbnail version fence

Start a thumbnail request for one reference, revise the item during decode, and verify the old result remains tagged with the old reference and cannot be applied to the new row. A request begun with an already stale reference fails rather than returning current bytes under the old key.

#### WS16 — Remove and not-found failures

Insert an item, then `perform(.remove(id))`. Expect `.removed(count: 1)`, `ChangePosition` advanced once, and the ID absent from subsequent browse/detail/paste. A later `.remove`, `.unpin`, or `.revise` on the absent ID returns `.notFound`; `.placePinned` returns `.invalidPinnedPlacement(.targetMissing)` — placement uses its own anchor-missing vocabulary by design (Part III-B §10 `PinnedPlacementFailure`). (Covers `.remove` and the `.notFound` / `.invalidPinnedPlacement` failure producers.)

#### WS17 — Search modes and matched ranges

Populate the store with known rows. For each frozen mode — exact (title-then-body substring), fuzzy (Fuse, pinned-first, score then recency then ID), regexp (`NSRegularExpression`, 1,000-Character prefixes) — assert the ranked rows, pinned-first ordering, and that `SearchPresentation.matchedRanges` are UTF-16 offsets that index correctly into `HistoryRow.title` (title match, `snippet == nil`) or into `snippet` (body match). Assert an invalid regexp returns `invalidInput(.invalidRegularExpression)` before scanning and a fuzzy query over 256 Characters returns `invalidInput(.invalidSearchTerm)`. (Covers the three search modes and their failure producers, and the Fuse-range→UTF-16 translation.)

#### WS18 — Pagination and cursor expiry

Browse with a small limit; assert `HistoryPage.next` resumes the continuation page with no overlap or gap. Then commit any mutation and reuse the old cursor; assert `browse` returns `.snapshotExpired(current:)` rather than skipping or repeating. A cursor whose query shape or generation no longer matches returns the same explicit failure, not a silent skip. (Covers cursor pagination and the `snapshotExpired` producer.)

#### WS19 — Out-of-order capture monotonicity

Capture an item, then submit an identical capture whose `observedAt` is earlier than the stored `lastCopiedAt`. Assert the winner ID is unchanged, occurrence `count` increments, `lastCopiedAt` does not move backward, and `lastSource` does not regress to nil. (Covers the out-of-order / monotone-occurrence behavior and the `lastSource ?? existing.lastSource` rule.)

#### WS20 — Concurrent revision and coalescing

Between the two phases of a revision, perform a Copy Coalescing commit on the same item; assert the revision still commits (Content Version preserved) and occurrence is folded. Perform instead a content-changing revision between the phases of a first revision; assert the first returns `.staleContent`. (Covers the two-phase revision OCC interleaving described in Part V §6.2; a deterministic concurrency harness drives the interleaving.)

#### WS21 — Retention policy in the primary commit

Set `maximumUnpinnedItems` to a value the current state already satisfies and assert `.unchanged` (no commit, no advance). Then lower it below the current unpinned count and assert the excess oldest unpinned items are retired in the same History Commit, the policy value is persisted on the singleton, and `.retentionPolicySet(removedCount:)` is returned with `ChangePosition` advanced once. Restart and confirm the singleton `maximumUnpinnedItems` survived. (Covers `.setRetentionPolicy` and the `retentionPolicySet` outcome — the last previously path-less included behavior.)

### 9. Performance proofs

Correctness gates run first. Performance claims are accepted only from a release-like runner workload with recorded fixtures and machine metadata.

- Capture commit interval excludes pasteboard access, fingerprinting, rich-text projection, and image decode.
- Healthy capture candidate generation is proportional to incoming bytes plus posting-set/candidate confirmation work, not all Canonical blobs.
- Index rebuild is O(retained signature metadata) and bounded by 5,000 items.
- Pin reorder is O(pinned count), bounded by retained count.
- User retention and clear are O(retained scalar metadata), bounded by retained count.
- Recent browse materializes at most `limit + 1` scalar rows after the storage query/order strategy is proved.
- v1 search may scan all bounded scalar search projections; no cache is added without G2 evidence.
- Detail/paste decode one item's bounded lineage.
- Thumbnail performs one bounded source fetch and one shared concurrent decode for an identical key.

No numeric latency target in a future PR may be declared satisfied by the current repository's implementation; it must measure the greenfield scaffold.

### 10. Documentation self-review gate

Before implementation begins, a mechanical scan of `docs/` must find none of the deleted v1 vocabulary except in explicit rejection/history statements:

```text
HistoryCommandPort
HistoryQueryPort
HistoryWorkingSet
ScanCompleteness
AppliedTransition
StructuralChangeRecord
ChangeKind-driven bump
ChangeFeed
ChangeCursor
VersionMap
SourceStamp
R0 / R1 / R2 as shipped tiers
registeredModel(for: HistoryItemID)
refreshAllObjects
four search modes
design phase complete
```

The review must also verify:

- exactly one Content Version rule;
- exactly one commit primitive and post-commit order;
- all public type names match across Parts;
- all Domain mutations have an executor mapping;
- all schema fields reconstruct the Domain state they claim to persist;
- all included behavior has at least one walking-skeleton path;
- all excluded behavior has no placeholder public/schema surface.

### 11. Completion statement

After the document self-review passes, the design is **consolidated**. It must still be described as “scaffold proof pending.”

Only after Sections 6–9 and WS1–WS21 pass may the header be changed to “executable v1 specification.” Only product implementation and its separate acceptance tests may call the greenfield refactor complete.
