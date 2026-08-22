/// R.3 — the `RetainedBytesRow` projection-lifecycle stamping: the
/// same-transaction insert/restamp/delete steps that keep the 1:1 per-item
/// byte projection coherent with the blob writes that change it, plus the
/// startup both-directions existence check that turns the M1 fixture
/// invariant into the runtime step-7 gate — since the RET-PLATFORM-1b(e)
/// measured-fact response, a TWO-phase gate (amended `V2-02` Record 5):
/// idempotent open-time recovery of the missing-rows (interrupted
/// migration) shape first, then the unchanged fail-closed strict
/// validation for every other divergence.
/// Owning spec: `V2-02` §3.3b (projection coherence: "its three scalar
/// fields are recomputed and stamped in the same `ModelContext.transaction`
/// as the blob write that changes them — at capture-insert ... at coalesce
/// (no blob changes → the row is present but unchanged) ... at revise ...
/// and at `.setRetentionPolicies` R3 prune"), §3.3/§3.4 (the `.delete`
/// extension removes the 1:1 row explicitly — "by an explicit stamping
/// step, not a `@Relationship`"), §6.3 (the restamp discipline), §3.2 (a
/// missing row is corruption, "never ... a zero-byte read"); roadmap:
/// `V2-roadmap` §6 R.3 ("maintain the 1:1 scalar projection on create,
/// append, prune, and delete even while policies are disabled") and §5
/// total open order step 7 (`RET-PLATFORM-1b(a)`, "enforced from slice
/// R.3").
///
/// Boundary (roadmap R.3/R.4): this file owns projection maintenance ONLY.
/// The capture/revise/policy-sweep compositions that decide WHEN revisions
/// or items are removed (R.4/R.5/R.6) live in their own slices; the insert
/// stamp below is mandatory maintenance regardless of policies (`V2-02`
/// §4.1: "the `RetainedBytesRow` projection is mandatorily maintained 1:1
/// even while every policy is disabled").
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData

// MARK: - Revision scalars (V2-02 §3.2 representation-byte measure)

/// The per-item revision summary the projection carries: the count of stored
/// revisions and the sum of their representation bytes (`V2-02` §3.2 —
/// "revision content bytes (the sum of stored-revision representation
/// bytes)", excluding Codable framing, `formatVersion`/`activeRevisionID`
/// overhead, and `.externalStorage` block overhead). Stamped beside the
/// `.appendRevision`/`.pruneRevisions` payloads so the transaction executor
/// restamps the projection from the same validated Domain values the blob
/// was encoded from — no blob decode on the commit path (`RET-PLATFORM-2`).
internal struct RetainedRevisionScalars: Sendable, Equatable {
    /// Count of stored revisions, active included (`V2-02` §5.1).
    internal let count: Int

    /// Sum of stored-revision representation bytes.
    internal let bytes: Int
}

// MARK: - Projection lifecycle stamping (V2-02 §3.3b / §6.3)

internal enum RetainedBytesStamping {

    /// The only projection version this lifecycle writes (`V2-02` §3.3b:
    /// the `bytesSchemaVersion` projection-coherence fence, 1 for V2-02).
    /// Same value and same fence as the M1.4 backfill's constant; declared
    /// separately because the fence is owned by the projection lifecycle,
    /// not by the one-time migration hop (each codec owns its own
    /// `formatVersion` the same way).
    internal static let bytesSchemaVersion: UInt16 = 1

    // MARK: Scalar recomputation

    /// Recomputes the revision summary of one (post-append or post-prune)
    /// revision list. The §4 codec bounds already cap per-revision bytes
    /// (`maximumProposedRevisionBytes`), per-item totals
    /// (`maximumTotalRevisionBytesPerItem`), and the revision count
    /// (`maximumRevisionsPerItem`), so the sum stays far below `Int`
    /// overflow — the same justification the M1.4 backfill's plain addition
    /// uses.
    internal static func revisionScalars(
        of revisions: [ContentRevision]
    ) -> RetainedRevisionScalars {
        var bytes = 0
        for revision in revisions {
            for representation in revision.content.representations {
                bytes += representation.bytes.count
            }
        }
        return RetainedRevisionScalars(count: revisions.count, bytes: bytes)
    }

    // MARK: Insert (V2-02 §3.3b capture-insert stamp)

    /// Stamps the 1:1 row for a `.create` mutation, in the same
    /// `ModelContext.transaction` as the row insert it follows
    /// (`V2-02` §3.3b): `canonicalBytes` is the sum of the signature
    /// entries being written — recomputed here by the envelope-only decode
    /// of the exact `canonicalSignatureBlob` in the same transaction, so the
    /// projection can never disagree with the durable bytes it summarizes
    /// (the §3.2 signature-envelope byte count; no Canonical content is
    /// materialized, `05` §13 decode discipline) — and a v1 insert carries
    /// an empty revision list (`02` §2 / `05` §3.1:
    /// `activeRevisionID == nil`, no "initial revision"), so
    /// `revisionCount == 0` and `revisionBytes == 0` (DC-04).
    ///
    /// No pre-existing-row check runs: the `.create` executor arm has
    /// already proved the business ID absent (durable lookup, or the
    /// fixture-only complete-index proof), and the 1:1 law makes a row for
    /// an absent item impossible; any drift is caught by the step-7 startup
    /// check below.
    internal static func stampForInsert(
        for item: StoredNewItem,
        limits: HistoryLimits,
        in context: ModelContext
    ) throws {
        let entries = try mapCodecFailure {
            try SignatureBlobCodec.decode(item.canonicalSignatureBlob, limits: limits)
        }
        var canonicalBytes = 0
        for entry in entries {
            canonicalBytes += entry.byteCount
        }
        context.insert(RetainedBytesRow(
            itemID: item.id.rawValue,
            canonicalBytes: canonicalBytes,
            revisionCount: 0,
            revisionBytes: 0,
            bytesSchemaVersion: bytesSchemaVersion
        ))
    }

    // MARK: Restamp (V2-02 §3.3b revise / §6.3 prune restamp)

    /// Restamps the existing 1:1 row's revision scalars to the post-append
    /// or post-prune value, in the same transaction as the
    /// `revisionStateBlob` write it follows (`V2-02` §6.3: "restamps the
    /// pruned item's `RetainedBytesRow` (`revisionCount`/`revisionBytes`
    /// updated to the post-prune value) in the same transaction").
    /// `canonicalBytes` is untouched: Canonical Content — and therefore the
    /// signature envelope — never changes after insert (D2; `V2-02` §5.2).
    ///
    /// A missing row is corruption, never a zero read or a silent skip
    /// (`V2-02` §3.2 / Record 5): the row is created at insert, maintained
    /// 1:1 by every blob-changing write, and its absence proves the store
    /// already violates the migration invariant.
    internal static func restamp(
        itemID: HistoryItemID,
        revisionScalars: RetainedRevisionScalars,
        in context: ModelContext
    ) throws {
        guard let row = try fetchRow(itemID: itemID, in: context) else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        row.revisionCount = revisionScalars.count
        row.revisionBytes = revisionScalars.bytes
    }

    // MARK: Prune payload (V2-02 §5.3 shorter blob + §6.3 restamp inputs)

    /// Encodes the shorter post-prune `RevisionStateBlobV1` and the
    /// post-prune revision scalars from one loaded lineage (`V2-02` §5.3:
    /// "the v1 `RevisionStateBlobV1` codec encodes and decodes it
    /// unchanged" — `formatVersion == 1`, fewer revisions, same
    /// `activeRevisionID`). Survivor order is append order (§5.2: pruning
    /// never reorders), and the §5.1/§5.2 safety laws are re-guarded here:
    ///
    /// - `removedRevisionIDs` is non-empty (a no-op prune never reaches
    ///   stamping, §5.3) and every ID names a loaded revision;
    /// - the active revision is never prunable (D3/D23) and still names a
    ///   survivor after pruning — a prune of a Canonical-state item (no
    ///   revisions, nil active) is incoherent by the same law.
    ///
    /// The WHICH-revisions question is `planRevisionRetentionExpansion`
    /// (`V2-02` §5.1/§6.5), composed by R.5/R.6; this helper is the
    /// mechanical re-encode the stamping arm and its seam tests share.
    internal static func prunedRevisionState(
        loadedRevisions: [ContentRevision],
        activeRevisionID: RevisionID?,
        removedRevisionIDs: [RevisionID]
    ) throws -> (
        revisionStateBlob: Data,
        retainedRevisionScalars: RetainedRevisionScalars
    ) {
        let removed = Set(removedRevisionIDs)
        guard !removed.isEmpty, let activeRevisionID else {
            throw StampingRejection.incoherentPlan
        }
        guard !removed.contains(activeRevisionID) else {
            throw StampingRejection.incoherentPlan
        }
        var survivors: [ContentRevision] = []
        survivors.reserveCapacity(loadedRevisions.count)
        var removedFound = 0
        for revision in loadedRevisions {
            if removed.contains(revision.id) {
                removedFound += 1
            } else {
                survivors.append(revision)
            }
        }
        guard removedFound == removed.count,
              survivors.contains(where: { $0.id == activeRevisionID })
        else {
            throw StampingRejection.incoherentPlan
        }
        return (
            revisionStateBlob: try RevisionStateBlobCodec.encode(
                revisions: survivors,
                activeRevisionID: activeRevisionID
            ),
            retainedRevisionScalars: revisionScalars(of: survivors)
        )
    }

    // MARK: Delete (V2-02 §3.3/§3.4 `.delete` extension)

    /// Removes the 1:1 row in the same transaction as the
    /// `HistoryItemRow` deletion it follows — the explicit stamping step of
    /// the V2-extended `.delete` (`V2-02` §3.4: "the V2 extension also
    /// removes the 1:1 `RetainedBytesRow` in the same
    /// `ModelContext.transaction` (by an explicit stamping step, not a
    /// `@Relationship`)"). An absent row fails closed exactly like
    /// `restamp`'s missing-row case: 1:1 is a store invariant, and a
    /// delete-as-repair here would mask corruption the step-7 check exists
    /// to surface.
    internal static func deleteRow(
        itemID: HistoryItemID,
        in context: ModelContext,
        prefetched: [UUID: RetainedBytesRow]? = nil
    ) throws {
        // The per-transaction prefetch (see `prefetchRowsForRetirements`)
        // supplies the row without a store fetch; an ID absent from the map
        // can only be a row inserted earlier in the SAME transaction (a
        // create's insert stamp — no v1/V2-02 plan shape mixes create with
        // retire, `02` §7/§12, but the fallback keeps the invariant total),
        // and a fresh fetch sees such a pending insert.
        let row: RetainedBytesRow?
        if let prefetched, let prefetchedRow = prefetched[itemID.rawValue] {
            row = prefetchedRow
        } else {
            row = try fetchRow(itemID: itemID, in: context)
        }
        guard let row else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        context.delete(row)
    }

    /// One bounded scalar fetch supplying every `.delete` of the plan with
    /// its 1:1 projection row (`V2-02` §3.3 delete extension, roadmap R.3).
    /// A per-item predicate fetch during a mass retirement (e.g. v1
    /// `.setRetentionPolicy(1)` over a full store — §9 bullet 5's
    /// `retentionMassEviction` envelope) degrades the commit to one scan
    /// per delete; prefetching once keeps the projection deletion
    /// O(retained) like every other commit-path step (`02` §12's
    /// bounded-inventory discipline). Returns nil when the plan retires
    /// nothing (the common single-action path fetches its one row
    /// directly). A duplicate `itemID` — impossible through `.unique` plus
    /// the single writer — is the invariant violation it represents
    /// (mirroring the backfill's duplicate guard).
    internal static func prefetchRowsForRetirements(
        in mutations: [StampedMutation],
        context: ModelContext
    ) throws -> [UUID: RetainedBytesRow]? {
        guard mutations.contains(where: {
            if case .delete = $0 { return true }
            return false
        }) else {
            return nil
        }
        let rows: [RetainedBytesRow]
        do {
            rows = try context.fetch(FetchDescriptor<RetainedBytesRow>())
        } catch {
            throw HistoryFailure.persistence(.transaction)
        }
        var byItem: [UUID: RetainedBytesRow] = [:]
        byItem.reserveCapacity(rows.count)
        for row in rows {
            guard byItem[row.itemID] == nil else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            byItem[row.itemID] = row
        }
        return byItem
    }

    // MARK: Startup 1:1 check (V2-roadmap §5 total open order step 7)

    /// The runtime `RET-PLATFORM-1b(a)` check, live from slice R.3
    /// (`V2-roadmap` §5 step-7 sequencing note: before R.3, capture creates
    /// items without rows, so an unconditional check would fail every
    /// capture-created item; R.3's lifecycle stamping is what makes the
    /// check enforceable): after the v1 scalar scan, every retained item has
    /// exactly one `RetainedBytesRow`, every row names a retained item
    /// (both directions), and every `bytesSchemaVersion == 1` — the
    /// projection-coherence fence (`V2-02` §3.3b). A fresh store holds the
    /// correspondence vacuously (zero items; rows arrive via the
    /// capture-insert stamping).
    ///
    /// TWO phases since the amended `V2-02` Record 5 (interruption
    /// recovery — the RET-PLATFORM-1b(e) measured-platform-fact response):
    ///
    /// - Phase (i) RECOVERY: a correspondence incomplete ONLY in the
    ///   missing-rows direction — every existing row names a retained item
    ///   and carries `bytesSchemaVersion == 1`, but some retained item
    ///   lacks its row — is the one producible interrupted-migration shape.
    ///   SwiftData stamps the store's schema version before (or
    ///   independently of) the custom stage's `didMigrate` data work
    ///   committing — measured fact, CI run 31955551834: a child process
    ///   dying mid-backfill pre-transaction leaves a version-V2 store with
    ///   missing rows, so the parent's open never re-runs the stage; the
    ///   engine does NOT provide interruption atomicity. The M1.4 backfill
    ///   is idempotent by construction (full recompute from the blobs,
    ///   delete-then-insert; V2-00 §5 decision 18 — recompute never invents
    ///   bytes and reproduces the (a)/(b) invariants exactly), so this
    ///   phase runs it ONCE on the Authority-owned startup context — no
    ///   new writer; the same sanctioned context that creates the position
    ///   singleton — and re-reads the correspondence.
    /// - Phase (ii) STRICT VALIDATION: any violation that remains — missing
    ///   rows after recovery, an orphan row, or a version mismatch — fails
    ///   closed `.persistence(.invariantViolation)` ("row existence is the
    ///   migration invariant ... never ... a zero-byte read", `V2-02`
    ///   §3.2). Orphans and version mismatches NEVER recover: the backfill
    ///   writes only complete rows for retained items, so neither is a
    ///   producible interruption shape.
    ///
    /// A store that cannot be read fails as `.persistence(.openStore)` (§2's
    /// startup vocabulary, which does not include `.transaction`). The
    /// check itself is scalar-only (no Canonical or revision blob decode,
    /// `05` §13); the phase-(i) backfill decodes blobs exactly as the
    /// migration hop always has.
    internal static func validateOneToOneCorrespondence(
        in context: ModelContext,
        limits: HistoryLimits
    ) throws {
        var itemDescriptor = FetchDescriptor<HistoryItemRow>()
        itemDescriptor.propertiesToFetch = [\.id]
        itemDescriptor.fetchLimit = limits.hardMaximumRetainedItems + 1
        let items: [HistoryItemRow]
        do {
            items = try context.fetch(itemDescriptor)
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }
        guard items.count <= limits.hardMaximumRetainedItems else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        var itemIDs = Set<UUID>(minimumCapacity: items.count)
        for item in items {
            // Duplicate business IDs were already rejected by the §13 step-6
            // scan this check follows; re-guarded because this fetch is a
            // separate pass over the same rows.
            guard itemIDs.insert(item.id).inserted else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
        }

        var rowItemIDs = try fetchedValidatedRowItemIDs(
            in: context,
            limits: limits,
            itemIDs: itemIDs
        )

        // Phase (i) — RECOVERY (amended Record 5): the strict row pass just
        // proved every PRESENT row valid and item-naming, so a set
        // difference here can only be the missing-rows direction — some
        // retained item lacks its row, the interrupted-migration shape.
        // Re-run the idempotent backfill once (it owns its
        // `ModelContext.transaction` on this context) and re-read the
        // correspondence; the item set needs no re-read because the
        // backfill writes only `RetainedBytesRow`s. A complete store —
        // migrated-complete or capture-maintained — skips this branch on
        // two set comparisons over already-fetched data: no measurable
        // open cost.
        if rowItemIDs != itemIDs {
            try RetainedBytesBackfill.backfill(in: context)
            rowItemIDs = try fetchedValidatedRowItemIDs(
                in: context,
                limits: limits,
                itemIDs: itemIDs
            )
        }

        // Phase (ii) — STRICT: direction 1 (every retained item has exactly
        // one row) holds after recovery or fails closed. Orphans, version
        // mismatches, and duplicates already threw inside the strict row
        // pass and never reach a repair.
        guard rowItemIDs == itemIDs else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
    }

    /// One strict row-side read of the correspondence: fetches every
    /// `RetainedBytesRow`'s identity fields under the hard-bound guard and
    /// returns the validated row item-ID set (the shared read of phases (i)
    /// and (ii) above). Per-row failures — an unknown `bytesSchemaVersion`,
    /// a duplicate business ID, or an orphan naming no retained item — fail
    /// closed `.persistence(.invariantViolation)` and are NEVER
    /// recoverable: the backfill writes only complete rows for retained
    /// items, so none of them is a producible interruption shape (amended
    /// Record 5). A store that cannot be read fails as
    /// `.persistence(.openStore)` (§2).
    private static func fetchedValidatedRowItemIDs(
        in context: ModelContext,
        limits: HistoryLimits,
        itemIDs: Set<UUID>
    ) throws -> Set<UUID> {
        var rowsDescriptor = FetchDescriptor<RetainedBytesRow>()
        rowsDescriptor.propertiesToFetch = [\.itemID, \.bytesSchemaVersion]
        // A store satisfying 1:1 cannot hold more projection rows than the
        // hard retained-item bound; one past it proves corruption without
        // fetching the rest.
        rowsDescriptor.fetchLimit = limits.hardMaximumRetainedItems + 1
        let rows: [RetainedBytesRow]
        do {
            rows = try context.fetch(rowsDescriptor)
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }
        guard rows.count <= limits.hardMaximumRetainedItems else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        var rowItemIDs = Set<UUID>(minimumCapacity: rows.count)
        for row in rows {
            // The version fence (V2-02 §3.3b): an unknown projection version
            // is never read as a possibly-correct byte fact.
            guard row.bytesSchemaVersion == bytesSchemaVersion else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            // The `.unique` attribute plus the single-writer rule make a
            // duplicate business ID impossible through public behavior; an
            // overwrite in the set would itself prove one.
            guard rowItemIDs.insert(row.itemID).inserted else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            // Direction 2: every row names a retained item — an orphan is
            // corruption, never a delete-as-repair (RET-PLATFORM-1b(a)).
            guard itemIDs.contains(row.itemID) else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
        }
        return rowItemIDs
    }

    // MARK: Row fetch

    /// Fetches the unique projection row carrying `itemID`, or `nil` when
    /// none exists. Bounded (`fetchLimit = 2`), mirroring
    /// `HistoryItemRowHydration.fetchRow`'s business-ID lookup discipline
    /// (`05` §5): a duplicate is an invariant violation, not a choose-one
    /// repair; a framework fetch failure maps to the same availability
    /// vocabulary the fact loaders use (inside the §10 transaction closure
    /// both surface at the boundary as `.persistence(.transaction)`, §16).
    private static func fetchRow(
        itemID: HistoryItemID,
        in context: ModelContext
    ) throws -> RetainedBytesRow? {
        let uuid = itemID.rawValue
        var descriptor = FetchDescriptor<RetainedBytesRow>(
            predicate: #Predicate { row in row.itemID == uuid }
        )
        descriptor.fetchLimit = 2
        let rows: [RetainedBytesRow]
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
}
