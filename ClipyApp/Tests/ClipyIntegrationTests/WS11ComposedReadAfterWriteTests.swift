/// WS11Composed — Receipt read-after-write through the composed app stack
/// (docs/06-cross-cutting.md §8 WS11; docs/04-coherence.md §3): after every
/// committed outcome family, the relevant composed read — the REAL
/// `HistoryViewState` (its rows via the observe loop) plus the purpose
/// reads behind it — reflects that commit without any manual refresh. Each
/// interaction goes through the view state the way the panel drives it
/// (03b §12); the thin async passthroughs (`details`, `revise`,
/// `applyMaximumUnpinnedItems`) are awaited directly because the panel's
/// sheets own their completion.
import Foundation
import HistoryCore
import HistoryStorage
import PresentationUI
import Testing

struct WS11ComposedReadAfterWriteTests {

    /// WS11 (docs/06-cross-cutting.md §8; 04 §3): one store; each committed
    /// outcome family is immediately visible — insert, coalesce, placePinned,
    /// revise, remove, clear, setRetentionPolicy — with the observed page
    /// replacing rows (04 §5) and no notification waiting anywhere.
    @Test @MainActor
    func everyCommittedOutcomeIsImmediatelyVisibleWithoutRefresh() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let viewState = HistoryViewState(history: history)
        defer { viewState.deactivate() }
        viewState.activate()

        let base = Date(timeIntervalSinceReferenceDate: 700_201_600)

        // (a) capture → rows + details.
        let textA = "ws11 composed alpha"
        let insertReceipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                textA, observedAt: base, source: "com.example.ws11composed.a"
            )
        ))
        let inserted = try #require(
            ComposedSupport.insertedReference(from: insertReceipt, "WS11 (a)")
        )
        #expect(
            await ComposedSupport.waitFor {
                viewState.rows.contains { $0.item == inserted }
            },
            "WS11 (a): the insert reaches the observed rows without refresh"
        )
        let detailsAfterInsert = try await viewState.details(for: inserted.id)
        #expect(detailsAfterInsert.item == inserted)

        // (b) coalesce (same capture again) → occurrence count 2 at the
        // SAME reference, rows still one.
        _ = try await history.perform(.capture(
            ComposedSupport.textCapture(
                textA,
                observedAt: base.addingTimeInterval(50),
                source: "com.example.ws11composed.b"
            )
        ))
        #expect(
            await ComposedSupport.waitFor { viewState.rows.first?.copyCount == 2 },
            "WS11 (b): the coalesce is visible (copyCount 2)"
        )
        let afterCoalesce = try await viewState.details(for: inserted.id)
        #expect(afterCoalesce.occurrence.count == 2)
        #expect(afterCoalesce.item.contentVersion == inserted.contentVersion)

        // (c) placePinned (the panel's Pin to Top) → pinned lane.
        viewState.pin(inserted.id, at: .first)
        #expect(
            await ComposedSupport.waitFor {
                viewState.pinnedRows.contains { $0.item.id == inserted.id }
            },
            "WS11 (c): the pin reaches the observed pinned lane"
        )
        #expect(viewState.failure == nil)

        // (d) revise (the editor's Save path) → new reference in rows; the
        // stale reference no longer applies (04 §9 reference-exactness).
        let revisedText = "ws11 composed revised"
        let reviseReceipt = try await viewState.revise(
            RevisionRequest(
                itemID: inserted.id,
                expected: afterCoalesce.item.contentVersion,
                intent: .replace(RevisionDraft(decisions: [
                    RevisionDecision(
                        typeIdentifier: ComposedSupport.plainTextTypeIdentifier,
                        action: .replace(bytes: Data(revisedText.utf8))
                    ),
                ]))
            )
        )
        let revised = try #require(
            ComposedSupport.revisedReference(from: reviseReceipt, "WS11 (d)")
        )
        #expect(
            await ComposedSupport.waitFor {
                viewState.pinnedRows.contains { $0.item == revised }
            },
            "WS11 (d): the revision's new reference replaces the row"
        )
        let detailsAfterRevise = try await viewState.details(for: inserted.id)
        #expect(
            detailsAfterRevise.item.contentVersion == revised.contentVersion
        )

        // (e) setRetentionPolicy (the settings' Apply) → the new value is
        // live immediately: with the cap at 1, the SECOND unpinned insert
        // retires the first in the same commit (WS21's composed companion).
        let policyReceipt = try await viewState.applyMaximumUnpinnedItems(1)
        #expect(ComposedSupport.commit(of: policyReceipt, "WS11 (e)") != nil)
        let betaReceipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                "ws11 composed beta",
                observedAt: base.addingTimeInterval(100),
                source: "com.example.ws11composed.e1"
            )
        ))
        let betaID = try #require(
            ComposedSupport.insertedReference(from: betaReceipt, "WS11 (e1)")
        ).id
        #expect(
            await ComposedSupport.waitFor {
                viewState.rows.count == 2 && viewState.pinnedRows.first?.item.id == inserted.id
            },
            "WS11 (e): alpha pinned + beta unpinned — cap 1 satisfied, no retirement"
        )
        _ = try await history.perform(.capture(
            ComposedSupport.textCapture(
                "ws11 composed gamma",
                observedAt: base.addingTimeInterval(150),
                source: "com.example.ws11composed.e2"
            )
        ))
        #expect(
            await ComposedSupport.waitFor {
                viewState.rows.count == 2 && !viewState.rows.map(\.item.id).contains(betaID)
            },
            "WS11 (e): the cap-1 policy retires the older unpinned item as observed"
        )
        #expect(viewState.pinnedRows.map(\.item.id) == [inserted.id])

        // (f) remove (the row's Remove command) → the ID vanishes from rows
        // and reads (the WS16 vocabulary arrives in its own suite below).
        viewState.remove(inserted.id)
        #expect(
            await ComposedSupport.waitFor {
                viewState.rows.count == 1 && !viewState.rows.map(\.item.id).contains(inserted.id)
            },
            "WS11 (f): the removal reaches the observed rows"
        )

        // (g) clear on the remaining row — everything goes, still healthy.
        viewState.clear(.all)
        #expect(
            await ComposedSupport.waitFor { viewState.rows.isEmpty },
            "WS11 (g): the clear empties the observed page"
        )
        #expect(viewState.failure == nil)
    }
}
