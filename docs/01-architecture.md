## Part I — Architecture

### 1. System shape

The architecture is a downward-only SwiftPM target graph with one public History boundary. Its depth comes from what callers do **not** need to know: Canonical Content, signatures, candidate completeness, SwiftData rows, pin ordinal shifts, retention victims, revision reconstruction, transaction order, and observation races all live behind `ClipboardHistory`.

All library targets live in one Swift package so package-only implementation vocabulary can cross internal target boundaries without becoming public. `ClipyApp` remains the Xcode application/composition target.

```text
ClipyApp
├── PresentationUI ────────→ HistoryCore + ClipboardFormats + ContentPreview
├── PasteboardAdapter ─────→ HistoryCore
└── HistoryStorage ────────→ HistoryCore + ClipboardFormats
          │                 → HistoryDomain
          ├────────────────→ xxh3
          └────────────────→ Fuse

HistoryDomain ─────────────→ HistoryCore

ClipboardFormats ────────→ Foundation only
ContentPreview ──────────→ ClipboardFormats + CoreGraphics + ImageIO
ClipyCLIContract ────────→ Foundation only
                            (pure wire contract; no shipped product surface)

HistoryPerfRunner ─────────→ HistoryCore + HistoryStorage
                             (proof executable; no shipped product surface)
HistoryRestartProbe ───────→ HistoryCore + HistoryStorage
                             (test-owned restart tracer; no shipped product surface)

ClipyUDSF0Client ──────────→ Foundation + AppKit + Darwin
                             (XcodeGen evidence target; no product CLI or History edge)
```

There is no `DomainCore` target. The few values that must appear in both the caller interface and Domain planning—`HistoryItemID`, `RevisionID`, `ContentVersion`, and `ChangePosition`—belong to `HistoryCore`. Everything else in `HistoryDomain` is `package` by default.

### 2. Target responsibilities

| Target | Surface | Owns | Must not own |
|---|---|---|---|
| `ClipboardFormats` | Package-only, Foundation-only | Open-world exact identifiers and declared string-codec facts | Purpose admission, decoders, bytes, registries, caches, plugins, framework objects |
| `ContentPreview` | Package-only concrete actor and immutable values | Preview source priority, exact text codecs, fixed resource profiles, eager ImageIO decode, and bounded inert text/raster outcomes | History reads, item/reference identity, selection or panel lifecycle, thumbnail request/source/cache policy, external I/O, registries, plugins, or framework objects in its interface |
| `ClipyCLIContract` | Package-only, Foundation-only, no product | Versioned UTF-8 JSON request/reply values, bounded decoding/encoding, and stable exit classes | File handles or standard-stream side effects, transport, credentials, Gateway/History access, a product CLI, operation dispatch, or fabricated Gateway results |
| `HistoryCore` | Public, Foundation-only | `ClipboardHistory`, IDs/tokens, History Actions, request/response DTOs, receipts, typed failures | Canonical state, fingerprints, SwiftData, AppKit, concrete storage |
| `HistoryDomain` | Package-only, Foundation-only | Content lineage, immutable state, complete fact values, pure planners, semantic mutation plans and invariants | Public ports, I/O, actors, clocks, UUID generation, persistence |
| `HistoryStorage` | Public concrete adapter plus internal implementation | `SwiftDataHistory`, Authority actor, schema/codecs, fact loaders, version minting, ingest preparation, Signature Index, read projections, observation plumbing, thumbnail production, and the internal F1 server-credential Keychain owner | AppKit pasteboard, UI state, service location, client credential files, or transport |
| `PasteboardAdapter` | Public adapter values used by the app | NSPasteboard observation/writes and translation to/from `HistoryCore` raw values | Deduplication, Canonical Content, fingerprints, persistence |
| `PresentationUI` | Public UI assembly | View state and interactions over History DTOs; exact-reference/task/lifecycle fences around ContentPreview | `@Model`, Domain state, persistence rules, change-feed bookkeeping, ImageIO decode |
| `ClipyApp` | Composition root | Concrete construction, lifecycle, paste orchestration, App Intents entry points, dependency injection, and the app-local external-remove→surface-purge join | Domain decisions, Gateway policy, global event buses, or duplicate persistence paths |
| `xxh3` | Package-internal C/ObjC++ sibling | 64-bit representation fingerprints | Item identity or final dedup decisions |
| `Fuse` | External Swift library used internally | Threshold-based fuzzy matching inside `SearchWorker` | Public search score or cross-actor matcher state |
| `HistoryPerfRunner` | Package executable, no product surface | Part VI §9 release-like workloads, machine metadata, and versioned fixtures | Caller APIs, alternate writers, production state, absolute-latency claims |
| `HistoryRestartProbe` | Package executable target, no declared product | Evidence Card 1C-1 short-lived public-API restart phases plus the X-HCR post-committed-receipt fatal-signal phase | App lifecycle, alternate writers, production state, migration, mid-transaction kill, power-loss, or physical-durability claims |
| `ClipyUDSF0Client` | XcodeGen command-line evidence target, not embedded or installed | The compile-time-isolated PLAY-PY-F0 fixed hello/ready client, bounded LaunchServices reconnect, and diagnostic process control | X.8 JSON, product `clipyctl`, History/Gateway access, credentials, authenticated ingress, or a supported automation surface |

#### Access rules

- `public` is reserved for caller-visible `HistoryCore`, the concrete `HistoryStorage` constructor needed by `ClipyApp`, and adapter/UI entry points.
- Cross-target implementation declarations use Swift `package` access.
- `ClipboardFormats` states stable exact facts only. Projection, Preview, Details, and Edit retain separate purpose policy; unknown identifiers remain opaque raw values.
- `ContentPreview` is one concrete deep module, not a renderer protocol,
  registry, plugin system, cache, or History reader. Callers select one of its
  closed product presets and receive only immutable bounded `Sendable` values.
- `ClipyCLIContract` describes and validates the X.8 wire boundary only. It has
  no executable entry point and neither dispatches operations nor fabricates a
  positive Gateway result.
- `ClipyUDSF0Client` and the app-side `CLIPY_UDS_F0` listener are disposable
  signed-runtime evidence only. Normal app builds contain no listener behavior;
  the diagnostic target is not embedded in a normal app artifact.
- Intra-target storage declarations use `internal` or `private`.
- `@Model` types are internal to `HistoryStorage` and never occur in a public or package signature.
- Domain planners and facts are not protocols intended for third-party extension. Adding a v1 History Action is an owned source change and must make compiler-exhaustive switches fail until handled.

### 3. Why this seam is deep

The public interface is placed at caller intent:

```swift
public protocol ClipboardHistory: Sendable {
    func perform(_ action: HistoryAction) async throws -> HistoryReceipt
    func browse(_ request: HistoryBrowseRequest) async throws -> HistoryPage
    func observe(
        _ request: HistoryObservationRequest
    ) async -> AsyncThrowingStream<HistoryPage, Error>
    func details(for id: HistoryItemID) async throws -> HistoryDetails
    func pastePayload(for id: HistoryItemID) async throws -> PastePayload
    func thumbnail(
        for item: HistoryItemReference,
        pixels: PixelSize
    ) async throws -> ThumbnailPayload?
}
```

Deleting this module would force callers to reimplement raw-copy normalization, deduplication, OCC, pin ordering, retention, revision resolution, transaction ordering, snapshot semantics, observation registration, and stale-thumbnail prevention. The small interface therefore hides substantial complexity and passes the deletion test.

The following rejected surfaces are implementation detail, not public abstraction:

- Generic `HistoryCommand` / `HistoryQuery` protocols.
- A `family` tag followed by runtime downcasts.
- Public Transition protocols.
- Public `HistoryWorkingSet`, `ScanCompleteness`, `AppliedTransition`, or `CandidateRank`.
- A public ChangeFeed or durable cursor when v1 has no journal.
- Repository or ModelContext ports mirroring SwiftData one method at a time.

### 4. Dependency classification and adapters

| Dependency | Category | Strategy |
|---|---|---|
| SwiftData | Local-substitutable | Production and tests use the same `SwiftDataHistory`; tests select an in-memory `ModelContainer`. There is no second fake writer implementation. |
| NSPasteboard/AppKit | Framework | `PasteboardAdapter` translates framework values to raw `HistoryCore` capture values and paste payloads back to AppKit. |
| SwiftUI | Framework | Confined to `PresentationUI`; views receive value snapshots and an injected `any ClipboardHistory`. |
| ImageIO | Framework | Confined to two concrete behavior owners: `HistoryStorage` produces version-fenced encoded thumbnails; `ContentPreview` eagerly materializes transient display rasters and full-pane preview artifacts. Neither exposes ImageIO/CoreGraphics objects across its actor/module seam, and there is no hypothetical public decoder port. |
| Security / Data Protection Keychain | True external | The internal `HistoryStorage` `CredentialStore` actor owns only the exact F1 server credential. Production uses `SecRandomCopyBytes` and app-private Data Protection Keychain operations; deterministic correctness tests inject a narrow operations adapter. Client custody, enrollment coordination, and signed/profile evidence remain separate. |
| xxh3 | In-process C dependency | Internal fingerprint function; a package-only deterministic collision double is permitted in Domain/Storage tests. |
| Fuse 1.4.x | Local library | Confined to `SearchWorker` for the specified fuzzy mode; its matcher remains inside actor isolation. The scaffold pins an exact resolved revision and fixtures lock behavior. |
| Clock and ID source | In-process injected dependencies | Package-only dependencies used to make planning and receipts deterministic in tests. They are not public application services. |
| Search evaluator | In-process | Pure work over a `SearchCorpusSnapshot`, executed on the `SearchWorker` actor (§6); not a persistence adapter. |
| Preview/scripted History | Alternate caller adapter | A small `ClipboardHistory` implementation is allowed for SwiftUI previews. It must not be used as a substitute for storage semantic tests. |

There are two real implementations of the public seam for different purposes: `SwiftDataHistory` for the application and a scripted preview adapter for UI preview construction. Persistence behavior tests always use `SwiftDataHistory` with an in-memory store.

### 5. End-to-end flows

#### 5.1 Capture and Copy Coalescing

```text
NSPasteboard
  → PasteboardAdapter freezes raw typed bytes + source/concealment observation
  → ClipboardHistory.perform(.capture(ClipboardCapture))
  → IngestPreparationActor rejects whole private/concealed items, then validates, normalizes, fingerprints, projects
  → HistoryAuthority loads complete IngestFacts
  → HistoryDomain plans insert or recordCopy plus retention victims
  → Authority stamps versions and commits one SwiftData transaction
  → SignatureIndex update
  → internal HistoryInvalidation publication
  → HistoryReceipt
```

The adapter never constructs `CanonicalContent` and never calls xxh3. Preparation happens before the serialized commit interval. The Authority admits an insert only when candidate coverage is proven complete. Fingerprint candidates are always byte-confirmed.

If `CopyOriginObservation.lineageHint` names a retained item, the fact loader fetches that item directly by `HistoryItemID`; it does not require the hint to appear in a canonical-signature result. Exact equality with the hinted item's Effective Content is required before the hint can win.

`ClipyApp` owns a fixed one-active/one-replaceable-latest capture lane. A
capture transaction that returns
`.temporarilyUnavailable(.insufficientDiskSpace)` publishes that exact
content-free health episode and drops the value that was already pending;
replaying it immediately cannot establish that volume capacity recovered. A
later complete pasteboard observation is the explicit retry, and only a
successful capture admitted after the episode clears it. Other typed failures
keep the ordinary active/latest drain rule, while a success admitted before a
newer failure never clears that newer episode. The app does not retain rejected
clipboard bytes for automatic retry and does not claim that remove or clear
will reclaim physical disk capacity.

#### 5.2 Pin, reorder, remove, and clear

```text
PresentationUI gesture
  → perform(.placePinned / .unpin / .remove / .clear)
  → Authority loads the exact item or complete pinned/clear facts
  → Domain computes the complete final pin order or removal set
  → one atomic transaction
  → receipt and observed page refresh
```

Callers express pin placement as `.first`, `.last`, or `.before(anchorID)`. They cannot choose a numeric slot. Storage persists `pinOrdinal` only as an internal encoding of a complete ordered list. A reorder writes every changed ordinal in the same History Commit.

#### 5.3 Replace and revert

```text
HistoryDetails reference + local edit draft
  → perform(.revise(itemID, expected ContentVersion, intent))
  → preparation validates and normalizes the draft
  → Authority loads current RevisionFacts
  → OCC check
  → Domain derives proposed Effective Content
  → no-op if byte-identical; otherwise append a complete ContentRevision
  → project title/search from new Effective Content
  → advance ContentVersion and ChangePosition
  → one atomic transaction
```

A revert copies the chosen historical Effective Content into a newly minted revision. It never repoints `activeRevisionID` to an older revision and never mutates old bytes. Canonical Content remains unchanged.

#### 5.4 Browse and search

```text
PresentationUI
  → browse(request) or observe(request)
  → Authority captures ChangePosition + scalar rows from one serialized read
  → exact/fuzzy/regexp evaluation over scalar search projections
  → HistoryPage(position, rows, cursor)
```

List and search do not return `HistoryItemState` and do not decode Canonical or revision blobs. Search rank is internal search vocabulary; dedup `CandidateRank` never crosses the Domain boundary. v1 deliberately freezes three modes: exact, fuzzy, and regular expression.

#### 5.5 Observation

`observe` produces an authoritative first page followed by replacement pages after relevant History Commits. Internally it registers a process-local invalidation before its first query, so a commit between registration and query cannot be missed. Callers never coordinate “subscribe, then query” themselves and never apply event deltas to reconstruct state.

The internal invalidation is content-free, may coalesce to the newest `ChangePosition`, has no replay after restart, and is not a durable History Change Record (which v1 explicitly excludes).

#### 5.6 Paste

```text
PresentationUI selection
  → ClipyApp asks history.pastePayload(for:)
  → HistoryStorage resolves current Effective Content
  → ClipyApp passes PastePayload to PasteboardAdapter
  → PasteboardAdapter writes framework values + lineage hint
```

`ClipyApp`, not either adapter, owns the orchestration. This avoids an adapter-to-adapter dependency and keeps outbound paste side effects outside History.

#### 5.7 Thumbnail

The UI requests a thumbnail using `HistoryItemReference(id, contentVersion)` and pixel dimensions. `HistoryStorage` verifies that exact version before decoding and shares only identical concurrent work. A result is tagged with the same reference; a caller applies it only while its row still carries that reference.

`ThumbnailStore` continues to own surface-local exact-reference retention and
passes an already selected encoded PNG payload to `ContentPreview` only for
eager display materialization. This does not move thumbnail request, source,
version, single-flight, or cache policy into `ContentPreview`.

### 6. Isolation model

#### Main actor

- SwiftUI views, observable presentation state, selection, and window behavior.
- `ClipyApp` forwards every capture `HistoryReceipt` to `HistoryViewState` on
  the main actor. When the package-only `hasDestructiveRetentionEffects` fact
  is true, the view state publishes its existing whole-surface purge before
  observation catches up, while an already-observed page at an equal or newer
  `ChangePosition` is preserved.
- No SwiftData context, row, or model identity.
- No content fingerprinting, rich-text parsing, search scan, or image decode.
- Relative copy-time labels use the system abbreviated formatter. One
  list-owned wall-clock minute cadence supplies the same explicit `now` to
  every row; an item-relative threshold may lag by less than one minute.
  Individual rows do not own timers, and there is no global clock service.

#### Background isolation

- `ContentPreview` owns transient preview source selection and text/image
  rendering on its actor. Its eager raster is tight premultiplied BGRA8/sRGB
  bytes with checked dimensions and byte count; no `CGImage`, `CGImageSource`,
  or encoded source bytes are retained in observable UI state. One native
  raster slot preserves bounded decode concurrency; the actor awaits that
  off-actor work, so a newer exact-text render can complete while an older
  native rasterization is pending. Cancellation remains a publication fence
  and does not promise immediate native preemption.

All of the following are `actor` types; each is therefore `Sendable`, which is what makes `SwiftDataHistory: Sendable` derivable without `@unchecked Sendable`. `SwiftDataHistory` stores six of them as fields (Part V §2); `ThumbnailWorker` is owned and invoked by `ThumbnailService`, not stored directly.

- `HistoryAuthority`: sole mutation serializer, sole creator/user of writable `ModelContext`s, and the serialization point for snapshot capture and observer registration.
- `IngestPreparationActor`: raw representation validation, normalization, xxh3, and projection preparation.
- `RevisionPreparationActor`: resolves a public revision draft or revert into complete proposed Effective Content and projections off the commit interval.
- `SearchWorker`: pure search evaluation over a captured `Sendable` value snapshot. The Fuse matcher is a non-`Sendable` Swift 5 class, so it is created and held inside this actor and never crosses an isolation boundary.
- `ThumbnailService`: the thumbnail single-flight coordinator; owns the actor-confined flight table keyed by `(HistoryItemReference, PixelSize)`.
- `ThumbnailWorker`: bounded ImageIO decode/downsample invoked by `ThumbnailService`.
- `ExternalGateway`: the internal X.5 admission/rate coordinator; it owns no
  SwiftData value and delegates each durable authorization/audit to the sole
  `HistoryAuthority`. Its public connection-bound facade waits for X.6.

The `ModelContext(container)` used by `HistoryAuthority` is created manually — it is **not** the SwiftUI-environment context (which Apple documents as main-actor-bound). Off-main use of a manually created context is the documented SwiftData pattern (`@ModelActor` / `ConcurrencySupport`); v1 uses a plain `actor` with a fresh context per operation, and Swift 6 compilability of that choice is a Part VI §6 compile-and-dependency proof gate. Adopting SwiftData's `@ModelActor`/`ModelExecutor` model instead is an open implementation option the current design does not require; if adopted it would replace the manual-context rule in Part V §5 without changing the public surface.

#### Boundary rule

Only immutable `Sendable` values cross an actor boundary. No context, `@Model`, lazy relationship, `PersistentIdentifier`, AppKit object, `NSImage`, or `CGImage` crosses.

The Authority does not retain model objects between operations. Each isolated read or commit creates a context, performs synchronous fetch/plan/transaction work without suspension, extracts values, and releases the context. At most one writable context is active because only the Authority can create one and Authority operations are serialized.

### 7. Ordering and visibility guarantees

- Mutating calls linearize inside `HistoryAuthority`; concurrent call start order is not promised.
- Callers that require order must await one call before issuing the next.
- A committed receipt is returned only after the transaction, required in-memory index update, and invalidation publication complete.
- A subsequent read through the same `ClipboardHistory` whose invocation begins after that receipt must observe a `ChangePosition` greater than or equal to the receipt's position.
- A no-op returns `.unchanged`, creates no History Commit, advances no token, and publishes no invalidation.
- One History Commit may affect multiple rows—pin shifts, clear, or retention—but advances `ChangePosition` exactly once.

### 8. Forbidden dependencies and anti-goals

- `ClipboardFormats` may import Foundation only and must not own a purpose-specific behavior policy.
- `ContentPreview` may import only Foundation, ClipboardFormats, CoreGraphics,
  and ImageIO. It must not import HistoryCore/HistoryStorage, SwiftUI/AppKit,
  persistence, or adapters; PresentationUI must not import ImageIO.
- `ClipyCLIContract` may import Foundation only and must not own standard-stream
  I/O, transport, credential, Gateway, History, or product-CLI behavior.
- `ClipyUDSF0Shared` may import Foundation and Darwin only;
  `ClipyUDSF0Client` may additionally import AppKit solely for bounded
  LaunchServices/process observation. Neither may import `ClipyCLIContract`,
  History modules, SwiftData, AppIntents, or a product transport.
- `HistoryCore` must not import `HistoryDomain`, `HistoryStorage`, SwiftData, AppKit, SwiftUI, ImageIO, or xxh3.
- `HistoryDomain` must not import `HistoryStorage`, SwiftData, AppKit, SwiftUI, ImageIO, or xxh3.
- Adapters and UI must not import `HistoryDomain` or `HistoryStorage`.
- `HistoryStorage` must not import an adapter or `PresentationUI`.
- `Security` is confined to `HistoryStorage`'s internal F1 server-credential
  implementation; it must not enter `HistoryCore`, `HistoryDomain`, UI, or an
  adapter as a credential-sharing shortcut.
- No adapter may import another adapter.
- `AppIntents` is confined to `ClipyApp/Sources` and the explicitly hosted
  `ClipyIntegrationTests`; it must not enter any SwiftPM target.
- `ClipyUITests` is the XcodeGen-owned running-app tracer target. It may use
  XCTest/AppKit accessibility and General pasteboard only through a DEBUG
  launch envelope; it must not import product modules or construct a second
  History/composition/capture pump (REVIEW Card 15).
- The one registered App Intents dependency is the internal Sendable
  `AppIntentHistoryIngress`: it contains the connection-bound public Storage
  facade, delegates every read/write unchanged, and after only a positive
  external remove awaits both exact purge publication and synchronous apply on
  the one AppDelegate-owned `HistoryPanelSurfaceState` before returning. It
  owns no authorization, audit, model context, cache, or general event stream.
- No application-owned `.shared`, `.current`, or other mutable authoritative
  service locator. The sole framework-owned exception is exactly one
  `AppDependencyManager.shared.add(dependency:)` registration in
  `ClipyApp/Sources/AppIntents/AppIntentDependencyRegistration.swift`.
  Hosted tests inject a standalone `AppDependencyManager()`.
- No second writer, UI-bound `ModelContext`, or background context outside `HistoryAuthority`.
- No hidden behavior in model observers or lifecycle callbacks.
- No public protocol whose only implementation simply forwards to SwiftData.
- No `@unchecked Sendable` or `nonisolated(unsafe)` escape hatch in the greenfield targets.

### 9. Build-time gates

1. A single Swift package expresses exactly the target edges above and fails on a deliberate back-edge.
2. SwiftLint and portable source scans reject forbidden framework imports
   outside their owner targets, including attributed/access-level import
   spellings. They scan SwiftPM sources/tests plus `ClipyApp` sources, hosted
   tests, and diagnostic tools; confine `AppIntents`, reject service-locator declarations, and enforce
   the single framework-owned App Intents dependency registration above.
   The same gates keep `ContentPreview` on its four-module allowlist,
   PresentationUI free of ImageIO, `ClipyCLIContract` Foundation-only, and the
   F0 shared/client sources confined to their Foundation/Darwin/AppKit evidence
   boundary.
3. Swift 6 complete strict-concurrency compilation succeeds without unchecked escape hatches.
4. The public `HistoryCore` symbol surface is snapshot-tested so package-only Domain/Storage vocabulary cannot leak accidentally.
5. App-level tests construct `SwiftDataHistory` with an in-memory store; they do not replace the semantic write path.
6. XcodeGen deterministically produces the application project while the library graph remains SwiftPM-owned.
7. Portable dependency gates reject byte drift in the pinned vendored xxHash sources and prove that only Clipy's wrapper is a global C symbol; production-wrapper known-answer tests pin digest behavior on macOS arm64.

### 10. Platform facts versus design choices

- SwiftData context serialization is not a cross-context single-writer guarantee; the application supplies that guarantee by routing every write through `HistoryAuthority`.
- `ModelContext.transaction` is the v1 atomic write primitive. Closure success commits pending changes; the kernel does not call a second `save()` afterward.
- `registeredModel(for:)` accepts a SwiftData `PersistentIdentifier`, not `HistoryItemID`, and therefore is not a business-ID lookup mechanism.
- The design does not depend on undocumented manual-refresh APIs or on a permanently resident context.
- `FetchDescriptor.propertiesToFetch` may be used to limit scalar reads. The
  scaffold must prove that browse/search do not decode content blobs before
  making a scalar-lane performance claim. Current hard-capped startup is a
  separate correctness path: it deliberately decodes Canonical to recompute
  authoritative Signature Index coverage, never revision state merely for the
  index, and any open-time performance claim must include that capped pass.
- `@Attribute(.externalStorage)` is a storage hint, not a correctness or memory guarantee.

Part V translates these facts into the Authority and schema design. Part VI owns the executable proofs.
