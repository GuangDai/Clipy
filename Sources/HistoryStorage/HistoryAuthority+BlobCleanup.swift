import Foundation
import HistoryCore

extension HistoryAuthority {
    /// One finite pass per orphan-producing work request. Requests arriving
    /// during a pass coalesce into one subsequent pass, because earlier
    /// visited entries may have lost their last reference in the meantime.
    internal func requestBlobCleanup() {
        if blobCleanupTask != nil {
            blobCleanupNeedsAnotherPass = true
            return
        }
        blobStore.cancelCleanupPass()
        blobCleanupNeedsAnotherPass = false
        contentCleanupAfterID = ""
        contentCleanupFinished = false
        blobCleanupTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                // Read the existing test handler without retaining Authority
                // across its suspension. Production has no handler installed.
                if let handler = await self?.suspensionHandler {
                    await handler(.blobCleanupBatchEntry)
                }
                guard !Task.isCancelled else { return }
                guard await self?.performBlobCleanupBatch() == true else { return }
                await Task.yield()
            }
        }
    }

    /// No await occurs from the reference query through unlink. Publication
    /// and its SQL commit likewise occupy one uninterrupted Authority call.
    private func performBlobCleanupBatch() -> Bool {
        // A cancelled old task cannot reset a newly requested task or pass.
        guard !Task.isCancelled else { return false }
        do {
            // Logical History deletion has already committed. These are
            // physical reclamation transactions: no accounting, HCR,
            // ChangePosition or observation changes belong to them.
            if !contentCleanupFinished {
                contentCleanupFinished = try reclaimDetachedContentBatch()
                if !contentCleanupFinished { return true }
            }
            let result = try blobStore.cleanupBatch { id in
                let statement = try database.prepare(
                    "SELECT 1 FROM representations WHERE blobID = ? LIMIT 1",
                    bindings: [.text(id.uuidString)]
                )
                defer { statement.finalize() }
                return try statement.step()
            }
            if !result.completedPass { return true }
            if blobCleanupNeedsAnotherPass {
                blobCleanupNeedsAnotherPass = false
                contentCleanupAfterID = ""
                contentCleanupFinished = false
                return true
            }
        } catch {
            // Cleanup failure cannot change a committed History receipt.
            // Stop this pass; a later actual work request or reopen retries.
            blobStore.cancelCleanupPass()
        }
        blobCleanupNeedsAnotherPass = false
        blobCleanupTask = nil
        return false
    }

    /// Visit at most 32 small content ownership rows and delete at most 32
    /// representations. Bounding content count alone would still cascade an
    /// arbitrarily large set of inline payload pages in one transaction.
    private func reclaimDetachedContentBatch() throws -> Bool {
        let rows = try database.prepare("""
            SELECT c.id,
                EXISTS(SELECT 1 FROM history_items h WHERE h.id=c.itemID),
                EXISTS(SELECT 1 FROM history_items h WHERE h.currentContentID=c.id)
            FROM contents c WHERE c.id > ? ORDER BY c.id LIMIT 32
            """, bindings: [.text(contentCleanupAfterID)])
        var candidates: [(id: String, owned: Bool, active: Bool)] = []
        while try rows.step() {
            candidates.append(try (rows.text(at: 0), rows.integer(at: 1) != 0, rows.integer(at: 2) != 0))
        }
        rows.finalize()
        guard !candidates.isEmpty else { return true }
        // Do not turn a corrupt cross-owner current-content reference into
        // destruction of a value that a live item still claims to own.
        guard !candidates.contains(where: { !$0.owned && $0.active }) else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        if candidates.allSatisfy({ $0.owned }) {
            contentCleanupAfterID = candidates[candidates.count - 1].id
            return false
        }
        var after = contentCleanupAfterID
        var unreferencedCandidates: [UUID] = []
        try database.writeTransaction(checkingCancellation: true) {
            var remaining = 32
            for candidate in candidates {
                try Task.checkCancellation()
                if candidate.owned {
                    after = candidate.id
                    continue
                }
                guard remaining > 0 else { break }
                let representations = try database.prepare("""
                    SELECT ordinal,blobID FROM representations
                    WHERE contentID=? ORDER BY ordinal LIMIT ?
                    """, bindings: [.text(candidate.id), .integer(Int64(remaining))])
                var removed: [(ordinal: Int64, blob: UUID?)] = []
                while try representations.step() {
                    let blob: UUID?
                    if let name = try representations.optionalText(at: 1) {
                        guard let id = UUID(uuidString: name) else {
                            throw HistoryFailure.persistence(.corruptStoredValue)
                        }
                        blob = id
                    } else { blob = nil }
                    removed.append(try (representations.integer(at: 0), blob))
                }
                representations.finalize()
                for representation in removed {
                    try database.execute(
                        "DELETE FROM representations WHERE contentID=? AND ordinal=?",
                        bindings: [.text(candidate.id), .integer(representation.ordinal)]
                    )
                    if let blob = representation.blob { unreferencedCandidates.append(blob) }
                }
                remaining -= removed.count
                let remainingRows = try database.prepare(
                    "SELECT 1 FROM representations WHERE contentID=? LIMIT 1", bindings: [.text(candidate.id)]
                )
                let hasRemaining = try remainingRows.step()
                remainingRows.finalize()
                // Leave the cursor before a partially reclaimed content so
                // the next batch resumes it; its absent owner is durable.
                if hasRemaining { break }
                try database.execute("DELETE FROM contents WHERE id=?", bindings: [.text(candidate.id)])
                after = candidate.id
            }
        }
        contentCleanupAfterID = after
        // Release disk space after each small SQL commit, not only after a
        // complete directory scan. Shared files survive until the final
        // representation reference disappears. No suspension splits check
        // and unlink from a competing publication on this Authority.
        for id in unreferencedCandidates {
            let references = try database.prepare(
                "SELECT 1 FROM representations WHERE blobID=? LIMIT 1", bindings: [.text(id.uuidString)]
            )
            let referenced = try references.step()
            references.finalize()
            if !referenced { try blobStore.remove(id: id) }
        }
        return false
    }

    /// Actor serialization ensures no batch is executing when this returns.
    /// A cancelled task parked before its next batch only exits when resumed.
    internal func cancelBlobCleanup() {
        blobCleanupTask?.cancel()
        blobCleanupTask = nil
        blobCleanupNeedsAnotherPass = false
        contentCleanupAfterID = ""
        contentCleanupFinished = false
        blobStore.cancelCleanupPass()
    }

    /// Tests and orderly shutdown can join the actual scheduled work, without
    /// timers, repeatedly checking state, or starting another scan.
    internal func waitForBlobCleanup() async {
        await blobCleanupTask?.value
    }
}
