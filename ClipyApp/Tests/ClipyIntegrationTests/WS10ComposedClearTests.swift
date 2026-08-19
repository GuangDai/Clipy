/// WS10Composed — Clear atomicity through the composed app stack
/// (docs/06-cross-cutting.md §8 WS10; docs/02-domain.md §12): with pinned
/// and unpinned items present, `.clear(.unpinned)` removes the complete
/// unpinned set in ONE commit and preserves the pins; a later `.clear(.all)`
/// removes every remaining row in one commit. Each clear's receipt is
/// `.cleared(count:)` at exactly one position advance, and the composed
/// panel (`HistoryViewState.clear(_:)`) drives the actions exactly as the
/// panel's footer menu does.
import Foundation
import HistoryCore
import HistoryStorage
import PresentationUI
import Testing

struct WS10ComposedClearTests {

    /// WS10 (docs/06-cross-cutting.md §8): clear-scenario committed through
    /// the composed interaction surface — `viewState.clear(.unpinned)` /
    /// `.clear(.all)` (the footer-menu actions, 03b §12) — with the final
    /// position arithmetic proving both clears were SEPARATE single commits
    /// (no partial page ever observable in between: browse between the two
    /// clears shows only the pinned row; the `.cleared(count:)` receipts
    /// themselves are pinned by the storage-side WS10 suite).
    @Test @MainActor
    func clearUnpinnedPreservesPinsThenClearAllRemovesEverything() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let viewState = HistoryViewState(history: history)
        defer { viewState.deactivate() }
        viewState.activate()

        let base = Date(timeIntervalSinceReferenceDate: 700_201_500)
        func capture(_ text: String, _ offset: TimeInterval) async throws -> HistoryItemID {
            let receipt = try await history.perform(.capture(
                ComposedSupport.textCapture(
                    text,
                    observedAt: base.addingTimeInterval(offset),
                    source: "com.example.ws10composed"
                )
            ))
            return try #require(
                ComposedSupport.insertedReference(from: receipt, "WS10 arrange")
            ).id
        }

        // Three rows; the newest is pinned.
        let oldUnpinnedID = try await capture("ws10 composed oldest", 0)
        let newerUnpinnedID = try await capture("ws10 composed newer", 100)
        let pinnedID = try await capture("ws10 composed pinned", 200)
        _ = try await history.perform(.placePinned(pinnedID, at: .last)) // commit 4

        // `.clear(.unpinned)` through the panel action: one commit (5),
        // `.cleared(count: 2)`, the pinned row preserved.
        viewState.clear(.unpinned)
        let unpinnedCleared = await ComposedSupport.waitFor {
            viewState.rows.count == 1 && viewState.rows.first?.item.id == pinnedID
        }
        #expect(
            unpinnedCleared,
            "WS10: the composed panel observes the complete unpinned removal"
        )
        #expect(viewState.failure == nil)
        let afterUnpinned = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 50)
        )
        #expect(
            afterUnpinned.rows.map(\.item.id) == [pinnedID],
            "WS10 (browse between the clears): no partial page — exactly the pinned row"
        )
        for retiredID in [oldUnpinnedID, newerUnpinnedID] {
            do {
                _ = try await history.details(for: retiredID)
                Issue.record("WS10: expected .notFound for a cleared unpinned item")
            } catch let failure as HistoryFailure {
                #expect(failure == .notFound(retiredID))
            }
        }
        // The pin itself is untouched (ordinal 0, still placed).
        let pinnedDetails = try await history.details(for: pinnedID)
        #expect(
            pinnedDetails.pinnedPosition == 0,
            "WS10: clear(.unpinned) preserves the pinned item's placement"
        )

        // `.clear(.all)` through the panel action: one commit (6),
        // `.cleared(count: 1)`, nothing remains.
        viewState.clear(.all)
        let allCleared = await ComposedSupport.waitFor { viewState.rows.isEmpty }
        #expect(allCleared, "WS10: the composed panel observes the empty store")
        let afterAll = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 50)
        )
        #expect(afterAll.rows.isEmpty)

        // Position proof that each clear was ONE commit: 3 inserts + 1 pin
        // + 2 clears = 6 (02 §13); the next real commit lands at 7.
        let followUp = try await history.perform(.capture(
            ComposedSupport.textCapture(
                "ws10 composed after clear",
                observedAt: base.addingTimeInterval(300),
                source: "com.example.ws10composed"
            )
        ))
        let followUpCommit = try #require(
            ComposedSupport.commit(of: followUp, "WS10 position proof")
        )
        #expect(
            followUpCommit.position.rawValue == 7,
            "WS10: both clears advanced Change Position exactly once each"
        )
    }
}
