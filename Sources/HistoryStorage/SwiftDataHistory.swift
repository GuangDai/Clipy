/// SwiftDataHistory — the production `ClipboardHistory` adapter: the public
/// facade over the five internal actors, owning closed action dispatch
/// (Part V §8), read forwarding and the subscribe-before-query observation
/// loop (Part V §14; Part IV §5), `open` startup (Part V §13), and public
/// failure translation (Part V §16).
/// Owning spec: docs/05-authority-kernel.md §2 (public concrete adapter and
/// internal actors); coherence: docs/04-coherence.md (Part IV); implementation
/// sequence: docs/roadmap/03-historystorage.md (steps 5–8).
///
/// `SwiftDataHistory` is a value of five `actor` references and nothing else:
/// the `Sendable` conformance is fully derived from the fields, so no unsafe
/// conformance or other escape hatch appears here (Part V §2; Part VI §6).
import Foundation
import HistoryCore
import SwiftData

#if DEBUG
/// Operation-local observation hook for deterministic outer-buffer tests.
/// Task-local inheritance reaches the producer `Task` without adding stored
/// state to the five-actor facade; Release builds contain no hook or branch.
internal enum ObservationDebugInstrumentation {
    @TaskLocal internal static var pageDidYield: (
        @Sendable (HistoryPage) async -> Void
    )? = nil
}
#endif

// MARK: - SwiftDataHistory (docs/05-authority-kernel.md §2)

/// The production `ClipboardHistory` adapter, backed by SwiftData.
///
/// Owning spec: docs/05-authority-kernel.md §2.
///
/// The facade holds exactly the five internal actors of the Part V §2
/// isolation tree — `HistoryAuthority` (sole writer and the serialization
/// point for snapshot capture and observer registration),
/// `IngestPreparationActor`, `RevisionPreparationActor`, `SearchWorker`, and
/// `ThumbnailService` — and every stored field is an `actor` type, so the
/// `Sendable` conformance is derived without any escape hatch. The facade
/// translates no semantics of its own: it validates nothing the actors own,
/// dispatches actions through one closed switch (§8), forwards reads to the
/// purpose-specific read paths (§14) and owns the Part IV §5 observation
/// loop, and lets actor-thrown `HistoryFailure`s propagate.
public struct SwiftDataHistory: ClipboardHistory, Sendable {
    /// Sole writer; also serializes source snapshot capture and observer
    /// registration (docs/05-authority-kernel.md §2).
    ///
    /// The five actor fields are `internal`, not the Part V §2 snippet's
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

    /// Evaluates search over a Sendable corpus snapshot off the Authority;
    /// never reads SwiftData (docs/05-authority-kernel.md §14.2).
    internal let searchWorker: SearchWorker

    /// Owns the thumbnail flight table and its worker
    /// (docs/05-authority-kernel.md §14.5; docs/04-coherence.md §9).
    internal let thumbnailService: ThumbnailService

    /// Assembles the facade from its five actors. Construction is internal to
    /// `open(configuration:)` — there is no other way to obtain a
    /// `SwiftDataHistory` (docs/05-authority-kernel.md §2).
    private init(
        authority: HistoryAuthority,
        ingestPreparation: IngestPreparationActor,
        revisionPreparation: RevisionPreparationActor,
        searchWorker: SearchWorker,
        thumbnailService: ThumbnailService
    ) {
        self.authority = authority
        self.ingestPreparation = ingestPreparation
        self.revisionPreparation = revisionPreparation
        self.searchWorker = searchWorker
        self.thumbnailService = thumbnailService
    }

    // MARK: Open (docs/05-authority-kernel.md §2, §13)

    /// Opens (or creates) the store and returns the ready facade.
    ///
    /// Performs the docs/05-authority-kernel.md §13 startup sequence,
    /// extended to the M1 total open order (`V2-roadmap` §5):
    ///
    /// 1. validates `configuration.initialMaximumUnpinnedItems` against the
    ///    fixed Part VI user range (`HistoryLimits.standard`, §2);
    /// 2. opens/creates the `ModelContainer` over the current immutable V3
    ///    schema (`Schema(versionedSchema: HistorySchemaV3.self)`) through
    ///    `HistoryMigrationPlan`: the custom `V1 → V2` stage (DC-02;
    ///    `V2-02` §3.3 / Record 5), then the additive lightweight `V2 → V3`
    ///    Gateway-table stage (DC-03; `V2-roadmap` §10 X.3). A fresh store is
    ///    created directly at V3 and runs no stage; a v1
    ///    store migrates during construction — the additive schema change
    ///    plus the `RetainedBytesRow` `didMigrate` backfill (idempotent by
    ///    construction) — on the migration-owned context, the sole
    ///    sanctioned pre-Authority writer. The configured durability medium
    ///    is unchanged: `.memory` changes the medium only and uses the same
    ///    Authority, planners, codecs, and transaction path (§2);
    /// 3. constructs `HistoryAuthority` over the container and asks it to
    ///    perform the store-side startup (create the position/retention
    ///    singleton for a new store, validate it, bootstrap/validate the
    ///    retention-expansion config singleton, bootstrap/validate the X.3
    ///    Gateway config plus deny-by-default App Intents connection, bound
    ///    the retained row count, rebuild legacy projection rows from their
    ///    content lineage, then rebuild the complete Signature Index from authoritative
    ///    Canonical/signature coverage without decoding revision state —
    ///    `V2-roadmap` §5 current total-order steps 3–12 over the v1 `05`
    ///    §13 store-side steps 3–11);
    /// 4. publishes the constructed facade with its five actors (current
    ///    roadmap step 13; v1 `05` §13 step 12).
    ///
    /// Failure translation at this boundary (§16, §2): an out-of-range
    /// initial retention value throws `.invalidInput(.invalidRetentionPolicy)`;
    /// a store that cannot be opened or migrated throws
    /// `.persistence(.openStore)`; startup corruption surfaced by the
    /// Authority propagates already typed as
    /// `.persistence(.corruptStoredValue)` or
    /// `.persistence(.invariantViolation)` — there is no silent repair path
    /// for corrupted data (§13). A projection-rebuild transaction failure
    /// follows §16's uniform `.persistence(.transaction)` mapping.
    public static func open(
        configuration: HistoryConfiguration
    ) async throws -> SwiftDataHistory {
        // §13 step 1: configuration validation against the fixed Part VI
        // safety profile (§2: "always uses the fixed HistoryLimits.standard
        // safety profile").
        let limits = HistoryLimits.standard
        guard limits.userMaximumUnpinnedRange.contains(
            configuration.initialMaximumUnpinnedItems
        ) else {
            throw HistoryFailure.invalidInput(.invalidRetentionPolicy)
        }

        // §13 step 2, extended by the M1 total open order (`V2-roadmap` §5
        // step 2; DC-02 / DC-03): build the current V3 schema ONCE and
        // construct the container through the ordered `HistoryMigrationPlan`.
        // A fresh store runs no stage; a v1 store migrates inside construction
        // (additive schema change + the RetainedBytesRow didMigrate
        // backfill), so both complete before `open` returns
        // (`RET-PLATFORM-1b(d)`). The durability medium is unchanged. Both
        // branches explicitly disable managed CloudKit discovery: clipboard
        // history is local-only, independent of future app entitlements.
        let schema = Schema(versionedSchema: HistorySchemaV3.self)
        let modelConfiguration: ModelConfiguration
        switch configuration.persistence {
        case .persistent(let storeURL):
            modelConfiguration = ModelConfiguration(
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
        case .memory:
            modelConfiguration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        }
        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: schema,
                migrationPlan: HistoryMigrationPlan.self,
                configurations: [modelConfiguration]
            )
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }

        // Current roadmap steps 3–12 (v1 §13 steps 3–11): the Authority owns
        // every store-side startup check,
        // including the X.3 Gateway bootstrap and bounded recipe-v2 rebuild
        // of legacy projection rows.
        // The current hard-capped Signature Index build additionally decodes
        // Canonical and recomputes xxh3 coverage; revision bytes remain
        // untouched unless the legacy recipe rebuild requires them (§13, §15).
        // The V2-02 §6.4 Storage clock is wired HERE, internally — the
        // production `SystemStorageClock` witness (the `{ Date.now }`
        // default) — so the public `open(configuration:)` signature and the
        // frozen `HistoryConfiguration` carry no clock parameter
        // (`RET-COMPILE-1`); tests inject a fixed clock only through the
        // `@testable` `HistoryAuthority` initializer.
        let authority = HistoryAuthority(
            container: container,
            storageClock: SystemStorageClock()
        )
        do {
            try await authority.performStartup(
                initialMaximumUnpinnedItems: configuration.initialMaximumUnpinnedItems
            )
        } catch let failure as HistoryFailure {
            // Already translated by the Authority (§16): corrupt stored
            // values and invariant violations fail open. The explicit legacy
            // projection rebuild is not a general stored-data repair path (§13).
            throw failure
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }

        // Current roadmap step 13 (v1 §13 step 12): publish the constructed
        // facade with its five actors.
        return SwiftDataHistory(
            authority: authority,
            ingestPreparation: IngestPreparationActor(),
            revisionPreparation: RevisionPreparationActor(),
            searchWorker: SearchWorker(),
            thumbnailService: ThumbnailService()
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
        switch action {
        case .capture(let raw):
            let prepared = try await ingestPreparation.prepare(raw)
            return try await authority.commitCapture(prepared)

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
    }

    // MARK: Reads (docs/05-authority-kernel.md §14)

    /// One-shot browse (docs/05-authority-kernel.md §14.1–§14.2).
    ///
    /// A `.recent` page is read entirely inside one Authority interval from
    /// scalar projection fields only (§14.1). A `.search` page follows the
    /// two-step value pipeline: the Authority captures a bounded
    /// `SearchCorpusSnapshot` plus the continuation anchor the next-page
    /// cursor is minted from, then `SearchWorker` evaluates the request over
    /// the snapshot off-actor — receiving the Authority's process marker so
    /// the minted cursor binds this process instance
    /// (docs/04-coherence.md §6) — and returns the bounded page stamped with
    /// the corpus position; the worker never reads SwiftData (§14.2;
    /// docs/04-coherence.md §7).
    public func browse(
        _ request: HistoryBrowseRequest
    ) async throws -> HistoryPage {
        switch request.kind {
        case .recent:
            return try await authority.recentPage(
                limit: request.limit,
                after: request.after
            )
        case .search:
            let captured = try await authority.searchCorpusSnapshot(for: request)
            return try await searchWorker.page(
                request,
                in: captured.snapshot,
                continuationAnchor: captured.continuationAnchor,
                processMarker: authority.cursorProcessMarker
            )
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
                    // §5 steps 2–4: the first page (P = page.position), then
                    // the race-closing recheck — while the durable position
                    // has moved past the page, a commit interleaved between
                    // registration and the query, so discard the page and
                    // query again. Position monotonicity proves freshness,
                    // not termination under an infinite write stream: v1
                    // intentionally waits for one query/recheck interval
                    // without an intervening commit rather than knowingly
                    // yielding a stale first page (04 §5).
                    var page = try await firstPage(for: request)
                    while try await authority.currentPosition() != page.position {
                        try Task.checkCancellation()
                        page = try await firstPage(for: request)
                    }
                    // §5 step 5.
                    continuation.yield(page)
#if DEBUG
                    await ObservationDebugInstrumentation.pageDidYield?(page)
#endif

                    // §5 steps 6–8: an invalidation at or behind the last
                    // yielded page is a buffered wake-up the page already
                    // covers (bufferingNewest(1) has also coalesced any
                    // burst); a newer one produces ONE replacement page. No
                    // phase-1 recheck here: the invalidation that woke the
                    // loop is by construction at or behind the replacement
                    // query's position (read-after-commit, §1), and a later
                    // commit simply produces the next wake-up.
                    for try await invalidation in registration.stream {
                        guard invalidation.latestPosition > page.position else {
                            continue
                        }
                        page = try await firstPage(for: request)
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
                    continuation.finish(throwing: error)
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

    /// Full detail for one retained item (docs/05-authority-kernel.md §14.3):
    /// the Authority fetches exactly one row, decodes and validates its full
    /// lineage, and maps it to the public detail DTO.
    public func details(
        for id: HistoryItemID
    ) async throws -> HistoryDetails {
        try await authority.details(for: id)
    }

    /// The paste payload for one retained item
    /// (docs/05-authority-kernel.md §14.3): the Authority fetches exactly one
    /// row and maps its current Effective Content plus the current reference
    /// and lineage hint.
    public func pastePayload(
        for id: HistoryItemID
    ) async throws -> PastePayload {
        try await authority.pastePayload(for: id)
    }

    /// The authoritative configured retention state (docs/v2/V2-07-ux.md
    /// §5.2/§6.3 — the settings panel-open read; audit SPEC-IMPL-003): the
    /// Authority reads both durable singletons inside one serialized,
    /// non-suspending interval — the v1 count from the position singleton
    /// (§3.2) and the V2-02 dimensions through the shared config→policy
    /// loader (`V2-02` §3.3). Configured policy only; no retained-byte usage
    /// rides this value (V2-07 §2.2 OPEN-2).
    public func retentionConfiguration() async throws -> HistoryRetentionConfiguration {
        try await authority.retentionConfiguration()
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
    /// source, no SwiftData value crosses an actor boundary, and completed
    /// bytes are not retained (docs/04-coherence.md §9).
    public func thumbnail(
        for item: HistoryItemReference,
        pixels: PixelSize
    ) async throws -> ThumbnailPayload? {
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
    }

    // MARK: Observation first page (docs/04-coherence.md §5)

    /// The first-page query of `observe`'s subscribe-before-query loop — a
    /// cursorless `browse` for the observation's query shape; observation
    /// intentionally has no cursor (docs/03a-instruction-set.md §7). The
    /// loop reuses it for the phase-1 recheck requeries and for every
    /// phase-2 replacement page (docs/04-coherence.md §5). A `.search` page
    /// keeps the two-step value pipeline: the Authority captures the bounded
    /// corpus plus the continuation anchor, and `SearchWorker` evaluates
    /// off-actor with the Authority's process marker for cursor minting
    /// (docs/05-authority-kernel.md §14.2; docs/04-coherence.md §6–§7).
    private func firstPage(
        for request: HistoryObservationRequest
    ) async throws -> HistoryPage {
        switch request.kind {
        case .recent:
            return try await authority.recentPage(limit: request.limit, after: nil)
        case .search:
            let browseRequest = HistoryBrowseRequest(
                kind: request.kind,
                limit: request.limit
            )
            let captured = try await authority.searchCorpusSnapshot(
                for: browseRequest
            )
            return try await searchWorker.page(
                browseRequest,
                in: captured.snapshot,
                continuationAnchor: captured.continuationAnchor,
                processMarker: authority.cursorProcessMarker
            )
        }
    }
}
