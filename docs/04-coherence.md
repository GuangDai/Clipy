## Part IV — Read and Observation Coherence

### 1. v1 coherence model

v1 has one semantic source of truth: durable SwiftData state accessed through `HistoryAuthority`. It has no list cache, search-result cache, detail cache, version map, durable change journal, or generic materialization tier.

The coherence contract is therefore stated in terms of commits and snapshots rather than cache invalidation:

1. Every non-empty History Commit persists one new `ChangePosition` in the same transaction as its item mutations.
2. Every read captures its source values and position during one non-suspending Authority interval.
3. A committed receipt is returned only after durable state, required Signature Index updates, and internal invalidation publication are complete.
4. A read whose invocation begins after that receipt sees the commit or a later one.
5. Derived work identifies the snapshot/version from which it was produced and is never relabeled as newer state.

### 2. Authoritative snapshots

`HistoryPage.position` is the durable `ChangePosition` captured with the scalar rows used to build the page. It means:

> Every source value used by this page was authoritative at this position.

It does not promise that no later commit occurred while an off-actor search evaluation or UI delivery was in progress. A one-shot `browse` may therefore return a valid historical snapshot. An observer handles intervening commits by issuing a replacement snapshot.

The Authority read interval is:

```text
enter HistoryAuthority
→ create operation-local ModelContext
→ read LastChangePositionRow
→ fetch the request's scalar projection using the same context
→ construct a Sendable source snapshot
→ release all @Model values and the context
→ leave HistoryAuthority
```

There is no `await` inside the interval, so the sole writer cannot interleave a commit between the position read and scalar fetch. Reads and writes share the same actor ordering even though each operation uses a fresh context.

### 3. Read-after-commit

For a returned receipt:

```swift
case .committed(let commit)
```

any `browse`, `details`, `pastePayload`, or version check that begins afterward must observe durable position `>= commit.position`.

This guarantee does not depend on cross-context notifications or manual refresh. The transaction completed before the receipt, and the later serialized read creates a new context against the same `ModelContainer`.

The Part VI walking skeleton must demonstrate this on the supported SwiftData runtime before the design is called executable.

### 4. Internal invalidation, not a public ChangeFeed

`HistoryStorage` owns a process-local value:

```swift
internal struct HistoryInvalidation: Sendable {
    let latestPosition: ChangePosition
}
```

Semantics:

- one invalidation is synchronously yielded after each successful History Commit;
- no invalidation is yielded for a no-op or failed transaction;
- buffering may keep only the newest value because it is a wake-up signal, not a delta;
- it has no replay after process restart;
- it contains no content, before/after state, audit identity, or requirement that every position be delivered;
- it is not public and is not a durable History Change Record (an explicitly excluded post-v1 concept).

Consumers never apply an invalidation to local state. `ClipboardHistory.observe` consumes it internally and re-reads authoritative state.

### 5. Race-free observation

The observation algorithm hides the classic “initial query versus subscription” race:

```text
1. Register an internal invalidation continuation with HistoryAuthority.
2. Start an authoritative first-page query.
3. Let P be the resulting page position.
4. If any registered invalidation has position > P, discard the page and query again.
5. Otherwise yield the page.
6. Await the next invalidation whose position is greater than the yielded page.
7. Coalesce immediately available invalidations and query one replacement page.
8. Repeat until cancellation or failure.
```

Because registration happens before the first query, a commit in between is recorded. Because the page carries its source position, the observer can discard an obsolete result deterministically.

Cancellation unregisters the continuation and releases query/search tasks. An observation created after restart gets current state as its first page; it does not replay past commits.

### 6. Browse pagination

`HistoryPageCursor` encodes, opaquely:

- the complete normalized query shape;
- the page's `ChangePosition`;
- the complete last-row ordering anchor;
- a process-instance/schema marker.

For recent history, the anchor includes pin group, pin ordinal or last-copied timestamp, and final History Item ID. Search cursors additionally bind the normalized term and mode-specific ordering anchor.

Before serving a continuation page, `browse` verifies:

1. the request shape matches the cursor;
2. the cursor belongs to this process/schema generation;
3. current durable `ChangePosition` equals the cursor position.

Any intervening commit expires the cursor with `.snapshotExpired(current:)`. This intentionally favors simple, explicit snapshot semantics over trying to merge writes into an old paginated view.

Observation is limited to the first page. Additional pages are explicit one-shot browse calls and restart from page one after expiration.

### 7. Search coherence

Search uses a two-step value pipeline:

```text
HistoryAuthority captures SearchCorpusSnapshot(position, scalar rows)
→ SearchWorker evaluates exact / fuzzy / regexp off-actor
→ bounded HistoryPage(position, ordered rows)
```

The source snapshot contains only scalar projection data required for search and row display. It does not contain Canonical Content, revision blobs, model instances, or dedup ranks.

For one-shot browse, a commit during evaluation does not corrupt the result; the returned page is correctly labeled with its older position. For observation, an invalidation newer than that position causes the result to be discarded and recomputed before it is yielded.

Search determinism requirements:

- exact, fuzzy, and regexp are separate algorithms with fixture-defined results;
- invalid regular expressions fail before scanning;
- mode-specific relevance is stable for identical inputs;
- every sort ends with `lastCopiedAt` descending and History Item ID bytes ascending;
- matched ranges use UTF-16 offsets into the returned snippet, not `String.Index` values;
- result and corpus sizes obey Part VI bounds.

### 8. Detail and paste coherence

`details(for:)` loads one complete item lineage, validates it, derives current Effective Content, and returns one `HistoryItemReference`. A later revision may make the details stale; edit submission detects this through its required expected Content Version.

`pastePayload(for:)` loads current Effective Content and returns it with the current reference and a lineage hint equal to the item ID. `ClipyApp` then asks `PasteboardAdapter` to write it. The write is intentionally outside the History transaction; a clipboard side effect is not durable History state.

Neither query caches an item or promises a lease. The caller must use the returned version when starting follow-up work.

### 9. Thumbnail single-flight

Thumbnail is the only v1 shared materialization coordination. It is single-flight, not a completed-result cache.

```swift
internal struct ThumbnailFlightKey: Sendable, Hashable {
    let item: HistoryItemReference
    let pixels: PixelSize
}
```

Flow:

1. Validate positive bounded dimensions.
2. Fetch the item and require its current Content Version to equal the requested reference.
3. Derive Effective Content and select the supported image representation as an immutable byte value.
4. If no supported image representation exists, return `nil`.
5. Join or create the flight for the exact `(ID, ContentVersion, dimensions)` key.
6. Decode/downsample on `ThumbnailWorker`, enforce output bounds, encode PNG, and return a payload carrying the same key values.
7. Remove the flight entry on success, failure, or cancellation. Completed bytes are not retained by HistoryStorage.

Steps 2–3 run inside one non-suspending `HistoryAuthority` interval, so no commit can interleave between the version check (step 2) and the Effective-Content derivation (step 3). The version fence is therefore about the off-Authority decode (step 6): if the item changes during decode, the result is still correctly tagged with the verified old reference, and the caller applies it only if its row still carries that reference. A request whose reference was already stale before step 2 fails there with `.staleContent`; current bytes are never returned under an old key. If the item changes after step 3, the old-version decode remains a valid result for the requested reference.

### 10. Projection coherence

The row's `title`, `searchBody`, and effective type summary are durable projections of Effective Content. The same transaction that appends a revision writes the new projections. Capture writes projections from initial Canonical-as-Effective Content. Metadata-only mutations do not rewrite them.

Projection rules are versioned storage implementation detail. At decode/migration boundaries, an unknown projection schema either triggers an explicit rebuild from content or fails initialization; it never silently treats stale projection text as current.

### 11. Absent v1 coherence machinery

The following names and concepts must not appear in the v1 public or shipped internal surface:

- `VersionMap` or ID-to-version mirror.
- Generic `Resolution`, `SourceStamp`, `ItemKey<Purpose>`, or `OutputParams` frameworks.
- R0/R1/R2 tier naming.
- Collection snapshot cache or incremental event application.
- Durable Change Cursor or `changes(since:)`.
- Publish fences, reap state machines, or generic materialization stores.
- Long-lived model objects refreshed through undocumented APIs.

The UI owning the latest returned page is ordinary caller state, not a History cache tier.

### 12. Law for future caches

If Part VI evidence later admits a cache, it must preserve this law:

> For the same authoritative source state and request, cache hit, cache miss, eviction, disabled cache, and process restart produce semantically identical values and failures; only latency and resource use may differ.

Any future item cache key must contain History Item ID, the relevant authoritative version, complete normalized parameters, and a structural materializer schema version. Any future collection cache requires a durable change journal or another proved completeness mechanism; the transient v1 invalidation stream is insufficient.
