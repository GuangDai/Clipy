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
private enum TransactionApplyRejection: Error {
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
/// a test arms it via @testable (no `#if DEBUG`). Arming is one-shot: the
/// first transaction closure entered after arming throws at the injection
/// point and disarms, so the exact WS13 interleaving — row mutation applied,
/// singleton position not yet written — commits nothing (§10: "Closure
/// failure commits nothing. There is no receipt, index delta, or
/// invalidation").
internal enum InjectedTransactionFailure: Error, Sendable {
    /// Throw after all row mutations and the final pin-order revalidation,
    /// immediately before the singleton position update (WS13).
    case beforeSingletonUpdate
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
    private let container: ModelContainer

    /// The fixed Part VI safety profile (docs/06-cross-cutting.md §2);
    /// `SwiftDataHistory.open` always uses `.standard` (§2).
    private let limits: HistoryLimits

    /// The actor-owned Signature Index value (§12). `init()` (unready) at
    /// construction; `performStartup` replaces it with the §13 step-8 build;
    /// commits mutate it only through the prevalidated `apply(_:)` delta
    /// (§9, §11). Capture-time rebuilds mint generation 0 themselves
    /// (`SignatureIndex.build`); the loader returns the rebuilt index.
    private var signatureIndex: SignatureIndex

    /// The process-local invalidation signal (docs/04-coherence.md §4);
    /// registration, unregistration, and the post-commit `publish` are
    /// synchronous actor operations (§14.4).
    private var invalidationPublisher: HistoryInvalidationPublisher

    /// The process-instance/schema marker stamped into every cursor this
    /// Authority mints (docs/04-coherence.md §6). A cursor from a different
    /// process or schema generation never decodes against this Authority;
    /// `PageCursorCodec.decode` rejects the marker mismatch and the caller
    /// maps it to `.snapshotExpired(current:)` (§16). Immutable for the
    /// Authority's lifetime.
    private let processMarker = UUID()

    /// Test seam: the harness-installed suspension handler, `nil` in
    /// production (see `AuthoritySuspensionPoint`).
    private var suspensionHandler: (@Sendable (AuthoritySuspensionPoint) async -> Void)?

    /// Test seam: the armed one-shot transaction failure, `nil` in
    /// production (see `InjectedTransactionFailure`).
    private var injectedTransactionFailure: InjectedTransactionFailure?

    /// The singleton row's well-known key (§3.2: always "retained-history").
    private static let positionSingletonKey = "retained-history"

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

    /// The process-instance/schema marker for cursor minting (04 §6). The
    /// `SearchWorker` call path mints cursors off-actor; it receives this
    /// marker so the minted cursor binds this Authority's generation.
    internal var cursorProcessMarker: UUID { processMarker }

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

        let context = ModelContext(container)
        context.autosaveEnabled = false

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
    private static func ensurePositionSingleton(
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
    private static func buildSignatureIndexAtStartup(
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
            // §13 step 7: the greenfield v1 schema requires projection
            // schema version 1.
            guard row.projectionSchemaVersion == ContentProjector.schemaVersion else {
                throw HistoryFailure.persistence(.corruptStoredValue)
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
        // §13 step 9 (D12): unique and exactly 0 ..< p — a sorted ordinal
        // list equals the index range iff the set is contiguous and
        // duplicate-free.
        pinnedOrdinals.sort()
        guard pinnedOrdinals == Array(0 ..< pinnedOrdinals.count) else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        do {
            return try SignatureIndex.build(from: signatures, limits: limits)
        } catch let rejection as SignatureIndexRejection {
            throw rejection.startupFailure
        }
    }

    // MARK: Capture commit (docs/05-authority-kernel.md §7.1, §9–§11)

    /// Commits one prepared capture: load proven-complete facts, plan
    /// purely, stamp mechanically, apply one atomic transaction, then apply
    /// the post-commit order without suspension.
    /// docs/05-authority-kernel.md §9 (the exact flow), §7.1, §10, §11
    ///
    /// Flow (§9): create operation-local context → load exact facts via
    /// `IngestFactLoader` (which rebuilds the Signature Index first when
    /// unready, §7.1 step 1) → `planCapture` → `.unchanged` releases the
    /// context and returns (no receipt, index delta, or invalidation,
    /// docs/04-coherence.md §4) → stamp via `CommitPlanStamper` →
    /// prevalidate the index delta (§9) → one `ModelContext.transaction`
    /// (§10) → nonthrowing Signature Index delta → synchronous invalidation
    /// yield → `.committed` receipt (§11).
    ///
    /// The single-writer interval contains no `await`: the only suspension
    /// is the roadmap-owned test point at entry, before the context exists
    /// (§5).
    ///
    /// - Throws: the fact loader's typed failures
    ///   (`.temporarilyUnavailable(.factProof)` / `.dedupIndexRebuild`,
    ///   `.persistence(...)`); the mapped `DomainRejection` vocabulary
    ///   (docs/02-domain.md §6); `StampingRejection` /
    ///   `CodecRejection.encodingFailed` via their §16 mappings;
    ///   `.persistence(.invariantViolation)` when the planner's winner is
    ///   absent from the loaded facts (defensive);
    ///   `.persistence(.transaction)` for any transaction-closure failure
    ///   including the armed WS13 injection (§16).
    internal func commitCapture(
        _ prepared: PreparedCaptureBundle
    ) async throws -> HistoryReceipt {
        // Roadmap-owned test seam: the one legal suspension point of this
        // path — no context, row, fact, or plan is live yet (§5).
        await suspendIfRequested(.captureCommitEntry)

        let context = ModelContext(container)
        context.autosaveEnabled = false

        // ── Non-suspending commit interval (§5): no `await` past this
        //    line while the context, facts, or commit plan is live. ──

        // The singleton supplies the current position (for stamping and the
        // §10 closure guard) and the authoritative retention policy (§3.2).
        let positionRow = try Self.fetchExactlyOnePositionRow(in: context)
        let (currentPosition, retention) = try Self.decodePositionRow(
            positionRow,
            limits: limits
        )

        // §7.1: complete facts, rebuilding the index first when unready
        // (`SignatureIndex.build` mints generation 0 itself; the loader
        // returns the rebuilt index).
        let load = try IngestFactLoader.loadFacts(
            in: context,
            prepared: prepared.domain,
            signatureIndex: signatureIndex,
            limits: limits
        )
        signatureIndex = load.signatureIndex

        // Pure planning (docs/02-domain.md §8): insert-or-coalesce plus
        // same-commit retention victims.
        let planningResult: PlanningResult
        do {
            planningResult = try planCapture(
                prepared.domain,
                facts: load.facts,
                retention: retention,
                hardMaximumRetainedItems: limits.hardMaximumRetainedItems
            )
        } catch let rejection as DomainRejection {
            throw rejection.historyFailure
        }

        guard case .commit(let mutationPlan) = planningResult else {
            // §9: release the context and return — nothing is retained
            // across the operation (§5), and a no-op yields no receipt,
            // index delta, or invalidation (docs/04-coherence.md §4).
            return .unchanged
        }

        // Copy Coalescing preserves the winner's loaded Content Version
        // (docs/02-domain.md §13); the receipt reference names that exact
        // state. The planner chose the winner from these facts, so absence
        // is a contract violation, not data.
        let coalescedWinnerVersion: ContentVersion?
        switch mutationPlan.outcome {
        case .inserted:
            coalescedWinnerVersion = nil
        case .coalesced(let winnerID):
            guard let version = Self.loadedContentVersion(
                of: winnerID,
                in: load.facts
            ) else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            coalescedWinnerVersion = version
        default:
            // planCapture emits only .inserted / .coalesced
            // (docs/02-domain.md §9).
            throw HistoryFailure.persistence(.invariantViolation)
        }

        // §9: mechanical stamping — the Domain never mints tokens
        // (docs/02-domain.md §4, §13).
        let stamped: StampedCommitPlan
        do {
            stamped = try CommitPlanStamper.stamp(
                mutationPlan,
                currentPosition: currentPosition,
                inputs: .capture(
                    projection: prepared.projection,
                    coalescedWinnerVersion: coalescedWinnerVersion
                )
            )
        } catch let rejection as StampingRejection {
            throw rejection.historyFailure
        } catch let rejection as CodecRejection {
            throw rejection.historyFailure
        }

        // §9: prevalidate the index delta before the transaction so the
        // §11 post-commit dictionary application cannot fail after durable
        // commit. A prevalidation failure happens before any durable write
        // and is an internal invariant violation (§12, §16).
        do {
            try signatureIndex.validate(stamped.indexDelta)
        } catch {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        // §10: the only durable History Commit primitive. Closure success is
        // the commit boundary — no trailing save, no compensating rollback.
        try executeCommitTransaction(
            stamped,
            expectedPreviousPosition: currentPosition,
            in: context
        )

        // §11 post-commit order, still isolated and without suspension:
        // 1. apply the already validated nonthrowing Signature Index delta
        //    (on detected divergence the index marks itself unready and the
        //    committed state stays authoritative, §11–§12);
        signatureIndex.apply(stamped.indexDelta)
        // 2. synchronously yield one invalidation to registered
        //    continuations (docs/04-coherence.md §4);
        invalidationPublisher.publish(
            HistoryInvalidation(latestPosition: stamped.position)
        )
        // 3. construct and return the committed receipt.
        return .committed(HistoryCommit(
            position: stamped.position,
            outcome: stamped.receiptOutcome
        ))
    }

    // MARK: Stamped-plan commit tail (docs/05-authority-kernel.md §9–§11)

    /// §9–§11 tail shared by the step-6 commits: prevalidate the index delta,
    /// execute the one atomic transaction, then apply the post-commit order
    /// without suspension (index delta → invalidation → committed receipt).
    /// docs/05-authority-kernel.md §9, §10, §11
    ///
    /// `commitCapture` keeps this tail inline (it additionally owns the
    /// unready-index rebuild of §7.1 step 1); the step-6 mutation commits
    /// share it here so each one is exactly context → singleton → facts →
    /// plan → stamp → tail (§9 flow).
    ///
    /// - Throws: `.persistence(.invariantViolation)` when the delta
    ///   prevalidation fails — an internal invariant violation raised before
    ///   any durable write (§12, §16); `.persistence(.transaction)` for any
    ///   transaction-closure failure (§16).
    private func executeStampedPlan(
        _ stamped: StampedCommitPlan,
        expectedPreviousPosition: ChangePosition,
        in context: ModelContext
    ) throws -> HistoryReceipt {
        // §9: prevalidate the index delta before the transaction so the
        // §11 post-commit dictionary application cannot fail after durable
        // commit. A prevalidation failure happens before any durable write
        // and is an internal invariant violation (§12, §16).
        do {
            try signatureIndex.validate(stamped.indexDelta)
        } catch {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        // §10: the only durable History Commit primitive. Closure success is
        // the commit boundary — no trailing save, no compensating rollback.
        try executeCommitTransaction(
            stamped,
            expectedPreviousPosition: expectedPreviousPosition,
            in: context
        )

        // §11 post-commit order, still isolated and without suspension:
        // 1. apply the already validated nonthrowing Signature Index delta
        //    (on detected divergence the index marks itself unready and the
        //    committed state stays authoritative, §11–§12);
        signatureIndex.apply(stamped.indexDelta)
        // 2. synchronously yield one invalidation to registered
        //    continuations (docs/04-coherence.md §4);
        invalidationPublisher.publish(
            HistoryInvalidation(latestPosition: stamped.position)
        )
        // 3. construct and return the committed receipt.
        return .committed(HistoryCommit(
            position: stamped.position,
            outcome: stamped.receiptOutcome
        ))
    }

    // MARK: Transaction execution (docs/05-authority-kernel.md §10)

    /// The one durable History Commit primitive (§10), shared by every
    /// stamped plan: fetch the singleton inside the closure, guard the
    /// expected previous position, apply every stamped mutation in order,
    /// revalidate the final pin order, fire the armed test injection if any,
    /// and write the singleton position last — all in one
    /// `ModelContext.transaction`.
    ///
    /// Rules (§10): no `await` in the closure or between fact load and
    /// closure completion; the executor fetches rows by business ID (never
    /// `registeredModel(for:)`); delete fetches the actual row; every
    /// referenced row exists exactly once unless the stamped case is create;
    /// closure failure commits nothing — there is no receipt, index delta,
    /// or invalidation; closure success is the save boundary, with no
    /// trailing `save()`/`processPendingChanges()`/`rollback()`.
    ///
    /// - Throws: `.persistence(.transaction)` for ANY closure failure —
    ///   including the `StorageInvariant.positionChanged` guard, executor
    ///   divergence, the armed `InjectedTransactionFailure` — or any
    ///   framework-level failure to durably commit (§16).
    private func executeCommitTransaction(
        _ plan: StampedCommitPlan,
        expectedPreviousPosition: ChangePosition,
        in context: ModelContext
    ) throws {
        do {
            try context.transaction {
                let meta = try Self.fetchExactlyOnePositionRow(in: context)
                guard meta.rawValue == expectedPreviousPosition.rawValue else {
                    throw StorageInvariant.positionChanged
                }
                for mutation in plan.mutations {
                    try self.apply(mutation, in: context, positionRow: meta)
                }
                try self.validateFinalPinOrder(in: context)
                // Roadmap-owned WS13 seam: one-shot injection after row
                // mutation, before the singleton update. Disarmed (nil) in
                // production.
                if let injection = self.injectedTransactionFailure {
                    self.injectedTransactionFailure = nil
                    throw injection
                }
                // The singleton position is written last, inside the same
                // transaction (§10, D6).
                meta.rawValue = plan.position.rawValue
            }
        } catch {
            // §16: a `ModelContext.transaction` closure failure (including
            // the `StorageInvariant.positionChanged` guard) or any
            // framework-level failure to durably commit the transaction.
            throw HistoryFailure.persistence(.transaction)
        }
    }

    /// Applies one stamped mutation to the transaction context.
    /// docs/05-authority-kernel.md §9 (rename table), §10 (executor rules)
    ///
    /// Every payload is already absolute — the Authority never infers hidden
    /// behavior from a case (docs/02-domain.md D18). Fetches go through the
    /// bounded business-ID lookup (§5); a missing referenced row, a
    /// duplicate create ID, or a revision base-version mismatch is
    /// `TransactionApplyRejection`, remapped to `.persistence(.transaction)`
    /// with every other closure failure (§16). Revision IDs are unique by
    /// construction (a freshly minted candidate ID appended to a validated
    /// unique-ID list) and re-verified at every decode (§4); the OCC check
    /// here is the interleaving guard (§9 `expectedCurrentVersion`).
    private func apply(
        _ mutation: StampedMutation,
        in context: ModelContext,
        positionRow: LastChangePositionRow
    ) throws {
        switch mutation {
        case .create(let item):
            guard try HistoryItemRowHydration.fetchRow(
                businessID: item.id,
                in: context
            ) == nil else {
                throw TransactionApplyRejection.duplicateCreateID(itemID: item.id)
            }
            context.insert(HistoryItemRow(
                id: item.id.rawValue,
                contentVersionRaw: item.contentVersion.rawValue,
                canonicalBlob: item.canonicalBlob,
                revisionStateBlob: item.revisionStateBlob,
                canonicalSignatureBlob: item.canonicalSignatureBlob,
                projectionSchemaVersion: item.projection.schemaVersion,
                title: item.projection.title,
                searchBody: item.projection.searchBody,
                effectiveTypeIdentifiersBlob: try EffectiveTypeIdentifiersBlobCodec
                    .encode(item.projection.effectiveTypeIdentifiers),
                firstCopiedAt: item.occurrence.firstCopiedAt,
                lastCopiedAt: item.occurrence.lastCopiedAt,
                copyCount: item.occurrence.count,
                firstSource: item.occurrence.firstSource,
                lastSource: item.occurrence.lastSource,
                pinOrdinal: nil
            ))

        case .updateOccurrence(let itemID, let occurrence):
            // Content Version and projections are preserved by absence from
            // the stamped payload (§9; docs/02-domain.md §13).
            let row = try requireRow(itemID, in: context)
            row.firstCopiedAt = occurrence.firstCopiedAt
            row.lastCopiedAt = occurrence.lastCopiedAt
            row.copyCount = occurrence.count
            row.firstSource = occurrence.firstSource
            row.lastSource = occurrence.lastSource

        case .setPinOrdinal(let itemID, let ordinal):
            let row = try requireRow(itemID, in: context)
            row.pinOrdinal = ordinal

        case .appendRevision(let update):
            let row = try requireRow(update.itemID, in: context)
            guard row.contentVersionRaw == update.expectedCurrentVersion.rawValue else {
                throw TransactionApplyRejection.contentVersionMismatch(
                    itemID: update.itemID
                )
            }
            // Revision state, Content Version, and effective projections are
            // written together (§10).
            row.contentVersionRaw = update.nextVersion.rawValue
            row.revisionStateBlob = update.revisionStateBlob
            row.projectionSchemaVersion = update.projection.schemaVersion
            row.title = update.projection.title
            row.searchBody = update.projection.searchBody
            row.effectiveTypeIdentifiersBlob = try EffectiveTypeIdentifiersBlobCodec
                .encode(update.projection.effectiveTypeIdentifiers)

        case .delete(let itemID, _):
            // §10: delete fetches the actual row — no predicate delete over
            // pending state. v1 writes no tombstone (docs/02-domain.md D15).
            let row = try requireRow(itemID, in: context)
            context.delete(row)

        case .setRetentionPolicy(let maximumUnpinnedItems):
            // The singleton owns the current v1 retention policy (§3.2);
            // the value was validated when the action entered (§2).
            positionRow.maximumUnpinnedItems = maximumUnpinnedItems
        }
    }

    /// Fetches the unique row a non-create stamped mutation references, or
    /// throws `TransactionApplyRejection.missingRow` (§10). A duplicate
    /// business ID or a framework fetch failure surfaces from the hydration
    /// helper already typed and is remapped with every other closure failure
    /// (§16).
    private func requireRow(
        _ itemID: HistoryItemID,
        in context: ModelContext
    ) throws -> HistoryItemRow {
        guard let row = try HistoryItemRowHydration.fetchRow(
            businessID: itemID,
            in: context
        ) else {
            throw TransactionApplyRejection.missingRow(itemID: itemID)
        }
        return row
    }

    /// §10: revalidates the final pinned order inside the transaction
    /// closure — ordinals non-negative, unique, and exactly `0 ..< p` (D12)
    /// — before closure success. The fetch is scalar (`pinOrdinal` only) and
    /// bounded by the hard retained-item maximum (§7.3), and unpinned rows
    /// are skipped in memory — the same shape as the §13 step-9 startup
    /// proof, avoiding any optional-`#Predicate` runtime-translation
    /// dependency (§18's verify-against-the-SDK stance).
    private func validateFinalPinOrder(in context: ModelContext) throws {
        var descriptor = FetchDescriptor<HistoryItemRow>()
        descriptor.propertiesToFetch = [\.pinOrdinal]
        descriptor.fetchLimit = limits.hardMaximumRetainedItems + 1
        let rows: [HistoryItemRow]
        do {
            rows = try context.fetch(descriptor)
        } catch {
            throw TransactionApplyRejection.finalPinOrderViolated
        }
        guard rows.count <= limits.hardMaximumRetainedItems else {
            throw TransactionApplyRejection.finalPinOrderViolated
        }
        var ordinals: [Int] = []
        ordinals.reserveCapacity(rows.count)
        for row in rows {
            guard let ordinal = row.pinOrdinal else { continue }
            guard ordinal >= 0 else {
                throw TransactionApplyRejection.finalPinOrderViolated
            }
            ordinals.append(ordinal)
        }
        ordinals.sort()
        guard ordinals == Array(0 ..< ordinals.count) else {
            throw TransactionApplyRejection.finalPinOrderViolated
        }
    }

    // MARK: Singleton access (docs/05-authority-kernel.md §3.2, §10)

    /// Fetches the one position/retention singleton row.
    /// docs/05-authority-kernel.md §3.2, §10 (`fetchExactlyOnePositionRow`)
    ///
    /// The fetch is bounded (`fetchLimit = 2`): exactly one row is valid;
    /// zero or duplicates are durable-state corruption
    /// (`.persistence(.invariantViolation)`). A framework fetch failure
    /// outside the transaction closure means the fact cannot be proven
    /// (`.temporarilyUnavailable(.factProof)`, §16); inside the closure the
    /// executor remaps it with every other closure failure to
    /// `.persistence(.transaction)`.
    private static func fetchExactlyOnePositionRow(
        in context: ModelContext
    ) throws -> LastChangePositionRow {
        let key = positionSingletonKey
        var descriptor = FetchDescriptor<LastChangePositionRow>(
            predicate: #Predicate { row in row.key == key }
        )
        descriptor.fetchLimit = 2
        let rows: [LastChangePositionRow]
        do {
            rows = try context.fetch(descriptor)
        } catch {
            throw HistoryFailure.temporarilyUnavailable(.factProof)
        }
        guard rows.count == 1, let row = rows.first else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return row
    }

    /// Decodes the singleton's scalar values: the current Change Position
    /// and the authoritative retention policy (§3.2). A stored policy
    /// outside the fixed Part VI user range is a corrupt stored value (§16,
    /// D19).
    private static func decodePositionRow(
        _ row: LastChangePositionRow,
        limits: HistoryLimits
    ) throws -> (position: ChangePosition, retention: RetentionPolicy) {
        guard limits.userMaximumUnpinnedRange.contains(row.maximumUnpinnedItems) else {
            throw HistoryFailure.persistence(.corruptStoredValue)
        }
        return (
            position: ChangePosition(rawValue: row.rawValue),
            retention: RetentionPolicy(maximumUnpinnedItems: row.maximumUnpinnedItems)
        )
    }

    /// The loaded Content Version of one item in the capture facts, checking
    /// the lineage hint first (it need not be a signature candidate,
    /// §7.1 step 4). Returns `nil` when the ID is absent — a planner
    /// contract violation for a chosen winner, never data.
    private static func loadedContentVersion(
        of itemID: HistoryItemID,
        in facts: IngestFacts
    ) -> ContentVersion? {
        if facts.hintedItem?.id == itemID {
            return facts.hintedItem?.contentVersion
        }
        return facts.candidates.items.first { $0.id == itemID }?.contentVersion
    }

    // MARK: Observation registration (docs/05-authority-kernel.md §14.4)

    /// Registers one invalidation continuation and returns its token and
    /// stream. docs/05-authority-kernel.md §14.4; docs/04-coherence.md §5
    /// step 1 (registration precedes the first authoritative query — the
    /// WS12 ordering rule).
    ///
    /// Registration is a synchronous actor operation. Cancellation of the
    /// returned stream fires the publisher's termination callback, which
    /// hops back onto the Authority and removes the token (§14.4:
    /// "Cancellation removes the token"); the weak hop avoids a
    /// publisher→continuation→actor retain cycle. Step 7's
    /// `SwiftDataHistory.observe` loop is the caller.
    internal func registerInvalidationSubscriber() -> (
        subscription: HistoryInvalidationSubscription,
        stream: HistoryInvalidationPublisher.Stream
    ) {
        invalidationPublisher.subscribe { [weak self] subscription in
            guard let self else { return }
            _ = Task { await self.unregisterInvalidationSubscriber(subscription) }
        }
    }

    /// Removes one subscription and finishes its stream (§14.4). Idempotent
    /// — a termination-triggered removal that races an explicit removal is
    /// a no-op.
    internal func unregisterInvalidationSubscriber(
        _ subscription: HistoryInvalidationSubscription
    ) {
        invalidationPublisher.unsubscribe(subscription)
    }

    // MARK: Roadmap-owned test seams (docs/roadmap/03-historystorage.md step 5)

    /// Installs (or clears) the suspension handler the deterministic
    /// concurrency harness drives. Test seam — `nil` in production, compiled
    /// in always, set via @testable; see `AuthoritySuspensionPoint`.
    internal func setSuspensionHandler(
        _ handler: (@Sendable (AuthoritySuspensionPoint) async -> Void)?
    ) {
        suspensionHandler = handler
    }

    /// Arms (or clears) the one-shot transaction failure of WS13. Test seam
    /// — disarmed in production, compiled in always, set via @testable; see
    /// `InjectedTransactionFailure`.
    internal func setTransactionFailureInjection(
        _ injection: InjectedTransactionFailure?
    ) {
        injectedTransactionFailure = injection
    }

    /// Suspends at `point` when the harness has installed a handler; a no-op
    /// otherwise and always in production. Callers place points only where
    /// an `await` is legal (§5).
    private func suspendIfRequested(_ point: AuthoritySuspensionPoint) async {
        await suspensionHandler?(point)
    }

    // MARK: - Mutation commits (docs/roadmap/03-historystorage.md step 6)

    // The step-6 mutation commits: pin placement, unpin, remove, clear,
    // retention policy, and the §6.2 two-phase revision. Each reuses the
    // capture path's spine — operation-local context, singleton position,
    // complete facts (§7.2–§7.3, via `MutationFactLoaders`), pure planning,
    // mechanical stamping, and the shared `executeStampedPlan` tail
    // (§9–§11) — with no `await` past context creation (§5).

    /// Commits one pin placement: load proven-complete pin facts, plan
    /// purely, stamp mechanically, then run the shared commit tail.
    /// docs/05-authority-kernel.md §9 (the exact flow), §7.2, §10, §11;
    /// docs/02-domain.md §10 (pinned order)
    ///
    /// Flow (§9): create operation-local context → read the singleton
    /// position → load `PinFacts` via `MutationFactLoaders` (target
    /// existence plus the validated complete pinned order, §7.2) →
    /// `planPinnedPlacement` → `.unchanged` releases the context and
    /// returns (no receipt, index delta, or invalidation,
    /// docs/04-coherence.md §4) → stamp (inputs `.none` — pin plans stamp
    /// from the Domain payloads alone) → `executeStampedPlan`.
    ///
    /// The single-writer interval contains no `await` (§5).
    ///
    /// - Throws: the fact loader's typed failures
    ///   (`.temporarilyUnavailable(.factProof)`, `.persistence(...)`); the
    ///   mapped `DomainRejection` vocabulary — placement rejects through
    ///   `.invalidPinnedPlacement`, never `.notFound` (docs/02-domain.md §6,
    ///   §10; docs/03b-instruction-set.md §10); `StampingRejection` /
    ///   `CodecRejection.encodingFailed` via their §16 mappings;
    ///   `.persistence(.transaction)` for any transaction-closure failure
    ///   (§16).
    internal func commitPinnedPlacement(
        _ itemID: HistoryItemID,
        _ placement: PinnedPlacement
    ) async throws -> HistoryReceipt {
        let context = ModelContext(container)
        context.autosaveEnabled = false

        // ── Non-suspending commit interval (§5): no `await` past this
        //    line while the context, facts, or commit plan is live. ──

        // The singleton supplies the current position (for stamping and the
        // §10 closure guard).
        let positionRow = try Self.fetchExactlyOnePositionRow(in: context)
        let (currentPosition, _) = try Self.decodePositionRow(
            positionRow,
            limits: limits
        )

        // §7.2: target existence plus every pinned row, validated into the
        // complete pinned order (D12).
        let facts = try MutationFactLoaders.loadPinFacts(
            itemID: itemID,
            in: context,
            limits: limits
        )

        // Pure planning (docs/02-domain.md §8, §10).
        let planningResult: PlanningResult
        do {
            planningResult = try planPinnedPlacement(
                itemID: itemID,
                placement: placement,
                facts: facts
            )
        } catch let rejection as DomainRejection {
            throw rejection.historyFailure
        }

        guard case .commit(let mutationPlan) = planningResult else {
            // §9: release the context and return — nothing is retained
            // across the operation (§5), and a no-op yields no receipt,
            // index delta, or invalidation (docs/04-coherence.md §4).
            return .unchanged
        }

        // §9: mechanical stamping — the Domain never mints tokens
        // (docs/02-domain.md §4, §13).
        let stamped: StampedCommitPlan
        do {
            stamped = try CommitPlanStamper.stamp(
                mutationPlan,
                currentPosition: currentPosition,
                inputs: .none
            )
        } catch let rejection as StampingRejection {
            throw rejection.historyFailure
        } catch let rejection as CodecRejection {
            throw rejection.historyFailure
        }

        return try executeStampedPlan(
            stamped,
            expectedPreviousPosition: currentPosition,
            in: context
        )
    }

    /// Commits one unpin: load proven-complete pin facts, plan purely,
    /// stamp mechanically, then run the shared commit tail.
    /// docs/05-authority-kernel.md §9 (the exact flow), §7.2, §10, §11;
    /// docs/02-domain.md §10 (pinned order)
    ///
    /// Identical spine to `commitPinnedPlacement`; `planUnpin` returns
    /// `.unchanged` when the target exists but is not pinned
    /// (docs/03a-instruction-set.md §5).
    ///
    /// The single-writer interval contains no `await` (§5).
    ///
    /// - Throws: the fact loader's typed failures; the mapped
    ///   `DomainRejection` vocabulary — unpin rejects a missing target as
    ///   `.notFound` (docs/02-domain.md §6, §10); `StampingRejection` /
    ///   `CodecRejection.encodingFailed` via their §16 mappings;
    ///   `.persistence(.transaction)` for any transaction-closure failure
    ///   (§16).
    internal func commitUnpin(_ itemID: HistoryItemID) async throws -> HistoryReceipt {
        let context = ModelContext(container)
        context.autosaveEnabled = false

        // ── Non-suspending commit interval (§5): no `await` past this
        //    line while the context, facts, or commit plan is live. ──

        // The singleton supplies the current position (for stamping and the
        // §10 closure guard).
        let positionRow = try Self.fetchExactlyOnePositionRow(in: context)
        let (currentPosition, _) = try Self.decodePositionRow(
            positionRow,
            limits: limits
        )

        // §7.2: target existence plus the complete pinned order — unpin
        // shifts every later pinned item (docs/02-domain.md §10).
        let facts = try MutationFactLoaders.loadPinFacts(
            itemID: itemID,
            in: context,
            limits: limits
        )

        // Pure planning (docs/02-domain.md §8, §10).
        let planningResult: PlanningResult
        do {
            planningResult = try planUnpin(itemID: itemID, facts: facts)
        } catch let rejection as DomainRejection {
            throw rejection.historyFailure
        }

        guard case .commit(let mutationPlan) = planningResult else {
            // §9: release the context and return — nothing is retained
            // across the operation (§5), and a no-op yields no receipt,
            // index delta, or invalidation (docs/04-coherence.md §4).
            return .unchanged
        }

        // §9: mechanical stamping — the Domain never mints tokens
        // (docs/02-domain.md §4, §13).
        let stamped: StampedCommitPlan
        do {
            stamped = try CommitPlanStamper.stamp(
                mutationPlan,
                currentPosition: currentPosition,
                inputs: .none
            )
        } catch let rejection as StampingRejection {
            throw rejection.historyFailure
        } catch let rejection as CodecRejection {
            throw rejection.historyFailure
        }

        return try executeStampedPlan(
            stamped,
            expectedPreviousPosition: currentPosition,
            in: context
        )
    }

    /// Commits one removal: load the target's scalar summary plus the
    /// complete pinned order, plan purely, stamp mechanically, then run the
    /// shared commit tail.
    /// docs/05-authority-kernel.md §9 (the exact flow), §7.3, §10, §11;
    /// docs/02-domain.md §10 (pinned-lane compaction), D15 (no tombstone)
    ///
    /// Flow (§9): create operation-local context → read the singleton
    /// position → load `RemoveFacts` via `MutationFactLoaders` (§7.3) →
    /// `planRemove` — removing a pinned item compacts the pinned lane in
    /// the same commit, so the §10 final-order revalidation cannot fail on
    /// a gap (docs/02-domain.md §10, D12) → stamp (inputs `.none`) →
    /// `executeStampedPlan`.
    ///
    /// The single-writer interval contains no `await` (§5).
    ///
    /// - Throws: the fact loader's typed failures; the mapped
    ///   `DomainRejection` vocabulary — remove rejects a missing target as
    ///   `.notFound` (docs/02-domain.md §6); `StampingRejection` /
    ///   `CodecRejection.encodingFailed` via their §16 mappings;
    ///   `.persistence(.transaction)` for any transaction-closure failure
    ///   (§16).
    internal func commitRemove(_ itemID: HistoryItemID) async throws -> HistoryReceipt {
        let context = ModelContext(container)
        context.autosaveEnabled = false

        // ── Non-suspending commit interval (§5): no `await` past this
        //    line while the context, facts, or commit plan is live. ──

        // The singleton supplies the current position (for stamping and the
        // §10 closure guard).
        let positionRow = try Self.fetchExactlyOnePositionRow(in: context)
        let (currentPosition, _) = try Self.decodePositionRow(
            positionRow,
            limits: limits
        )

        // §7.3: the target's scalar summary plus the complete pinned order
        // (the §7.2 load).
        let facts = try MutationFactLoaders.loadRemoveFacts(
            itemID: itemID,
            in: context,
            limits: limits
        )

        // Pure planning (docs/02-domain.md §8, §5.4).
        let planningResult: PlanningResult
        do {
            planningResult = try planRemove(itemID: itemID, facts: facts)
        } catch let rejection as DomainRejection {
            throw rejection.historyFailure
        }

        guard case .commit(let mutationPlan) = planningResult else {
            // §9: release the context and return — nothing is retained
            // across the operation (§5), and a no-op yields no receipt,
            // index delta, or invalidation (docs/04-coherence.md §4).
            return .unchanged
        }

        // §9: mechanical stamping — the Domain never mints tokens
        // (docs/02-domain.md §4, §13).
        let stamped: StampedCommitPlan
        do {
            stamped = try CommitPlanStamper.stamp(
                mutationPlan,
                currentPosition: currentPosition,
                inputs: .none
            )
        } catch let rejection as StampingRejection {
            throw rejection.historyFailure
        } catch let rejection as CodecRejection {
            throw rejection.historyFailure
        }

        return try executeStampedPlan(
            stamped,
            expectedPreviousPosition: currentPosition,
            in: context
        )
    }

    /// Commits one clear: load the complete affected set `scope` selects at
    /// this linearization point, plan purely, stamp mechanically, then run
    /// the shared commit tail. There is no partial clear
    /// (docs/02-domain.md §5.4).
    /// docs/05-authority-kernel.md §9 (the exact flow), §7.3, §10, §11
    ///
    /// Flow (§9): create operation-local context → read the singleton
    /// position → load `ClearFacts` via `MutationFactLoaders` (§7.3) →
    /// `planClear` (non-throwing — an empty affected set is `.unchanged`,
    /// never a rejection, docs/02-domain.md §8) → stamp (inputs `.none`) →
    /// `executeStampedPlan`.
    ///
    /// The single-writer interval contains no `await` (§5).
    ///
    /// - Throws: the fact loader's typed failures; `StampingRejection` /
    ///   `CodecRejection.encodingFailed` via their §16 mappings;
    ///   `.persistence(.transaction)` for any transaction-closure failure
    ///   (§16).
    internal func commitClear(_ scope: ClearScope) async throws -> HistoryReceipt {
        let context = ModelContext(container)
        context.autosaveEnabled = false

        // ── Non-suspending commit interval (§5): no `await` past this
        //    line while the context, facts, or commit plan is live. ──

        // The singleton supplies the current position (for stamping and the
        // §10 closure guard).
        let positionRow = try Self.fetchExactlyOnePositionRow(in: context)
        let (currentPosition, _) = try Self.decodePositionRow(
            positionRow,
            limits: limits
        )

        // §7.3: every ID/pin value selected by scope.
        let facts = try MutationFactLoaders.loadClearFacts(
            scope: scope,
            in: context,
            limits: limits
        )

        // Pure planning (docs/02-domain.md §8, §5.4): retire exactly the
        // affected set in one commit.
        let planningResult = planClear(scope: scope, facts: facts)

        guard case .commit(let mutationPlan) = planningResult else {
            // §9: release the context and return — nothing is retained
            // across the operation (§5), and a no-op yields no receipt,
            // index delta, or invalidation (docs/04-coherence.md §4).
            return .unchanged
        }

        // §9: mechanical stamping — the Domain never mints tokens
        // (docs/02-domain.md §4, §13).
        let stamped: StampedCommitPlan
        do {
            stamped = try CommitPlanStamper.stamp(
                mutationPlan,
                currentPosition: currentPosition,
                inputs: .none
            )
        } catch let rejection as StampingRejection {
            throw rejection.historyFailure
        } catch let rejection as CodecRejection {
            throw rejection.historyFailure
        }

        return try executeStampedPlan(
            stamped,
            expectedPreviousPosition: currentPosition,
            in: context
        )
    }

    /// Phase one of the OCC-safe two-phase revision preparation (§6.2):
    /// fetch and fully hydrate the target in one non-suspending read-only
    /// interval, reject an already-stale `request.expected` immediately,
    /// and return the validated lineage as a Sendable
    /// `RevisionPreparationSnapshot` — no row or context escapes (§5).
    /// docs/05-authority-kernel.md §6.2, §5, §7.3
    ///
    /// This interval is not a commit: there is no receipt, index delta, or
    /// invalidation (docs/04-coherence.md §4).
    ///
    /// - Throws: `.notFound(request.itemID)` when the target is not
    ///   retained; `.staleContent(expected:current:)` when the item's
    ///   Content Version already differs from the request's OCC token
    ///   (§6.2); the hydration decode mappings
    ///   (`.persistence(.corruptStoredValue)`, §4/§16) and the bounded
    ///   business-ID fetch's `.temporarilyUnavailable(.factProof)` (§16).
    internal func revisionPreparationSnapshot(
        _ request: RevisionRequest
    ) async throws -> RevisionPreparationSnapshot {
        let context = ModelContext(container)
        context.autosaveEnabled = false

        // ── Non-suspending read interval (§5): no `await` past this line
        //    while the context or fetched row is live. ──

        // §7.3: fetch and decode exactly the target item.
        guard let row = try HistoryItemRowHydration.fetchRow(
            businessID: request.itemID,
            in: context
        ) else {
            throw HistoryFailure.notFound(request.itemID)
        }
        let item = try HistoryItemRowHydration.hydrate(row, limits: limits)

        // §6.2: reject immediately when the OCC token is already stale —
        // the expensive resolution/projection phase never runs for a
        // proposal that cannot commit.
        guard request.expected == item.contentVersion else {
            throw HistoryFailure.staleContent(
                expected: request.expected,
                current: item.contentVersion
            )
        }

        return RevisionPreparationSnapshot(
            canonical: item.canonical,
            revisions: item.revisions,
            activeRevisionID: item.activeRevisionID,
            contentVersion: item.contentVersion
        )
    }

    /// Phase two of the OCC-safe revision commit (§6.2): reload the
    /// target's complete lineage, recheck the OCC token through pure
    /// planning, stamp from the reloaded facts, then run the shared commit
    /// tail.
    /// docs/05-authority-kernel.md §6.2, §9 (the exact flow), §7.3, §10,
    /// §11; docs/02-domain.md §11 (revision planning and OCC)
    ///
    /// Flow (§9): create operation-local context → read the singleton
    /// position → load `RevisionFacts` via `MutationFactLoaders` — exactly
    /// the target item, fully decoded (§7.3); a missing target fails the
    /// load as `.notFound` → `planRevision` (OCC, base-version, and
    /// normalization rechecks; a byte-identical proposal is `.unchanged`)
    /// → stamp with `.revision` inputs taken from the reloaded facts →
    /// `executeStampedPlan` (the transaction executor re-verifies
    /// `expectedCurrentVersion`, §10).
    ///
    /// The single-writer interval contains no `await`: the only suspension
    /// is the roadmap-owned WS20 test point at entry, before the context
    /// exists (§5).
    ///
    /// - Throws: the fact loader's typed failures (`.notFound`,
    ///   `.temporarilyUnavailable(.factProof)`, `.persistence(...)`); the
    ///   mapped `DomainRejection` vocabulary — `.staleContent` on the OCC
    ///   recheck, `.invalidInput(.incoherentRevisionDraft)` on a draft
    ///   failing Domain revalidation (docs/02-domain.md §6, §11);
    ///   `StampingRejection` / `CodecRejection.encodingFailed` via their
    ///   §16 mappings; `.persistence(.transaction)` for any
    ///   transaction-closure failure (§16).
    internal func commitRevision(
        _ request: RevisionRequest,
        _ bundle: PreparedRevisionBundle
    ) async throws -> HistoryReceipt {
        // Roadmap-owned WS20 test seam: the one legal suspension point of
        // this path — no context, row, fact, or plan is live yet (§5).
        await suspendIfRequested(.revisionCommitEntry)

        let context = ModelContext(container)
        context.autosaveEnabled = false

        // ── Non-suspending commit interval (§5): no `await` past this
        //    line while the context, facts, or commit plan is live. ──

        // The singleton supplies the current position (for stamping and the
        // §10 closure guard).
        let positionRow = try Self.fetchExactlyOnePositionRow(in: context)
        let (currentPosition, _) = try Self.decodePositionRow(
            positionRow,
            limits: limits
        )

        // §7.3: fetch and decode exactly the target item.
        let facts = try MutationFactLoaders.loadRevisionFacts(
            itemID: request.itemID,
            in: context,
            limits: limits
        )

        // Pure planning (docs/02-domain.md §8, §11): the Domain rechecks
        // the OCC token and the preparation's base version against the
        // reloaded facts.
        let planningResult: PlanningResult
        do {
            planningResult = try planRevision(
                request: request,
                prepared: bundle.domain,
                facts: facts
            )
        } catch let rejection as DomainRejection {
            throw rejection.historyFailure
        }

        guard case .commit(let mutationPlan) = planningResult else {
            // §9: release the context and return — nothing is retained
            // across the operation (§5), and a no-op yields no receipt,
            // index delta, or invalidation (docs/04-coherence.md §4).
            return .unchanged
        }

        // §9: mechanical stamping from the reloaded facts — the item's
        // current Content Version, its complete existing revision list,
        // and the prepared revision projection (§6.2).
        let stamped: StampedCommitPlan
        do {
            stamped = try CommitPlanStamper.stamp(
                mutationPlan,
                currentPosition: currentPosition,
                inputs: .revision(
                    currentVersion: facts.item.contentVersion,
                    existingRevisions: facts.item.revisions,
                    projection: bundle.projection
                )
            )
        } catch let rejection as StampingRejection {
            throw rejection.historyFailure
        } catch let rejection as CodecRejection {
            throw rejection.historyFailure
        }

        return try executeStampedPlan(
            stamped,
            expectedPreviousPosition: currentPosition,
            in: context
        )
    }

    /// Commits one retention-policy change: validate the value against the
    /// fixed Part VI user range at the boundary (§2, D19), load the
    /// complete retained-set inventory, plan purely, stamp mechanically,
    /// then run the shared commit tail.
    /// docs/05-authority-kernel.md §9 (the exact flow), §7.3, §10, §11;
    /// docs/02-domain.md §12 (retention)
    ///
    /// Flow (§9): boundary validation → create operation-local context →
    /// read the singleton position and the authoritative current policy
    /// (§3.2) → load `RetentionFacts` via `MutationFactLoaders` (§7.3) →
    /// `planRetention` (non-throwing — a same-value no-victim set is
    /// `.unchanged` before stamping, §9; docs/02-domain.md §12) → stamp
    /// (inputs `.none`) → `executeStampedPlan`.
    ///
    /// The single-writer interval contains no `await` (§5).
    ///
    /// - Throws: `.invalidInput(.invalidRetentionPolicy)` for an
    ///   out-of-range value (§2, §16); the fact loader's typed failures;
    ///   `StampingRejection` / `CodecRejection.encodingFailed` via their
    ///   §16 mappings; `.persistence(.transaction)` for any
    ///   transaction-closure failure (§16).
    internal func commitRetentionPolicy(
        _ maximumUnpinnedItems: Int
    ) async throws -> HistoryReceipt {
        // §2, §16, D19: boundary validation before any context — the value
        // must lie in the fixed Part VI user range (which always permits at
        // least one unpinned item).
        guard limits.userMaximumUnpinnedRange.contains(maximumUnpinnedItems) else {
            throw HistoryFailure.invalidInput(.invalidRetentionPolicy)
        }

        let context = ModelContext(container)
        context.autosaveEnabled = false

        // ── Non-suspending commit interval (§5): no `await` past this
        //    line while the context, facts, or commit plan is live. ──

        // The singleton supplies the current position (for stamping and the
        // §10 closure guard) and the authoritative current retention policy
        // (§3.2).
        let positionRow = try Self.fetchExactlyOnePositionRow(in: context)
        let (currentPosition, currentPolicy) = try Self.decodePositionRow(
            positionRow,
            limits: limits
        )

        // §7.3: every retained ID, last-copied time, and pin ordinal.
        let facts = try MutationFactLoaders.loadRetentionFacts(
            currentPolicy: currentPolicy,
            in: context,
            limits: limits
        )

        // Pure planning (docs/02-domain.md §8, §12): the policy write plus
        // any eviction victims, or `.unchanged` for a same-value no-victim
        // set.
        let planningResult = planRetention(
            facts: facts,
            policy: RetentionPolicy(maximumUnpinnedItems: maximumUnpinnedItems)
        )

        guard case .commit(let mutationPlan) = planningResult else {
            // §9: release the context and return — nothing is retained
            // across the operation (§5), and a no-op yields no receipt,
            // index delta, or invalidation (docs/04-coherence.md §4).
            return .unchanged
        }

        // §9: mechanical stamping — the Domain never mints tokens
        // (docs/02-domain.md §4, §13).
        let stamped: StampedCommitPlan
        do {
            stamped = try CommitPlanStamper.stamp(
                mutationPlan,
                currentPosition: currentPosition,
                inputs: .none
            )
        } catch let rejection as StampingRejection {
            throw rejection.historyFailure
        } catch let rejection as CodecRejection {
            throw rejection.historyFailure
        }

        return try executeStampedPlan(
            stamped,
            expectedPreviousPosition: currentPosition,
            in: context
        )
    }

    // MARK: - Read paths (docs/05-authority-kernel.md §14; docs/04-coherence.md)

    // The step-7 read methods: position-only recheck, recent browse
    // (§14.1), search corpus capture (§14.2), detail and paste (§14.3).
    // Each reuses this file's non-suspending read-interval spine: the only
    // `await` is the WS12 test seam at entry, before the context exists (§5).

    /// The position-only scalar read backing the observe loop's phase-1
    /// race-closing recheck (docs/04-coherence.md §5) and WS12
    /// (docs/06-cross-cutting.md §8).
    ///
    /// Flow: WS12 seam at entry → operation-local context → singleton fetch/
    /// decode → return position. The single read interval contains no `await`
    /// past context creation (§5).
    ///
    /// - Throws: `.temporarilyUnavailable(.factProof)` for a framework fetch
    ///   failure; `.persistence(.invariantViolation)` for a duplicate/absent
    ///   singleton; `.persistence(.corruptStoredValue)` for an out-of-range
    ///   stored retention value (§16).
    internal func currentPosition() async throws -> ChangePosition {
        // WS12 seam: the one legal suspension point of this path — no
        // context is live yet (§5).
        await suspendIfRequested(.positionRecheckEntry)

        let context = ModelContext(container)
        context.autosaveEnabled = false

        // ── Non-suspending read interval (§5): no `await` past this
        //    line while the context is live. ──

        let positionRow = try Self.fetchExactlyOnePositionRow(in: context)
        let (currentPosition, _) = try Self.decodePositionRow(
            positionRow,
            limits: limits
        )
        return currentPosition
    }

    /// Recent browse (docs/05-authority-kernel.md §14.1): one non-suspending
    /// interval reading the position and at most `limit + 1` scalar projection
    /// rows per lane, with cursor validation and expiry.
    /// docs/05-authority-kernel.md §14.1; docs/04-coherence.md §6
    ///
    /// Flow: WS12 seam at entry → limit validation → cursor decode+validation
    /// when present → operation-local context → position read → scalar-only
    /// two-lane fetch (pinned by `pinOrdinal` ascending; unpinned by
    /// `lastCopiedAt DESC, id ASC`) → in-memory tie-break guard → continuation
    /// anchor application → page assembly → cursor mint.
    ///
    /// No Canonical/revision blob is decoded (§14.1, §7.5); only scalar
    /// projection fields plus the small `effectiveTypeIdentifiersBlob`.
    ///
    /// - Throws: `.invalidInput(.invalidPageLimit)` for an out-of-range limit
    ///   (§16); `.snapshotExpired(current:)` for a cursor that is undecodable,
    ///   generation-mismatched, shape-mismatched, position-mismatched, or whose
    ///   anchor names no retained row (§16); `.temporarilyUnavailable(.factProof)`
    ///   for a framework fetch failure; `.persistence(...)` for decode or
    ///   invariant failures (§16).
    internal func recentPage(
        limit: Int,
        after: HistoryPageCursor?
    ) async throws -> HistoryPage {
        // WS12 seam: the one legal suspension point of this path — no
        // context is live yet (§5).
        await suspendIfRequested(.readEntry)

        // §16: validate the page-row limit before any context.
        guard limits.pageRowLimitRange.contains(limit) else {
            throw HistoryFailure.invalidInput(.invalidPageLimit)
        }

        // §6 step 1–2: decode the cursor (format version + process marker)
        // and verify the query shape matches. The position check (§6 step 3)
        // runs below inside the same non-suspending interval. A cursor decode
        // or shape failure reads the current position for the
        // `.snapshotExpired(current:)` mapping (§16).
        let recentRequest = HistoryBrowseRequest(kind: .recent, limit: limit)
        let resolvedCursor: ResolvedPageCursor?
        if let cursor = after {
            do {
                resolvedCursor = try Self.decodeCursor(
                    cursor,
                    request: recentRequest,
                    processMarker: processMarker
                )
            } catch is PageCursorRejection {
                // §16: undecodable, marker-mismatched, or shape-mismatched
                // cursor → `.snapshotExpired(current:)`.
                let pos = try readPositionInLocalContext()
                throw HistoryFailure.snapshotExpired(current: pos)
            }
        } else {
            resolvedCursor = nil
        }

        let context = ModelContext(container)
        context.autosaveEnabled = false

        // ── Non-suspending read interval (§5): no `await` past this
        //    line while the context or fetched rows are live. ──

        let positionRow = try Self.fetchExactlyOnePositionRow(in: context)
        let (currentPosition, _) = try Self.decodePositionRow(
            positionRow,
            limits: limits
        )

        // §6 step 3: current durable ChangePosition must equal the cursor
        // position; any intervening commit expires the cursor (§16).
        if let cursor = resolvedCursor {
            guard cursor.position == currentPosition else {
                throw HistoryFailure.snapshotExpired(current: currentPosition)
            }
        }

        // §14.1: scalar-only two-lane fetch. The `propertiesToFetch` selects
        // only the projection fields — no Canonical or revision blob is
        // faulted (§7.5).
        let scalarProperties: [PartialKeyPath<HistoryItemRow>] = [
            \.id,
            \.contentVersionRaw,
            \.title,
            \.effectiveTypeIdentifiersBlob,
            \.lastCopiedAt,
            \.copyCount,
            \.lastSource,
            \.pinOrdinal,
        ]

        // Pinned lane: pinOrdinal != nil, sorted by pinOrdinal ascending.
        var pinnedDescriptor = FetchDescriptor<HistoryItemRow>(
            predicate: #Predicate { $0.pinOrdinal != nil }
        )
        pinnedDescriptor.propertiesToFetch = scalarProperties
        pinnedDescriptor.sortBy = [SortDescriptor(\.pinOrdinal)]
        pinnedDescriptor.fetchLimit = limit + 1
        let pinnedRows: [HistoryItemRow]
        do {
            pinnedRows = try context.fetch(pinnedDescriptor)
        } catch {
            throw HistoryFailure.temporarilyUnavailable(.factProof)
        }

        // Unpinned lane: pinOrdinal == nil, sorted by lastCopiedAt descending.
        var unpinnedDescriptor = FetchDescriptor<HistoryItemRow>(
            predicate: #Predicate { $0.pinOrdinal == nil }
        )
        unpinnedDescriptor.propertiesToFetch = scalarProperties
        unpinnedDescriptor.sortBy = [SortDescriptor(\.lastCopiedAt, order: .reverse)]
        unpinnedDescriptor.fetchLimit = limit + 1
        let unpinnedRows: [HistoryItemRow]
        do {
            unpinnedRows = try context.fetch(unpinnedDescriptor)
        } catch {
            throw HistoryFailure.temporarilyUnavailable(.factProof)
        }

        // EXACTNESS GUARD (§14.1): `\.id` is not trusted to sort at the store
        // level. If a lane's slice is full (limit+1 rows) AND rows[limit-1]
        // and rows[limit] tie on the lane sort key (same lastCopiedAt for the
        // unpinned lane; pinned lane sorts by pinOrdinal which is unique so
        // no tie is possible there), re-fetch that lane with the hard bound
        // and order it fully in memory. Otherwise order the small slice by
        // the full key.
        let pinnedOrdered = try orderPinnedLane(pinnedRows)
        let unpinnedOrdered = try orderUnpinnedLane(unpinnedRows, limit: limit, in: context)

        // Merge lanes: pinned first, then unpinned (03b §8). The continuation
        // anchor drops rows up to and including the anchored row in the
        // computed order (§6).
        let merged: [ScalarReadRow]
        if let anchor = resolvedCursor?.anchor {
            let combined = pinnedOrdered + unpinnedOrdered
            guard let anchorIndex = combined.firstIndex(where: { $0.matches(anchor) }) else {
                // §16: the anchored row is absent — the snapshot expired.
                throw HistoryFailure.snapshotExpired(current: currentPosition)
            }
            merged = Array(combined[(anchorIndex + 1)...])
        } else {
            merged = pinnedOrdered + unpinnedOrdered
        }

        let pageSlice = Array(merged.prefix(limit))
        let rows: [HistoryRow] = try pageSlice.map { scalarRow in
            try scalarRow.toHistoryRow(limits: limits)
        }

        // Mint the next cursor when more rows remain, binding the LAST
        // RETURNED row's `.defaultOrder` anchor (§6).
        let next: HistoryPageCursor?
        if merged.count > limit, let lastReturned = pageSlice.last {
            next = PageCursorCodec.encode(
                ResolvedPageCursor(
                    queryShape: .recent(limit: limit),
                    position: currentPosition,
                    anchor: lastReturned.defaultOrderAnchor
                ),
                processMarker: processMarker
            )
        } else {
            next = nil
        }

        return HistoryPage(position: currentPosition, rows: rows, next: next)
    }

    /// Search corpus capture (docs/05-authority-kernel.md §14.2): captures
    /// the bounded `SearchCorpusSnapshot` (position plus scalar projection
    /// rows) the `SearchWorker` evaluates off-actor, plus the decoded
    /// continuation anchor for a continuation page (`nil` for a first page).
    /// docs/05-authority-kernel.md §14.2; docs/04-coherence.md §6–§7
    ///
    /// Flow: WS12 seam at entry → limit validation → cursor decode+validation
    /// when present → operation-local context → position read → scalar-only
    /// full-corpus fetch bounded by the hard retained-item maximum → default-
    /// order sort → `SearchCorpusSnapshot` + decoded anchor.
    ///
    /// No Canonical/revision blob is decoded (§14.2); only scalar projection
    /// fields plus the small `effectiveTypeIdentifiersBlob`.
    ///
    /// - Throws: `.invalidInput(.invalidPageLimit)` for an out-of-range limit
    ///   (§16); `.snapshotExpired(current:)` for a cursor that is undecodable,
    ///   generation-mismatched, shape-mismatched, or position-mismatched (§16);
    ///   `.temporarilyUnavailable(.factProof)` for a framework fetch failure;
    ///   `.persistence(...)` for decode or invariant failures (§16).
    internal func searchCorpusSnapshot(
        for request: HistoryBrowseRequest
    ) async throws -> (snapshot: SearchCorpusSnapshot, continuationAnchor: StoredOrderingAnchor?) {
        // WS12 seam: the one legal suspension point of this path — no
        // context is live yet (§5).
        await suspendIfRequested(.readEntry)

        // §16: validate the page-row limit before any context.
        guard limits.pageRowLimitRange.contains(request.limit) else {
            throw HistoryFailure.invalidInput(.invalidPageLimit)
        }

        // §6 steps 1–2: decode the cursor and verify shape match. The
        // position check runs inside the interval below.
        let resolvedCursor: ResolvedPageCursor?
        if let cursor = request.after {
            do {
                resolvedCursor = try Self.decodeCursor(
                    cursor,
                    request: request,
                    processMarker: processMarker
                )
            } catch is PageCursorRejection {
                // §16: cursor decode/shape failure → `.snapshotExpired`.
                let pos = try readPositionInLocalContext()
                throw HistoryFailure.snapshotExpired(current: pos)
            }
        } else {
            resolvedCursor = nil
        }

        let context = ModelContext(container)
        context.autosaveEnabled = false

        // ── Non-suspending read interval (§5): no `await` past this
        //    line while the context or fetched rows are live. ──

        let positionRow = try Self.fetchExactlyOnePositionRow(in: context)
        let (currentPosition, _) = try Self.decodePositionRow(
            positionRow,
            limits: limits
        )

        // §6 step 3: position recheck.
        if let cursor = resolvedCursor {
            guard cursor.position == currentPosition else {
                throw HistoryFailure.snapshotExpired(current: currentPosition)
            }
        }

        // §14.2: capture scalar fields for EVERY retained row, bounded by the
        // hard retained-item maximum. Scalar-only — no content blob decode.
        var descriptor = FetchDescriptor<HistoryItemRow>()
        descriptor.propertiesToFetch = [
            \.id,
            \.contentVersionRaw,
            \.title,
            \.searchBody,
            \.effectiveTypeIdentifiersBlob,
            \.lastCopiedAt,
            \.copyCount,
            \.lastSource,
            \.pinOrdinal,
        ]
        descriptor.fetchLimit = limits.hardMaximumRetainedItems + 1
        let rows: [HistoryItemRow]
        do {
            rows = try context.fetch(descriptor)
        } catch {
            throw HistoryFailure.temporarilyUnavailable(.factProof)
        }
        guard rows.count <= limits.hardMaximumRetainedItems else {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        // Build the corpus rows and sort by the default order (pinned ordinal
        // ascending, then lastCopiedAt DESC + id ASC) so exact/regexp preserve
        // the default order (§14.2; 03b §8).
        var corpusRows: [SearchCorpusRow] = []
        corpusRows.reserveCapacity(rows.count)
        for row in rows {
            // Bind the row's scalar values first: the non-Sendable @Model
            // row must not be captured by the `mapCodecFailure` closures
            // (actor-isolated context — sending the row risks data races).
            let identifiersBlob = row.effectiveTypeIdentifiersBlob
            let contentVersionRaw = row.contentVersionRaw
            let rawPinOrdinal = row.pinOrdinal
            let typeIdentifiers = try mapCodecFailure {
                try EffectiveTypeIdentifiersBlobCodec.decode(
                    identifiersBlob,
                    limits: limits
                )
            }
            let contentVersion = try mapCodecFailure {
                try RevisionStateBlobCodec.decodeContentVersion(contentVersionRaw)
            }
            let pinOrdinal = try mapCodecFailure {
                try RevisionStateBlobCodec.decodePinOrdinal(rawPinOrdinal)
            }
            corpusRows.append(SearchCorpusRow(
                id: HistoryItemID(rawValue: row.id),
                contentVersion: contentVersion,
                title: row.title,
                searchBody: row.searchBody,
                typeIdentifiers: typeIdentifiers,
                lastCopiedAt: row.lastCopiedAt,
                copyCount: row.copyCount,
                lastSource: row.lastSource,
                pinOrdinal: pinOrdinal
            ))
        }
        corpusRows.sort { lhs, rhs in
            Self.defaultOrderIsOrdered(lhs, rhs)
        }

        let snapshot = SearchCorpusSnapshot(position: currentPosition, rows: corpusRows)
        return (snapshot, resolvedCursor?.anchor)
    }

    /// Detail (docs/05-authority-kernel.md §14.3; docs/03b-instruction-set.md
    /// §9): fetches exactly one row, decodes/validates its full lineage, and
    /// maps it to the public detail DTO.
    ///
    /// One non-suspending read interval: no WS12 seam — detail is a one-shot
    /// caller query, not an observe-loop step.
    ///
    /// - Throws: `.notFound(id)` when the target is not retained; the codec
    ///   decode mappings (`.persistence(.corruptStoredValue)`, §4/§16);
    ///   `.temporarilyUnavailable(.factProof)` for a framework fetch failure;
    ///   `.persistence(.invariantViolation)` for corrupt lineage
    ///   (`effectiveContent` → `DomainRejection.corruptLineage`).
    internal func details(for id: HistoryItemID) async throws -> HistoryDetails {
        let context = ModelContext(container)
        context.autosaveEnabled = false

        // ── Non-suspending read interval (§5): no `await` past this
        //    line while the context or fetched row is live. ──

        guard let row = try HistoryItemRowHydration.fetchRow(
            businessID: id,
            in: context
        ) else {
            throw HistoryFailure.notFound(id)
        }
        let item = try HistoryItemRowHydration.hydrate(row, limits: limits)

        // Derive current Effective Content (docs/02-domain.md §2.6).
        let effective: EffectiveContent
        do {
            effective = try effectiveContent(of: item)
        } catch is DomainRejection {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        // Map Canonical representations.
        let canonicalRepresentations = item.canonical.representations.map {
            representation in
            HistoryRepresentation(
                typeIdentifier: representation.content.typeIdentifier,
                bytes: representation.content.bytes
            )
        }
        // Map Effective representations.
        let effectiveRepresentations = effective.representations.map {
            representation in
            HistoryRepresentation(
                typeIdentifier: representation.typeIdentifier,
                bytes: representation.bytes
            )
        }
        // Map every stored revision.
        let revisionSummaries = item.revisions.map { revision -> RevisionSummary in
            let revisionTypeIdentifiers = revision.content.representations.map(
                \.typeIdentifier
            )
            let byteCount = revision.content.representations.reduce(0) {
                $0 + $1.bytes.count
            }
            let revisionTitle = ContentProjector.project(
                revision.content,
                limits: limits
            ).title
            return RevisionSummary(
                id: revision.id,
                createdAt: revision.createdAt,
                isActive: revision.id == item.activeRevisionID,
                title: revisionTitle,
                typeIdentifiers: revisionTypeIdentifiers,
                byteCount: byteCount
            )
        }
        let occurrence = CopyOccurrenceSummary(
            firstCopiedAt: item.occurrence.firstCopiedAt,
            lastCopiedAt: item.occurrence.lastCopiedAt,
            count: item.occurrence.count,
            firstSource: item.occurrence.firstSource,
            lastSource: item.occurrence.lastSource
        )
        return HistoryDetails(
            item: HistoryItemReference(
                id: item.id,
                contentVersion: item.contentVersion
            ),
            canonical: canonicalRepresentations,
            effective: effectiveRepresentations,
            revisions: revisionSummaries,
            occurrence: occurrence,
            pinnedPosition: item.pinOrdinal?.rawValue
        )
    }

    /// Paste payload (docs/05-authority-kernel.md §14.3; docs/04-coherence.md
    /// §8): fetches exactly one row, decodes/validates its full lineage, and
    /// maps current Effective Content plus the current reference and lineage
    /// hint.
    ///
    /// One non-suspending read interval: no WS12 seam — paste is a one-shot
    /// caller query, not an observe-loop step.
    ///
    /// - Throws: `.notFound(id)` when the target is not retained; the codec
    ///   decode mappings (`.persistence(.corruptStoredValue)`, §4/§16);
    ///   `.temporarilyUnavailable(.factProof)` for a framework fetch failure;
    ///   `.persistence(.invariantViolation)` for corrupt lineage
    ///   (`effectiveContent` → `DomainRejection.corruptLineage`).
    internal func pastePayload(for id: HistoryItemID) async throws -> PastePayload {
        let context = ModelContext(container)
        context.autosaveEnabled = false

        // ── Non-suspending read interval (§5): no `await` past this
        //    line while the context or fetched row is live. ──

        guard let row = try HistoryItemRowHydration.fetchRow(
            businessID: id,
            in: context
        ) else {
            throw HistoryFailure.notFound(id)
        }
        let item = try HistoryItemRowHydration.hydrate(row, limits: limits)

        let effective: EffectiveContent
        do {
            effective = try effectiveContent(of: item)
        } catch is DomainRejection {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        let representations = effective.representations.map { representation in
            HistoryRepresentation(
                typeIdentifier: representation.typeIdentifier,
                bytes: representation.bytes
            )
        }
        return PastePayload(
            item: HistoryItemReference(
                id: item.id,
                contentVersion: item.contentVersion
            ),
            representations: representations,
            lineageHint: item.id
        )
    }

    // MARK: - Thumbnail source (docs/05-authority-kernel.md §14.5; docs/04-coherence.md §9)

    // Step 8 (step 8 in flight): `StepDeferredError` now remains only in
    // ActorStubs.swift's ThumbnailService, which owns the off-Authority decode
    // (§9 step 6). This method — the Authority side of the thumbnail
    // single-flight — is the WS15 version fence (docs/06-cross-cutting.md §8).

    /// The frozen v1 set of ImageIO-decodable image type identifiers whose
    /// bytes are eligible as thumbnail source input. docs/04-coherence.md §9
    /// ("supported image representation") — the spec does not enumerate the
    /// set; v1 freezes the concrete decodable UTIs (not the abstract
    /// `public.image`, even though CGImageSource sniffs bytes) so the source
    /// representation is a pure, deterministic function of the content with no
    /// framework conformance lookup.
    private static let thumbnailImageTypeIdentifiers: Set<String> = [
        "public.png",
        "public.jpeg",
        "public.tiff",
        "public.heic",
        "public.heif",
        "com.compuserve.gif",
        "public.bmp",
    ]

    /// Thumbnail source (docs/05-authority-kernel.md §14.5; docs/04-coherence.md
    /// §9): verifies the requested Content Version and returns immutable source
    /// image bytes — `nil` when the item has no supported image representation —
    /// inside one non-suspending Authority interval.
    ///
    /// The §9 single-flight flow, steps 1–4 (the Authority's part):
    /// 1. Validate that both `pixels` axes lie in
    ///    `limits.thumbnailDimensionRange` (§9 step 1) — before any context.
    /// 2. Fetch and fully hydrate exactly one row, then require
    ///    `hydrated.contentVersion == item.contentVersion` (§9 step 2) — the
    ///    version fence.
    /// 3. Derive current Effective Content (§9 step 3) — the same pure
    ///    derivation as `details(for:)` and `pastePayload(for:)`.
    /// 4. Select the first representation (in the Effective Content's
    ///    normalized type order) whose type identifier is in the frozen v1
    ///    image set, and return its immutable `bytes` (§9 step 3→4). No match
    ///    → `nil` (§9 step 4) — the facade then answers `nil` without entering
    ///    ThumbnailService.
    ///
    /// "Steps 2–3 run inside one non-suspending `HistoryAuthority` interval,
    /// so no commit can interleave between the version check (step 2) and the
    /// Effective-Content derivation (step 3)" (docs/04-coherence.md §9). The
    /// version fence is therefore about the off-Authority decode (step 6): if
    /// the item changes during decode, the result is still correctly tagged
    /// with the verified old reference. "A request whose reference was already
    /// stale before step 2 fails there with `.staleContent`; current bytes are
    /// never returned under an old key" (docs/04-coherence.md §9).
    ///
    /// - Throws: `.invalidInput(.invalidPixelSize)` when either `pixels` axis
    ///   is outside `limits.thumbnailDimensionRange` (§16); `.notFound(id)`
    ///   when the target is not retained; `.staleContent(expected:current:)`
    ///   when the item's Content Version already differs from the reference's
    ///   OCC token (§16 OCC mapping); the codec decode mappings
    ///   (`.persistence(.corruptStoredValue)`, §4/§16);
    ///   `.temporarilyUnavailable(.factProof)` for a framework fetch failure
    ///   (§16); `.persistence(.invariantViolation)` for corrupt lineage
    ///   (`effectiveContent` → `DomainRejection.corruptLineage`, mirrored from
    ///   `details(for:)`).
    internal func thumbnailSource(
        for item: HistoryItemReference,
        pixels: PixelSize
    ) async throws -> Data? {
        // §9 step 1: validate both dimensions before any context — the fixed
        // Part VI thumbnail-dimension interval (docs/06-cross-cutting.md §2).
        guard limits.thumbnailDimensionRange.contains(pixels.width),
              limits.thumbnailDimensionRange.contains(pixels.height)
        else {
            throw HistoryFailure.invalidInput(.invalidPixelSize)
        }

        let context = ModelContext(container)
        context.autosaveEnabled = false

        // ── Non-suspending read interval (§5; §9 steps 2–3): no `await` past
        //    this line while the context or fetched row is live. No commit can
        //    interleave between the version check and Effective-Content
        //    derivation (docs/04-coherence.md §9). ──

        // §9 step 2: fetch and fully hydrate exactly the target item.
        guard let row = try HistoryItemRowHydration.fetchRow(
            businessID: item.id,
            in: context
        ) else {
            throw HistoryFailure.notFound(item.id)
        }
        let hydrated = try HistoryItemRowHydration.hydrate(row, limits: limits)

        // §9 step 2: the version fence — a reference already stale before this
        // point fails here; current bytes are never returned under an old key.
        guard hydrated.contentVersion == item.contentVersion else {
            throw HistoryFailure.staleContent(
                expected: item.contentVersion,
                current: hydrated.contentVersion
            )
        }

        // §9 step 3: derive current Effective Content — the same pure
        // derivation as `details(for:)`. A lineage inconsistency maps to
        // `.persistence(.invariantViolation)` (mirrors `details(for:)`'s
        // `catch is DomainRejection` → invariant-violation mapping).
        let effective: EffectiveContent
        do {
            effective = try effectiveContent(of: hydrated)
        } catch is DomainRejection {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        // §9 steps 3–4: select the first representation (in the Effective
        // Content's normalized type order) whose type identifier is in the
        // frozen v1 image set. No match → `nil` — the facade answers `nil`
        // without entering ThumbnailService.
        for representation in effective.representations {
            if Self.thumbnailImageTypeIdentifiers.contains(
                representation.typeIdentifier
            ) {
                return representation.bytes
            }
        }
        return nil
    }

    // MARK: - Read-path helpers (docs/05-authority-kernel.md §14; docs/04-coherence.md §6)

    /// Reads the current ChangePosition in a fresh operation-local context
    /// with no suspension — used to supply the `current:` argument of a
    /// `.snapshotExpired` failure raised before the main read interval.
    /// docs/04-coherence.md §6; docs/05-authority-kernel.md §16
    private func readPositionInLocalContext() throws -> ChangePosition {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let positionRow = try Self.fetchExactlyOnePositionRow(in: context)
        let (currentPosition, _) = try Self.decodePositionRow(
            positionRow,
            limits: limits
        )
        return currentPosition
    }

    /// Decodes and validates the cursor's format version, process marker, and
    /// query shape (§6 steps 1–2). The position check (§6 step 3) is deferred
    /// to the caller's non-suspending interval. docs/04-coherence.md §6
    ///
    /// - Throws: `PageCursorRejection` for any decode or marker failure, or a
    ///   shape mismatch (§16). The caller catches this and supplies the
    ///   current position for the `.snapshotExpired(current:)` mapping.
    private static func decodeCursor(
        _ cursor: HistoryPageCursor,
        request: HistoryBrowseRequest,
        processMarker: UUID
    ) throws -> ResolvedPageCursor {
        let resolved = try PageCursorCodec.decode(cursor, processMarker: processMarker)
        guard resolved.queryShape.matches(request) else {
            throw PageCursorRejection.malformedCursor
        }
        return resolved
    }

    /// Default total-order comparison for scalar browse/search rows: pinned
    /// rows first by `pinOrdinal` ascending, then unpinned by `lastCopiedAt`
    /// descending and History Item ID bytes ascending (03b §8; 04 §7).
    private static func defaultOrderIsOrdered(
        _ lhs: SearchCorpusRow,
        _ rhs: SearchCorpusRow
    ) -> Bool {
        switch (lhs.pinOrdinal, rhs.pinOrdinal) {
        case (let l?, let r?):
            // Both pinned: pinOrdinal ascending.
            return l < r
        case (_?, nil):
            // Pinned before unpinned.
            return true
        case (nil, _?):
            // Unpinned after pinned.
            return false
        case (nil, nil):
            // Both unpinned: lastCopiedAt DESC, id ASC.
            if lhs.lastCopiedAt != rhs.lastCopiedAt {
                return lhs.lastCopiedAt > rhs.lastCopiedAt
            }
            return lhs.id < rhs.id
        }
    }
}

// MARK: - Scalar read row helper (docs/05-authority-kernel.md §14.1)

/// One scalar projection row extracted from a fetched `HistoryItemRow`, with
/// the decoded scalar fields `recentPage` needs to assemble a `HistoryRow` and
/// mint the continuation anchor. No `@Model` instance escapes the read
/// interval (§5).
private struct ScalarReadRow {
    private let id: HistoryItemID
    private let contentVersion: ContentVersion
    private let title: String
    private let effectiveTypeIdentifiersBlob: Data
    private let lastCopiedAt: Date
    private let copyCount: UInt64
    private let lastSource: String?
    private let pinOrdinal: PinOrdinal?

    fileprivate init(_ row: HistoryItemRow, limits: HistoryLimits) throws {
        self.id = HistoryItemID(rawValue: row.id)
        self.contentVersion = try mapCodecFailure {
            try RevisionStateBlobCodec.decodeContentVersion(row.contentVersionRaw)
        }
        self.title = row.title
        self.effectiveTypeIdentifiersBlob = row.effectiveTypeIdentifiersBlob
        self.lastCopiedAt = row.lastCopiedAt
        self.copyCount = row.copyCount
        self.lastSource = row.lastSource
        self.pinOrdinal = try mapCodecFailure {
            try RevisionStateBlobCodec.decodePinOrdinal(row.pinOrdinal)
        }
    }

    /// The `.defaultOrder` anchor for this row (04 §6).
    fileprivate var defaultOrderAnchor: StoredOrderingAnchor {
        .defaultOrder(
            pinnedOrdinal: pinOrdinal?.rawValue,
            lastCopiedAt: lastCopiedAt,
            id: id
        )
    }

    /// Whether this row matches the given continuation anchor (04 §6).
    fileprivate func matches(_ anchor: StoredOrderingAnchor) -> Bool {
        switch anchor {
        case .defaultOrder(let pinnedOrdinal, let anchoredLastCopiedAt, let anchoredID):
            return id == anchoredID
                && lastCopiedAt == anchoredLastCopiedAt
                && pinOrdinal?.rawValue == pinnedOrdinal
        case .fuzzyUnpinned:
            // The recent-browse path only produces `.defaultOrder` anchors;
            // a fuzzy anchor never matches here.
            return false
        }
    }

    /// Maps this scalar row to a `HistoryRow`, decoding the small
    /// `effectiveTypeIdentifiersBlob` projection (§14.1: the effective type
    /// identifiers blob decode is a small scalar blob, not a content blob).
    fileprivate func toHistoryRow(limits: HistoryLimits) throws -> HistoryRow {
        let typeIdentifiers = try mapCodecFailure {
            try EffectiveTypeIdentifiersBlobCodec.decode(
                effectiveTypeIdentifiersBlob,
                limits: limits
            )
        }
        return HistoryRow(
            item: HistoryItemReference(id: id, contentVersion: contentVersion),
            title: title,
            typeIdentifiers: typeIdentifiers,
            lastCopiedAt: lastCopiedAt,
            copyCount: copyCount,
            lastSource: lastSource,
            pinnedPosition: pinOrdinal?.rawValue,
            search: nil
        )
    }
}

// MARK: - Lane ordering helpers (docs/05-authority-kernel.md §14.1)

private extension HistoryAuthority {

    /// Orders the pinned lane by the full key `(pinOrdinal ascending)`.
    ///
    /// The pinned lane sorts by `pinOrdinal`, which is unique and contiguous
    /// (D12, proved at startup §13 step 9), so no tie is possible and the
    /// small slice is ordered directly. A full slice (limit+1 rows) is still
    /// safe: `pinOrdinal` alone is a total order over the pinned set.
    func orderPinnedLane(
        _ rows: [HistoryItemRow]
    ) throws -> [ScalarReadRow] {
        // The store already sorted by `\.pinOrdinal`; re-sort in memory to
        // guarantee determinism regardless of store-level tie behavior.
        let sorted = rows.sorted { ($0.pinOrdinal ?? 0) < ($1.pinOrdinal ?? 0) }
        return try sorted.map { try ScalarReadRow($0, limits: limits) }
    }

    /// Orders the unpinned lane by the full key `(lastCopiedAt DESC, id ASC)`.
    ///
    /// EXACTNESS GUARD (§14.1): if the slice is full (limit+1 rows) AND
    /// rows[limit-1] and rows[limit] tie on `lastCopiedAt`, re-fetch the lane
    /// with the hard retained-item bound and order fully in memory; otherwise
    /// order the small slice by the full key. `\.id` is never trusted to sort
    /// at the store level.
    func orderUnpinnedLane(
        _ rows: [HistoryItemRow],
        limit: Int,
        in context: ModelContext
    ) throws -> [ScalarReadRow] {
        // Check whether the store-level sort is insufficient: a full slice
        // with a tie at the page boundary means `\.id` ordering matters.
        let needsFullFetch = rows.count == limit + 1
            && rows.count >= 2
            && rows[limit - 1].lastCopiedAt == rows[limit].lastCopiedAt

        let source: [HistoryItemRow]
        if needsFullFetch {
            var descriptor = FetchDescriptor<HistoryItemRow>(
                predicate: #Predicate { $0.pinOrdinal == nil }
            )
            descriptor.propertiesToFetch = [
                \.id,
                \.contentVersionRaw,
                \.title,
                \.effectiveTypeIdentifiersBlob,
                \.lastCopiedAt,
                \.copyCount,
                \.lastSource,
                \.pinOrdinal,
            ]
            descriptor.fetchLimit = limits.hardMaximumRetainedItems
            do {
                source = try context.fetch(descriptor)
            } catch {
                throw HistoryFailure.temporarilyUnavailable(.factProof)
            }
        } else {
            source = rows
        }

        // Order by the full key: lastCopiedAt DESC, id ASC.
        let sorted = source.sorted { lhs, rhs in
            if lhs.lastCopiedAt != rhs.lastCopiedAt {
                return lhs.lastCopiedAt > rhs.lastCopiedAt
            }
            return HistoryItemID(rawValue: lhs.id) < HistoryItemID(rawValue: rhs.id)
        }
        return try sorted.map { try ScalarReadRow($0, limits: limits) }
    }
}

// MARK: - Failure translation helpers (docs/05-authority-kernel.md §16)

/// Translates a throwing codec/scalar-decode call into the §16 boundary
/// vocabulary: decode rejections are corrupt persisted values, the
/// encode-side backstop is an invariant violation. Errors that are not codec
/// rejections propagate unchanged (there is no stringly-typed re-labeling,
/// §16).
private func mapCodecFailure<T>(_ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let rejection as CodecRejection {
        throw rejection.historyFailure
    } catch let rejection as RevisionStateCodecRejection {
        throw rejection.historyFailure
    }
}

private extension DomainRejection {
    /// The exhaustive docs/02-domain.md §6 → Part III mapping the storage
    /// boundary applies to every planner throw.
    var historyFailure: HistoryFailure {
        switch self {
        case .notFound(let itemID):
            return .notFound(itemID)
        case .staleContent(let expected, let current):
            return .staleContent(expected: expected, current: current)
        case .invalidPinnedPlacement(let failure):
            return .invalidPinnedPlacement(failure)
        case .invalidRevisionDraft:
            return .invalidInput(.incoherentRevisionDraft)
        case .revisionNotFound(let revisionID):
            return .revisionNotFound(revisionID)
        case .corruptLineage:
            return .persistence(.invariantViolation)
        case .capacityExceeded(let kind):
            return .capacityExceeded(kind)
        }
    }
}

private extension SignatureIndexRejection {
    /// The §13 startup mapping (§2, §16): corrupt durable signature metadata
    /// fails open as `.persistence(.corruptStoredValue)` rather than
    /// enabling writes from an unproved state; an over-bound retained count
    /// is an invariant violation. Delta-prevalidation cases are unreachable
    /// from `build(from:limits:)` and map defensively.
    var startupFailure: HistoryFailure {
        switch self {
        case .retainedCountExceedsBound:
            return .persistence(.invariantViolation)
        case .emptySignatureEntries, .duplicateEntry:
            return .persistence(.corruptStoredValue)
        case .additionAlreadyIndexed, .removalNotIndexed, .overlappingAdditionAndRemoval:
            return .persistence(.invariantViolation)
        }
    }
}
