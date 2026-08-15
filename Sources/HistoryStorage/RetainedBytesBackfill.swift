/// M1.4 — the one-time `RetainedBytesRow` projection-rebuild backfill.
/// Owning spec: `V2-02` Record 5 (projection layer: "For each existing
/// `HistoryItemRow` (<= 5,000, `06` §2), the stage decodes its
/// `canonicalSignatureBlob` (envelope only, no Canonical content) and
/// `revisionStateBlob` once and writes the 1:1 `RetainedBytesRow`"),
/// `RET-PLATFORM-1b` (the (a)–(e) migration proof gates), §3.3b/§3.2 (the
/// representation-byte measure), and DC-02 (`V2-02` §3.3 Stage topology: the
/// backfill runs as the single custom hop's `didMigrate`, after the additive
/// schema change, with the new models writable).
///
/// Idempotence is BY CONSTRUCTION (DC-02 / `RET-PLATFORM-1b(e)`): because
/// SwiftData's custom-stage failure semantics are undocumented, every row is
/// fully recomputed from the blobs and rewritten (delete-then-insert) — never
/// a resumed partial write — so a re-run reproduces exactly the same rows.
///
/// The migration context this runs on is the sole sanctioned pre-Authority
/// writer, owned by M1 (`V2-02` Record 5: "The custom-stage closures run on a
/// context the SwiftData migration machinery owns ... confined to the
/// migration hop during container construction inside `SwiftDataHistory.open`
/// (an explicit, recorded exception to the Authority-only writable-context
/// rule, `05` §2, owned by M1)").
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData

// MARK: - RetainedBytesRow backfill (V2-02 Record 5 / RET-PLATFORM-1b)

internal enum RetainedBytesBackfill {

    /// The only projection version this backfill writes (`V2-02` §3.3b: the
    /// `bytesSchemaVersion` projection-coherence fence, 1 for V2-02).
    internal static let bytesSchemaVersion: UInt16 = 1

    /// One recomputed per-item byte projection, computed before any write so
    /// a codec rejection commits nothing.
    private struct ComputedBytes {
        let itemID: UUID
        let canonicalBytes: Int
        let revisionCount: Int
        let revisionBytes: Int
    }

    /// Rebuilds the `RetainedBytesRow` projection for EVERY retained
    /// `HistoryItemRow` (≤ 5,000, `06` §2) in `context`:
    ///
    /// - `canonicalBytes` — the sum of the decoded
    ///   `canonicalSignatureBlob` entries' `StoredSignatureEntryV1.byteCount`
    ///   (`V2-02` §3.2/§3.3b; `05` §4). The signature decode is envelope
    ///   only — no Canonical content and no fingerprint/coverage check runs
    ///   here (`05` §13's index-build decode discipline).
    /// - `revisionCount` — the count of stored revisions.
    /// - `revisionBytes` — the sum of stored-revision representation bytes
    ///   (`V2-02` §3.2: "revision content bytes (the sum of stored-revision
    ///   representation bytes)"; §5.4: excluding Codable framing), taken
    ///   from the validated `RevisionStateBlobCodec` decode. That decode
    ///   requires the item's Canonical type set for its §4 containment
    ///   check, so the Canonical blob is decoded first.
    ///
    /// Upsert is 1:1: any existing row for the item's ID is deleted, then
    /// the recomputed row is inserted with `bytesSchemaVersion == 1` —
    /// idempotent by construction (full recompute, DC-02 /
    /// `RET-PLATFORM-1b(e)`). A pre-existing row naming no retained item is
    /// an orphan — corruption per `RET-PLATFORM-1b(a)`, which "fails closed
    /// `.persistence(.invariantViolation)`, never ... a zero-byte read" —
    /// and is never silently deleted as a repair.
    ///
    /// Failure translation: any codec rejection fails closed as
    /// `.persistence(.corruptStoredValue)` (`05` §4 exhaustive-decode
    /// discipline: never skip an item, never invent bytes, never trust a
    /// stale scalar); an over-bound retained count or an orphan row is
    /// `.persistence(.invariantViolation)`; a store that cannot be read or
    /// written fails as `.persistence(.openStore)` (the §2 startup
    /// vocabulary this open-path writer shares with the v1 singleton
    /// bootstrap, which does not include `.transaction`).
    internal static func backfill(in context: ModelContext) throws {
        let limits = HistoryLimits.standard

        // Fetch every retained item with the §13 step-5 fetch shape: one
        // past the hard bound proves the count inside it.
        var itemDescriptor = FetchDescriptor<HistoryItemRow>()
        itemDescriptor.fetchLimit = limits.hardMaximumRetainedItems + 1
        let items: [HistoryItemRow]
        do {
            items = try context.fetch(itemDescriptor)
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }
        // Record 5: the backfill covers each existing HistoryItemRow
        // (<= 5,000); more than the hard bound is store corruption.
        guard items.count <= limits.hardMaximumRetainedItems else {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        var itemIDs = Set<UUID>(minimumCapacity: items.count)
        for item in items {
            itemIDs.insert(item.id)
        }

        // Existing projection rows, keyed by the 1:1 business ID. A
        // duplicate ID cannot occur through the `.unique` attribute and the
        // single-writer rule; an overwrite in the dictionary would itself
        // prove a duplicate, so it is treated as the invariant violation it
        // represents.
        let existingRows: [RetainedBytesRow]
        do {
            existingRows = try context.fetch(FetchDescriptor<RetainedBytesRow>())
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }
        var existingByItemID: [UUID: RetainedBytesRow] = [:]
        existingByItemID.reserveCapacity(existingRows.count)
        for row in existingRows {
            guard existingByItemID[row.itemID] == nil else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            // RET-PLATFORM-1b(a): every RetainedBytesRow names a retained
            // item (checked both directions). An orphan is corruption, not
            // a delete-as-repair.
            guard itemIDs.contains(row.itemID) else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            existingByItemID[row.itemID] = row
        }

        // Compute every projection from the blobs BEFORE any write, so a
        // codec rejection leaves the store untouched. The codec bounds
        // (Canonical <= 128 MiB per capture, revision bytes <= 256 MiB per
        // item, 06 §2) keep every sum far below Int overflow.
        var computed: [ComputedBytes] = []
        computed.reserveCapacity(items.count)
        for item in items {
            // canonicalBytes: the signature envelope's stored per-entry byte
            // counts (StoredSignatureEntryV1.byteCount via the validated
            // decode), never the JSON framing of the blob itself.
            let signatureEntries = try mapCodecFailure {
                try SignatureBlobCodec.decode(item.canonicalSignatureBlob)
            }
            var canonicalBytes = 0
            for entry in signatureEntries {
                canonicalBytes += entry.byteCount
            }

            // The revision decode requires the Canonical type set for its
            // §4 containment check, so the Canonical blob is decoded first
            // (one decode per blob, Record 5).
            let canonical = try mapCodecFailure {
                try CanonicalBlobCodec.decode(item.canonicalBlob)
            }
            let revisionState = try mapCodecFailure {
                try RevisionStateBlobCodec.decode(
                    item.revisionStateBlob,
                    canonical: canonical
                )
            }
            var revisionBytes = 0
            for revision in revisionState.revisions {
                for representation in revision.content.representations {
                    revisionBytes += representation.bytes.count
                }
            }
            computed.append(ComputedBytes(
                itemID: item.id,
                canonicalBytes: canonicalBytes,
                revisionCount: revisionState.revisions.count,
                revisionBytes: revisionBytes
            ))
        }

        // The rewrite: one ModelContext.transaction owns every delete+insert
        // (the §10 atomicity discipline; closure success is the durable
        // boundary), exactly like the v1 singleton create's transaction.
        do {
            try context.transaction {
                for entry in computed {
                    if let existing = existingByItemID[entry.itemID] {
                        context.delete(existing)
                    }
                    context.insert(RetainedBytesRow(
                        itemID: entry.itemID,
                        canonicalBytes: entry.canonicalBytes,
                        revisionCount: entry.revisionCount,
                        revisionBytes: entry.revisionBytes,
                        bytesSchemaVersion: bytesSchemaVersion
                    ))
                }
            }
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }
    }
}
