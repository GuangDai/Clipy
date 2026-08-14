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
/// a test arms it via @testable (no `#if DEBUG`). Each case is one-shot and
/// consumed only when its matching production guard is reached. The WS13
/// case preserves its exact interleaving — row mutation applied, singleton
/// position not yet written — while the guard-specific cases alter only a
/// local decision value, never durable fixture state. Every injected guard
/// failure therefore traverses the real transaction catch and commits nothing
/// (§10: "Closure failure commits nothing. There is no receipt, index delta,
/// or invalidation").
internal enum InjectedTransactionFailure: Error, Sendable, Equatable {
    /// Throw after all row mutations and the final pin-order revalidation,
    /// immediately before the singleton position update (WS13).
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

    /// Constructs the Authority over an already-opened v1 container.
    /// docs/05-authority-kernel.md §2, §13
    ///
    /// `SwiftDataHistory.open` owns §13 steps 1–2 (configuration validation
    /// and container creation); this Authority then owns the store-side
    /// startup steps 3–9 via `performStartup(initialMaximumUnpinnedItems:)`.
    /// The Signature Index starts unready (§12) and the test seams disarmed.
    internal init(container: ModelContainer, limits: HistoryLimits = .standard) {
        self.container = container
        self.limits = limits
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
    /// new store (step 3), validate exactly one singleton (step 4), validate
    /// the retained row count against the hard bound (step 5), fetch each
    /// row's scalar and signature metadata without decoding content blobs
    /// (step 6), require projection schema version 1 (step 7), decode and
    /// validate signatures and build the complete Signature Index (step 8),
    /// and validate the full pinned ordinal set from scalar fields (step 9).
    ///
    /// The initial retention value is revalidated against the fixed Part VI
    /// user range (§2) so the singleton is never written from an invalid
    /// value even when a test constructs the Authority directly.
    ///
    /// No suspension point is needed here: startup completes before the
    /// facade is published (§13 step 10), and the whole sequence is one
    /// non-suspending interval on an operation-local context (§5).
    ///
    /// - Throws: `.invalidInput(.invalidRetentionPolicy)` for an out-of-range
    ///   initial value; `.persistence(.openStore)` when the store cannot be
    ///   read or the singleton cannot be created (§2: store-open failures);
    ///   `.persistence(.corruptStoredValue)` for corrupt durable signature,
    ///   projection-version, Content Version, or pin-ordinal values;
    ///   `.persistence(.invariantViolation)` for a duplicate/absent
    ///   singleton, over-bound or duplicate rows, or a malformed pinned
    ///   order. Corrupt durable metadata fails open — v1 has no silent
    ///   repair path (§13).
    internal func performStartup(initialMaximumUnpinnedItems: Int) async throws {
        // §2, §13 step 1: the singleton must never carry an out-of-range
        // retention value (D19 requires the stored policy to permit at
        // least one unpinned item).
        guard limits.userMaximumUnpinnedRange.contains(initialMaximumUnpinnedItems) else {
            throw HistoryFailure.invalidInput(.invalidRetentionPolicy)
        }

        try autoreleasepool {
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
                initialMaximumUnpinnedItems: initialMaximumUnpinnedItems
            )

            // §13 steps 5–9: scalar scan, Signature Index build, pin-order proof.
            signatureIndex = try Self.buildSignatureIndexAtStartup(
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
        }
#if DEBUG
        storageLifecycleDebugProbe.record(phase: .startupAutoreleasePoolDrained)
#endif
    }

    /// §13 steps 3–4: create the singleton at position 0 for a new store,
    /// then require exactly one. docs/05-authority-kernel.md §13, §3.2
    ///
    /// The create is one `ModelContext.transaction` — closure success is the
    /// durable boundary, exactly as for a History Commit (§10), and no
    /// `save()` follows it. A store that cannot be read or written at this
    /// point fails open as `.persistence(.openStore)` (§2's startup failure
    /// vocabulary, which does not include `.transaction`); zero or
    /// duplicate singletons are `.persistence(.invariantViolation)`.
    internal static func ensurePositionSingleton(
        in context: ModelContext,
        initialMaximumUnpinnedItems: Int
    ) throws {
        let key = positionSingletonKey
        var descriptor = FetchDescriptor<LastChangePositionRow>(
            predicate: #Predicate { row in row.key == key }
        )
        descriptor.fetchLimit = 2
        let rows: [LastChangePositionRow]
        do {
            rows = try context.fetch(descriptor)
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }
        switch rows.count {
        case 0:
            // New store: the singleton starts at position 0 so empty stores
            // still support an authoritative `HistoryPage(position: 0)`
            // (§3.2), carrying the validated initial retention value (§2).
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
            // Existing store: its durable singleton value rules; the
            // configuration's initial value is ignored (§2).
            break
        default:
            throw HistoryFailure.persistence(.invariantViolation)
        }
    }

    /// §13 steps 5–9: one bounded scalar fetch over every retained row
    /// yields the startup proofs and the complete Signature Index, without
    /// decoding Canonical or revision blobs (§13). docs/05-authority-kernel.md
    /// §13, §12
    ///
    /// Checks, in fetch order: row count within the hard retained-item bound
    /// (step 5); unique business IDs; a nonzero Content Version (step 6, §4);
    /// projection schema version exactly the v1 value (step 7); signature
    /// blob decode plus complete index build (step 8); the full pinned
    /// ordinal set unique and exactly `0 ..< p` from scalar fields (step 9,
    /// D12). Corrupt metadata fails open (§13); a store that cannot be read
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
            // §13 step 6, §4: a valid (≥1) Content Version.
            _ = try mapCodecFailure {
                try RevisionStateBlobCodec.decodeContentVersion(row.contentVersionRaw)
            }
            // §13 step 7: the greenfield v1 schema requires the known
            // projection schema version. Reuse the same fail-closed validator
            // as every read path (§4).
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
            // §13 step 8: decode/validate signatures — never content bytes.
            let entries = try mapCodecFailure {
                try SignatureBlobCodec.decode(row.canonicalSignatureBlob, limits: limits)
            }
            signatures[itemID] = entries
        }
        // §13 step 9 (D12): unique and exactly 0 ..< p. Direct slot
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
