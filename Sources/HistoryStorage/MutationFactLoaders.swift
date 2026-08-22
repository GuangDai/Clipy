/// Fact loading for the mutation actions of roadmap step 6 — pin/unpin,
/// revision, remove, clear, and retention (docs/roadmap/03-historystorage.md
/// "Step 6 — mutations").
/// Owning spec: docs/05-authority-kernel.md §7.2 (pin/unpin complete fact
/// loading), §7.3 (revision, remove, clear, retention), §5 (context
/// confinement — bounded business-ID fetch, never `registeredModel(for:)`),
/// §16 (failure translation); docs/02-domain.md §5.2 (CompletePinnedOrder
/// and PinFacts), §5.3 (RevisionFacts), §5.4 (RemoveFacts — amended by
/// AUDIT IMP6-01 — and ClearFacts), §5.5 (RetentionFacts), §3.2
/// (PinOrdinal), D12 (contiguous pin order).
///
/// Every function here is synchronous and runs inside one serialized
/// `HistoryAuthority` interval on an operation-local `ModelContext`
/// (docs/05 §5): there is no `await` while a context, fetched row, complete
/// fact, or commit plan is live, and no row or context is retained after
/// return. The loaders reuse the shared `HistoryItemRowHydration` helpers
/// (FactLoaders.swift) rather than re-implementing row→Domain hydration, so
/// failures arrive already mapped to the public §16 vocabulary: codec
/// rejections via their `historyFailure`, framework fetch failures as
/// `.temporarilyUnavailable(.factProof)` (completeness cannot be proven),
/// and durable-state invariant violations as
/// `.persistence(.invariantViolation)`. These loaders add only the
/// action-specific proofs: the D12 unique-contiguous pinned-order check
/// (§7.2 — stored corruption fails; no loader performs an implicit repair)
/// and the revision target's `.notFound` (docs/02 §5.3, §16).
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData

// MARK: - Mutation fact loading (docs/05-authority-kernel.md §7.2–§7.3)

/// The complete fact loaders for the pin, unpin, revision, remove, clear,
/// and retention actions. docs/05-authority-kernel.md §7.2–§7.3
///
/// One namespace of synchronous static functions; each loads exactly the
/// complete fact the action's Domain planner reads (docs/02-domain.md §8 —
/// the compiler-visible planner signature documents which complete proof
/// each operation needs) and nothing else. There is no generic partial map
/// (§7): a loader either constructs the complete value or fails the History
/// Action before planning.
internal enum MutationFactLoaders {
    // MARK: Pinned-order facts (docs/05-authority-kernel.md §7.2)

    /// Loads the complete pinned order: every pinned retained item's ID in
    /// ordinal order, shared by the pin, unpin, and remove loads.
    /// docs/05-authority-kernel.md §7.2 ("Fetch ... every row with a
    /// non-nil pin ordinal. Validate unique contiguous order"); construction
    /// guarantees: docs/02-domain.md §5.2 (`CompletePinnedOrder`), §3.2,
    /// D12.
    ///
    /// The load derives from the complete retention inventory — already
    /// bounded by the hard retained-item maximum, duplicate-ID checked, and
    /// scalar-only (§7.3: "All collection-wide loads are bounded by the
    /// hard retained-item maximum") — filters to summaries with a non-nil
    /// pin ordinal, and places IDs directly into ordinal slots. Per-row
    /// non-negativity was already proven by the scalar decode
    /// (`decodePinOrdinal`, §4); this loader adds the collection-wide D12
    /// proof that ordinals are unique and exactly `0 ..< count`, using the
    /// same linear permutation validator as the §13 step-9 startup proof and
    /// the §10 final-order revalidation. A malformed stored order is a
    /// persistence invariant failure — the loader never repairs (§7.2,
    /// docs/02 §5.2: "the planner does not guess a repair").
    ///
    /// - Parameters:
    ///   - context: the operation-local `ModelContext` created by
    ///     `HistoryAuthority` for this commit interval (§5).
    ///   - limits: the fixed `HistoryLimits.standard` safety profile
    ///     (docs/06-cross-cutting.md §2).
    /// - Throws: `.temporarilyUnavailable(.factProof)` when the inventory
    ///   fetch cannot complete (docs/02 §5.1, §16);
    ///   `.persistence(.corruptStoredValue)` for a corrupt stored scalar
    ///   (§4); `.persistence(.invariantViolation)` for an over-bound
    ///   retained count, a duplicate business ID, or a malformed stored
    ///   pinned order (§7.2, D12).
    internal static func loadCompletePinnedOrder(
        in context: ModelContext,
        limits: HistoryLimits = .standard
    ) throws -> CompletePinnedOrder {
        let inventory = try HistoryItemRowHydration.fetchRetainedInventory(
            in: context,
            limits: limits
        )
        var pinned: [(ordinal: Int, id: HistoryItemID)] = []
        pinned.reserveCapacity(inventory.count)
        for summary in inventory {
            guard let pinOrdinal = summary.pinOrdinal else { continue }
            pinned.append((ordinal: pinOrdinal.rawValue, id: summary.id))
        }
        // D12 (docs/02-domain.md §3.2, §5.2): unique and exactly
        // 0 ..< count. The same linear slot proof is shared with startup and
        // final transaction validation, while this caller keeps its existing
        // persistence-invariant failure mapping.
        guard let sourceOffsets = PinnedOrderValidator.sourceOffsetsByOrdinal(
            in: pinned,
            ordinal: { $0.ordinal }
        ) else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return CompletePinnedOrder(itemIDs: sourceOffsets.map { pinned[$0].id })
    }

    /// Loads the complete facts pin placement and unpin planning require:
    /// target existence plus the complete pinned order.
    /// docs/05-authority-kernel.md §7.2 ("Fetch target existence plus every
    /// row with a non-nil pin ordinal"); construction guarantees:
    /// docs/02-domain.md §5.2 (`PinFacts`); WS8 (docs/06-cross-cutting.md
    /// §8).
    ///
    /// Existence is the shared hydration helper's bounded business-ID fetch
    /// (§5: exactly zero or one row is valid; a duplicate is persistence
    /// corruption). An absent target is data, not a loader failure:
    /// `targetExists` is `false` and planning rejects it
    /// (`DomainRejection.notFound` / `.invalidPinnedPlacement`,
    /// docs/02 §10 step 1, WS16).
    ///
    /// - Parameters:
    ///   - itemID: the public pin/unpin target.
    ///   - context: the operation-local `ModelContext` (§5).
    ///   - limits: the fixed `HistoryLimits.standard` safety profile
    ///     (docs/06-cross-cutting.md §2).
    /// - Throws: the `fetchRow` / `loadCompletePinnedOrder` §16 mappings —
    ///   `.temporarilyUnavailable(.factProof)`,
    ///   `.persistence(.corruptStoredValue)`, or
    ///   `.persistence(.invariantViolation)`.
    internal static func loadPinFacts(
        itemID: HistoryItemID,
        in context: ModelContext,
        limits: HistoryLimits = .standard
    ) throws -> PinFacts {
        let targetExists = try HistoryItemRowHydration.fetchRow(
            businessID: itemID,
            in: context
        ) != nil
        let order = try loadCompletePinnedOrder(in: context, limits: limits)
        return PinFacts(targetExists: targetExists, order: order)
    }

    // MARK: Revision facts (docs/05-authority-kernel.md §7.3)

    /// Loads the complete lineage of the revision target — exactly the one
    /// item revision planning reads. docs/05-authority-kernel.md §7.3
    /// ("Revision fetches and decodes exactly the target item");
    /// construction guarantees: docs/02-domain.md §5.3 (`RevisionFacts`:
    /// "the complete target lineage or `notFound`"); WS6/WS7
    /// (docs/06-cross-cutting.md §8).
    ///
    /// The row is fetched by the shared helper's bounded business-ID
    /// predicate and fully hydrated through the step-4 versioned codecs —
    /// every §4 decode check, including D3 active-ID coherence and the
    /// bidirectional fingerprint/signature coverage check. A missing row is
    /// not a partial fact: §16 maps missing rows to `.notFound`, so the
    /// loader throws `HistoryFailure.notFound(itemID)` itself rather than
    /// synthesizing an empty lineage (docs/02 §5.3: "it does not
    /// synthesize a missing active revision").
    ///
    /// - Parameters:
    ///   - itemID: the public revision target.
    ///   - context: the operation-local `ModelContext` (§5).
    ///   - limits: the fixed `HistoryLimits.standard` safety profile
    ///     (docs/06-cross-cutting.md §2).
    /// - Throws: `.notFound(itemID)` when no retained row carries the ID
    ///   (§16, docs/02 §5.3); otherwise the `fetchRow` / `hydrate` §16
    ///   mappings — `.temporarilyUnavailable(.factProof)`,
    ///   `.persistence(.corruptStoredValue)`, or
    ///   `.persistence(.invariantViolation)`.
    internal static func loadRevisionFacts(
        itemID: HistoryItemID,
        in context: ModelContext,
        limits: HistoryLimits = .standard
    ) throws -> RevisionFacts {
        guard let row = try HistoryItemRowHydration.fetchRow(
            businessID: itemID,
            in: context
        ) else {
            // docs/02-domain.md §5.3: the loader returns the complete
            // lineage or notFound; §16: missing rows → .notFound.
            throw HistoryFailure.notFound(itemID)
        }
        return RevisionFacts(
            item: try HistoryItemRowHydration.hydrate(row, limits: limits)
        )
    }

    // MARK: Remove and clear facts (docs/05-authority-kernel.md §7.3)

    /// Loads the complete facts removal planning requires: the target's
    /// scalar summary plus the complete pinned order (the §7.2 load).
    /// docs/05-authority-kernel.md §7.3; construction guarantees:
    /// docs/02-domain.md §5.4 (`RemoveFacts`, amended by AUDIT IMP6-01:
    /// removing a pinned item compacts the pinned lane in the same commit —
    /// docs/02 §10, D12 — which a target-only fact cannot plan); WS16
    /// (docs/06-cross-cutting.md §8).
    ///
    /// An absent target is data, not a loader failure: `item` is `nil` and
    /// planning rejects it with `.notFound` (docs/02 §5.4). The scalar
    /// summary is the retention-relevant projection (`id`,
    /// `lastCopiedAt`, validated non-negative pin ordinal) — no Canonical
    /// or revision blob is decoded for a removal. The pinned order is
    /// loaded even when the target turns out unpinned, so the one commit
    /// can compact the lane whenever the target is pinned.
    ///
    /// - Parameters:
    ///   - itemID: the public removal target.
    ///   - context: the operation-local `ModelContext` (§5).
    ///   - limits: the fixed `HistoryLimits.standard` safety profile
    ///     (docs/06-cross-cutting.md §2).
    /// - Throws: the `fetchRow` / `retainedSummary` /
    ///   `loadCompletePinnedOrder` §16 mappings —
    ///   `.temporarilyUnavailable(.factProof)`,
    ///   `.persistence(.corruptStoredValue)`, or
    ///   `.persistence(.invariantViolation)`.
    internal static func loadRemoveFacts(
        itemID: HistoryItemID,
        in context: ModelContext,
        limits: HistoryLimits = .standard
    ) throws -> RemoveFacts {
        var item: RetainedItemSummary?
        if let row = try HistoryItemRowHydration.fetchRow(
            businessID: itemID,
            in: context
        ) {
            item = try HistoryItemRowHydration.retainedSummary(of: row)
        }
        let pinnedOrder = try loadCompletePinnedOrder(
            in: context,
            limits: limits
        )
        return RemoveFacts(item: item, pinnedOrder: pinnedOrder)
    }

    /// Loads every ID/pin value selected by the requested scope.
    /// docs/05-authority-kernel.md §7.3 ("Clear fetches every ID/pin value
    /// selected by scope"); construction guarantees: docs/02-domain.md §5.4
    /// (`ClearFacts.affected` is the complete set selected by the requested
    /// scope at the Authority linearization point — "There is no partial
    /// clear"); WS10 (docs/06-cross-cutting.md §8).
    ///
    /// The complete retention inventory — already bounded by the hard
    /// retained-item maximum, duplicate-ID checked, and sorted by History
    /// Item ID, which keeps the fact deterministic (D16) — is filtered by
    /// scope: `.all` selects the whole inventory, `.unpinned` only the
    /// summaries with a nil pin ordinal. Both v1 scopes leave the surviving
    /// pinned lane trivially contiguous, so a clear needs no pinned-order
    /// fact (docs/02 §5.4, D12).
    ///
    /// - Parameters:
    ///   - scope: the public `ClearScope` of the action.
    ///   - context: the operation-local `ModelContext` (§5).
    ///   - limits: the fixed `HistoryLimits.standard` safety profile
    ///     (docs/06-cross-cutting.md §2).
    /// - Throws: the `fetchRetainedInventory` §16 mappings —
    ///   `.temporarilyUnavailable(.factProof)`,
    ///   `.persistence(.corruptStoredValue)`, or
    ///   `.persistence(.invariantViolation)`.
    internal static func loadClearFacts(
        scope: ClearScope,
        in context: ModelContext,
        limits: HistoryLimits = .standard
    ) throws -> ClearFacts {
        let inventory = try HistoryItemRowHydration.fetchRetainedInventory(
            in: context,
            limits: limits
        )
        let affected: [RetainedItemSummary]
        switch scope {
        case .all:
            affected = inventory
        case .unpinned:
            affected = inventory.filter { $0.pinOrdinal == nil }
        }
        return ClearFacts(affected: affected)
    }

    // MARK: Retention facts (docs/05-authority-kernel.md §7.3)

    /// Loads the complete facts retention planning requires: the complete
    /// retained inventory plus the policy the Authority decoded from the
    /// position singleton. docs/05-authority-kernel.md §7.3 ("Retention
    /// fetches every retained ID, last-copied time, and pin ordinal");
    /// construction guarantees: docs/02-domain.md §5.5 (`RetentionFacts`);
    /// WS21 (docs/06-cross-cutting.md §8).
    ///
    /// The policy is a caller input, not a store-side fact this loader
    /// proves: the Authority decodes it from the §3.2 singleton — the one
    /// authoritative retention value, validated against the fixed Part VI
    /// user range — in the same serialized interval and passes it in. The
    /// loader proves only the store-side inventory: every retained item's
    /// ID, last-copied time, and pin ordinal exactly once, bounded by the
    /// hard retained-item maximum (§7.3: "A loader never labels an
    /// incomplete result as complete").
    ///
    /// - Parameters:
    ///   - currentPolicy: the authoritative retention policy the Authority
    ///     decoded from the position singleton (§3.2).
    ///   - context: the operation-local `ModelContext` (§5).
    ///   - limits: the fixed `HistoryLimits.standard` safety profile
    ///     (docs/06-cross-cutting.md §2).
    /// - Throws: the `fetchRetainedInventory` §16 mappings —
    ///   `.temporarilyUnavailable(.factProof)`,
    ///   `.persistence(.corruptStoredValue)`, or
    ///   `.persistence(.invariantViolation)`.
    internal static func loadRetentionFacts(
        currentPolicy: RetentionPolicy,
        in context: ModelContext,
        limits: HistoryLimits = .standard
    ) throws -> RetentionFacts {
        let inventory = try HistoryItemRowHydration.fetchRetainedInventory(
            in: context,
            limits: limits
        )
        return RetentionFacts(
            inventory: CompleteRetentionInventory(allItems: inventory),
            currentPolicy: currentPolicy
        )
    }
}
