import Foundation
@testable import HistoryCore
@testable import ClipyApp
import Testing

struct HistoryDetailsLifecycleOwnershipTests {
    @Test func committedRevisionCannotAdvanceAnOwnerAfterItDisappears() throws {
        let original = HistoryItemReference(id: .init(rawValue: UUID()), contentVersion: .initial)
        let revised = HistoryItemReference(id: original.id, contentVersion: .init(rawValue: 2))
        var fence = HistoryDetailsLoadFence()
        let pending = try #require(fence.begin())
        fence.suspend()

        #expect(!fence.advanceReference(from: original, to: revised))
        #expect(!fence.owns(fence.generation), "Even the latest token has no live UI owner after disappearance")
        #expect(!fence.accepts(fence.generation, returned: original, expected: original, isCancelled: false))

        fence.resume()
        #expect(!fence.owns(pending))
        #expect(fence.advanceReference(from: original, to: revised))
        let current = try #require(fence.begin())
        #expect(fence.accepts(current, returned: revised, expected: revised, isCancelled: false))
    }
}
