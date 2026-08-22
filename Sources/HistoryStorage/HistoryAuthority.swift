/// HistoryAuthority — the sole writer and serialization point of
/// `SwiftDataHistory`: open/startup (§13), the capture commit path
/// (§7.1/§9–§11), context confinement (§5), and the roadmap-owned
/// deterministic-test seams (transaction-failure injection and suspension
/// points).
/// Owning spec: docs/05-authority-kernel.md §2 (role — "the sole writer ...
/// serialization point for source snapshot capture and observer
/// registration"), §5 (context confinement), §7.1 (capture fact loading, via
/// `IngestFactLoader`), §9 (from Domain plan to stamped commit plan), §10
/// (atomic transaction), §11 (post-commit order), §12–§13 (Signature Index
/// lifecycle and startup), §16 (failure translation); coherence:
/// docs/04-coherence.md §1 (commit/snapshot contract) and §4 (internal
/// invalidation); test seams: docs/roadmap/03-historystorage.md step 5 and
/// docs/06-cross-cutting.md §8 (WS13).
///
/// Confinement rules honored here (§5; docs/06-cross-cutting.md §6):
///
/// - a fresh `ModelContext(container)` is created per isolated operation and
///   never crosses an actor boundary;
/// - startup, public capture, and recent-browse context intervals are bounded
///   by operation-local autorelease pools so SwiftData/CoreData backing
///   references drain before the next Authority operation begins;
/// - no `await` occurs while a commit context, fetched row, complete fact,
///   or commit plan is live (the one `await` in `commitCapture` is the test
///   suspension point at entry, before the context exists);
/// - no `@Model` instance, `ModelContext`, or `PersistentIdentifier` is
///   stored across operations or escapes — only immutable Sendable values;
/// - no unsafe Sendable conformances, no unsafe nonisolated state, no
///   service locator (docs/06-cross-cutting.md §6).
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData

// MARK: - Storage invariant (docs/05-authority-kernel.md §10)

/// The storage-invariant guard vocabulary of the §10 transaction closure.
/// docs/05-authority-kernel.md §10
///
/// Any case escaping the transaction closure maps to
/// `.persistence(.transaction)` at the boundary (§16: "a
/// `ModelContext.transaction` closure failure (including the
/// `StorageInvariant.positionChanged` guard)").
internal enum StorageInvariant: Error {
    /// The singleton position read at fact-load time no longer matches the
    /// durable one inside the transaction (§10).
    case positionChanged
}

// MARK: - Transaction executor rejection (docs/05-authority-kernel.md §10)

/// Divergence detected by the transaction executor while applying a stamped
/// plan. docs/05-authority-kernel.md §10
///
/// The single-writer rule makes every case unreachable through public
/// behavior — facts are loaded in the same serialized interval the
/// transaction closes — so these are defensive guards, and any case escaping
/// the closure maps uniformly to `.persistence(.transaction)` (§16).
internal enum TransactionApplyRejection: Error {
    /// A mutation referenced a row the store does not contain (§10: "Every
    /// referenced row must exist exactly once unless the stamped case is
    /// create").
    case missingRow(itemID: HistoryItemID)

    /// A `.create` mutation named an ID that already has a row (§10: "Create
    /// IDs ... are checked for uniqueness").
    case duplicateCreateID(itemID: HistoryItemID)

    /// An `.appendRevision` mutation found a row Content Version differing
    /// from the stamped `expectedCurrentVersion` (§9, §10: revision state,
    /// Content Version, and effective projections are written together).
    case contentVersionMismatch(itemID: HistoryItemID)

    /// The final pinned ordinal set was not unique and exactly `0 ..< p`
    /// (§10: "Final pin order is revalidated before closure success"; D12).
    case finalPinOrderViolated
}

/// How a `.create` mutation proves its business ID is absent before insert.
/// Public behavior always performs the bounded durable lookup required by
/// Part V §10. The package-only disposable-fixture path may reuse the
/// Authority's already-complete ready Signature Index after additionally
/// proving its whole plan contains creates and matching additions only.
internal enum CreateExistenceProof: Sendable {
    case durableLookup
    case readySignatureIndex
}

// MARK: - Roadmap-owned deterministic-test seams (docs/roadmap/03-historystorage.md step 5)

/// Named suspension points of `HistoryAuthority` for the deterministic
/// concurrency harness (`SuspensionGate` in HistoryStorageTests).
/// docs/roadmap/03-historystorage.md step-5 note (concurrency harness);
/// harness contract: Tests/HistoryStorageTests/ConcurrencyHarness.
///
/// Test seam, compiled in always and harmless in production: the handler is
/// `nil` unless a test installs one via @testable, so every point is a no-op
/// outside the harness (no `#if DEBUG`). Every point is placed where an
/// `await` is legal — never inside a commit/read interval (§5). The WS12
/// registration/query seams landed at step 7; the WS15 step-8 seam is the
/// only pending one.
internal enum AuthoritySuspensionPoint: String, Sendable {
    /// On capture-commit entry, before the operation-local `ModelContext` is
    /// created — the last legal suspension before the non-suspending commit
    /// interval begins (docs/05-authority-kernel.md §5).
    case captureCommitEntry = "HistoryAuthority.commitCapture.entry"

    /// On revision-commit entry, before the operation-local `ModelContext` is
    /// created — the last legal suspension before the non-suspending commit
    /// interval begins (docs/05-authority-kernel.md §5); the WS20 two-phase
    /// revision seam (docs/06-cross-cutting.md §8).
    case revisionCommitEntry = "HistoryAuthority.commitRevision.entry"

    /// On read-path entry (recent browse or search corpus capture), before
    /// the operation-local `ModelContext` is created — the WS12 seam that
    /// parks the Authority between observer registration and the first
    /// authoritative query (docs/06-cross-cutting.md §8; docs/04-coherence.md
    /// §5).
    case readEntry = "HistoryAuthority.read.entry"

    /// On `currentPosition` entry, before the operation-local `ModelContext`
    /// is created — the WS12 discard-path seam the observe loop's phase-1
    /// race-closing recheck drives (docs/06-cross-cutting.md §8;
    /// docs/04-coherence.md §5).
    case positionRecheckEntry = "HistoryAuthority.currentPosition.entry"
}

/// The failure a test can inject inside the transaction closure.
/// docs/roadmap/03-historystorage.md step-5 note (transaction-injection
/// seam); WS13: docs/06-cross-cutting.md §8.
///
/// Test seam, compiled in always and harmless in production: disarmed unless
/// a test arms it via @testable (no `#if DEBUG`). Each case is one-shot. The
/// The two HCR boundary cases preserve the exact pre-/post-append
/// interleavings after row mutation while the singleton position is still
/// unchanged. The guard-specific cases alter only a local decision value,
/// never durable fixture state.
/// Every injected failure traverses the real transaction catch and commits nothing
/// (§10: "Closure failure commits nothing. There is no receipt, index delta,
/// or invalidation").
internal enum InjectedTransactionFailure: Error, Sendable, Equatable {
    /// Throw after all row mutations and final pin-order revalidation but
    /// before the plan's HCR append (X-HCR.2 / WS-J1-5 window a).
    case beforeHCRAppend

    /// Throw after the plan's HCR append, immediately before the singleton
    /// position update (WS13 / WS-J1-5 window b).
    case beforeSingletonUpdate

    /// Make the real §10 singleton-position guard observe a mismatch.
    case positionChanged

    /// Make the real non-create row-existence guard observe no row.
    case missingRow

    /// Make the real create-ID uniqueness guard observe a duplicate.
    case duplicateCreateID

    /// Make the real append-revision OCC guard observe a version mismatch.
    case contentVersionMismatch

    /// Add one impossible ordinal to the validator's local scalar snapshot so
    /// its real D12 contiguity guard rejects the transaction.
    case finalPinOrderViolated

    /// Throw a Cocoa out-of-space error after row mutation and before the
    /// singleton update so the production transaction catch and rollback are
    /// exercised.
    case insufficientDiskSpace
}

// MARK: - HistoryAuthority (docs/05-authority-kernel.md §2, §5)

/// The sole writer of the History store and the serialization point for
/// source snapshot capture and observer registration.
/// docs/05-authority-kernel.md §2
///
/// Isolation and confinement (§5): every read or commit creates an
/// operation-local `ModelContext` from the owned `ModelContainer`, disables
/// autosave, synchronously fetches/decodes/plans/transacts/extracts value
/// snapshots, and retains no row or context after returning. There is no
/// `await` while a commit context, fetched row, complete fact, or commit
/// plan is live, and at most one Authority operation uses a context at a
/// time — the actor is the single-writer rule made executable.
///
/// Owned value state (§2, §12): the `ModelContainer`, the fixed
/// `HistoryLimits.standard` safety profile, the `SignatureIndex` value
/// (actor-owned value state, never a second persistence authority), the
/// process-local `HistoryInvalidationPublisher`, and the disarmed test
/// seams. It stores no `@Model` instance or `ModelContext` across
/// operations (§2).
internal actor HistoryAuthority {
    /// The owned container every operation-local context derives from (§5).
    internal let container: ModelContainer

    /// The fixed Part VI safety profile (docs/06-cross-cutting.md §2);
    /// `SwiftDataHistory.open` always uses `.standard` (§2).
    internal let limits: HistoryLimits

    /// The actor-owned Signature Index value (§12). `init()` (unready) at
    /// construction; `performStartup` replaces it with the §13 step-8 build;
    /// commits mutate it only through the prevalidated `apply(_:)` delta
    /// (§9, §11). Capture-time rebuilds replace it wholesale through
    /// `SignatureIndex.build`; the loader returns the rebuilt value.
    internal var signatureIndex: SignatureIndex

    /// The process-local invalidation signal (docs/04-coherence.md §4);
    /// registration, unregistration, and the post-commit `publish` are
    /// synchronous actor operations (§14.4).
    internal var invalidationPublisher: HistoryInvalidationPublisher

    /// The process-instance marker stamped into every cursor this Authority
    /// mints (docs/04-coherence.md §6). `PageCursorCodec.decode` rejects a
    /// marker minted by any other Authority/process and the caller maps the
    /// mismatch to `.snapshotExpired(current:)` (§16). A schema deployment
    /// necessarily starts a new process/Authority, so the random process
    /// marker also invalidates pre-deployment cursors without duplicating the
    /// durable schema version in this ephemeral token. Immutable for the
    /// Authority's lifetime.
    internal let processMarker = UUID()

    /// Test seam: the harness-installed suspension handler, `nil` in
    /// production (see `AuthoritySuspensionPoint`).
    internal var suspensionHandler: (@Sendable (AuthoritySuspensionPoint) async -> Void)?

    /// Test seam: the armed one-shot transaction failure, `nil` in
    /// production (see `InjectedTransactionFailure`).
    internal var injectedTransactionFailure: InjectedTransactionFailure?

    /// The Storage-side clock (V2-02 §6.4 / V2-05 §4.6), supplying the R1
    /// reference `now` for the `.setRetentionPolicies` sweep lane and the
    /// one-time App Intents connection enrollment timestamp. Injected at this
    /// INTERNAL initializer (production wires `SystemStorageClock` inside
    /// `SwiftDataHistory.open`; tests inject a fixed `Date` via
    /// `@testable`) and never exposed on the public `open` /
    /// `HistoryConfiguration` seam (§6.4 "Injection mechanism";
    /// `RET-COMPILE-1`). The sweep reads it once per commit inside the
    /// serialized Authority interval before fact load (§6.4); X.3 reads it
    /// only on the absent-config bootstrap path before the create transaction.
    internal let storageClock: any StorageClock

    /// Durable Gateway connection identity source (`V2-05` §4.1/§4.6).
    /// X.3 consumes it once for the bootstrapped App Intents identity; X.4
    /// consumes it once per admitted enrollment. It is internal initializer
    /// injection for deterministic tests only: production uses an explicit
    /// `{ UUID() }` closure, and neither public `HistoryConfiguration` nor a
    /// global locator can override it.
    internal let gatewayConnectionIDSource: @Sendable () -> UUID

#if DEBUG
    /// Opt-in aggregate search tracing. This field and every call site are
    /// absent from Release builds; tests may replace the environment-backed
    /// stderr probe with an in-memory sink.
    internal var searchDebugProbe = SearchDebugProbe.environmentConfigured()

    /// Opt-in storage lifecycle tracing. Fixed, privacy-safe phase events
    /// expose where a context-bound operation last made progress without
    /// retaining a logger, context, or row across Authority operations.
    internal var storageLifecycleDebugProbe = StorageLifecycleDebugProbe
        .environmentConfigured()
#endif

    /// The singleton row's well-known key (§3.2: always "retained-history").
    internal static let positionSingletonKey = "retained-history"

    /// Constructs the Authority over an already-opened current container.
    /// docs/05-authority-kernel.md §2, §13
    ///
    /// `SwiftDataHistory.open` owns §13 steps 1–2 (configuration validation
    /// and container creation); this Authority then owns the store-side
    /// current total-order startup steps 3–12 via
    /// `performStartup(initialMaximumUnpinnedItems:)` (extending the v1
    /// `05` §13 store-side steps 3–11).
    /// The Signature Index starts unready (§12) and the test seams disarmed.
    /// The `storageClock` parameter is the Storage-clock seam:
    /// internal to `HistoryStorage`, defaulted to the production
    /// `SystemStorageClock` witness so no existing construction site
    /// changes, and never carried on the public `open` signature. The
    /// `gatewayConnectionIDSource` is the Gateway connection-ID value seam;
    /// production defaults to an explicit `{ UUID() }` Sendable closure.
    internal init(
        container: ModelContainer,
        limits: HistoryLimits = .standard,
        storageClock: any StorageClock = SystemStorageClock(),
        gatewayConnectionIDSource: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.container = container
        self.limits = limits
        self.storageClock = storageClock
        self.gatewayConnectionIDSource = gatewayConnectionIDSource
        self.signatureIndex = SignatureIndex()
        self.invalidationPublisher = HistoryInvalidationPublisher()
        self.suspensionHandler = nil
        self.injectedTransactionFailure = nil
    }

    /// The process-instance marker for cursor minting (04 §6). The
    /// `SearchWorker` call path mints cursors off-actor; it receives this
    /// marker so the minted cursor binds this Authority's generation.
    internal var cursorProcessMarker: UUID { processMarker }

#if DEBUG
    /// Installs a Debug-only search probe without introducing a second
    /// persistence implementation or a global logger.
    internal func setSearchDebugProbe(_ probe: SearchDebugProbe) {
        searchDebugProbe = probe
    }

    /// Installs a Debug-only lifecycle probe for supported-platform tests and
    /// diagnostics. The probe is a Sendable value with a synchronous sink.
    internal func setStorageLifecycleDebugProbe(
        _ probe: StorageLifecycleDebugProbe
    ) {
        storageLifecycleDebugProbe = probe
    }
#endif

    // MARK: Startup (docs/05-authority-kernel.md §13)

    /// Performs the store-side §13 startup sequence inside one isolated
    /// interval: create the position/retention singleton at position 0 for a
    /// new store (step 3), validate exactly one singleton (step 4),
    /// bootstrap/validate the retention-expansion config singleton and the
    /// X.3 deny-by-default Gateway config/App Intents connection pair
    /// (`V2-roadmap` §5 total open order step 5, M1.3), then bootstrap/
    /// validate and age-compact the internal DC-25 X-HCR suffix before any
    /// projection/index work, validate the
    /// retained row count against the hard bound, first rebuild legacy
    /// projection rows from their validated content lineage, then require
    /// projection schema version 2 and enforce the
    /// `RetainedBytesRow` 1:1 correspondence both directions with
    /// `bytesSchemaVersion == 1` (the V2 half of `V2-roadmap` §5 step 11,
    /// `RET-PLATFORM-1b(a)`; live from roadmap R.3 — with the amended
    /// Record 5 missing-rows recovery re-run first, see
    /// `RetainedBytesStamping.validateOneToOneCorrespondence`), decode and
    /// decode Canonical/signatures, recompute authoritative signature
    /// coverage and build the complete Signature Index, and
    /// validate the full pinned ordinal set from scalar fields.
    ///
    /// The initial retention value is revalidated against the fixed Part VI
    /// user range (§2) so the singleton is never written from an invalid
    /// value even when a test constructs the Authority directly.
    ///
    /// No suspension point is needed here: startup completes before the
    /// facade is published (current roadmap step 13; v1 `05` §13 step 12),
    /// and the whole sequence is one
    /// non-suspending interval on an operation-local context (§5).
    ///
    /// - Throws: `.invalidInput(.invalidRetentionPolicy)` for an out-of-range
    ///   initial value; `.persistence(.openStore)` when the store cannot be
    ///   read or the singleton cannot be created (§2: store-open failures);
    ///   `.persistence(.corruptStoredValue)` for an out-of-range durable
    ///   position-singleton retention value, or corrupt durable signature,
    ///   projection-version, Content Version, pin-ordinal, or
    ///   retention-config values (unknown `configSchemaVersion` or a
    ///   non-finite `ageMaxSeconds`, `V2-02` §3.3 / DC-21);
    ///   `.persistence(.invariantViolation)` for a duplicate/absent
    ///   singleton, an out-of-range or contradictory retention-config
    ///   combination (`V2-02` §8.3), over-bound or duplicate rows, a
    ///   malformed pinned order, or a violated `RetainedBytesRow` 1:1
    ///   correspondence / `bytesSchemaVersion` fence after the Record 5
    ///   missing-rows recovery re-run (`V2-02` §3.3b). Corrupt durable
    ///   metadata fails open; the explicit legacy derived-projection rebuild
    ///   is not a general stored-data repair path (§13). A projection-rebuild
    ///   transaction failure is
    ///   `.persistence(.transaction)` under the uniform §16 boundary.
    @discardableResult
    internal func performStartup(
        initialMaximumUnpinnedItems: Int
    ) async throws -> ExternalConnectionID {
        // §2, §13 step 1: the singleton must never carry an out-of-range
        // retention value (D19 requires the stored policy to permit at
        // least one unpinned item).
        guard limits.userMaximumUnpinnedRange.contains(initialMaximumUnpinnedItems) else {
            throw HistoryFailure.invalidInput(.invalidRetentionPolicy)
        }

        let appIntentsConnectionID = try autoreleasepool {
            let context = ModelContext(container)
            context.autosaveEnabled = false
#if DEBUG
            let startupFetchClock = ContinuousClock()
            let startupFetchStart = startupFetchClock.now
            storageLifecycleDebugProbe.record(phase: .startupFetchBegin)
#endif

            // §13 steps 3–4: load-or-create the singleton; validate exactly one.
            try Self.ensurePositionSingleton(
                in: context,
                initialMaximumUnpinnedItems: initialMaximumUnpinnedItems,
                limits: limits
            )

            // V2-roadmap §5 total open order step 5 (M1.3): bootstrap/validate
            // the retention-expansion config singleton immediately AFTER the
            // v1 position singleton and before the retained-row scan —
            // absent → create all-disabled (a migrated store starts
            // v1-faithful); present → the fail-closed V2-02 §3.3 validation.
            try Self.ensureRetentionExpansionConfig(in: context)

            // V2-roadmap §10 X.3 / V2-05 §4.6: after the pre-existing
            // position/retention singletons, atomically bootstrap or
            // fail-closed validate the Gateway config + App Intents
            // connection before any facade can be published. X.3 admits no
            // grant or audit row; X.4 replaces that exact-zero audit rule
            // together with the first writer and complete validation.
            let appIntentsConnectionID = try ensureGatewayBootstrap(in: context)

            // DC-25 X-HCR open-order step 7: V4 migration has completed and
            // Gateway/Audit state is valid. Bootstrap or fail-closed validate
            // the internal journal suffix, then run its fixed startup prefix
            // compaction before projection/index construction or publication.
            try HCRBootstrap.ensureReady(
                in: context,
                now: storageClock.now(),
                historyLimits: limits
            )

            // §13 step 6 / §15: projection recipe v1 → v2 rebuild is an
            // Authority-owned, bounded, atomic startup operation. It finishes
            // before the Signature Index is declared ready or capture exists.
            try ContentProjectionRebuild.rebuildIfNeeded(
                in: context,
                limits: limits
            )

            // §13 steps 7–10: scalar scan, Signature Index build, pin-order proof.
            signatureIndex = try Self.buildSignatureIndexAtStartup(
                in: context,
                limits: limits
            )

            // V2-roadmap §5 total open order step 11 (roadmap R.3, live from
            // this slice per the step-11 sequencing note): after the scalar
            // scan, enforce the `RetainedBytesRow` 1:1 correspondence both
            // directions with `bytesSchemaVersion == 1`
            // (`RET-PLATFORM-1b(a)`). A fresh store holds vacuously (zero
            // items; rows arrive via the capture-insert stamping, V2-02
            // §3.3b). Amended Record 5 (interruption recovery): a
            // missing-rows-only divergence — the producible
            // interrupted-migration shape — first re-runs the idempotent
            // backfill once on this Authority-owned startup context (no new
            // writer); every remaining violation fails closed — never a
            // zero read (V2-02 §3.2).
            try RetainedBytesStamping.validateOneToOneCorrespondence(
                in: context,
                limits: limits
            )
#if DEBUG
            storageLifecycleDebugProbe.record(
                phase: .startupFetchComplete,
                elapsed: startupFetchStart.duration(to: startupFetchClock.now),
                rows: signatureIndex.itemCount
            )
#endif
            return appIntentsConnectionID
        }
#if DEBUG
        storageLifecycleDebugProbe.record(phase: .startupAutoreleasePoolDrained)
#endif
        return appIntentsConnectionID
    }

    /// §13 steps 3–4: create the singleton at position 0 only for the
    /// fresh-compatible empty V3 row shape, then require exactly one row
    /// carrying the well-known key. docs/05-authority-kernel.md §13, §3.2;
    /// deep review DATA-1 / Card 1A-1.
    ///
    /// The create is one `ModelContext.transaction` — closure success is the
    /// durable boundary, exactly as for a History Commit (§10), and no
    /// `save()` follows it. A store that cannot be read or written at this
    /// point fails open as `.persistence(.openStore)` (§2's startup failure
    /// vocabulary, which does not include `.transaction`). A missing row in
    /// any non-fresh shape, a wrong/extra key, or duplicate rows are
    /// `.persistence(.invariantViolation)`. The fetch is over the complete
    /// singleton table, not just the expected key, so a wrong-key row cannot
    /// be mistaken for absence and repaired. An existing row is decoded with
    /// the same §3.2 scalar validation used by reads and commits; startup
    /// never replaces its durable policy from the caller's initial value.
    internal static func ensurePositionSingleton(
        in context: ModelContext,
        initialMaximumUnpinnedItems: Int,
        limits: HistoryLimits
    ) throws {
        let key = positionSingletonKey
        var descriptor = FetchDescriptor<LastChangePositionRow>()
        descriptor.fetchLimit = 2
        let rows: [LastChangePositionRow]
        do {
            rows = try context.fetch(descriptor)
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }
        switch rows.count {
        case 0:
            // Absence authorizes a write only when every other V3 durable
            // table is empty. Any surviving history, retention, projection,
            // or Gateway fact proves damaged state, not a new store.
            guard try isFreshCompatiblePositionBootstrapShape(in: context) else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            // A fresh-compatible empty store starts at position 0 so empty
            // stores still support an authoritative
            // `HistoryPage(position: 0)` (§3.2), carrying the validated
            // initial retention value (§2).
            do {
                try context.transaction {
                    context.insert(LastChangePositionRow(
                        key: key,
                        rawValue: 0,
                        maximumUnpinnedItems: initialMaximumUnpinnedItems
                    ))
                }
            } catch {
                throw HistoryFailure.persistence(.openStore)
            }
        case 1:
            guard rows[0].key == key else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            // Existing store: its durable singleton value rules; the
            // configuration's initial value is ignored (§2), but startup
            // must validate the stored scalars before publishing the facade.
            _ = try Self.decodePositionRow(rows[0], limits: limits)
        default:
            throw HistoryFailure.persistence(.invariantViolation)
        }
    }

    /// The only currently distinguishable write authorization for an absent
    /// position singleton.
    /// Current `HistorySchemaV4` contains the history/retention siblings
    /// queried here plus the Gateway and HCR tables queried by their bounded
    /// absence classifiers; zero rows in every sibling table is the
    /// fresh-compatible shape. It is not causal proof: an existing V4 store
    /// stripped of every durable row is identical without provenance. This is
    /// intentionally not a generic repair classifier; any surviving durable
    /// fact makes missing authoritative position state unrecoverable.
    private static func isFreshCompatiblePositionBootstrapShape(
        in context: ModelContext
    ) throws -> Bool {
        do {
            let itemCount = try context.fetchCount(
                FetchDescriptor<HistoryItemRow>()
            )
            let configCount = try context.fetchCount(
                FetchDescriptor<RetentionExpansionConfigRow>()
            )
            let retainedBytesCount = try context.fetchCount(
                FetchDescriptor<RetainedBytesRow>()
            )
            guard itemCount == 0,
                  configCount == 0,
                  retainedBytesCount == 0 else {
                return false
            }
            guard try gatewayTablesAreEmpty(in: context) else { return false }
            return try HCRBootstrap.tablesAreEmpty(in: context)
        } catch let failure as HistoryFailure {
            throw failure
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }
    }

    /// §13 scan/index steps 7–10: one bounded fetch over every retained row
    /// yields the startup proofs and the complete Signature Index. In the
    /// current hard-capped profile it decodes Canonical together with
    /// signature metadata and recomputes xxh3 from every representation's
    /// bytes before publishing a ready index; revision blobs remain untouched
    /// (§12–§13, DATA-11). This O(N) hydration is capped-only and must not
    /// survive the `DEC-U-SCALE-STARTUP-INDEX` transition.
    ///
    /// Checks, in fetch order: row count within the hard retained-item bound;
    /// unique business IDs; a nonzero Content Version (§4); projection schema
    /// version exactly the current v2 value; Canonical/signature decode plus
    /// authoritative recomputed coverage and complete index build; and the
    /// full pinned ordinal set unique and exactly `0 ..< p` from scalar fields
    /// (D12). Corrupt metadata fails open (§13); a store that cannot be read
    /// fails as `.persistence(.openStore)` (§2).
    internal static func buildSignatureIndexAtStartup(
        in context: ModelContext,
        limits: HistoryLimits
    ) throws -> SignatureIndex {
        var descriptor = FetchDescriptor<HistoryItemRow>()
        descriptor.propertiesToFetch = [
            \.id,
            \.contentVersionRaw,
            \.projectionSchemaVersion,
            \.pinOrdinal,
            \.canonicalBlob,
            \.canonicalSignatureBlob,
        ]
        descriptor.fetchLimit = limits.hardMaximumRetainedItems + 1
        let rows: [HistoryItemRow]
        do {
            rows = try context.fetch(descriptor)
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }
        // §13 step 5: the retained count never exceeds the hard bound.
        guard rows.count <= limits.hardMaximumRetainedItems else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        var seen = Set<HistoryItemID>(minimumCapacity: rows.count)
        var signatures: [HistoryItemID: [ContentSignatureEntry]] = [:]
        signatures.reserveCapacity(rows.count)
        var pinnedOrdinals: [Int] = []
        for row in rows {
            let itemID = HistoryItemID(rawValue: row.id)
            guard seen.insert(itemID).inserted else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            // §13 step 7, §4: a valid (≥1) Content Version.
            _ = try mapCodecFailure {
                try RevisionStateBlobCodec.decodeContentVersion(row.contentVersionRaw)
            }
            // §13 step 8: startup rebuild has already upgraded every legacy
            // row, so only the current projection version is valid here.
            // Reuse the same fail-closed validator as every read path (§4).
            let projectionSchemaVersion = row.projectionSchemaVersion
            try mapCodecFailure {
                try ContentProjector.validateStoredSchemaVersion(
                    projectionSchemaVersion
                )
            }
            let pinOrdinal = try mapCodecFailure {
                try RevisionStateBlobCodec.decodePinOrdinal(row.pinOrdinal)
            }
            if let pinOrdinal {
                pinnedOrdinals.append(pinOrdinal.rawValue)
            }
            // §13 step 9, DATA-11: the current hard-capped ready index may
            // provide negative dedup evidence only after Canonical bytes are
            // decoded and their xxh3 values recomputed. Revision bytes remain
            // untouched. This complete hydration must not survive U-scale.
            let entries = try mapCodecFailure {
                try SignatureBlobCodec.decodeAuthoritativeEntries(
                    canonicalBlob: row.canonicalBlob,
                    signatureBlob: row.canonicalSignatureBlob,
                    limits: limits
                )
            }
            signatures[itemID] = entries
        }
        // §13 step 10 (D12): unique and exactly 0 ..< p. Direct slot
        // placement proves the permutation in O(P), without sorting.
        guard PinnedOrderValidator.sourceOffsetsByOrdinal(
            in: pinnedOrdinals,
            ordinal: { $0 }
        ) != nil else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        do {
            return try SignatureIndex.build(from: signatures, limits: limits)
        } catch let rejection as SignatureIndexRejection {
            throw rejection.startupFailure
        }
    }

}
