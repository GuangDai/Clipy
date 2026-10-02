import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct MutationCancellationTests {
    enum Operation: CaseIterable, Sendable { case pin, unpin, clear, countRetention }

    @Test(arguments: Operation.allCases)
    func alreadyCancelledNoOpStopsBeforePlanningAndLeavesHistoryUsable(operation: Operation) async throws {
        let history = try await WSSupport.makeHistory()
        let action: HistoryAction
        switch operation {
        case .pin:
            let item = try await RetainedBytesTestSupport.capture("pinned item", in: history)
            _ = try await history.perform(.placePinned(item.id, at: .first))
            action = .placePinned(item.id, at: .first)
        case .unpin:
            let item = try await RetainedBytesTestSupport.capture("unpinned item", in: history)
            action = .unpin(item.id)
        case .clear:
            action = .clear(.all)
        case .countRetention:
            action = .setRetentionPolicy(maximumUnpinnedItems: 200)
        }
        guard case .unchanged = try await history.perform(action) else {
            Issue.record("Expected an unchanged operation before cancellation")
            return
        }
        let before = try await GatewayHistoryTestSnapshot.read(from: history.authority)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await history.perform(action)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await GatewayHistoryTestSnapshot.read(from: history.authority) == before)

        let oldPosition = try await history.usage().position
        let item = try await RetainedBytesTestSupport.capture("next capture", in: history)
        #expect(try await history.pastePayload(for: item.id).item == item)
        #expect(try await history.usage().position.rawValue == oldPosition.rawValue + 1)
    }
}
