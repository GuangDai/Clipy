#if DEBUG
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

/// Cancelled panel queries stop at existing read boundaries and release the
/// Authority's transaction; these tests do not rely on wall-clock races.
struct RecentReadCancellationTests {
    @Test(arguments: [
        HistoryBrowseKind.recent,
        .search(text: "", mode: .exact),
        .search(text: "", mode: .regexp),
        .search(text: "", mode: .fuzzy),
    ])
    func cancelledQueuedBrowseDoesNotFetchRows(kind: HistoryBrowseKind) async throws {
        let history = try await fixture()
        let gate = SuspensionGate()
        let (events, continuation) = AsyncStream<StorageLifecycleDebugEvent>.makeStream()
        await history.authority.setStorageLifecycleDebugProbe(.init(isEnabled: true) {
            _ = continuation.yield($0)
        })
        await history.authority.setSuspensionHandler { point in
            if point == .readEntry { await gate.park(at: point.rawValue) }
        }
        let task = Task {
            try await history.browse(.init(kind: kind, limit: 7))
        }
        await gate.waitForPark(AuthoritySuspensionPoint.readEntry.rawValue)
        task.cancel()
        await history.authority.setSuspensionHandler(nil)
        await gate.resume(AuthoritySuspensionPoint.readEntry.rawValue)
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        continuation.finish()
        for await event in events {
            #expect(event.phase != .recentFetchBegin)
        }
        let replacement = try await history.browse(.init(kind: kind, limit: 7))
        #expect(replacement.rows.map(\.title) == ["recent cancellation"])
    }

    @Test(arguments: [
        StorageLifecycleDebugPhase.recentPinnedFetchComplete,
        .recentFetchComplete,
    ])
    func cancelledReadStopsBeforeTheNextLaneOrPublication(phase: StorageLifecycleDebugPhase) async throws {
        let history = try await fixture()
        let (events, continuation) = AsyncStream<StorageLifecycleDebugEvent>.makeStream()
        await history.authority.setStorageLifecycleDebugProbe(.init(isEnabled: true) { event in
            _ = continuation.yield(event)
            if event.phase == phase {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        })
        // Cancel only this child, from the synchronous existing probe. No
        // mutable state crosses the actor or survives the read transaction.
        let task = Task {
            try await history.browse(.init(kind: .recent, limit: 7))
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        continuation.finish()
        var reachedCancellation = false
        for await event in events {
            if event.phase == phase { reachedCancellation = true }
            if phase == .recentPinnedFetchComplete {
                #expect(event.phase != .recentUnpinnedFetchComplete)
                #expect(event.phase != .recentFetchComplete)
            }
        }
        #expect(reachedCancellation)
        await history.authority.setStorageLifecycleDebugProbe(.init(isEnabled: false))
        // A replacement uses the same connection. A leaked transaction
        // would reject BEGIN and prevent this ordinary read from succeeding.
        let replacement = try await history.browse(.init(kind: .recent, limit: 7))
        #expect(replacement.rows.map(\.title) == ["recent cancellation"])
    }

    private func fixture() async throws -> SQLiteHistory {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        _ = try await history.perform(.capture(WSSupport.textCapture(
            "recent cancellation", observedAt: Date(timeIntervalSinceReferenceDate: 1)
        )))
        return history
    }
}
#endif
