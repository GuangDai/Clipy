/// M1.4 — the one-time `RetainedBytesRow` projection-rebuild backfill.
/// Owning spec: `V2-02` Record 5 (the projection layer decodes each existing
/// item's `canonicalSignatureBlob` and `revisionStateBlob` once and writes
/// the 1:1 `RetainedBytesRow`), plus DATA-11's required companion Canonical
/// decode and bidirectional signature-coverage check (`05` §4),
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

#if DEBUG
/// RET-PLATFORM-1b(e) engine-level interruption seam — TEST-ONLY,
/// DEBUG-only, and inert unless the `CLIPY_MIGRATION_BACKFILL_ABORT_AFTER`
/// environment variable holds a positive row count (`V2-02` Record 3:
/// "prove on the macOS runner that an interrupted migration (process death
/// mid-backfill) leaves the store openable and that the re-run reproduces
/// exactly the (a)/(b) invariants"). When armed,
/// `abortIfArmed(afterComputedRows:)` kills the process with
/// `exit(EXIT_FAILURE)` exactly when the backfill's compute loop has
/// produced that many rows — a TRUE mid-backfill process death: no error
/// is thrown, no rollback or cleanup code runs, and the migration
/// machinery never regains control. The macOS-runner fixture that arms
/// it is `HistoryMigrationInterruptionTests`, which spawns the DEBUG
/// `HistoryPerfRunner` child mode (`--migration-abort-child`) with this
/// variable set in the CHILD's environment alone.
///
/// The gating mirrors the repo's probe-seam discipline
/// (`StorageLifecycleDebugProbe.environmentConfigured`: `#if DEBUG` plus
/// one environment read, nothing else): release builds compile out the
/// read, the marker, and the exit, so production migration behavior is
/// byte-for-byte unchanged.
internal enum MigrationBackfillAbortProbe {

    /// The environment key that arms the seam (a positive computed-row
    /// count).
    internal static let environmentKey = "CLIPY_MIGRATION_BACKFILL_ABORT_AFTER"

    /// The fixed stderr marker emitted immediately before the injected
    /// death, so the parent fixture can prove the child died AT the seam
    /// rather than anywhere else in the open path. A fixed string: no
    /// store path, item identifier, or clipboard value can enter it.
    internal static let markerLine = "[CLIPY_MIGRATION_ABORT] backfill interrupted mid-loop"

    /// Kills the process when `computedRows` reaches the armed count.
    /// Every call with the seam disarmed (the environment unset, or not a
    /// positive integer) returns immediately.
    internal static func abortIfArmed(afterComputedRows computedRows: Int) {
        guard let raw = ProcessInfo.processInfo.environment[environmentKey],
              let armed = Int(raw),
              armed > 0,
              computedRows == armed
        else { return }
        try? FileHandle.standardError.write(
            contentsOf: Data("\(markerLine) after \(computedRows) rows\n".utf8)
        )
        exit(EXIT_FAILURE)
    }
}
#endif

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
    /// - `canonicalBytes` — the sum of the decoded and coverage-validated
    ///   `canonicalSignatureBlob` entries' `StoredSignatureEntryV1.byteCount`
    ///   (`V2-02` §3.2/§3.3b; `05` §4). The Canonical blob already needed by
    ///   revision containment also proves the signature list's bidirectional
    ///   type/fingerprint/byte-count coverage before any projection scalar is
    ///   accepted (DATA-11 / `05` §4).
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
            // Decode both durable copies before deriving a scalar. The
            // Canonical decode is also required by revision containment, so
            // DATA-11's coverage proof adds no blob read or second decode.
            let signatureEntries = try mapCodecFailure {
                try SignatureBlobCodec.decode(item.canonicalSignatureBlob)
            }
            let canonical = try mapCodecFailure {
                try CanonicalBlobCodec.decode(item.canonicalBlob)
            }
            try mapCodecFailure {
                try SignatureBlobCodec.validateCoverage(
                    canonical: canonical,
                    entries: signatureEntries
                )
            }

            // canonicalBytes: coverage-validated stored per-entry byte
            // counts, never the JSON framing of either blob.
            var canonicalBytes = 0
            for entry in signatureEntries {
                canonicalBytes += entry.byteCount
            }

            // The revision decode requires the Canonical type set for its
            // §4 containment check (one decode per blob, Record 5).
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
#if DEBUG
            // RET-PLATFORM-1b(e) seam call: a no-op unless the environment
            // armed it (see `MigrationBackfillAbortProbe` above); compiled
            // out of release builds entirely.
            MigrationBackfillAbortProbe.abortIfArmed(
                afterComputedRows: computed.count
            )
#endif
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
