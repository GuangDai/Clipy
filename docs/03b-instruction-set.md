## Part III — Caller Interface (B): DTOs, failures & caller examples

### 8. Browse DTOs

```swift
public struct UTF16TextRange: Sendable, Hashable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public struct SearchPresentation: Sendable, Hashable {
    public let snippet: String?
    public let matchedRanges: [UTF16TextRange]

    public init(
        snippet: String?,
        matchedRanges: [UTF16TextRange]
    ) {
        self.snippet = snippet
        self.matchedRanges = matchedRanges
    }
}

public struct HistoryRow: Sendable, Hashable {
    public let item: HistoryItemReference
    public let title: String
    public let typeIdentifiers: [String]
    public let lastCopiedAt: Date
    public let copyCount: UInt64
    public let lastSource: String?
    public let pinnedPosition: Int?
    public let search: SearchPresentation?

    package init(
        item: HistoryItemReference,
        title: String,
        typeIdentifiers: [String],
        lastCopiedAt: Date,
        copyCount: UInt64,
        lastSource: String?,
        pinnedPosition: Int?,
        search: SearchPresentation?
    ) {
        self.item = item
        self.title = title
        self.typeIdentifiers = typeIdentifiers
        self.lastCopiedAt = lastCopiedAt
        self.copyCount = copyCount
        self.lastSource = lastSource
        self.pinnedPosition = pinnedPosition
        self.search = search
    }
}

public struct HistoryPage: Sendable, Hashable {
    public let position: ChangePosition
    public let rows: [HistoryRow]
    public let next: HistoryPageCursor?

    package init(
        position: ChangePosition,
        rows: [HistoryRow],
        next: HistoryPageCursor?
    ) {
        self.position = position
        self.rows = rows
        self.next = next
    }
}
```

Recent rows have `search == nil`; search rows carry presentation evidence but not an internal score. Results are already deterministically ordered. `HistoryRow.pinnedPosition` is 0-based and equals the item's `PinOrdinal` (`nil` for unpinned rows); it identifies position within the pinned group only — a UI wanting a 1-based display number adds one itself.

Default total ordering:

```text
pinned rows:   pinOrdinal ascending
unpinned rows: lastCopiedAt descending, HistoryItemID bytes ascending
```

Search behavior is frozen as follows:

- An empty term is equivalent to `.recent` and carries no search presentation.
- Exact is a case-insensitive literal substring search. It checks title first and, only when title does not match, the full bounded `searchBody`. It returns the first match and preserves the default row order.
- Regexp first rejects an invalid or known unsafe pattern, then uses Foundation `NSRegularExpression` (an NFA engine, hence the conservative unsafe-pattern guards). It scans at most the first 1,000 Characters of title and, only on title miss, the first 1,000 Characters of body, returns the first match, and preserves the default row order.
- Fuzzy uses `krisk/fuse-swift` 1.4.x with `threshold` 0.7, `location` 0, `distance` 100, and `isCaseSensitive` false — all fixed and fixture-locked. It scans at most the first 5,000 Characters of title and, only on title miss, the first 5,000 Characters of body. Fuse 1.4.0 does **not** enforce its `maxPatternLength` option (the parameter is unread in that release, so the documented "return nil" never fires); the SearchWorker therefore enforces the Part VI fuzzy-query bound (256 Characters) itself — a query exceeding it is rejected as `invalidInput(.invalidSearchTerm)` before Fuse is called. Fuse returns match ranges as Character offsets into its own lowercased working copy; the SearchWorker translates those to UTF-16 offsets into the original (non-lowercased) title or excerpt before building `matchedRanges`. Results preserve the default pinned-first order: pinned rows first, ordered by `pinOrdinal` ascending (matching the default order); then unpinned rows, ordered by ascending Fuse score, then `lastCopiedAt` descending, then History Item ID bytes ascending.
- A title match has `snippet == nil` and UTF-16 ranges relative to `HistoryRow.title`. A body match supplies a deterministic bounded excerpt in `snippet`; its ranges are relative to that excerpt.

Body excerpt construction is fixed: sort match ranges; if the body is shorter than 320 Characters the window is the whole body and no ellipses are added; otherwise center a window of at most 320 Characters on the earliest match (when the match itself is longer, retain its first 320 Characters), distribute remaining context equally before/after with the extra Character after — context that would extend past a body edge is redistributed to the other side; add `…` at each edge where text was omitted — a leading ellipsis appears only when the window starts after the body start, a trailing ellipsis only when it ends before the body end; clip later ranges to the retained window; then convert the retained ranges to UTF-16 offsets into the final snippet, shifting each range right by the length of the leading ellipsis only when one is present. The final snippet is at most 322 Characters.

Regexp admission rejects, returning `invalidInput(.invalidRegularExpression)` in every case: a pattern over the Part VI 512-Character limit; a pattern that fails Foundation `NSRegularExpression` compilation; a quantified group that itself contains a quantifier and is quantified (e.g. `(a+)+`); a quantified alternation group whose branches contain quantifiers (e.g. `(a+|b)+`); and any backreference — the features that risk catastrophic NFA backtracking or unbounded work. Plain non-capturing groups `(?:…)`, anchors, and character-class constructs are permitted *unless* they participate in a rejected nested-quantifier form. These conservative guards intentionally reject some valid but risky patterns; regexp search never executes a rejected pattern.

Search scores and Fuse objects remain internal. Fixture tests own Unicode conversion, unsafe-regexp rejection, title-before-body behavior, tie-breakers, and excerpt/range stability.

### 9. Detail, paste, and thumbnail DTOs

```swift
public struct HistoryRepresentation: Sendable, Hashable {
    public let typeIdentifier: String
    public let bytes: Data

    package init(typeIdentifier: String, bytes: Data) {
        self.typeIdentifier = typeIdentifier
        self.bytes = bytes
    }
}

public struct RevisionSummary: Sendable, Hashable {
    public let id: RevisionID
    public let createdAt: Date
    public let isActive: Bool
    public let title: String
    public let typeIdentifiers: [String]
    public let byteCount: Int

    package init(
        id: RevisionID,
        createdAt: Date,
        isActive: Bool,
        title: String,
        typeIdentifiers: [String],
        byteCount: Int
    ) {
        self.id = id
        self.createdAt = createdAt
        self.isActive = isActive
        self.title = title
        self.typeIdentifiers = typeIdentifiers
        self.byteCount = byteCount
    }
}

public struct CopyOccurrenceSummary: Sendable, Hashable {
    public let firstCopiedAt: Date
    public let lastCopiedAt: Date
    public let count: UInt64
    public let firstSource: String?
    public let lastSource: String?

    package init(
        firstCopiedAt: Date,
        lastCopiedAt: Date,
        count: UInt64,
        firstSource: String?,
        lastSource: String?
    ) {
        self.firstCopiedAt = firstCopiedAt
        self.lastCopiedAt = lastCopiedAt
        self.count = count
        self.firstSource = firstSource
        self.lastSource = lastSource
    }
}

public struct HistoryDetails: Sendable, Hashable {
    public let item: HistoryItemReference
    public let canonical: [HistoryRepresentation]
    public let effective: [HistoryRepresentation]
    public let revisions: [RevisionSummary]
    public let occurrence: CopyOccurrenceSummary
    public let pinnedPosition: Int?

    package init(
        item: HistoryItemReference,
        canonical: [HistoryRepresentation],
        effective: [HistoryRepresentation],
        revisions: [RevisionSummary],
        occurrence: CopyOccurrenceSummary,
        pinnedPosition: Int?
    ) {
        self.item = item
        self.canonical = canonical
        self.effective = effective
        self.revisions = revisions
        self.occurrence = occurrence
        self.pinnedPosition = pinnedPosition
    }
}

public struct PastePayload: Sendable, Hashable {
    public let item: HistoryItemReference
    public let representations: [HistoryRepresentation]
    public let lineageHint: HistoryItemID

    package init(
        item: HistoryItemReference,
        representations: [HistoryRepresentation],
        lineageHint: HistoryItemID
    ) {
        self.item = item
        self.representations = representations
        self.lineageHint = lineageHint
    }
}

public struct PixelSize: Sendable, Hashable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public enum ThumbnailFormat: Sendable, Hashable {
    case png
}

public struct ThumbnailPayload: Sendable, Hashable {
    public let item: HistoryItemReference
    public let pixels: PixelSize
    public let format: ThumbnailFormat
    public let encodedBytes: Data

    package init(
        item: HistoryItemReference,
        pixels: PixelSize,
        format: ThumbnailFormat,
        encodedBytes: Data
    ) {
        self.item = item
        self.pixels = pixels
        self.format = format
        self.encodedBytes = encodedBytes
    }
}
```

Detail is the only general UI query that returns content lineage bytes. Paste returns current Effective Content only. Thumbnail returns encoded, Sendable bytes rather than `NSImage`/`CGImage`.

### 10. Typed failures

```swift
public enum HistoryFailure: Error, Sendable, Equatable {
    case notFound(HistoryItemID)
    case staleContent(
        expected: ContentVersion,
        current: ContentVersion
    )
    case invalidInput(InvalidInputReason)
    case invalidPinnedPlacement(PinnedPlacementFailure)
    case revisionNotFound(RevisionID)
    case snapshotExpired(current: ChangePosition)
    case capacityExceeded(CapacityKind)
    case temporarilyUnavailable(UnavailableReason)
    case persistence(PersistenceFailure)
}

public enum InvalidInputReason: Sendable, Equatable {
    case emptyCapture
    case duplicateRepresentationType(String)
    case unsupportedRepresentationType(String)
    case representationLimit
    case byteLimit
    case incoherentRevisionDraft
    case invalidRegularExpression
    case invalidPageLimit
    case invalidPixelSize
    case invalidRetentionPolicy
    case invalidSearchTerm
}

public enum PinnedPlacementFailure: Sendable, Equatable {
    case targetMissing
    case anchorMissingOrUnpinned
    case targetEqualsAnchor
}

public enum CapacityKind: Sendable, Equatable {
    case retainedItems
    case revisionCount
    case revisionBytes
    case copyCount
    case coherenceToken
}

public enum UnavailableReason: Sendable, Equatable {
    case factProof
    case dedupIndexRebuild
}

public enum PersistenceFailure: Sendable, Equatable {
    case openStore
    case corruptStoredValue
    case invariantViolation
    case transaction
}
```

Storage maps package-only Domain rejections and platform errors to this vocabulary at one boundary. Public failures contain no raw SQL, model object, file path, or stringly typed reason.

### 11. Interface guarantees

1. `perform(.committed)` returns only after the durable transaction, mandatory index update, and internal invalidation publication.
2. A later call begun after that receipt observes at least its `ChangePosition`.
3. No-op actions return `.unchanged`; failures return no receipt.
4. Every page identifies the durable snapshot position from which its source values were captured.
5. `observe` emits complete replacement pages, not deltas.
6. A cursor from an older position fails explicitly rather than silently skipping or repeating items.
7. Detail/paste/thumbnail either resolve the requested current item/version semantics or return a typed stale/not-found failure; they never label new bytes with an old Content Version.
8. All returned collections and byte payloads are bounded by Part VI configuration limits.
9. The interface exposes no `@Model`, persistence identity, fingerprint, Candidate Rank, Domain state, change journal, or cache key.

### 12. Caller examples

#### Capture

```swift
let receipt = try await history.perform(
    .capture(
        ClipboardCapture(
            representations: snapshot.values.map {
                CapturedRepresentation(
                    typeIdentifier: $0.typeIdentifier,
                    bytes: $0.bytes
                )
            },
            origin: CopyOriginObservation(
                sourceApplication: frontmostBundleID,
                lineageHint: snapshot.historyItemID  // adapter-decoded prior-paste hint; nil if none
            ),
            observedAt: observedAt
        )
    )
)
```

#### Observe current recent rows

```swift
let pages = await history.observe(
    HistoryObservationRequest(kind: .recent, limit: 200)
)

for try await page in pages {
    rows = page.rows
}
```

#### Search

```swift
let request = HistoryObservationRequest(
    kind: .search(text: query, mode: .fuzzy),
    limit: 50
)

for try await page in await history.observe(request) {
    matches = page.rows
}
```

#### Pin and reorder

```swift
try await history.perform(.placePinned(id, at: .first))
try await history.perform(.placePinned(draggedID, at: .before(anchorID)))
try await history.perform(.unpin(id))
```

#### Revise with OCC

```swift
let details = try await history.details(for: id)

try await history.perform(
    .revise(
        RevisionRequest(
            itemID: id,
            expected: details.item.contentVersion,
            intent: .replace(draft)
        )
    )
)
```

#### Paste orchestration

```swift
let payload = try await history.pastePayload(for: id)
try await pasteboardAdapter.write(payload)
```

The last two lines belong in `ClipyApp` coordination. `HistoryStorage` does not import AppKit, and `PasteboardAdapter` does not call a concrete storage type.
