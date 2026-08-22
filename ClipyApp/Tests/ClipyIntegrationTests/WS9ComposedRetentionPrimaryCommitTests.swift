/// WS9Composed — Retention in the primary commit through the composed app
/// stack (docs/06-cross-cutting.md §8 WS9; docs/02-domain.md §12):
/// configure maximum unpinned count 2, insert three unpinned items, and
/// expect the OLDEST eligible item retired in the third insert's SAME
/// History Commit — leaving two unpinned items, the retired ID gone from
/// every read, and ChangePosition advanced exactly once for that commit.
/// The pinned exemption is exercised too: with the oldest item pinned, the
/// newer unpinned item retires instead (D13).
///
/// The gate's planner-seam capacity clause (`capacityExceeded(.retainedItems)`
/// at an all-pinned hard bound) is a Domain-planner seam test and stays in
/// `Tests/HistoryStorageTests/WS9RetentionPrimaryCommitTests.swift`.
import Foundation
import HistoryCore
import HistoryStorage
import PresentationUI
import Testing

struct WS9ComposedRetentionPrimaryCommitTests {

    /// WS9 (docs/06-cross-cutting.md §8): the third insert into a
    /// maximum-2 store retires the OLDEST unpinned item in the same commit
    /// (receipt at exactly one position advance), and the composed panel
    /// (`HistoryViewState`) settles on the two survivors.
    @Test @MainActor
    func thirdInsertRetiresOldestUnpinnedInTheSameCommit() async throws {
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
        _ = try await capture(bravoText, 100)

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
        #expect(settled, "WS9: the view state observes the post-retention set")
        #expect(!viewState.rows.map(\.item.id).contains(alphaID))
    }

    /// WS9 pinned-exemption clause (02 §12 D13; 02 §5/06 §2 "Pinned items
    /// are exempt from the user maximum-unpinned policy"): the cap counts
    /// UNPINNED items only, so with the oldest item PINNED and the cap at 2,
    /// the FOURTH insert pushes the unpinned count to 3 and retires the
    /// oldest UNPINNED item — the newer unpinned item retires, never the pin,
    /// even though the pin is older overall.
    @Test
    func pinnedOldestItemIsExemptAndNewerUnpinnedRetires() async throws {
        let history = try await ComposedSupport.openMemoryHistory(maximumUnpinned: 2)

        let base = Date(timeIntervalSinceReferenceDate: 700_201_400)
        func capture(_ text: String, _ offset: TimeInterval) async throws -> HistoryItemID {
            let receipt = try await history.perform(.capture(
                ComposedSupport.textCapture(
                    text,
                    observedAt: base.addingTimeInterval(offset),
                    source: "com.example.ws9composed.pin"
                )
            ))
            return try #require(
                ComposedSupport.insertedReference(from: receipt, "WS9 pin-exempt arrange")
            ).id
        }

        let oldestID = try await capture("ws9 composed pinned oldest", 0)
        let middleID = try await capture("ws9 composed middle", 100)
        // Pin the oldest item: the exemption now protects it (D13), and it
        // leaves the unpinned count at 1 against the cap of 2.
        let pinReceipt = try await history.perform(.placePinned(oldestID, at: .last))
        #expect(ComposedSupport.commit(of: pinReceipt, "WS9 pin") != nil)

        _ = try await capture("ws9 composed newer", 200)
        // Insert four pushes the UNPINNED count to 3 > 2: the victim is the
        // oldest UNPINNED item (middle) by lastCopiedAt ascending (02 §12),
        // never the pinned oldest — without D13 the older pin would retire
        // instead.
        _ = try await capture("ws9 composed newest", 300)

        // The pin survives; the middle unpinned item retired in its place.
        let details = try await history.details(for: oldestID)
        #expect(details.pinnedPosition == 0, "WS9 (D13): the pinned item was not retired")
        do {
            _ = try await history.details(for: middleID)
            Issue.record("WS9 (D13): expected .notFound for the retired unpinned item")
        } catch let failure as HistoryFailure {
            #expect(failure == .notFound(middleID))
        }
        let page = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 50)
        )
        #expect(
            page.rows.contains { $0.item.id == oldestID },
            "WS9: the pinned row is still browsable"
        )
        #expect(
            page.rows.count == 3,
            "WS9: pin (1) + two surviving unpinned items — the cap excludes pins"
        )
    }
}
