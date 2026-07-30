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
/// `await` is legal — never inside a commit/read interval (§5). A later
/// roadmap step adds its own point (WS12's registration/query seam at
/// step 7) as its path lands.
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

    // MARK: - Step-deferred surface (docs/roadmap/03-historystorage.md steps 7–8)

    // The following Authority methods pin the signatures their step-7–8
    // implementations will have — the `SwiftDataHistory` facade already
    // dispatches to them (Part V §14) — and throw `StepDeferredError`
    // (defined in SwiftDataHistory.swift), exactly like the sibling stubs in
    // ActorStubs.swift. They are replaced, not wrapped, by the real
    // implementations; each reuses this file's non-suspending read-interval
    // spine (§5, §14).

    /// Step 7 (docs/05-authority-kernel.md §14.1): recent browse — one
    /// non-suspending interval reading the position and at most `limit + 1`
    /// scalar projection rows, with cursor validation and expiry.
    internal func recentPage(
        limit: Int,
        after: HistoryPageCursor?
    ) async throws -> HistoryPage {
        throw StepDeferredError.notYetImplemented(operation: "recentPage")
    }

    /// Step 7 (docs/05-authority-kernel.md §14.2): captures the bounded
    /// `SearchCorpusSnapshot` (position plus scalar projection rows) the
    /// `SearchWorker` evaluates off-actor.
    internal func searchCorpusSnapshot(
        for request: HistoryBrowseRequest
    ) async throws -> SearchCorpusSnapshot {
        throw StepDeferredError.notYetImplemented(operation: "searchCorpusSnapshot")
    }

    /// Step 7 (docs/05-authority-kernel.md §14.3): detail — fetches exactly
    /// one row, decodes/validates its full lineage, and maps it to the
    /// public detail DTO.
    internal func details(for id: HistoryItemID) async throws -> HistoryDetails {
        throw StepDeferredError.notYetImplemented(operation: "details")
    }

    /// Step 7 (docs/05-authority-kernel.md §14.3): paste — maps current
    /// Effective Content plus the current reference and lineage hint.
    internal func pastePayload(for id: HistoryItemID) async throws -> PastePayload {
        throw StepDeferredError.notYetImplemented(operation: "pastePayload")
    }

    /// Step 8 (docs/05-authority-kernel.md §14.5; docs/04-coherence.md §9):
    /// verifies the requested Content Version and returns immutable source
    /// image bytes (`nil` when the item has no supported image
    /// representation) inside one non-suspending interval — the version
    /// fence the off-Authority decode relies on.
    internal func thumbnailSource(
        for item: HistoryItemReference,
        pixels: PixelSize
    ) async throws -> Data? {
        throw StepDeferredError.notYetImplemented(operation: "thumbnailSource")
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
