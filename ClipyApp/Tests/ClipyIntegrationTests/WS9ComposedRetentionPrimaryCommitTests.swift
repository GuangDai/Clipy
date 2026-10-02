/// WS9Composed — Retention in the primary commit through the composed app
/// stack (docs/testing.md WS9; docs/architecture.md):
/// configure maximum unpinned count 2, insert three unpinned items, and
/// expect the OLDEST eligible item retired in the third insert's SAME
/// History Commit — leaving two unpinned items, the retired ID gone from
/// every read, and ChangePosition advanced exactly once for that commit.
/// The pinned exemption is exercised too: with the oldest item pinned, the
/// newer unpinned item retires instead (D13).
import Foundation
import HistoryCore
import HistoryStorage
@testable import ClipyApp
import Testing

struct WS9ComposedRetentionPrimaryCommitTests {

    /// WS9 (docs/testing.md): the third insert into a
    /// maximum-2 store retires the OLDEST unpinned item in the same commit
    /// (receipt at exactly one position advance), and the composed panel
    /// (`HistoryViewState`) settles on the two survivors.
    @Test @MainActor
    func capturesRetireOldestUnpinnedInTheSameCommitAndPreserveTheOlderPin() async throws {
        let history = try await ComposedSupport.openMemoryHistory(maximumUnpinned: 2)

        let base = Date(timeIntervalSinceReferenceDate: 700_201_300)
        let alphaText = "ws9 composed alpha"
        let bravoText = "ws9 composed bravo"
        let charlieText = "ws9 composed charlie"

        func capture(_ text: String, _ offset: TimeInterval) async throws -> HistoryItemID {
            let receipt = try await history.perform(.capture(
                ComposedSupport.textCapture(
                    text,
                    observedAt: base.addingTimeInterval(offset),
                    source: "com.example.ws9composed"
                )
            ))
            return try #require(
                ComposedSupport.insertedReference(from: receipt, "WS9 arrange")
            ).id
        }

        let alphaID = try await capture(alphaText, 0)
        let bravoID = try await capture(bravoText, 100)

        // Insert number three: alpha (oldest) retires INSIDE this commit
        // (02 §12 eviction order: lastCopiedAt ascending), and the receipt
        // still advances Change Position exactly once (02 §13).
        let thirdReceipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                charlieText,
                observedAt: base.addingTimeInterval(200),
                source: "com.example.ws9composed"
            )
        ))
        let thirdCommit = try #require(
            ComposedSupport.commit(of: thirdReceipt, "WS9"),
            "WS9: the retention-bearing insert is a History Commit"
        )
        #expect(
            thirdCommit.position.rawValue == 3,
            "WS9: three inserts, three commits — retirement rides the primary commit"
        )

        // Two unpinned items remain; the retired ID is gone from every
        // public read (WS16 vocabulary): browse, details, paste.
        let page = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 50)
        )
        #expect(page.rows.count == 2, "WS9: two unpinned items remain")
        #expect(
            !page.rows.map(\.item.id).contains(alphaID),
            "WS9: the retired ID is absent from browse"
        )
        do {
            _ = try await history.details(for: alphaID)
            Issue.record("WS9: expected .notFound for the retired item")
        } catch let failure as HistoryFailure {
            #expect(failure == .notFound(alphaID))
        }
        do {
            _ = try await history.pastePayload(for: alphaID)
            Issue.record("WS9: expected .notFound from pastePayload for the retired item")
        } catch let failure as HistoryFailure {
            #expect(failure == .notFound(alphaID))
        }

        // The composed panel settles on the two survivors.
        let viewState = HistoryViewState(history: history)
        defer { viewState.deactivate() }
        viewState.activate()
        let settled = await ComposedSupport.waitFor { viewState.rows.count == 2 }
        try #require(settled, "WS9: the view state observes the post-retention set")
        #expect(!viewState.rows.map(\.item.id).contains(alphaID))

        // Reuse the two observed survivors: the oldest becomes protected,
        // and the next over-cap capture must retire the older unpinned row.
        let charlieID = try #require(
            ComposedSupport.insertedReference(from: thirdReceipt, "WS9 surviving unpinned")
        ).id
        _ = try await history.perform(.placePinned(bravoID, at: .last))
        _ = try await capture("ws9 composed newer", 300)
        let beforeFinalCapture = try await history.usage()
        _ = try await capture("ws9 composed newest", 400)
        let afterFinalCapture = try await history.usage()
        #expect(afterFinalCapture.position.rawValue == beforeFinalCapture.position.rawValue + 1)
        #expect(try await history.details(for: bravoID).pinnedPosition == 0)
        await #expect(throws: HistoryFailure.notFound(charlieID)) {
            try await history.details(for: charlieID)
        }
        let protectedPage = try await history.browse(.init(kind: .recent, limit: 50))
        #expect(protectedPage.rows.count == 3)
        #expect(protectedPage.rows.contains { $0.item.id == bravoID })
        #expect(await ComposedSupport.waitFor {
            viewState.rows.count == 3 && viewState.pinnedRows.first?.item.id == bravoID
                && !viewState.rows.contains { $0.item.id == charlieID }
        }, "Pinned exemption must also reach the composed panel")
    }

}
