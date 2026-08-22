/// SignatureIndex — the in-memory dedup-candidate acceleration structure with
/// its two-state lifecycle, owned as value state by `HistoryAuthority`.
/// Owning spec: docs/05-authority-kernel.md §12 (Signature Index lifecycle),
/// §13 (startup), §7.1 (capture fact loading), §9/§11 (delta prevalidation
/// and post-commit application), §16 (failure translation); candidacy
/// semantics: docs/02-domain.md §9.1; bounds: docs/06-cross-cutting.md §2;
/// WS5 (rebuild failure): docs/06-cross-cutting.md §8.
///
/// The index is a pure value type — no actor of its own, no I/O, and never a
/// second persistence authority (§12: "The index is actor-owned value state,
/// not a second persistence authority"). Index readiness may affect capture
/// availability, never browse/detail/paste correctness (§12).
import Foundation
import HistoryCore
import HistoryDomain

// MARK: - Rejection vocabulary (docs/05-authority-kernel.md §12–§13)

/// Rejection of Signature Index construction or delta prevalidation.
/// docs/05-authority-kernel.md §12
///
/// Thrown only by `build(from:limits:)` and `validate(_:)` — the two proving
/// points. Post-commit `apply(_:)` is nonthrowing (§11): the same conditions
/// are rechecked there as internal assertions, and any detected divergence
/// marks the index unready instead of throwing after durable commit.
///
/// Mapping at the `SwiftDataHistory` boundary (§16): a build failure on the
/// startup path (§13 step 8) fails `open` — corrupt durable signature
/// metadata fails open rather than enabling writes from an unproved state; a
/// build failure on the capture-time rebuild path (§7.1 step 1) means the
/// index could not be rebuilt to a proved-complete state and maps to
/// `.temporarilyUnavailable(.dedupIndexRebuild)` — the WS5 path
/// (docs/06-cross-cutting.md §8). A prevalidation failure happens before any
/// durable write and is an internal invariant violation.
internal enum SignatureIndexRejection: Error, Sendable, Equatable {
    /// Construction input exceeds the Part VI hard retained-item bound; both
    /// construction paths are bounded by the retained count (§7.1 step 1,
    /// §13 step 5; docs/06-cross-cutting.md §2).
    case retainedCountExceedsBound(found: Int, bound: Int)

    /// An item contributed zero signature entries; every retained row
    /// contributes every Canonical signature entry, and Canonical Content is
    /// non-empty (§12; docs/02-domain.md §2.3).
    case emptySignatureEntries(item: HistoryItemID)

    /// One item's entry list contains the same entry twice; entries derive
    /// one-to-one from a normalized Canonical representation set, so a valid
    /// row cannot produce a duplicate (§12: "every retained row contributes
    /// every Canonical signature entry exactly once"; §4).
    case duplicateEntry(item: HistoryItemID, typeIdentifier: String)

    /// One item contributes more than one entry for the same Canonical type,
    /// even when fingerprint/count evidence differs (§2.1, §12).
    case duplicateTypeIdentifier(item: HistoryItemID, typeIdentifier: String)

    /// A create delta names an item that already has postings (§12: "Create
    /// adds all entries" — for a new row, never an existing one).
    case additionAlreadyIndexed(HistoryItemID)

    /// A delete delta names an item with no postings to remove (§12: "delete
    /// removes all entries and empty postings").
    case removalNotIndexed(HistoryItemID)

    /// One delta lists the same item as both an addition and a removal; the
    /// §9 stamping rules never produce that.
    case overlappingAdditionAndRemoval(HistoryItemID)
}

// MARK: - SignatureIndex (docs/05-authority-kernel.md §12)

/// The Signature Index: an in-memory ContentSignatureEntry → retained
/// HistoryItemID posting map with an `.unready` / `.ready`
/// lifecycle. docs/05-authority-kernel.md §12
///
/// Ready means every retained row contributes every Canonical signature entry
/// exactly once (§12). The index only accelerates dedup candidacy:
/// fingerprints may collide, so full content confirmation remains mandatory
/// for every candidate (§12, D7; docs/02-domain.md §9.2), and the Domain ever
/// sees only `CompleteDedupCandidates`, never this index (docs/02-domain.md
/// §9.1).
///
/// Lifecycle: `HistoryAuthority` starts with `init()` (unready); `open`
/// replaces it with the §13 step-8 `build(from:limits:)` result; a capture
/// fact load finding `.unready` attempts one complete rebuild through the
/// same `build` (§7.1 step 1); commits mutate it only through the
/// prevalidated `apply(_:)` delta (§9, §11); detected divergence or an
/// unprovable fact load marks it unready again. There is no partial repair
/// path (§13).
internal struct SignatureIndex: Sendable, Equatable {

    /// Lifecycle state. docs/05-authority-kernel.md §12
    ///
    /// Readiness is sufficient because every fact load and plan→transaction→
    /// apply sequence is one non-suspending `HistoryAuthority` interval; a
    /// counter could not add an independent interleaving proof (§5, §7.1).
    internal enum State: Sendable, Equatable {
        case unready
        case ready
    }

    /// The current lifecycle state (§12). Readable by the owning Authority
    /// and its fact loaders; transitions happen only by wholesale `build`
    /// replacement, `apply(_:)`, or `markUnready()`.
    internal private(set) var state: State

    /// ContentSignatureEntry → retained HistoryItemID posting set (§12).
    ///
    /// The posting key is the complete entry — type identifier, fingerprint
    /// evidence, and byte count. For correctly derived metadata, equal bytes
    /// have equal xxh3 and length, so the full key does not drop a true
    /// candidate; a fingerprint collision can only add a candidate that
    /// mandatory byte confirmation then rejects (§12, D7). The current
    /// hard-capped startup and unready-index rebuild paths recompute xxh3 from
    /// Canonical bytes before publishing this value (DATA-11), so a ready
    /// index may use absence as negative evidence. Ordinary signature decode
    /// remains only structural validation and never establishes that proof.
    private var postings: [ContentSignatureEntry: Set<HistoryItemID>]

    /// Reverse map: retained item → its complete signature entry list,
    /// maintained in lockstep with `postings`. Delete deltas carry only the
    /// item ID (§9 `SignatureIndexDelta.removals`), so removal needs the
    /// item's entries to delete every posting and every emptied posting set
    /// (§12).
    private var entriesByItem: [HistoryItemID: [ContentSignatureEntry]]

    /// Exact retained-ID coverage, maintained with both maps so a capture fact
    /// load does not materialize another O(N) set.
    private var indexedItemIDs: Set<HistoryItemID>

    /// A fresh, unready index (§12 `.unready`). `HistoryAuthority` creates
    /// this on entry; `open` (§13) or the capture-time rebuild (§7.1 step 1)
    /// replaces it with a `build(from:limits:)` result.
    internal init() {
        state = .unready
        postings = [:]
        entriesByItem = [:]
        indexedItemIDs = []
    }

    /// Designated initializer from already-validated maps.
    private init(
        state: State,
        postings: [ContentSignatureEntry: Set<HistoryItemID>],
        entriesByItem: [HistoryItemID: [ContentSignatureEntry]],
        indexedItemIDs: Set<HistoryItemID>
    ) {
        self.state = state
        self.postings = postings
        self.entriesByItem = entriesByItem
        self.indexedItemIDs = indexedItemIDs
    }

    // MARK: Complete construction (§13 step 8; §7.1 step 1)

    /// Builds a complete, ready index from the decoded signature metadata of
    /// every retained row — the one proving point shared by §13 step-8
    /// startup construction and the §7.1 step-1 capture-time rebuild.
    ///
    /// `signatures` must contain every retained row exactly once: the current
    /// hard-capped callers decode Canonical/signature blobs and recompute xxh3
    /// coverage before passing entries here. Startup constructs postings
    /// before declaring ready and never decodes revision bytes merely to build
    /// the index (§12–§13). An empty dictionary builds an empty ready index,
    /// valid only for an empty retained store (§12); the caller passes the
    /// complete retained set, and every capture fact load re-verifies index
    /// coverage against the fetched retained IDs before constructing
    /// `IngestFacts` (§7.1 step 6).
    ///
    /// - Throws: `SignatureIndexRejection` when completeness cannot be proved
    ///   — the input exceeds the hard retained-item bound, or an entry list
    ///   no valid row could produce. Blob decode failures surface earlier as
    ///   `CodecRejection` from `SignatureBlobCodec.decode`.
    internal static func build(
        from signatures: [HistoryItemID: [ContentSignatureEntry]],
        limits: HistoryLimits = .standard
    ) throws -> SignatureIndex {
        guard signatures.count <= limits.hardMaximumRetainedItems else {
            throw SignatureIndexRejection.retainedCountExceedsBound(
                found: signatures.count,
                bound: limits.hardMaximumRetainedItems
            )
        }
        var postings: [ContentSignatureEntry: Set<HistoryItemID>] = [:]
        postings.reserveCapacity(signatures.values.reduce(0) { $0 + $1.count })
        var entriesByItem: [HistoryItemID: [ContentSignatureEntry]] = [:]
        entriesByItem.reserveCapacity(signatures.count)
        for (itemID, entries) in signatures {
            try checkEntryList(entries, for: itemID)
            entriesByItem[itemID] = entries
            for entry in entries {
                postings[entry, default: []].insert(itemID)
            }
        }
        return SignatureIndex(
            state: .ready,
            postings: postings,
            entriesByItem: entriesByItem,
            indexedItemIDs: Set(signatures.keys)
        )
    }

    // MARK: Candidate lookup (docs/02-domain.md §9.1; §7.1 steps 2 and 6)

    /// The complete set of retained item IDs currently indexed.
    /// docs/05-authority-kernel.md §12
    ///
    /// A capture fact load compares this against the fetched retained ID set
    /// before constructing `IngestFacts` (§7.1 step 6) — the standing check
    /// behind §12's "an empty ready index is valid only for an empty retained
    /// store" and "every fact-load checks that candidate IDs remain retained
    /// in its serialized Authority interval".
    internal var itemIDs: Set<HistoryItemID> {
        indexedItemIDs
    }

    /// The number of retained items currently indexed.
    /// docs/05-authority-kernel.md §12
    internal var itemCount: Int { entriesByItem.count }

    /// Intersects the posting sets of all incoming signature entries: the
    /// complete Canonical-containment candidate ID set when the index is
    /// ready and complete (docs/02-domain.md §9.1;
    /// docs/05-authority-kernel.md §7.1 step 2).
    ///
    /// Returns `nil` when unready — candidacy is unprovable, and the caller
    /// follows §7.1 step 1 (attempt one complete rebuild, else fail capture
    /// with `.temporarilyUnavailable(.dedupIndexRebuild)`) instead of ever
    /// planning from a partial set. An empty `entries` list yields `nil`:
    /// unreachable in production (Canonical Content is non-empty,
    /// docs/02-domain.md §2.3) and treated as unprovable rather than a
    /// vacuously complete candidate set. A missing posting
    /// set intersects as empty — no retained item can byte-confirm an entry
    /// it does not post. The smallest posting is copied first, then intersected
    /// with every other posting. Input order therefore cannot make the scratch
    /// set larger than the narrowest posting (`O(min posting)` space instead of
    /// `O(first posting)`); the complete intersection is unchanged. Completeness,
    /// not correctness of any single match, is what this proves: every returned
    /// ID still requires full content confirmation (docs/02-domain.md §9.2) and
    /// the §7.1 step-6 agreement check against retained IDs.
    internal func candidateIDs(
        matching entries: [ContentSignatureEntry]
    ) -> Set<HistoryItemID>? {
        guard case .ready = state else { return nil }
        guard !entries.isEmpty else { return nil }

        // A missing posting proves the whole intersection empty without
        // allocating a candidate set. Otherwise select the narrowest posting
        // in one bounded representation pass (A <= 32, Part VI §2). Copy-on-
        // write then materializes at most that posting when the first
        // intersection mutates it.
        var smallestIndex = entries.startIndex
        var smallestPosting: Set<HistoryItemID>?
        for index in entries.indices {
            guard let posting = postings[entries[index]] else { return [] }
            guard let currentSmallest = smallestPosting else {
                smallestIndex = index
                smallestPosting = posting
                continue
            }
            if posting.count < currentSmallest.count {
                smallestIndex = index
                smallestPosting = posting
            }
        }
        guard var candidates = smallestPosting else { return [] }

        for index in entries.indices where index != smallestIndex {
            guard !candidates.isEmpty else { break }
            // Every posting was proved present in the selection pass above.
            // The defensive fallback remains an empty intersection if the
            // implementation ever drifts despite value isolation.
            candidates.formIntersection(postings[entries[index]] ?? [])
        }
        return candidates
    }

    // MARK: Delta prevalidation and application (§9; §11)

    /// Proves a stamped plan's index delta can be applied after the durable
    /// transaction without failing — §9 "prevalidate its index delta", §11
    /// "the delta is precomputed and checked before the transaction so
    /// ordinary dictionary application cannot fail after durable commit".
    /// docs/05-authority-kernel.md §9
    ///
    /// When the index is ready: additions and removals must be disjoint,
    /// every addition must name an unindexed item with a well-formed
    /// non-empty entry list, and every removal must name an indexed item.
    /// When the index is unready there is nothing to prove — `apply(_:)` is
    /// a no-op on an unready index and the next capture rebuilds from durable
    /// signature blobs (§11) — so remove/clear/retention commits never depend
    /// on readiness: readiness gates capture availability only (§12).
    ///
    /// - Throws: `SignatureIndexRejection` on the first unprovable condition.
    internal func validate(_ delta: SignatureIndexDelta) throws {
        guard case .ready = state else { return }
        try checkDelta(delta)
    }

    /// Applies an already validated delta after transaction success —
    /// nonthrowing, §11 post-commit step 1. Index deltas exist only for
    /// create and delete because Canonical Content never changes (§11).
    /// docs/05-authority-kernel.md §11
    ///
    /// On an unready index this is a no-op: the committed durable state
    /// remains authoritative and the next capture completes a full rebuild
    /// before deciding insert/coalesce (§11).
    ///
    /// Every prevalidated condition is rechecked as an internal assertion; if
    /// one nevertheless detects divergence the index is marked unready (the
    /// caller still invalidates observers, and the committed state stays
    /// authoritative, §11). Removals delete all of the item's entries and
    /// every emptied posting set (§12); additions insert every entry. A valid
    /// delta preserves `.ready`; Authority isolation is the interleaving proof.
    internal mutating func apply(_ delta: SignatureIndexDelta) {
        guard case .ready = state else { return }
        do {
            try checkDelta(delta)
        } catch {
            markUnready()
            return
        }
        for itemID in delta.removals {
            guard let entries = entriesByItem.removeValue(forKey: itemID) else {
                markUnready()
                return
            }
            guard indexedItemIDs.remove(itemID) != nil else {
                markUnready()
                return
            }
            for entry in entries {
                guard var posting = postings[entry],
                      posting.remove(itemID) != nil
                else {
                    markUnready()
                    return
                }
                if posting.isEmpty {
                    postings.removeValue(forKey: entry)
                } else {
                    postings[entry] = posting
                }
            }
        }
        for (itemID, entries) in delta.additions {
            entriesByItem[itemID] = entries
            guard indexedItemIDs.insert(itemID).inserted else {
                markUnready()
                return
            }
            for entry in entries {
                postings[entry, default: []].insert(itemID)
            }
        }
        state = .ready
    }

    /// Drops readiness and every posting (§12 `.unready`; §11 divergence
    /// path). docs/05-authority-kernel.md §12
    ///
    /// Called by `apply(_:)` when an internal assertion detects divergence and
    /// by `HistoryAuthority` when a fact load proves the index incomplete;
    /// WS5 forces this state to prove the rebuild-failure path
    /// (docs/06-cross-cutting.md §8). Recovery is always a complete
    /// `build(from:limits:)` from durable signature blobs — there is no
    /// silent repair path (§13) — and the committed durable state remains
    /// authoritative throughout (§11).
    internal mutating func markUnready() {
        state = .unready
        postings.removeAll()
        entriesByItem.removeAll()
        indexedItemIDs.removeAll()
    }

    // MARK: Shared delta and entry-list checks (§9, §12)

    /// The single structural proof shared by pre-transaction validation and
    /// post-commit defensive revalidation. Keeping the checks here prevents
    /// the two passes required by §11 from drifting apart.
    private func checkDelta(_ delta: SignatureIndexDelta) throws {
        for itemID in delta.removals where delta.additions[itemID] != nil {
            throw SignatureIndexRejection.overlappingAdditionAndRemoval(itemID)
        }
        for (itemID, entries) in delta.additions {
            try Self.checkEntryList(entries, for: itemID)
            guard entriesByItem[itemID] == nil else {
                throw SignatureIndexRejection.additionAlreadyIndexed(itemID)
            }
        }
        for itemID in delta.removals where entriesByItem[itemID] == nil {
            throw SignatureIndexRejection.removalNotIndexed(itemID)
        }
    }

    /// The entry-list well-formedness shared by construction and delta
    /// checks: non-empty (Canonical Content is non-empty, docs/02-domain.md
    /// §2.3), with neither an exactly repeated entry nor two entries for one
    /// Canonical type identifier — each row contributes each Canonical type's
    /// signature entry exactly once (§12).
    private static func checkEntryList(
        _ entries: [ContentSignatureEntry],
        for itemID: HistoryItemID
    ) throws {
        guard !entries.isEmpty else {
            throw SignatureIndexRejection.emptySignatureEntries(item: itemID)
        }
        var seenEntries = Set<ContentSignatureEntry>()
        seenEntries.reserveCapacity(entries.count)
        var seenTypeIdentifiers = Set<String>()
        seenTypeIdentifiers.reserveCapacity(entries.count)
        for entry in entries {
            guard seenEntries.insert(entry).inserted else {
                throw SignatureIndexRejection.duplicateEntry(
                    item: itemID,
                    typeIdentifier: entry.typeIdentifier
                )
            }
            guard seenTypeIdentifiers.insert(entry.typeIdentifier).inserted else {
                throw SignatureIndexRejection.duplicateTypeIdentifier(
                    item: itemID,
                    typeIdentifier: entry.typeIdentifier
                )
            }
        }
    }
}
