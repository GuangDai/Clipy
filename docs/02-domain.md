## Part II — Domain Model

### 1. Role and boundary

`HistoryDomain` is the package-only functional core. It imports `Foundation` and `HistoryCore`, but no framework that performs I/O or owns UI/storage objects. It contains immutable values and pure functions. It has no actor, clock, UUID generator, model context, cache, global singleton, or async method.

The Domain answers one question:

> Given one requested operation, its prepared value inputs, and action-specific facts that are proven complete, is there a valid mutation; if so, what complete semantic mutations must one History Commit perform?

It does **not** answer how rows are fetched, how bytes are fingerprinted, how tokens are minted, how a transaction is committed, or how callers are notified.

The former generic `Transition`, `HistoryWorkingSet`, `ScanCompleteness`, `StructuralChangeRecord`, and parallel delta maps are deleted. They made unlike operations appear uniform while weakening the completeness and payload guarantees each operation actually needs.

### 2. Content values

All declarations in this Part are `package` unless explicitly described as a reference to a public `HistoryCore` type.

#### 2.1 Content representation

```swift
package struct ContentRepresentation: Sendable, Hashable {
    package let typeIdentifier: String
    package let bytes: Data
}
```

Equality is byte-exact on `(typeIdentifier, bytes)`. A normalized content set:

- is non-empty;
- contains at most one representation for each `typeIdentifier`;
- contains no representation whose `bytes` is empty (zero length);
- is sorted by `typeIdentifier` using a stable Unicode scalar ordering;
- contains no transient/private pasteboard type rejected by preparation;
- stays within the hard representation-count and byte-size bounds in Part VI.

Two representations with the same type identifier and different bytes are ambiguous input, not an invitation to choose by iteration order. Preparation rejects them with a typed invalid-input failure.

#### 2.2 Fingerprint and signature evidence

```swift
package struct ContentFingerprint: Sendable, Hashable {
    package let rawValue: UInt64
}

package struct ContentSignatureEntry: Sendable, Hashable {
    package let typeIdentifier: String
    package let fingerprint: ContentFingerprint
    package let byteCount: Int
}
```

The fingerprint is xxh3-64 over one representation's bytes. A signature entry is derived from a Canonical representation. Neither value is identity and neither is sufficient for Copy Coalescing.

The equality and hashing of Canonical or Effective Content ignore fingerprints. A corrupted or colliding fingerprint may create an extra candidate; it must never create a false confirmed match.

#### 2.3 Canonical Content

```swift
package struct CanonicalRepresentation: Sendable, Hashable {
    package let content: ContentRepresentation
    package let fingerprint: ContentFingerprint

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.content == rhs.content
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(content)
    }
}

package struct CanonicalContent: Sendable, Hashable {
    package let representations: [CanonicalRepresentation]
}
```

`CanonicalContent` has one validating package initializer. It accepts already-prepared representations, verifies normalization and fingerprint coverage, and rejects empty or duplicate-type input. Its custom equality and hash use `content` only.

Canonical Content is the immutable ingest-lineage root:

- created only for a new History Item;
- preserved on Copy Coalescing;
- never replaced by a revision;
- never changed by pinning, retention, or observation;
- used by the general deduplication lane.

#### 2.4 Effective Content

```swift
package struct EffectiveContent: Sendable, Hashable {
    package let representations: [ContentRepresentation]
}
```

Effective Content is the single content state used for display, search, paste, editing, and thumbnails. It is distinct from Canonical Content even when their bytes currently match.

#### 2.5 Content Revision

```swift
package struct ContentRevision: Sendable, Hashable {
    package let id: RevisionID
    package let createdAt: Date
    package let content: EffectiveContent
}
```

A v1 revision stores a **complete Effective Content snapshot**, not a sparse action map. This intentionally spends bounded storage to obtain a deep and reliable invariant:

- the active revision contains every byte required to rebuild current Effective Content after restart;
- inactive revisions are independently readable;
- reverting does not depend on later Canonical interpretation rules;
- storage never has an `activeRevisionID` whose bytes are absent.

Revision rules:

1. The revision list is ordered by append order; when non-empty it contains the active revision.
2. Revision IDs are unique within an item.
3. `activeRevisionID == nil` implies Effective Content is derived from Canonical Content (one direction only; the full iff is stated in invariant D3).
4. A non-nil active ID names exactly one revision in the full list.
5. Revisions are immutable and append-only in v1.
6. A meaningful replace or revert appends a new revision and makes it active.
7. A proposed revision byte-equal to current Effective Content is a no-op: no redundant revision, commit, version, or invalidation.
8. v1 performs no automatic revision pruning. A hard per-item revision-count and revision-byte bound rejects growth beyond its safety envelope.

#### 2.6 Effective Content derivation

```swift
package func effectiveContent(of item: HistoryItemState) throws -> EffectiveContent
```

- With no active revision, strip fingerprints from Canonical representations and return the normalized result.
- With an active revision, find it in `item.revisions` and return its complete content snapshot.
- A missing active revision (non-nil `activeRevisionID` naming no stored revision), a duplicated active revision, or a non-empty revision list with a nil active ID (D3) is corrupt persisted state, not an implicit fallback to Canonical Content.

Title, search body, paste bytes, edit draft, and thumbnail input are all derived from this one result. Revision never changes the Canonical signature used by general deduplication.

### 3. Retained item state

#### 3.1 Copy origin and occurrence

```swift
package struct CopyOrigin: Sendable, Hashable {
    package let lineageHint: HistoryItemID?
    package let sourceApplication: String?
}

package struct CopyOccurrence: Sendable, Hashable {
    package let firstCopiedAt: Date
    package let lastCopiedAt: Date
    package let count: UInt64
    package let firstSource: String?
    package let lastSource: String?
}
```

A new item initializes all first/last values from the accepted capture and sets `count = 1`.

Copy Coalescing produces a complete replacement occurrence value:

```text
firstCopiedAt = existing.firstCopiedAt
lastCopiedAt  = max(existing.lastCopiedAt, incoming.observedAt)
count         = checked(existing.count + 1)
firstSource   = existing.firstSource
lastSource    = (incoming.sourceApplication ?? existing.lastSource)
                when incoming.observedAt >= existing.lastCopiedAt,
                otherwise existing.lastSource
```

Out-of-order capture must not move recency or its associated source observation backwards. Count overflow rejects the operation instead of wrapping or silently saturating.

`sourceApplication` and `lineageHint` are observations, not authenticated provenance. A lineage hint never bypasses byte comparison.

#### 3.2 Pin state

```swift
package struct PinOrdinal: Sendable, Hashable, Comparable {
    package let rawValue: Int

    package static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
```

Swift does not synthesize `Comparable`; `<` orders by `rawValue` as shown above. `rawValue` is non-negative (planners only ever mint `0 ..< p`); a negative stored value is persistence corruption (Part V §7.2). An item stores `PinOrdinal?`; `nil` means unpinned. The semantic pin state is the ordered list of pinned History Item IDs. Ordinals are only its persistence encoding.

For `p` pinned items, valid ordinals are exactly `0 ..< p`, each used once. Callers can observe a pinned position but cannot submit a numeric ordinal.

#### 3.3 History Item state

```swift
package struct HistoryItemState: Sendable, Hashable {
    package let id: HistoryItemID
    package let contentVersion: ContentVersion
    package let canonical: CanonicalContent
    package let revisions: [ContentRevision]
    package let activeRevisionID: RevisionID?
    package let occurrence: CopyOccurrence
    package let pinOrdinal: PinOrdinal?
}
```

The value is a fully hydrated item used only when an operation requires content lineage. List and search reads do not expose or hydrate it.

Removal is absence from the retained set. There is no tombstone flag or reusable removed-ID pool. Once removed, an ID is never resurrected or reassigned; a later capture creates a new ID.

### 4. Prepared action inputs

Preparation and entropy live in `HistoryStorage`, then enter pure planning as values.

```swift
package struct PreparedCapture: Sendable {
    package let candidateID: HistoryItemID
    package let canonical: CanonicalContent
    package let origin: CopyOrigin
    package let observedAt: Date
}

package struct PreparedRevision: Sendable {
    package let candidateRevisionID: RevisionID
    package let createdAt: Date
    package let basedOn: ContentVersion
    package let proposedContent: EffectiveContent
}
```

`RevisionDraft` and `RevisionTarget` are public `HistoryCore` values defined in Part III. `HistoryStorage` first obtains an immutable revision-preparation snapshot, resolves the public intent and validates raw byte/count/coherence bounds off the Authority, then produces this complete proposed content. Domain planning rechecks it against the latest item and the request's OCC token before admitting it.

The Domain never calls `UUID()`, `Date()`, `ContentVersion.initial/successor`, or `ChangePosition.successor`.

### 5. Action-specific complete facts

Completeness is expressed by the fact type that a planner accepts, not by a flag on a generic aggregate. A fact loader either constructs the required complete value or fails the History Action before planning.

#### 5.1 Ingest facts

```swift
package struct CompleteDedupCandidates: Sendable {
    package let items: [HistoryItemState]
}

package struct RetainedItemSummary: Sendable, Hashable {
    package let id: HistoryItemID
    package let lastCopiedAt: Date
    package let pinOrdinal: PinOrdinal?
}

package struct CompleteRetentionInventory: Sendable {
    package let allItems: [RetainedItemSummary]
}

package struct IngestFacts: Sendable {
    package let hintedItem: HistoryItemState?
    package let candidates: CompleteDedupCandidates
    package let retention: CompleteRetentionInventory
}
```

Construction guarantees:

- `hintedItem` is fetched directly by business ID when a hint exists; it is independent of signature candidacy.
- `candidates.items` contains every retained item whose Canonical signature can cover every incoming signature entry.
- Every candidate is loaded sufficiently to perform byte-exact confirmation.
- `retention.allItems` contains every retained item exactly once.
- Failure to establish any guarantee is a Storage fact-loading failure mapped to `HistoryFailure.temporarilyUnavailable` — `.factProof` for an action-specific fact load, or `.dedupIndexRebuild` when the Signature Index itself cannot be rebuilt to a proved-complete state (Part V §7.1 step 1, §16) — or a persistence-corruption failure. The Domain planner is not invoked with a partial fact.

There is no `.bounded` state and no rule that an empty partial scan permits insertion.

#### 5.2 Pinned-order facts

```swift
package struct CompletePinnedOrder: Sendable {
    package let itemIDs: [HistoryItemID]
}

package struct PinFacts: Sendable {
    package let targetExists: Bool
    package let order: CompletePinnedOrder
}
```

Construction validates that every pinned retained row appears exactly once and ordinals are unique and contiguous. A malformed stored order is a persistence invariant failure; the planner does not guess a repair.

#### 5.3 Revision facts

```swift
package struct RevisionFacts: Sendable {
    package let item: HistoryItemState
}
```

The fact loader must return the complete target lineage or `notFound`. It does not synthesize a missing active revision.

#### 5.4 Clear and remove facts

```swift
package struct RemoveFacts: Sendable {
    package let item: RetainedItemSummary?
}

package struct ClearFacts: Sendable {
    package let affected: [RetainedItemSummary]
}
```

`ClearFacts.affected` is the complete set selected by the requested scope at the Authority linearization point. There is no partial clear.

#### 5.5 Retention facts

```swift
package struct RetentionFacts: Sendable {
    package let inventory: CompleteRetentionInventory
    package let currentPolicy: RetentionPolicy
}

package struct RetentionPolicy: Sendable, Hashable {
    package let maximumUnpinnedItems: Int
}
```

`maximumUnpinnedItems` is at least 1 and no greater than the configured hard retained-item bound, matching the Part VI user range 1–5,000. A value of 0 is rejected at the `HistoryStorage` boundary (typed `invalidInput`) so the policy always permits at least one unpinned item. Pinned items are exempt from the user policy, but not from the global hard safety bound.

### 6. Domain rejection vocabulary

```swift
package enum DomainRejection: Error, Sendable, Equatable {
    case notFound(HistoryItemID)
    case staleContent(
        expected: ContentVersion,
        current: ContentVersion
    )
    case invalidPinnedPlacement(PinnedPlacementFailure)
    case invalidRevisionDraft
    case revisionNotFound(RevisionID)
    case corruptLineage
    case capacityExceeded(CapacityKind)
}
```

Planners throw only this package vocabulary. `HistoryStorage` maps it exhaustively to the public `HistoryFailure` cases in Part III: `notFound`→`.notFound`, `staleContent`→`.staleContent`, `invalidPinnedPlacement`→`.invalidPinnedPlacement`, `invalidRevisionDraft`→`.invalidInput(.incoherentRevisionDraft)`, `revisionNotFound`→`.revisionNotFound`, `capacityExceeded`→`.capacityExceeded`, and the defensive `corruptLineage`→`.persistence(.invariantViolation)`. Persistence corruption and fact-proof availability are normally caught at the Storage fact-loading boundary before planning; `corruptLineage` exists only as the planner's defensive backstop if a validated fact is internally inconsistent (e.g. an active revision ID that names no stored revision). A planner is never invoked with a known-incomplete fact.

### 7. Strong semantic mutation plan

The Domain returns one ordered plan. A mutation case carries the complete semantic payload for that kind of change.

```swift
package enum HistoryMutation: Sendable {
    case create(NewHistoryItem)
    case recordCopy(itemID: HistoryItemID, occurrence: CopyOccurrence)
    case assignPin(itemID: HistoryItemID, ordinal: PinOrdinal?)
    case appendRevision(
        itemID: HistoryItemID,
        revision: ContentRevision,
        activeRevisionID: RevisionID
    )
    case retire(itemID: HistoryItemID, reason: RetirementReason)
    case setRetentionPolicy(maximumUnpinnedItems: Int)
}

package struct NewHistoryItem: Sendable {
    package let id: HistoryItemID
    package let canonical: CanonicalContent
    package let occurrence: CopyOccurrence
}

package enum RetirementReason: Sendable {
    case userRemoval
    case clear
    case retention
}

package struct MutationPlan: Sendable {
    package let outcome: PlannedOutcome
    package let mutations: [HistoryMutation] // non-empty by invariant
}

package enum PlannedOutcome: Sendable {
    case inserted(HistoryItemID)
    case coalesced(HistoryItemID)
    case placedPinned(HistoryItemID)
    case unpinned(HistoryItemID)
    case removed(count: Int)
    case cleared(count: Int)
    case revised(HistoryItemID)
    case retentionPolicySet(removedCount: Int)
}

package enum PlanningResult: Sendable {
    case unchanged
    case commit(MutationPlan)
}
```

`PlannedOutcome` is package vocabulary mapped mechanically to the public receipt outcome in Part III. A policy update and all victims needed to satisfy it are one plan.

Plan invariants:

1. `mutations` is non-empty.
2. A create ID does not already exist in the facts.
3. `recordCopy` carries the final folded occurrence; Storage does not reconstruct it.
4. The final set of `assignPin` mutations plus unchanged pinned items produces exactly one contiguous order.
5. `appendRevision` carries the complete immutable revision and final active ID.
6. The revision case always changes Effective Content; same-content requests returned `.unchanged` earlier.
7. A retired item is not also the primary created/coalesced/revised result of the same plan.
8. Retention never retires a pinned item.
9. No plan redirects, merges, or reuses History Item IDs.
10. Version and projection values are intentionally absent. Part V stamps them mechanically from the mutation case and derived Effective Content, producing a storage-internal `StampedCommitPlan` before transaction execution.

This differs from the deleted parallel-map design: there is no independent change-kind array that can disagree with its payload and no Authority-only hidden occurrence fold.

### 8. Pure planners

The public closed `HistoryAction` is dispatched in `HistoryStorage`. Each case invokes a specific package planner with exactly the facts it requires.

```swift
package func planCapture(
    _ capture: PreparedCapture,
    facts: IngestFacts,
    retention: RetentionPolicy,
    hardMaximumRetainedItems: Int
) throws -> PlanningResult

package func planPinnedPlacement(
    itemID: HistoryItemID,
    placement: PinnedPlacement,
    facts: PinFacts
) throws -> PlanningResult

package func planUnpin(
    itemID: HistoryItemID,
    facts: PinFacts
) throws -> PlanningResult

package func planRemove(
    itemID: HistoryItemID,
    facts: RemoveFacts
) throws -> PlanningResult

package func planClear(
    scope: ClearScope,
    facts: ClearFacts
) -> PlanningResult

package func planRevision(
    request: RevisionRequest,
    prepared: PreparedRevision,
    facts: RevisionFacts
) throws -> PlanningResult

package func planRetention(
    facts: RetentionFacts,
    policy: RetentionPolicy
) -> PlanningResult
```

There is deliberately no universal `apply(_:to:)` protocol. The compiler-visible function signature documents which complete proof each operation needs.

### 9. Deduplication

#### 9.1 Candidate generation

For each incoming signature entry, `SignatureIndex` supplies a posting set of retained IDs. The intersection of all posting sets is the complete Canonical-containment candidate ID set when the index is ready and complete.

The index is an acceleration structure. Its readiness/completeness is established by `HistoryStorage`; the Domain receives only `CompleteDedupCandidates`. If index construction cannot be proven complete, capture fails before planning.

#### 9.2 Confirmation relation

```swift
package func canonicalContains(
    existing: CanonicalContent,
    incoming: CanonicalContent
) -> Bool
```

It returns true when every incoming `(typeIdentifier, bytes)` appears byte-exactly in the existing Canonical Content. Set containment is reflexive, antisymmetric, and transitive; it is a partial order, not an equivalence relation because it is not symmetric.

This preserves the useful “rich copy absorbs a later plain-only copy” behavior while refusing hash-only matches.

#### 9.3 Matching lanes

1. **Lineage lane.** If a direct retained hint exists and incoming content is byte-set-equal to the hinted item's current Effective Content, the hinted item wins. Containment is insufficient in this lane; equality prevents a spoofed hint from discarding representations.
2. **Canonical lane.** Byte-confirm `canonicalContains(existing, incoming)` for every complete signature candidate. Effective Content and inactive revisions do not participate.
3. **Insert.** Insert only when both lanes have no confirmed winner and candidate completeness has already been proven.

#### 9.4 Deterministic winner

When multiple Canonical candidates confirm, choose the minimum rank under:

```text
exact Canonical equality       descending (exact first)
extra representation count    ascending
lastCopiedAt                   descending
HistoryItemID bytes            ascending
```

The final ID tie-breaker makes selection independent of fetch or dictionary iteration order. Non-winning matching items remain distinct; they are never consolidated or redirected.

#### 9.5 Coalescing result

The winning item receives one `.recordCopy` mutation with the fully folded occurrence. Its ID, Canonical Content, Content Version, revision list, active revision, and pin ordinal remain unchanged. The later retention calculation operates on the projected latest occurrence order.

### 10. Pinned order

`PinnedPlacement` is owned publicly by Part III:

```swift
public enum PinnedPlacement: Sendable, Hashable {
    case first
    case last
    case before(HistoryItemID)
}
```

Planning algorithm:

1. Reject a missing target.
2. Copy the complete ordered ID list and remove the target if already pinned.
3. Insert at the requested explicit position.
4. `.before(anchor)` requires another retained pinned item; an anchor equal to the target is invalid.
5. If the final ordered IDs equal the original order, return `.unchanged`.
6. Zip the final order with `0 ..< count` and emit `.assignPin` only for IDs whose ordinal changed, including the target.

Unpin removes the target and shifts later ordinals. Pin/reorder/unpin never advances `ContentVersion`; the History Commit advances `ChangePosition` once.

Numeric pin-slot collision is no longer a caller-visible failure mode. Uniqueness is guaranteed by planning a complete order and committing all affected assignments atomically.

### 11. Revision planning and OCC

Every `RevisionRequest` carries the `ContentVersion` on which the editor based its draft.

Planning order is fixed:

1. Require `request.expected == facts.item.contentVersion`; otherwise throw `.staleContent(expected:current:)`.
2. Require `prepared.basedOn == request.expected`; a preparation result is built for exactly one base version and is never reused, so a mismatch is a defensive invariant violation that throws `.invalidRevisionDraft` (by construction preparation uses the request's expected version).
3. Derive current Effective Content. Storage validates lineage at fact load; if a defensive check here still finds it inconsistent (a missing or duplicated active revision, or a non-empty revision list with a nil active ID per D3), throw `.corruptLineage`.
4. Revalidate Domain-level invariants on `prepared.proposedContent`: it is normalized, non-empty, and contains only Canonical representation types; otherwise throw `.invalidRevisionDraft`. Storage has already enforced byte, per-representation-count, and per-item revision-count/byte hard limits during preparation (Part V §6.2); the Domain does not re-assert numeric bounds it does not receive.
5. If proposed and current bytes are equal, return `.unchanged`.
6. Otherwise append `ContentRevision(candidateRevisionID, createdAt, proposed)` and make it active.

Before this planner runs, Part V intent preparation has already applied every replace draft decision, resolved Canonical/revision revert targets, rejected missing/duplicated/foreign types, and copied the complete target Effective Content.

Storage later projects title/search from the proposed Effective Content and advances Content Version exactly once. A revert never restores an old version number.

### 12. Retention and hard capacity

v1 has one user retention dimension: maximum unpinned History Item count. Items are ordered for eviction by:

```text
lastCopiedAt ascending, HistoryItemID bytes ascending
```

Rules:

- Pinned items are excluded before victim selection.
- Capture retention is evaluated on the projected post-insert or post-coalesce state.
- Insert and its retention retirements are one History Commit.
- Coalescing can change which unpinned item is oldest.
- If the global hard retained-item maximum would be exceeded and no eligible unpinned victim can restore the bound, capture fails with `.capacityExceeded(.retainedItems)`.
- The primary inserted/coalesced item is not selected as a victim in the same commit. Configuration must permit at least one unpinned item.
- Setting the already-persisted policy value when current state also satisfies it is a no-op. Lowering the value updates the policy and retires all required victims in the same History Commit.
- Age, total-byte, and automatic revision-retention policies are outside v1.

Per-capture, per-revision, representation-count, per-item revision-count, and per-item revision-byte hard limits are admission/safety limits, not user retention policies.

### 13. Content Version and Change Position effects

The Domain does not mint either token. The Authority maps semantic mutations as follows:

| Semantic mutation | Content Version | Change Position |
|---|---|---|
| `.create` | initial value `1` | commit advances once |
| `.recordCopy` | preserve | commit advances once |
| `.assignPin` | preserve | commit advances once |
| `.appendRevision` | checked successor | commit advances once |
| `.retire` | item removed | commit advances once |
| `.setRetentionPolicy` | preserve every item version | commit advances once when the value changes or victims retire |
| `.unchanged` | preserve | no commit, no advance |

This table is the stamping contract the Authority (Part V §9) applies mechanically to each mutation case; the Domain itself mints neither token. If one plan contains multiple mutations, `ChangePosition` advances **exactly once for the whole plan** (not once per mutation): the Authority computes one checked successor of the current singleton position and reuses it for every mutation in the plan. All arithmetic is checked — a `ContentVersion` or `ChangePosition` successor overflow maps to `.capacityExceeded(.coherenceToken)`, and an occurrence `count` overflow maps to `.capacityExceeded(.copyCount)`; overflow fails closed and never wraps.

### 14. Domain invariants

- **D1 Stable identity:** Copy Coalescing preserves the winner ID; deletion never redirects or reuses it.
- **D2 Canonical immutability:** no mutation case can replace Canonical Content.
- **D3 Complete active lineage:** `activeRevisionID == nil` if and only if the revision list is empty; when nil, Effective Content is derived from Canonical Content. A non-nil active revision ID names exactly one stored full revision. A non-empty revision list with a nil active ID, or a non-nil ID naming no stored revision, is corrupt. (The iff is about the revision *list*, not Effective bytes: a revert-to-canonical appends a real revision whose bytes happen to equal Canonical, so active-ID-non-nil with Effective bytes equal to Canonical is valid.)
- **D4 Append-only meaningful revision:** replace/revert append only when Effective Content changes; prior revisions are immutable.
- **D5 Precise Content Version:** only create and effective-content-changing revision mint a new value.
- **D6 One global commit position:** every non-empty plan receives one new Change Position regardless of row count.
- **D7 Byte-exact confirmation:** fingerprint evidence never completes a dedup decision.
- **D8 Complete candidates:** no capture planner runs with partial candidacy.
- **D9 Deterministic winner:** the winner rank has a stable final ID tie-breaker.
- **D10 No loser consolidation:** non-winning matching items keep their IDs and state.
- **D11 Monotone occurrence:** Copy Coalescing cannot reduce last-copied time or count.
- **D12 Contiguous pin order:** retained pinned ordinals are unique and exactly `0 ..< pinnedCount`.
- **D13 Pin-protected retention:** user retention cannot retire a pinned item.
- **D14 Latest-state retention:** victim selection includes the primary mutation's projected effect.
- **D15 Removal is absence:** no domain tombstone is required in v1.
- **D16 Pure planning:** identical prepared inputs and facts produce identical planning results.
- **D17 No framework leakage:** all Domain stored properties are immutable `Sendable` values; no unchecked concurrency escape is allowed.
- **D18 Semantic-plan completeness:** Storage applies explicit mutation payloads and never infers hidden domain behavior from outcome labels.
- **D19 Retention floor:** the user retention policy received by planning is always at least one unpinned item (`HistoryStorage` rejects 0 at the boundary), so capture never retires the primary to satisfy the user policy alone; only the global hard retained-item bound can force a capacity failure.

These invariants are design requirements. Part VI defines the tests that must demonstrate them before this specification is called executable.
