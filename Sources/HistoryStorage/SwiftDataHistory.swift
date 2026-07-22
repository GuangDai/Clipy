/// SwiftDataHistory — the production `ClipboardHistory` adapter: the public
/// facade over the five internal actors, owning closed action dispatch
/// (Part V §8), read forwarding (Part V §14), `open` startup
/// (Part V §13), and public failure translation (Part V §16).
/// Owning spec: docs/05-authority-kernel.md §2 (public concrete adapter and
/// internal actors); coherence: docs/04-coherence.md (Part IV); step phasing:
/// docs/roadmap/03-historystorage.md (steps 5–8).
///
/// `SwiftDataHistory` is a value of five `actor` references and nothing else:
/// the `Sendable` conformance is fully derived from the fields, so no unsafe
/// conformance or other escape hatch appears here (Part V §2; Part VI §6).
import Foundation
import HistoryCore
import SwiftData

// MARK: - Step-deferred error (transient; docs/roadmap/03-historystorage.md)

/// Internal marker thrown by an actor method whose implementation lands at a
/// later roadmap step (steps 6–8: mutations, reads/observation, thumbnail).
///
/// `StepDeferredError` is transient scaffolding for the step-5 slice: it is
/// NOT a `HistoryFailure`, is never translated into one, and propagates
/// through the `SwiftDataHistory` facade unchanged so a caller hitting a
/// not-yet-implemented path sees a distinct programmer-visible failure rather
/// than a misclassified public one. It is removed when steps 6–8 land
/// (docs/roadmap/03-historystorage.md).
internal enum StepDeferredError: Error, Sendable {
    /// The named operation is implemented at a later roadmap step. The name
    /// is diagnostic-only — nothing branches on it.
    case notYetImplemented(operation: String)
}

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
/// purpose-specific read paths (§14), and lets actor-thrown `HistoryFailure`s
/// (and, during the step-5 slice, `StepDeferredError`s) propagate.
public struct SwiftDataHistory: ClipboardHistory, Sendable {
    /// Sole writer; also serializes source snapshot capture and observer
    /// registration (docs/05-authority-kernel.md §2).
    private let authority: HistoryAuthority

    /// Prepares raw captures outside the commit interval
    /// (docs/05-authority-kernel.md §6.1).
    private let ingestPreparation: IngestPreparationActor

    /// Resolves revision drafts against a preparation snapshot outside the
    /// commit interval (docs/05-authority-kernel.md §6.2).
    private let revisionPreparation: RevisionPreparationActor

    /// Evaluates search over a Sendable corpus snapshot off the Authority;
    /// never reads SwiftData (docs/05-authority-kernel.md §14.2).
    private let searchWorker: SearchWorker

    /// Owns the thumbnail flight table and its worker
    /// (docs/05-authority-kernel.md §14.5; docs/04-coherence.md §9).
    private let thumbnailService: ThumbnailService

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
    /// Performs the docs/05-authority-kernel.md §13 startup sequence:
    ///
    /// 1. validates `configuration.initialMaximumUnpinnedItems` against the
    ///    fixed Part VI user range (`HistoryLimits.standard`, §2);
    /// 2. opens/creates the v1 `ModelContainer` (`v1Schema`, §3) for the
    ///    configured durability medium — `.memory` changes the medium only
    ///    and uses the same Authority, planners, codecs, and transaction
    ///    path (§2);
    /// 3. constructs `HistoryAuthority` over the container and asks it to
    ///    perform the store-side startup (create the position/retention
    ///    singleton for a new store, validate it, bound the retained row
    ///    count, and rebuild the complete Signature Index from durable
    ///    signature metadata without decoding content blobs, §13 steps 3–9);
    /// 4. publishes the constructed facade with its five actors (§13 step 10).
    ///
    /// Failure translation at this boundary (§16, §2): an out-of-range
    /// initial retention value throws `.invalidInput(.invalidRetentionPolicy)`;
    /// a store that cannot be opened throws `.persistence(.openStore)`;
    /// startup corruption surfaced by the Authority propagates already typed
    /// as `.persistence(.corruptStoredValue)` or
    /// `.persistence(.invariantViolation)` — v1 has no silent repair or
    /// migration path for corrupted data (§13).
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

        // §13 step 2: open/create the v1 ModelContainer for the configured
        // durability medium.
        let modelConfiguration: ModelConfiguration
        switch configuration.persistence {
        case .persistent(let storeURL):
            modelConfiguration = ModelConfiguration(schema: v1Schema, url: storeURL)
        case .memory:
            modelConfiguration = ModelConfiguration(
                schema: v1Schema,
                isStoredInMemoryOnly: true
            )
        }
        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: v1Schema,
                configurations: [modelConfiguration]
            )
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }

        // §13 steps 3–9: the Authority owns every store-side startup check.
        let authority = HistoryAuthority(container: container)
        do {
            try await authority.performStartup(
                initialMaximumUnpinnedItems: configuration.initialMaximumUnpinnedItems
            )
        } catch let failure as HistoryFailure {
            // Already translated by the Authority (§16): corrupt stored
            // values and invariant violations fail open — v1 has no silent
            // repair path (§13).
            throw failure
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }

        // §13 step 10: publish the constructed facade with its five actors.
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
    /// Actor-thrown failures propagate unchanged: typed `HistoryFailure`s on
    /// implemented paths (§16) and — during the step-5 slice —
    /// `StepDeferredError` on paths that land at steps 6–8
    /// (docs/roadmap/03-historystorage.md).
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
            let source = try await authority.revisionPreparationSnapshot(request)
            let bundle = try await revisionPreparation.prepare(request, from: source)
            return try await authority.commitRevision(request, bundle)

        case .setRetentionPolicy(let maximum):
            return try await authority.commitRetentionPolicy(maximum)
        }
    }

    // MARK: Reads (docs/05-authority-kernel.md §14)

    /// One-shot browse (docs/05-authority-kernel.md §14.1–§14.2).
    ///
    /// A `.recent` page is read entirely inside one Authority interval from
    /// scalar projection fields only (§14.1). A `.search` page follows the
    /// two-step value pipeline: the Authority captures a bounded
    /// `SearchCorpusSnapshot`, then `SearchWorker` evaluates the request over
    /// it off-actor and returns the bounded page stamped with the corpus
    /// position — the worker never reads SwiftData (§14.2;
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
            let corpus = try await authority.searchCorpusSnapshot(for: request)
            return try await searchWorker.page(request, in: corpus)
        }
    }

    /// Observes the current first page for one query
    /// (docs/05-authority-kernel.md §14.4; docs/04-coherence.md §5).
    ///
    /// This facade owns the Part IV §5 subscribe-before-query algorithm
    /// (register the invalidation continuation before the first query,
    /// discard pages older than a recorded invalidation, coalesce wake-ups
    /// into one replacement page) and any `SearchWorker` task. That loop
    /// lands at roadmap step 7 with the rest of the read surface
    /// (docs/roadmap/03-historystorage.md); at step 5 the stream performs the
    /// deferred first-page query and therefore finishes with the same failure
    /// the one-shot read path produces (`StepDeferredError` until step 7).
    ///
    /// Cancellation of the stream cancels the producer task; step 7's loop
    /// additionally unregisters the invalidation continuation
    /// (docs/04-coherence.md §5).
    public func observe(
        _ request: HistoryObservationRequest
    ) async -> AsyncThrowingStream<HistoryPage, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await firstPage(for: request)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
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

    /// An encoded thumbnail for one item at one Effective Content state,
    /// sized to `pixels`; `nil` when the item has no thumbnailable content
    /// (docs/05-authority-kernel.md §14.5; docs/04-coherence.md §9).
    ///
    /// The facade wires the §9 pipeline: the Authority validates the
    /// dimensions, fetches exactly one item, verifies the requested Content
    /// Version, and derives immutable source image bytes — answering `nil`
    /// itself when the item has no supported image representation — inside
    /// one non-suspending interval; `ThumbnailService` then joins/creates the
    /// single-flight for the exact key and decodes off the Authority, after
    /// all SwiftData objects and context have been released. Completed bytes
    /// are not retained (docs/04-coherence.md §9).
    public func thumbnail(
        for item: HistoryItemReference,
        pixels: PixelSize
    ) async throws -> ThumbnailPayload? {
        guard let sourceBytes = try await authority.thumbnailSource(
            for: item,
            pixels: pixels
        ) else {
            return nil
        }
        return try await thumbnailService.thumbnail(
            sourceBytes,
            for: item,
            pixels: pixels
        )
    }

    // MARK: Observation first page (docs/04-coherence.md §5)

    /// The first-page query shared by `observe` — a cursorless `browse` for
    /// the observation's query shape. Step 7's subscribe-before-query loop
    /// reuses it for every replacement page (docs/04-coherence.md §5);
    /// observation intentionally has no cursor (docs/03a-instruction-set.md
    /// §7).
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
            let corpus = try await authority.searchCorpusSnapshot(for: browseRequest)
            return try await searchWorker.page(browseRequest, in: corpus)
        }
    }
}
