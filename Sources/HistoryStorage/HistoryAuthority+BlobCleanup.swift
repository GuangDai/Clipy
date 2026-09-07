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

    /// Actor serialization ensures no batch is executing when this returns.
    /// A cancelled task parked before its next batch only exits when resumed.
    internal func cancelBlobCleanup() {
        blobCleanupTask?.cancel()
        blobCleanupTask = nil
        blobCleanupNeedsAnotherPass = false
        blobStore.cancelCleanupPass()
    }

    /// Tests and orderly shutdown can join the actual scheduled work, without
    /// timers, repeatedly checking state, or starting another scan.
    internal func waitForBlobCleanup() async {
        await blobCleanupTask?.value
    }
}
