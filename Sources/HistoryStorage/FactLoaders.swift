/// Fact loading for the capture path, plus the shared row→Domain hydration
/// helpers every other action-specific fact loader reuses (pin/unpin,
/// revision, remove, clear, and retention at roadmap step 6).
/// Owning spec: docs/05-authority-kernel.md §7 (complete fact loading, §7.1
/// capture), §5 (context confinement — bounded business-ID fetch, never
/// `registeredModel(for:)`), §4 (decode checks, applied through the step-4
/// versioned codecs), §12 (Signature Index lifecycle), §16 (failure
/// translation); docs/02-domain.md §5.1 (IngestFacts construction guarantees
/// and the `.temporarilyUnavailable(.factProof)` / `.dedupIndexRebuild`
/// mapping).
///
/// Every function here is synchronous and runs inside one serialized
/// `HistoryAuthority` interval on an operation-local `ModelContext`
/// (docs/05 §5): there is no `await` while a context, fetched row, complete
/// fact, or commit plan is live, and no row or context is retained after
/// return. Failures are thrown already mapped to the public §16 vocabulary:
/// codec rejections via their `historyFailure`, framework fetch failures as
/// `.temporarilyUnavailable(...)` (completeness cannot be proven), and
/// durable-state invariant violations as `.persistence(.invariantViolation)`.
/// Platform error strings are never used as semantic discriminators (§16).
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData

// MARK: - Codec failure translation (docs/05-authority-kernel.md §16)

/// Translates a throwing codec/scalar-decode call into the §16 boundary
/// vocabulary: decode rejections are corrupt persisted values, the
/// encode-side backstop is an invariant violation. Errors that are not codec
/// rejections propagate unchanged (there is no stringly-typed re-labeling).
private func mapCodecFailure<T>(_ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let rejection as CodecRejection {
        throw rejection.historyFailure
    } catch let rejection as RevisionStateCodecRejection {
        throw rejection.historyFailure
    }
}

// MARK: - Row → Domain hydration (docs/05-authority-kernel.md §7, §4)

/// Shared helpers that fetch `HistoryItemRow` values and reconstruct
/// validated Domain values through the step-4 versioned codecs.
/// docs/05-authority-kernel.md §7 (each action's loader), §5 (all
/// business-ID lookup uses a bounded fetch predicate on `HistoryItemRow.id`;
/// exactly zero or one row is valid — duplicates are persistence corruption
/// even though the schema also declares uniqueness).
///
/// These are the hydration entry points the step-6 loaders (pin/unpin,
/// revision, remove, clear, retention) reuse; the projection fields
/// (`title`, `searchBody`, `effectiveTypeIdentifiersBlob`) are deliberately
/// not decoded here — they belong to the read paths (§14), not to fact
/// loading.
internal enum HistoryItemRowHydration {
    /// Fetches the unique row carrying `businessID`, or `nil` when no
    /// retained row carries it. docs/05-authority-kernel.md §5
    ///
    /// The fetch is bounded (`fetchLimit = 2`): a business ID names at most
    /// one row, so the fetch only ever needs to distinguish absence, the one
    /// valid row, and corruption. A duplicate business ID is a schema
    /// invariant failure mapped to `.persistence(.invariantViolation)` (§5,
    /// §16). A framework fetch failure means the fact cannot be proven
    /// complete and maps to `.temporarilyUnavailable(.factProof)`
    /// (docs/02-domain.md §5.1).
    internal static func fetchRow(
        businessID: HistoryItemID,
        in context: ModelContext
    ) throws -> HistoryItemRow? {
        let uuid = businessID.rawValue
        var descriptor = FetchDescriptor<HistoryItemRow>(
            predicate: #Predicate { row in row.id == uuid }
        )
        descriptor.fetchLimit = 2
        let rows: [HistoryItemRow]
        do {
            rows = try context.fetch(descriptor)
        } catch {
            throw HistoryFailure.temporarilyUnavailable(.factProof)
        }
        guard rows.count <= 1 else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return rows.first
    }

    /// Fully hydrates one row into a `HistoryItemState`, applying every §4
    /// decode check through the versioned codecs:
    ///
    /// - `canonicalBlob` → validated `CanonicalContent`;
    /// - `revisionStateBlob` → the complete revision list and active
    ///   Revision ID, checked against the Canonical type set and D3
    ///   active-ID coherence;
    /// - `canonicalSignatureBlob` → signature entries plus the §4
    ///   bidirectional fingerprint/signature coverage check against the
    ///   Canonical representations;
    /// - `contentVersionRaw` → a valid (≥1) Content Version;
    /// - the occurrence fields → a valid `CopyOccurrence` (count ≥ 1,
    ///   monotone recency, bounded source observations);
    /// - `pinOrdinal` → non-negative or `nil`.
    ///
    /// Any violation throws the codec rejection's §16 mapping
    /// (`.persistence(.corruptStoredValue)`); the decoder never repairs,
    /// drops, or guesses (§4). docs/05-authority-kernel.md §7, §4
    internal static func hydrate(
        _ row: HistoryItemRow,
        limits: HistoryLimits = .standard
    ) throws -> HistoryItemState {
        let canonical = try mapCodecFailure {
            try CanonicalBlobCodec.decode(row.canonicalBlob, limits: limits)
        }
        let lineage = try mapCodecFailure {
            try RevisionStateBlobCodec.decode(
                row.revisionStateBlob,
                canonical: canonical,
                limits: limits
            )
        }
        let signatureEntries = try mapCodecFailure {
            try SignatureBlobCodec.decode(row.canonicalSignatureBlob, limits: limits)
        }
        try mapCodecFailure {
            try SignatureBlobCodec.validateCoverage(
                canonical: canonical,
                entries: signatureEntries
            )
        }
        let contentVersion = try mapCodecFailure {
            try RevisionStateBlobCodec.decodeContentVersion(row.contentVersionRaw)
        }
        let occurrence = try mapCodecFailure {
            try RevisionStateBlobCodec.decodeOccurrence(
                firstCopiedAt: row.firstCopiedAt,
                lastCopiedAt: row.lastCopiedAt,
                copyCount: row.copyCount,
                firstSource: row.firstSource,
                lastSource: row.lastSource,
                limits: limits
            )
        }
        let pinOrdinal = try mapCodecFailure {
            try RevisionStateBlobCodec.decodePinOrdinal(row.pinOrdinal)
        }
        return HistoryItemState(
            id: HistoryItemID(rawValue: row.id),
            contentVersion: contentVersion,
            canonical: canonical,
            revisions: lineage.revisions,
            activeRevisionID: lineage.activeRevisionID,
            occurrence: occurrence,
            pinOrdinal: pinOrdinal
        )
    }

    /// Projects one already-fetched row to its retention-relevant scalar
    /// summary. docs/05-authority-kernel.md §7.1 step 5, docs/02-domain.md
    /// §5.1 (`RetainedItemSummary`). The pin ordinal is validated
    /// non-negative (§4); the collection-wide unique-contiguous pinned-order
    /// proof is the pin loader's separate job (§7.2).
    internal static func retainedSummary(
        of row: HistoryItemRow
    ) throws -> RetainedItemSummary {
        let pinOrdinal = try mapCodecFailure {
            try RevisionStateBlobCodec.decodePinOrdinal(row.pinOrdinal)
        }
        return RetainedItemSummary(
            id: HistoryItemID(rawValue: row.id),
            lastCopiedAt: row.lastCopiedAt,
            pinOrdinal: pinOrdinal
        )
    }

    /// Fetches the complete retention inventory: a scalar summary of every
    /// retained row, exactly once each. docs/05-authority-kernel.md §7.1
    /// step 5, §7.3 ("All collection-wide loads are bounded by the hard
    /// retained-item maximum"); docs/02-domain.md §5.1
    /// (`CompleteRetentionInventory`).
    ///
    /// The fetch is scalar-only (`propertiesToFetch` selects `id`,
    /// `lastCopiedAt`, `pinOrdinal`), so no Canonical or revision blob is
    /// faulted for this load (§14.1, §18; the no-blob-decode proof itself is
    /// the docs/06-cross-cutting.md §7.5 runner gate). The result is sorted
    /// by History Item ID so identical stores yield identical fact values.
    ///
    /// A row count above the hard retained-item bound or a duplicate
    /// business ID is a durable-state invariant violation (matching the
    /// startup stance of §13 step 5); a framework fetch failure is
    /// `.temporarilyUnavailable(.factProof)` — the loader never labels an
    /// incomplete result as complete (§7.3).
    internal static func fetchRetainedInventory(
        in context: ModelContext,
        limits: HistoryLimits = .standard
    ) throws -> [RetainedItemSummary] {
        var descriptor = FetchDescriptor<HistoryItemRow>()
        descriptor.propertiesToFetch = [\.id, \.lastCopiedAt, \.pinOrdinal]
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
        var seen = Set<HistoryItemID>(minimumCapacity: rows.count)
        var summaries: [RetainedItemSummary] = []
        summaries.reserveCapacity(rows.count)
        for row in rows {
            let summary = try retainedSummary(of: row)
            guard seen.insert(summary.id).inserted else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            summaries.append(summary)
        }
        summaries.sort { $0.id < $1.id }
        return summaries
    }
}

// MARK: - Capture fact loading (docs/05-authority-kernel.md §7.1)

/// The complete fact loader for the capture path (`HistoryAction.capture`).
/// docs/05-authority-kernel.md §7.1; construction guarantees:
/// docs/02-domain.md §5.1.
///
/// One load performs §7.1's six steps in order inside one serialized
/// `HistoryAuthority` interval (no suspension, so the sole writer cannot
/// interleave a commit mid-load):
///
/// 1. Require Signature Index state `.ready` *for the current retained ID
///    set*: a ready index whose `itemIDs` differs from the fetched retained
///    IDs is not ready for this interval, and an `.unready` index is not
///    ready at all — either way, attempt one complete rebuild from every
///    retained row's signature blob within the hard item bound (§12).
/// 2. Intersect posting sets for all incoming signature entries (derived
///    from the prepared Canonical Content, the same entries preparation
///    constructed at §6.1 step 6) via `SignatureIndex.candidateIDs`.
/// 3. Fetch and fully decode every candidate ID.
/// 4. Fetch the lineage hint separately by business ID when a hint exists,
///    even when it is absent from the candidate intersection.
/// 5. Fetch scalar retention summaries for every retained row (step 5 runs
///    first here: one bounded scalar fetch yields both the retention
///    inventory and the authoritative retained ID set the step-6 agreement
///    checks compare against).
/// 6. Verify candidate IDs, retained IDs, and index generation agree before
///    constructing `IngestFacts`.
///
/// If any step cannot prove completeness the capture is rejected — there is
/// no "scan the first N and insert if absent" path (§7.1, D8).
internal enum IngestFactLoader {
    /// The result of one capture fact load.
    internal struct LoadResult: Sendable {
        /// The proven-complete facts for `planCapture` (docs/02-domain.md
        /// §5.1). The Domain planner is never invoked with a partial fact.
        internal let facts: IngestFacts

        /// The Signature Index value the Authority retains after this load:
        /// the input index unchanged when it was already `.ready` for the
        /// current retained ID set, otherwise the complete rebuild this load
        /// performed (§7.1 step 1, §12; a fresh `SignatureIndex.build` starts
        /// at generation 0). The load itself applies no delta and marks
        /// nothing unready; index mutation on commit stays on the §11
        /// post-commit path.
        internal let signatureIndex: SignatureIndex
    }

    /// Loads the complete capture facts for one prepared capture.
    /// docs/05-authority-kernel.md §7.1
    ///
    /// - Parameters:
    ///   - context: the operation-local `ModelContext` created by
    ///     `HistoryAuthority` for this commit interval (§5).
    ///   - prepared: the off-Authority prepared capture; supplies the
    ///     incoming Canonical Content (for signature entries) and the
    ///     lineage-hint observation. The minted `candidateID` is a planning
    ///     input, not a fact-load input — plan invariant 2 (docs/02 §7)
    ///     checks it against these facts.
    ///   - signatureIndex: the Authority-owned index value at interval
    ///     start. The loader mints no generation: a rebuild is constructed
    ///     by `SignatureIndex.build`, which starts its own generation at 0
    ///     (§12).
    ///   - limits: the fixed `HistoryLimits.standard` safety profile
    ///     (docs/06-cross-cutting.md §2).
    /// - Throws: `.temporarilyUnavailable(.dedupIndexRebuild)` when the index
    ///   cannot be rebuilt to a proved-complete state (§16, WS5);
    ///   `.temporarilyUnavailable(.factProof)` when a fact fetch cannot
    ///   complete (docs/02 §5.1); codec-mapped
    ///   `.persistence(.corruptStoredValue)` for corrupt stored values;
    ///   `.persistence(.invariantViolation)` for durable-state invariant
    ///   violations (over-bound retained count, duplicate business IDs,
    ///   same-interval store/index divergence).
    internal static func loadFacts(
        in context: ModelContext,
        prepared: PreparedCapture,
        signatureIndex: SignatureIndex,
        limits: HistoryLimits = .standard
    ) throws -> LoadResult {
        // §7.1 step 5 first: the complete retained inventory doubles as the
        // authoritative retained ID set for the step-6 agreement checks.
        let inventory = try HistoryItemRowHydration.fetchRetainedInventory(
            in: context,
            limits: limits
        )
        let retainedIDs = Set(inventory.map(\.id))

        // §7.1 step 1: require a ready index *for the current retained ID
        // set*; otherwise attempt one complete rebuild within the hard item
        // bound (§12). A ready index whose covered ID set disagrees with the
        // store is not ready for this interval — within one serialized
        // interval that can only follow an Authority-side delta bug, and the
        // safe response is the same proved-complete rebuild, never planning
        // from a partial candidacy.
        let index: SignatureIndex
        if case .ready = signatureIndex.state, signatureIndex.itemIDs == retainedIDs {
            index = signatureIndex
        } else {
            index = try rebuildSignatureIndex(
                in: context,
                retainedIDs: retainedIDs,
                limits: limits
            )
        }

        // §7.1 step 2 (docs/02-domain.md §9.1): intersect the posting sets
        // of all incoming signature entries — the complete
        // Canonical-containment candidate ID set for a ready index. The
        // entries derive from the prepared Canonical Content exactly as at
        // §6.1 step 6. `nil` (index unready) is unreachable after the
        // readiness resolution above and would be an internal contradiction.
        let incomingEntries = prepared.canonical.representations.map { representation in
            ContentSignatureEntry(
                typeIdentifier: representation.content.typeIdentifier,
                fingerprint: representation.fingerprint,
                byteCount: representation.content.bytes.count
            )
        }
        guard let candidateIDs = index.candidateIDs(matching: incomingEntries) else {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        // §7.1 step 6, candidate side: a ready-and-current index posts only
        // retained IDs; anything else is index/store divergence, not a
        // partial fact (§12: "every fact-load checks that candidate IDs
        // remain retained in its serialized Authority interval").
        guard candidateIDs.isSubset(of: retainedIDs) else {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        // §7.1 step 3: fetch and fully decode every candidate in
        // deterministic ID order (D9's tie-breaker must never depend on
        // fetch or dictionary iteration order).
        var candidates: [HistoryItemState] = []
        candidates.reserveCapacity(candidateIDs.count)
        for candidateID in candidateIDs.sorted() {
            guard let row = try HistoryItemRowHydration.fetchRow(
                businessID: candidateID,
                in: context
            ) else {
                // The index named an item the store does not retain:
                // index/store divergence is an internal invariant failure.
                throw HistoryFailure.persistence(.invariantViolation)
            }
            candidates.append(try HistoryItemRowHydration.hydrate(row, limits: limits))
        }

        // §7.1 step 4: the lineage hint is fetched separately by business ID
        // even when it is absent from the candidate intersection
        // (docs/01-architecture.md §5.1). A hint naming no retained row
        // decodes to `nil` — the lineage lane simply has no candidate.
        var hintedItem: HistoryItemState?
        if let hint = prepared.origin.lineageHint,
           let row = try HistoryItemRowHydration.fetchRow(businessID: hint, in: context) {
            hintedItem = try HistoryItemRowHydration.hydrate(row, limits: limits)
        }

        // §7.1 step 6: every agreement check has passed — the index covers
        // exactly the retained ID set, candidate IDs are a subset of it,
        // every candidate and the hint decoded fully, the inventory contains
        // every retained item exactly once, and the index generation used
        // for candidacy is the one returned with the facts (value semantics
        // inside one serialized interval make mid-load drift impossible).
        let facts = IngestFacts(
            hintedItem: hintedItem,
            candidates: CompleteDedupCandidates(items: candidates),
            retention: CompleteRetentionInventory(allItems: inventory)
        )
        return LoadResult(facts: facts, signatureIndex: index)
    }

    /// Rebuilds the complete Signature Index from every retained row's
    /// signature blob within the hard item bound. docs/05-authority-kernel.md
    /// §7.1 step 1, §12 ("Ready means every retained row contributes every
    /// Canonical signature entry exactly once"), §13.
    ///
    /// The fetch is scalar-plus-signature-blob only; Canonical and revision
    /// blobs are never decoded for a rebuild (§13). Failure mapping (§16,
    /// docs/02-domain.md §5.1, and `SignatureIndexRejection`'s documented
    /// capture-path mapping):
    ///
    /// - a framework fetch failure or a `SignatureIndex.build` rejection
    ///   means the index cannot be rebuilt to a proved-complete state →
    ///   `.temporarilyUnavailable(.dedupIndexRebuild)` (the WS5 path,
    ///   docs/06-cross-cutting.md §8);
    /// - a corrupt signature blob is a decode failure →
    ///   `.persistence(.corruptStoredValue)` via the codec mapping (the §13
    ///   stance: corrupt durable signature metadata fails closed rather than
    ///   enabling writes from an unproved state);
    /// - a duplicate business ID, or a rebuild row set that disagrees with
    ///   the retained set fetched earlier in the same interval, is
    ///   `.persistence(.invariantViolation)`.
    ///
    /// (The retained-count bound is already enforced by the inventory fetch
    /// before this runs; the repeated bound check here is defensive — its
    /// `.dedupIndexRebuild` mapping matches `SignatureIndexRejection
    /// .retainedCountExceedsBound` on this path.)
    private static func rebuildSignatureIndex(
        in context: ModelContext,
        retainedIDs: Set<HistoryItemID>,
        limits: HistoryLimits
    ) throws -> SignatureIndex {
        var descriptor = FetchDescriptor<HistoryItemRow>()
        descriptor.propertiesToFetch = [\.id, \.canonicalSignatureBlob]
        descriptor.fetchLimit = limits.hardMaximumRetainedItems + 1
        let rows: [HistoryItemRow]
        do {
            rows = try context.fetch(descriptor)
        } catch {
            throw HistoryFailure.temporarilyUnavailable(.dedupIndexRebuild)
        }
        guard rows.count <= limits.hardMaximumRetainedItems else {
            throw HistoryFailure.temporarilyUnavailable(.dedupIndexRebuild)
        }
        var signatures: [HistoryItemID: [ContentSignatureEntry]] = [:]
        signatures.reserveCapacity(rows.count)
        for row in rows {
            let itemID = HistoryItemID(rawValue: row.id)
            let entries = try mapCodecFailure {
                try SignatureBlobCodec.decode(row.canonicalSignatureBlob, limits: limits)
            }
            guard signatures.updateValue(entries, forKey: itemID) == nil else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
        }
        // Completeness proof: the rebuild input covers exactly the retained
        // set fetched in the same serialized interval — no row missing, no
        // row extra (§12, §7.1 step 6).
        guard Set(signatures.keys) == retainedIDs else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        do {
            return try SignatureIndex.build(from: signatures, limits: limits)
        } catch is SignatureIndexRejection {
            // A build rejection on the capture-time rebuild path means the
            // index could not be rebuilt to a proved-complete state (§16) —
            // the WS5 failure producer (docs/06-cross-cutting.md §8).
            throw HistoryFailure.temporarilyUnavailable(.dedupIndexRebuild)
        }
    }
}
