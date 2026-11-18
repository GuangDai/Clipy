/// WS8Composed — Pin order through the composed app stack
/// (docs/testing.md WS8; docs/architecture.md; D12): pin three
/// items, move the last before the first, then unpin the item now occupying
/// the middle position. After each receipt the public order is asserted
/// through the detail reads (`pinnedPosition` ordinals unique and exactly
/// `0 ..< count`), Content Versions remain unchanged, and the composed panel
/// surface shows pins above ordinary history when browsing in the default order.
import Foundation
import HistoryCore
import HistoryStorage
@testable import ClipyApp
import Testing

struct WS8ComposedPinOrderTests {

    /// Asserts one committed `.placePinned`/`.unpin` receipt advanced the
    /// position exactly once, and returns nothing (issues are recorded).
    private static func expectSingleAdvance(
        _ receipt: HistoryReceipt,
        position expectedPosition: UInt64,
        _ clause: String
    ) {
        guard let commit = ComposedSupport.commit(of: receipt, clause) else { return }
        #expect(
            commit.position.rawValue == expectedPosition,
            "\(clause): Change Position advanced exactly once"
        )
    }

    /// Asserts the current public pin ordinals are unique and exactly
    /// `0 ..< count` (D12) and match the expected pinned ID order.
    private static func expectPinnedOrder(
        _ history: SQLiteHistory,
        ids expectedOrder: [HistoryItemID],
        _ clause: String
    ) async throws {
        var ordinals: [(HistoryItemID, Int?)] = []
        for id in expectedOrder {
            let details = try await history.details(for: id)
            ordinals.append((id, details.pinnedPosition))
        }
        // Every expected-pinned item has an ordinal and vice versa.
        #expect(
            ordinals.allSatisfy { $0.1 != nil },
            "\(clause): every expected-pinned item reports an ordinal"
        )
        let positions = ordinals.compactMap { $0.1 }
        #expect(
            Set(positions) == Set(0..<expectedOrder.count),
            "\(clause): stored ordinals are unique and exactly 0..<count"
        )
        // Public order = ascending ordinal.
        let ordered = ordinals.sorted { ($0.1 ?? -1) < ($1.1 ?? -1) }
        #expect(
            ordered.map { $0.0 } == expectedOrder,
            "\(clause): public pinned order matches"
        )
    }

    /// WS8 (docs/testing.md): pin A, B, C (`.last`), move C
    /// `.before` A ([A,B,C] → [C,A,B]), then unpin the middle item (A),
    /// leaving [C,B]. Content Versions never move; each non-no-op action
    /// advances Change Position once; the composed view state renders the
    /// pinned/unpinned lanes from the replacement page (04 §5).
    @Test @MainActor
    func pinReorderUnpinKeepsUniqueOrdinalsAndComposedLanes() async throws {
        let history = try await ComposedSupport.openMemoryHistory()

        let base = Date(timeIntervalSinceReferenceDate: 700_201_200)
        let textA = "ws8 composed alpha"
        let textB = "ws8 composed bravo"
        let textC = "ws8 composed charlie"

        func capture(_ text: String, _ offset: TimeInterval) async throws -> HistoryItemID {
            let receipt = try await history.perform(.capture(
                ComposedSupport.textCapture(
                    text,
                    observedAt: base.addingTimeInterval(offset),
                    source: "com.example.ws8composed"
                )
            ))
            return try #require(
                ComposedSupport.insertedReference(from: receipt, "WS8 arrange")
            ).id
        }

        let idA = try await capture(textA, 0)
        let idB = try await capture(textB, 100)
        let idC = try await capture(textC, 200)

        // Pin all three at the back: A→0, B→1, C→2 (02 §10 steps 2–3).
        Self.expectSingleAdvance(
            try await history.perform(.placePinned(idA, at: .last)), position: 4, "WS8 pin A"
        )
        Self.expectSingleAdvance(
            try await history.perform(.placePinned(idB, at: .last)), position: 5, "WS8 pin B"
        )
        Self.expectSingleAdvance(
            try await history.perform(.placePinned(idC, at: .last)), position: 6, "WS8 pin C"
        )
        try await Self.expectPinnedOrder(history, ids: [idA, idB, idC], "WS8 after pins")

        // Move the LAST before the FIRST: [A,B,C] → [C,A,B] (02 §10 steps 2–4).
        Self.expectSingleAdvance(
            try await history.perform(.placePinned(idC, at: .before(idA))),
            position: 7,
            "WS8 move C before A"
        )
        try await Self.expectPinnedOrder(history, ids: [idC, idA, idB], "WS8 after move")

        // Unpin the item now in the MIDDLE (A): [C,B] with ordinals 0,1.
        Self.expectSingleAdvance(
            try await history.perform(.unpin(idA)), position: 8, "WS8 unpin A"
        )
        try await Self.expectPinnedOrder(history, ids: [idC, idB], "WS8 after unpin")

        // Content Versions remain unchanged through every metadata-only
        // action (03a §6: placedPinned/unpinned keep the Content Version).
        for id in [idA, idB, idC] {
            let details = try await history.details(for: id)
            #expect(
                details.item.contentVersion.rawValue == 1,
                "WS8: pinning never mints a Content Version"
            )
        }
        let unpinnedDetails = try await history.details(for: idA)
        #expect(
            unpinnedDetails.pinnedPosition == nil,
            "WS8: the unpinned item left the pinned lane"
        )

        // The composed panel surface renders the same split from the real
        // observe loop, with a newer unpinned copy below both pins by default.
        let idD = try await capture("ws8 composed delta", 300)
        let viewState = HistoryViewState(history: history)
        defer { viewState.deactivate() }
        viewState.activate()
        try #require(await ComposedSupport.waitFor {
            viewState.rows.count == 4
        })
        let pinnedFirst = [idC, idB, idD, idA]
        #expect(viewState.rows.map(\.item.id) == pinnedFirst)

        let saved = HistorySearchDefinition(query: "ws8 composed", mode: .fuzzy, sortOrder: .newestFirst)
        try #require(saved.apply(to: viewState))
        #expect(viewState.searchMode == .fuzzy)
        try #require(await ComposedSupport.waitFor {
            viewState.rows.first?.search != nil
        })
        #expect(viewState.rows.map(\.item.id) == [idD, idC, idB, idA])

        viewState.resetSearchForOpening()
        #expect(viewState.searchMode == .exact)
        try #require(await ComposedSupport.waitFor {
            viewState.rows.count == 4
        })
        #expect(viewState.rows.map(\.item.id) == pinnedFirst)

        viewState.searchMode = .regexp
        viewState.sortOrder = .oldestFirst
        try #require(saved.apply(to: viewState))
        #expect(viewState.preferredSortOrder == .oldestFirst)
        viewState.resetSearchForOpening()
        #expect(viewState.searchMode == .regexp)
        try #require(await ComposedSupport.waitFor {
            viewState.rows.count == 4
        })
        #expect(viewState.rows.map(\.item.id) == [idA, idB, idC, idD])
        #expect(viewState.failure == nil)
    }
}
