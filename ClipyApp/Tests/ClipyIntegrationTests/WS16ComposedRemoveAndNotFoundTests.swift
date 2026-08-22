/// WS16Composed — Remove and not-found failures through the composed app
/// stack (docs/06-cross-cutting.md §8 WS16; docs/03b-instruction-set.md
/// §10): `viewState.remove(_:)` (the row's ⌫ command) removes exactly one
/// item with one position advance; the ID is then absent from browse,
/// details, and paste; and the follow-up failure vocabulary on the absent
/// ID — `.notFound` for remove/unpin/revise,
/// `.invalidPinnedPlacement(.targetMissing)` for placePinned — is stored
/// into the view state's failure banner (03b §10 → FailurePresentation).
import Foundation
import HistoryCore
import HistoryStorage
import PresentationUI
import Testing

struct WS16ComposedRemoveAndNotFoundTests {

    /// WS16 (docs/06-cross-cutting.md §8): insert one item, remove it via
    /// the composed panel interaction, and prove the removed ID's absence
    /// plus the typed failure producers — with the position proof that one
    /// removal and NOTHING after it advanced the position.
    @Test @MainActor
    func removeThenAbsentIDFailsTypedThroughEveryFollowUp() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let viewState = HistoryViewState(history: history)
        defer { viewState.deactivate() }
        viewState.activate()

        let insertReceipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                "ws16 composed doomed item",
                observedAt: Date(timeIntervalSinceReferenceDate: 700_202_200),
                source: "com.example.ws16composed"
            )
        ))
        let inserted = try #require(
            ComposedSupport.insertedReference(from: insertReceipt, "WS16 arrange")
        )
        #expect(
            await ComposedSupport.waitFor { viewState.rows.count == 1 },
            "WS16: the row is observed before removal"
        )

        // The row's Remove command. The removal is one commit at position 2
        // (insert = 1), proven below via the follow-up commit.
        viewState.remove(inserted.id)
        #expect(
            await ComposedSupport.waitFor { viewState.rows.isEmpty },
            "WS16: the removed row disappears from the observed page"
        )

        // The ID is absent from every read family (WS16): browse, details,
        // paste.
        let page = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 50)
        )
        #expect(
            !page.rows.map(\.item.id).contains(inserted.id),
            "WS16: browse omits the removed ID"
        )
        do {
            _ = try await history.details(for: inserted.id)
            Issue.record("WS16: expected .notFound from details")
        } catch let failure as HistoryFailure {
            #expect(failure == .notFound(inserted.id))
        }
        do {
            _ = try await history.pastePayload(for: inserted.id)
            Issue.record("WS16: expected .notFound from pastePayload")
        } catch let failure as HistoryFailure {
            #expect(failure == .notFound(inserted.id))
        }

        // Follow-up producers on the absent ID (03b §10). The async
        // passthrough (revise) throws; the fire-and-forget interactions
        // (remove/unpin/placePinned) land in `failure`.
        do {
            _ = try await viewState.revise(
                RevisionRequest(
                    itemID: inserted.id,
                    expected: inserted.contentVersion,
                    intent: .revert(to: .canonical)
                )
            )
            Issue.record("WS16: expected .notFound from revise")
        } catch let failure as HistoryFailure {
            #expect(failure == .notFound(inserted.id))
        }

        viewState.remove(inserted.id)
        #expect(
            await ComposedSupport.waitFor {
                viewState.failure == .notFound(inserted.id)
            },
            "WS16 (03b §10): the second remove surfaces .notFound in the banner"
        )

        viewState.unpin(inserted.id)
        #expect(
            await ComposedSupport.waitFor {
                viewState.failure == .notFound(inserted.id)
            },
            "WS16: unpin on the absent ID surfaces .notFound"
        )

        // placePinned uses its own anchor-missing vocabulary by design
        // (03b §10 PinnedPlacementFailure): `.targetMissing`, not `.notFound`.
        viewState.pin(inserted.id, at: .first)
        #expect(
            await ComposedSupport.waitFor {
                viewState.failure == .invalidPinnedPlacement(.targetMissing)
            },
            "WS16 (03b §10): placePinned on the absent ID reports targetMissing"
        )

        // The user-facing message for the banner (03b §10 →
        // FailurePresentation), as the panel renders it.
        #expect(
            FailurePresentation.message(for: .notFound(inserted.id)) == "Item was removed"
        )

        // Position proof: insert(1) + removal(2), and every failed follow-up
        // above advanced NOTHING — the next healthy commit lands at 3.
        let followUpReceipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                "ws16 composed survivor",
                observedAt: Date(timeIntervalSinceReferenceDate: 700_202_250),
                source: "com.example.ws16composed"
            )
        ))
        let followUpCommit = try #require(
            ComposedSupport.commit(of: followUpReceipt, "WS16 position proof")
        )
        #expect(
            followUpCommit.position.rawValue == 3,
            "WS16: one removal commit; the typed failures committed nothing"
        )
    }
}
