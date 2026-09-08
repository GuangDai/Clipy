/// SQLiteHistory — the production `ClipboardHistory` adapter: the public
/// facade over the six internal actors, owning closed action dispatch
/// (Part V §8), read forwarding and the subscribe-before-query observation
/// loop (Part V §14; Part IV §5), `open` startup (Part V §13), and public
/// failure translation (Part V §16).
/// Owning spec: docs/05-authority-kernel.md §2 (public concrete adapter and
/// internal actors); coherence: docs/04-coherence.md (Part IV); implementation
/// sequence: docs/roadmap/03-historystorage.md (steps 5–8).
///
/// `SQLiteHistory` is a value of six actor references plus the immutable,
/// `Sendable` App Intents connection identity accepted during startup and,
/// for a persistent store, the held cross-process StoreRoot lease
/// (`StoreRootLease`, REVIEW DATA-7). Its `Sendable`
/// conformance is fully derived from those fields, so no unsafe
/// conformance or other escape hatch appears here (Part V §2; Part VI §6).
import Foundation
import HistoryCore

#if DEBUG
/// Operation-local observation hook for deterministic outer-buffer tests.
/// Task-local inheritance reaches the producer `Task` without adding stored
/// state to the six-actor facade; Release builds contain no hook or branch.
internal enum ObservationDebugInstrumentation {
    /// Parks immediately before the cancellation fence that guards a public
    /// stream yield. Card 11B uses it to cancel a producer after search page
    /// construction without relying on a scheduler turn or wall-clock delay.
    @TaskLocal internal static var pageWillYield: (
        @Sendable (HistoryPage) async -> Void
    )? = nil
    @TaskLocal internal static var pageDidYield: (
        @Sendable (HistoryPage) async -> Void
    )? = nil
}
#endif

// MARK: - SQLiteHistory (docs/v2/V2-09-multilevel-storage.md §2)

/// The production `ClipboardHistory` adapter, backed by SQLite metadata and
/// immutable content files (V2-09 §2–§6).
///
/// Owning spec: docs/05-authority-kernel.md §2.
///
/// The facade holds exactly the six internal actors of the Part V §2
/// isolation tree — `HistoryAuthority` (sole writer and the serialization
/// point for snapshot capture and observer registration),
/// `IngestPreparationActor`, `RevisionPreparationActor`, `SearchWorker`, and
/// `ThumbnailService`, and the internal X.5/X.6 `ExternalGateway` — plus the
/// immutable App Intents connection identity. Every stored field is Sendable,
/// so the
/// `Sendable` conformance is derived without any escape hatch. The facade
/// translates no semantics of its own: it validates nothing the actors own,
/// dispatches actions through one closed switch (§8), forwards reads to the
/// purpose-specific read paths (§14) and owns the Part IV §5 observation
/// loop, and lets actor-thrown `HistoryFailure`s propagate.
public struct SQLiteHistory: ClipboardHistory, Sendable {
    /// Total candidate-ID mint attempts admitted for one capture, including
    /// the initial candidate. UUID collisions should be vanishingly rare in
    /// production; eight keeps a broken/injected source strictly bounded
    /// without widening the public limits or failure vocabulary (Card 2B-2).
    internal static let captureCandidateIDAttemptLimit = 8

    /// Sole writer; also serializes source snapshot capture and observer
    /// registration (docs/05-authority-kernel.md §2).
    ///
    /// The six actor fields are `internal`, not the Part V §2 snippet's
    /// `private`: the deterministic concurrency harness (WS12/WS15,
    /// docs/roadmap/03-historystorage.md step-5 note) installs suspension
    /// handlers on the facade's own Authority from `@testable` tests, which
    /// requires same-module visibility. Cross-module surface is unchanged —
    /// `internal` members of a public struct are not reachable outside the
    /// HistoryStorage module (docs/01-architecture.md §8), so the §2
    /// isolation contract is preserved (deviation recorded in
    /// docs/PROGRESS.md).
    internal let authority: HistoryAuthority

    /// Prepares raw captures outside the commit interval
    /// (docs/05-authority-kernel.md §6.1).
    internal let ingestPreparation: IngestPreparationActor

    /// Resolves revision drafts against a preparation snapshot outside the
    /// commit interval (docs/05-authority-kernel.md §6.2).
    internal let revisionPreparation: RevisionPreparationActor

    /// Evaluates bounded search batches on its own SQLite read connection.
    /// Only Sendable store locations and result values cross actors.
    internal let searchWorker: SearchWorker

    /// Search and Authority retain the same disposable directory lifetime;
    /// no database or statement handle is shared between them (V2-09 §4).
    private let storeLocation: HistoryStoreLocation

    /// Owns the thumbnail flight table and its worker
    /// (docs/05-authority-kernel.md §14.5; docs/04-coherence.md §9).
    internal let thumbnailService: ThumbnailService

    /// Owns process-local external admission/rate state and delegates every
    /// durable authorization and operation to `HistoryAuthority`. X.6's
    /// public connection-bound facade retains this actor reference.
    internal let externalGateway: ExternalGateway

    /// The exact durable App Intents identity accepted during startup. X.6
    /// copies it into the public connection-bound facade and never re-mints it.
    private let appIntentsConnectionID: ExternalConnectionID

    /// The cross-process single-writer lease held for a persistent store's
    /// whole facade lifetime (REVIEW DATA-7 / PLAY-DISK-0B); `nil` for the
    /// `.temporary` medium, which owns a private directory. The facade's last
    /// release closes the descriptor and with it the record lock.
    private let storeRootLease: StoreRootLease?

    /// Assembles the facade from its six actors and startup-validated external
    /// identity. Construction is internal to
    /// `open(configuration:)` — there is no other way to obtain a
    /// `SQLiteHistory` (docs/05-authority-kernel.md §2).
    private init(
        authority: HistoryAuthority,
        ingestPreparation: IngestPreparationActor,
        revisionPreparation: RevisionPreparationActor,
        searchWorker: SearchWorker,
        thumbnailService: ThumbnailService,
        externalGateway: ExternalGateway,
        appIntentsConnectionID: ExternalConnectionID,
        storeLocation: HistoryStoreLocation,
        storeRootLease: StoreRootLease?
    ) {
        self.authority = authority
        self.ingestPreparation = ingestPreparation
        self.revisionPreparation = revisionPreparation
        self.searchWorker = searchWorker
        self.thumbnailService = thumbnailService
        self.externalGateway = externalGateway
        self.appIntentsConnectionID = appIntentsConnectionID
        self.storeLocation = storeLocation
        self.storeRootLease = storeRootLease
    }

    // MARK: Open (docs/05-authority-kernel.md §2, §13)

    /// Opens (or creates) the store and returns the ready facade.
    ///
    /// Validates the initial retention setting, resolves the persistent or
    /// disposable directory, then lets Authority open its own SQLite
    /// connection and immutable blob store. Startup creates or reads the
    /// current metadata schema without loading all retained content. Gateway
    /// construction follows successful startup, sharing its clock and search
    /// worker with ordinary History calls (V2-09 §2/§4/§6).
    ///
    /// Failure translation at this boundary (§16, §2): an out-of-range
    /// initial retention value throws `.invalidInput(.invalidRetentionPolicy)`;
    /// a StoreRoot already leased by another live owner process throws
    /// `.persistence(.storeAlreadyOpen)` (DATA-7);
    /// a store that cannot be opened throws
    /// `.persistence(.openStore)`; startup corruption surfaced by the
    /// Authority propagates already typed as
    /// `.persistence(.corruptStoredValue)` or
    /// `.persistence(.invariantViolation)` — there is no silent repair path
    /// for corrupted data (§13).
    public static func open(
        configuration: HistoryConfiguration
    ) async throws -> SQLiteHistory {
        try await open(
            configuration: configuration,
            makeCandidateID: { HistoryItemID(rawValue: UUID()) }
        )
    }

    /// Package-owned deterministic capture-ID seam. Production always enters
    /// through the public overload above; storage semantic tests inject fixed
    /// candidates without exposing entropy configuration to callers
    /// (docs/01-architecture.md §4; Card 2B-2).
    internal static func open(
        configuration: HistoryConfiguration,
        limits: HistoryLimits = .standard,
        makeCandidateID: @escaping @Sendable () -> HistoryItemID
    ) async throws -> SQLiteHistory {
        // Nil explicitly disables count retention; resource limits remain fixed.
        guard configuration.initialMaximumUnpinnedItems.map(limits.userMaximumUnpinnedRange.contains) ?? true else {
            throw HistoryFailure.invalidInput(.invalidRetentionPolicy)
        }

        let storeLocation = try HistoryStoreLocation(persistence: configuration.persistence)
        // Persistent ownership is established before SQLite opens. Disposable
        // directories are unique and need no cross-process ownership lease.
        let storeRootLease: StoreRootLease?
        if case .persistent = configuration.persistence {
            storeRootLease = try StoreRootLease.acquire(storeURL: storeLocation.databaseURL)
        } else {
            storeRootLease = nil
        }

        // The same clock is used for History and externally requested work;
        // entropy and clock injection remain internal implementation details.
        let storageClock = SystemStorageClock()
        let searchWorker = SearchWorker()
        // Both media now use files. Construct a fresh URL per observation so
        // cached NSURL resource values cannot outlive an intervening write.
        let storePath = storeLocation.databaseURL.path
        let volumeAvailableCapacityReader: @Sendable () -> Int64? = {
            let freshURL = URL(fileURLWithPath: storePath)
            guard let values = try? freshURL.resourceValues(
                forKeys: [.volumeAvailableCapacityKey]
            ), let capacity = values.volumeAvailableCapacity else {
                return nil
            }
            return Int64(capacity)
        }
        let authority: HistoryAuthority
        let appIntentsConnectionID: ExternalConnectionID
        do {
            authority = try HistoryAuthority(
                storeLocation: storeLocation,
                limits: limits,
                storageClock: storageClock,
                volumeAvailableCapacityReader: volumeAvailableCapacityReader
            )
            appIntentsConnectionID = try await authority.performStartup(
                initialMaximumUnpinnedItems: configuration.initialMaximumUnpinnedItems
            )
        } catch let failure as HistoryFailure {
            // Already translated by the Authority (§16): corrupt stored
            // values and invariant violations reject open without repair (§13).
            throw failure
        } catch let failure as SQLiteFailure {
            throw failure.openFailure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }

        // No facade escapes until the History and Gateway state is ready.
        let revisionPreparation = RevisionPreparationActor()
        let externalGateway = ExternalGateway(
            authority: authority,
            appIntentsConnectionID: appIntentsConnectionID,
            searchWorker: searchWorker,
            storageClock: storageClock,
            revisionPreparation: revisionPreparation
        )
        let history = SQLiteHistory(
            authority: authority,
            ingestPreparation: IngestPreparationActor(
                makeCandidateID: makeCandidateID
            ),
            revisionPreparation: revisionPreparation,
            searchWorker: searchWorker,
            thumbnailService: ThumbnailService(),
            externalGateway: externalGateway,
            appIntentsConnectionID: appIntentsConnectionID,
            storeLocation: storeLocation,
            storeRootLease: storeRootLease
        )
        // Construction is complete before maintenance is scheduled. This
        // actor call only queues work; startup never walks blob directories.
        await authority.requestBlobCleanup()
        return history
    }

    /// Returns the External History entry bound to the startup-validated
    /// durable App Intents connection (`V2-05` §6.5; roadmap X.6).
    /// This synchronous no-argument accessor cannot select or mint an ID.
    public func makeAppIntentsHistoryFacade() -> ExternalHistoryFacade {
        ExternalHistoryFacade(
            gateway: externalGateway,
            connectionID: appIntentsConnectionID
        )
    }

    // MARK: Closed action dispatch (docs/05-authority-kernel.md §8)

    /// Performs one mutating History Action through the closed §8 switch:
    /// capture is prepared off the Authority and then committed by it, a
    /// revision uses the two-phase OCC-safe preparation (§6.2), and every
    /// other action is committed directly by the Authority. There is no
    /// generic existential, family tag, registry, visitor, or dynamic cast
    /// dispatch (§8).
    ///
    /// Actor-thrown failures propagate unchanged as typed `HistoryFailure`s
    /// (§16); every v1 action path is implemented as of roadmap step 6
    /// (docs/roadmap/03-historystorage.md), and the V2-02
    /// `.setRetentionPolicies` case is implemented by the R.6 policy sweep
    /// (`V2-02` §4.4; `V2-roadmap` §6).
    public func perform(_ action: HistoryAction) async throws -> HistoryReceipt {
        do {
            switch action {
            case .capture(let raw):
                var prepared = try await ingestPreparation.prepare(raw)
                var attempts = 1
                while true {
                    do {
                        return try await authority.commitCapture(prepared)
                    } catch is CaptureCandidateIDCollision {
                        guard attempts < Self.captureCandidateIDAttemptLimit else {
                            // No new public failure case is needed: an internal ID
                            // source unable to produce a valid business identity
                            // is a Storage invariant failure, and every collision
                            // was rejected before transaction/publish.
                            throw HistoryFailure.persistence(.invariantViolation)
                        }
                        attempts += 1
                        prepared = await ingestPreparation.remintCandidateID(
                            in: prepared
                        )
                    }
                }

            case .placePinned(let id, let placement):
                return try await authority.commitPinnedPlacement(id, placement)

            case .unpin(let id):
                return try await authority.commitUnpin(id)

            case .remove(let id):
                return try await authority.commitRemove(id)

            case .clear(let scope):
                return try await authority.commitClear(scope)

            case .revise(let request):
                // V2-02 §4.3 PHASE 1 (roadmap R.5): the Authority captures the
                // OCC snapshot AND the current revise-lane policies in one
                // serialized interval (Record 2's policy-sourcing mechanism),
                // then threads the policies as the sibling R3 input to the
                // V2-extended preparation call. A nil policy value (R1-only or
                // all-disabled config) leaves the preparation byte-for-byte v1.
                let inputs = try await authority.revisionPreparationInputs(request)
                let bundle = try await revisionPreparation.prepare(
                    request,
                    from: inputs.snapshot,
                    retentionPolicies: inputs.retentionPolicies
                )
                return try await authority.commitRevision(request, bundle)

            case .setRetentionPolicy(let maximum):
                return try await authority.commitRetentionPolicy(maximum)

            case .setRetentionPolicies(let policies):
                // V2-02 §8.1 case (roadmap R.6, policy sweep): the full R1/R2/R3
                // sweep — boundary validation, R3 prunes per exceeding item, the
                // projected R1/R2 pass, the survivor-scoped unsatisfiable-R3 veto,
                // and the same-value/satisfied `.unchanged` no-op — all inside
                // the Authority's one serialized commit interval (`V2-02` §4.4).
                return try await authority.commitRetentionPolicies(policies)
            }
        } catch {
            throw Self.translatedFailure(error)
        }
    }

    // MARK: Reads (docs/05-authority-kernel.md §14)

    /// One-shot browse (docs/05-authority-kernel.md §14.1–§14.2).
    ///
    /// A `.recent` page, including the recent-equivalent empty-search shape,
    /// is read entirely inside one Authority interval from scalar projection
    /// fields only (§14.1; 03b §8). A non-empty `.search` opens a consistent
    /// SQLite read transaction inside SearchWorker and scans bounded batches
    /// with a bounded result set (V2-09 §4). The process marker still binds
    /// every continuation cursor to this History instance (04 §6).
    public func browse(
        _ request: HistoryBrowseRequest
    ) async throws -> HistoryPage {
        do {
            switch request.kind {
            case .recent:
                return try await authority.recentPage(
                    limit: request.limit,
                    cursor: request.cursor,
                    filter: request.filter
                )
            case .search(let text, _) where text.isEmpty:
                return try await authority.recentPage(
                    limit: request.limit,
                    cursor: request.cursor,
                    filter: request.filter
                )
            case .search:
                return try await searchWorker.page(
                    request,
                    store: storeLocation,
                    processMarker: authority.cursorProcessMarker
                )
            }
        } catch {
            throw Self.translatedFailure(error)
        }
    }

    /// Observes the current first page for one query
    /// (docs/05-authority-kernel.md §14.4; docs/04-coherence.md §5).
    ///
    /// The facade owns the Part IV §5 subscribe-before-query algorithm: the
    /// invalidation continuation is registered with the Authority BEFORE any
    /// query (§5 step 1); the first page is yielded only after the
    /// race-closing recheck shows the durable position still equals the
    /// page's (§5 steps 2–5); and each later invalidation newer than the
    /// last yielded page produces exactly one replacement page, with the
    /// subscriber's `.bufferingNewest(1)` buffer coalescing bursts (§5 steps
    /// 6–8; §4). The public stream independently keeps only its newest page:
    /// snapshots are replaceable state, so a paused consumer resumes at the
    /// latest page rather than replaying superseded pages. The loop also owns
    /// the search evaluation: a `.search` observation runs its `SearchWorker`
    /// evaluation as a plain await inside the producer task (§14.4), so
    /// cancelling the producer abandons the in-flight evaluation with it.
    ///
    /// Cancellation unregisters the continuation and releases query/search
    /// tasks (§5): terminating the stream cancels the producer task and hops
    /// an idempotent unregistration onto the Authority (§14.4 — the
    /// publisher's own termination hop then repeats the removal as a
    /// no-op). Any query failure finishes the stream with that error (§5:
    /// "until cancellation or failure"). An observation created after
    /// restart gets current state as its first page; it does not replay past
    /// commits (§5).
    public func observe(
        _ request: HistoryObservationRequest
    ) async -> AsyncThrowingStream<HistoryPage, Error> {
        // §5 step 1: register the invalidation continuation BEFORE any
        // query. Registration is a synchronous Authority operation (§14.4),
        // so the await orders it strictly before the producer task's first
        // authoritative read; a commit landing between registration and
        // that read is already recorded in the subscriber's newest-value
        // buffer (§4), which the phase-1 recheck below detects through the
        // durable position rather than by peeking the buffer. The local
        // `authority` binding keeps the termination hop capturing only the
        // actor; the producer Task separately captures this immutable,
        // Sendable facade through `firstPage(for:)`.
        let registration = await authority.registerInvalidationSubscriber()
        let authority = self.authority
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    // §5 steps 2–4: query and recheck before publication.
                    // The same freshness rule applies to replacement search
                    // pages when a commit lands during evaluation (04 §7).
                    var page = try await firstPage(for: request)
                    // §5 step 5.
#if DEBUG
                    await ObservationDebugInstrumentation.pageWillYield?(page)
#endif
                    try Task.checkCancellation()
                    continuation.yield(page)
#if DEBUG
                    await ObservationDebugInstrumentation.pageDidYield?(page)
#endif

                    // §5 steps 6–8: an invalidation at or behind the last
                    // yielded page is a buffered wake-up the page already
                    // covers (bufferingNewest(1) has also coalesced any
                    // burst); a newer one produces ONE replacement page.
                    // Recheck that page too: a later commit can supersede
                    // its snapshot while SearchWorker evaluates off-actor.
                    for try await invalidation in registration.stream {
                        guard invalidation.latestPosition > page.position else {
                            continue
                        }
                        page = try await firstPage(for: request)
#if DEBUG
                        await ObservationDebugInstrumentation.pageWillYield?(page)
#endif
                        try Task.checkCancellation()
                        continuation.yield(page)
#if DEBUG
                        await ObservationDebugInstrumentation.pageDidYield?(page)
#endif
                    }
                    // The publisher finished the registration stream
                    // (Authority teardown, §14.4): end normally.
                    continuation.finish()
                } catch {
                    // §5: the loop repeats until cancellation or failure —
                    // any query failure finishes the stream with that error.
                    continuation.finish(throwing: Self.translatedFailure(error))
                }
            }
            // §5: "Cancellation unregisters the continuation and releases
            // query/search tasks." Cancelling the producer ends its
            // iteration (and abandons any in-flight SearchWorker
            // evaluation — a plain await inside the producer, §14.4); the
            // one-shot hop unregisters the token, which the publisher's own
            // termination hop then repeats as a no-op (§14.4: "Cancellation
            // removes the token"; removal is idempotent).
            continuation.onTermination = { _ in
                task.cancel()
                _ = Task {
                    await authority.unregisterInvalidationSubscriber(
                        registration.subscription
                    )
                }
            }
        }
    }

    /// Metadata-only detail for one retained item (V2-09 §5). Payloads remain
    /// unopened until an explicit representation, paste or thumbnail request.
    public func details(
        for id: HistoryItemID
    ) async throws -> HistoryDetails {
        do {
            return try await authority.details(for: id)
        } catch {
            throw Self.translatedFailure(error)
        }
    }

    public func representation(
        _ request: HistoryRepresentationRequest
    ) async throws -> HistoryRepresentation {
        do {
            return try await authority.representation(request)
        } catch {
            throw Self.translatedFailure(error)
        }
    }

    /// The paste payload for one retained item
    /// (docs/05-authority-kernel.md §14.3): the Authority fetches exactly one
    /// row and maps its current Effective Content plus the current reference
    /// and lineage hint.
    public func pastePayload(
        for id: HistoryItemID
    ) async throws -> PastePayload {
        do {
            return try await authority.pastePayload(for: id)
        } catch {
            throw Self.translatedFailure(error)
        }
    }

    /// One authoritative snapshot of retained counts and logical content
    /// bytes. The Authority owns aggregation and snapshot coherence.
    public func usage() async throws -> HistoryUsage {
        do {
            return try await authority.usage()
        } catch {
            throw Self.translatedFailure(error)
        }
    }

    public func backup(to directory: URL) async throws -> HistoryBackupReceipt {
        try await authority.backup(to: directory)
    }

    /// The authoritative configured retention state (docs/v2/V2-07-ux.md
    /// §5.2/§6.3 — the settings panel-open read; audit SPEC-IMPL-003): the
    /// Authority reads both durable singletons inside one serialized,
    /// non-suspending interval — the v1 count from the position singleton
    /// (§3.2) and the V2-02 dimensions through the shared config→policy
    /// loader (`V2-02` §3.3). Retained counts and content bytes are read
    /// separately through `usage()`.
    public func retentionConfiguration() async throws -> HistoryRetentionConfiguration {
        do {
            return try await authority.retentionConfiguration()
        } catch {
            throw Self.translatedFailure(error)
        }
    }

    /// An encoded thumbnail for one item at one Effective Content state,
    /// sized to `pixels`; `nil` when the item has no thumbnailable content
    /// (docs/05-authority-kernel.md §14.5; docs/04-coherence.md §9).
    ///
    /// The facade supplies production Authority operations to the §9 deep
    /// module. `ThumbnailService` first joins or installs an exact-key
    /// source-to-decode task. Its creator performs the complete source/version
    /// fence and then decodes off the Authority; an existing-flight caller
    /// performs only a scalar dimension/existence/version fence before sharing
    /// that task. Thus concurrent identical requests hydrate one bounded image
    /// source, no database handle crosses an actor boundary, and completed
    /// bytes are not retained (docs/04-coherence.md §9).
    public func thumbnail(
        for item: HistoryItemReference,
        pixels: PixelSize
    ) async throws -> ThumbnailPayload? {
        do {
            let authority = authority
            return try await thumbnailService.thumbnail(
                for: item,
                pixels: pixels,
                loadSource: {
                    let selection = try await authority.thumbnailSource(
                        for: item,
                        pixels: pixels
                    )
                    return selection?.bytes
                },
                validateJoin: {
                    try await authority.validateThumbnailFlightJoin(
                        for: item,
                        pixels: pixels
                    )
                }
            )
        } catch {
            throw Self.translatedFailure(error)
        }
    }

    /// Translate only the internal SQL error. Domain, History, cancellation
    /// and decoding failures keep the semantics chosen by their owning code.
    private static func translatedFailure(_ error: any Error) -> any Error {
        if let failure = error as? SQLiteFailure { return failure.historyFailure }
        return error
    }

    // MARK: Observation first page (docs/04-coherence.md §5)

    /// The fresh first-page query of `observe`'s subscribe-before-query loop — a
    /// cursorless `browse` for the observation's query shape; observation
    /// intentionally has no cursor (docs/03a-instruction-set.md §7). The
    /// loop reuses it for the phase-1 recheck requeries and for every
    /// phase-2 replacement page (docs/04-coherence.md §5). Empty search uses
    /// the same scalar recent path as one-shot browse (03b §8). Every page,
    /// including a replacement, rechecks its source position after off-actor
    /// search evaluation so superseded results are discarded before yield
    /// (04 §7). As in initial observation, an uninterrupted write stream may
    /// delay publication; cancellation exits between reads (04 §5).
    private func firstPage(
        for request: HistoryObservationRequest
    ) async throws -> HistoryPage {
        let browseRequest = HistoryBrowseRequest(kind: request.kind, limit: request.limit, filter: request.filter)
        while true {
            try Task.checkCancellation()
            let page = try await browse(browseRequest)
            try Task.checkCancellation()
            if try await authority.currentPosition() == page.position {
                return page
            }
        }
    }
}
