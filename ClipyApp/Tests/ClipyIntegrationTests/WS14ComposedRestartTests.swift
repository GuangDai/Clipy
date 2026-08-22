/// WS14Composed — Restart reconstruction through the composed app stack
/// (docs/06-cross-cutting.md §8 WS14; docs/05-authority-kernel.md §13):
/// after insert, coalesce, pin reorder, and multiple revisions on a DURABLE
/// temp store, reopen the facade and assert the composed surfaces — the
/// reopened `HistoryViewState`, detail reads, and paste payload — match the
/// pre-restart public results: complete rebuilt Signature Index (a fresh
/// capture of the revised item's CANONICAL bytes coalesces instead of
/// duplicating), current position, Effective Content, occurrences, and pin
/// order (the storage-side suite additionally asserts row/blob internals
/// through an independent `ModelContainer`).
import Foundation
import HistoryCore
import HistoryStorage
import PresentationUI
import Testing

struct WS14ComposedRestartTests {

    /// WS14 (docs/06-cross-cutting.md §8): reopen over the same on-disk
    /// store and observe through the composed panel that every pre-restart
    /// public result survived: rows (title + copyCount + pinned lane), the
    /// item's Effective Content and revision lineage in details, the paste
    /// payload's bytes, and dedup candidacy (the rebuilt index).
    @Test @MainActor
    func restartPreservesComposedPublicResultsAndRebuildsIndex() async throws {
        let storeURL = ComposedSupport.tempStoreURL("ws14-composed-restart")
        defer { ComposedSupport.removeStore(storeURL) }

        // Phase 1 — build durable state over the persistent store.
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(
                persistence: .persistent(storeURL: storeURL)
            )
        )

        let base = Date(timeIntervalSinceReferenceDate: 700_202_000)
        let textA = "ws14 composed alpha canonical"
        let textB = "ws14 composed bravo canonical"

        // Commit 1 — insert A.
        let receiptA = try await history.perform(.capture(
            ComposedSupport.textCapture(
                textA, observedAt: base, source: "com.example.ws14composed.a1"
            )
        ))
        let referenceA = try #require(
            ComposedSupport.insertedReference(from: receiptA, "WS14 insert A")
        )
        // Commit 2 — coalesce A.
        let coalesceA = try await history.perform(.capture(
            ComposedSupport.textCapture(
                textA,
                observedAt: base.addingTimeInterval(50),
                source: "com.example.ws14composed.a2"
            )
        ))
        guard ComposedSupport.commit(of: coalesceA, "WS14 coalesce A") != nil else { return }
        // Commit 3 — insert B.
        let receiptB = try await history.perform(.capture(
            ComposedSupport.textCapture(
                textB,
                observedAt: base.addingTimeInterval(100),
                source: "com.example.ws14composed.b"
            )
        ))
        let idB = try #require(
            ComposedSupport.insertedReference(from: receiptB, "WS14 insert B")
        ).id
        // Commit 4 — pin A.
        _ = try await history.perform(.placePinned(referenceA.id, at: .last))
        // Commit 5 — pin B (pin order [A, B] — the pre-restart pinned lane).
        _ = try await history.perform(.placePinned(idB, at: .last))
        // Commits 6–7 — two byte-changing revisions of A.
        var currentVersion = referenceA.contentVersion
        for (ordinal, replacement) in [
            (6, "ws14 composed replacement one"),
            (7, "ws14 composed replacement two"),
        ] {
            let reviseReceipt = try await history.perform(.revise(
                RevisionRequest(
                    itemID: referenceA.id,
                    expected: currentVersion,
                    intent: .replace(RevisionDraft(decisions: [
                        RevisionDecision(
                            typeIdentifier: ComposedSupport.plainTextTypeIdentifier,
                            action: .replace(bytes: Data(replacement.utf8))
                        ),
                    ]))
                )
            ))
            let revised = try #require(
                ComposedSupport.revisedReference(from: reviseReceipt, "WS14 revision \(ordinal)")
            )
            currentVersion = revised.contentVersion
        }
        let preRestartPosition: UInt64 = 7

        // Pre-restart public results to compare against.
        let preRestartDetails = try await history.details(for: referenceA.id)
        let preRestartPayload = try await history.pastePayload(for: referenceA.id)

        // Phase 2 — RESTART: reopen the facade over the same on-disk store
        // (the §13 startup rebuilds the Signature Index and revalidates the
        // pinned ordinals), and observe through a FRESH composed view state.
        let restarted = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(
                persistence: .persistent(storeURL: storeURL)
            )
        )
        let viewState = HistoryViewState(history: restarted)
        defer { viewState.deactivate() }
        viewState.activate()

        // The observed page names the latest position; the pinned lane kept
        // its order and the occurrence fold survived.
        let settled = await ComposedSupport.waitFor {
            viewState.pinnedRows.count == 2
                && viewState.pinnedRows.first?.item.id == referenceA.id
                && viewState.pinnedRows.first?.copyCount == 2
        }
        #expect(settled, "WS14: the reopened panel observes the pinned lane and occurrence fold")
        #expect(
            viewState.pinnedRows.map(\.item.id) == [referenceA.id, idB],
            "WS14: pin order survived the restart"
        )
        #expect(
            viewState.rows.first?.item.contentVersion == currentVersion,
            "WS14: rows carry the successor Content Version"
        )

        // Details match the pre-restart public results exactly.
        let postRestartDetails = try await restarted.details(for: referenceA.id)
        #expect(postRestartDetails == preRestartDetails)
        #expect(postRestartDetails.revisions.count == 2)
        #expect(postRestartDetails.occurrence.count == 2)
        #expect(
            postRestartDetails.effective.first?.bytes
                == Data("ws14 composed replacement two".utf8),
            "WS14: Effective Content is the active revision's snapshot"
        )

        // The paste payload is byte-identical and version-current.
        let postRestartPayload = try await restarted.pastePayload(for: referenceA.id)
        #expect(postRestartPayload == preRestartPayload)
        #expect(postRestartPayload.item.contentVersion == currentVersion)

        // The rebuilt Signature Index is COMPLETE: a fresh capture of A's
        // CANONICAL bytes coalesces into A at the preserved Content Version
        // instead of inserting a duplicate row.
        let postRestartCapture = try await restarted.perform(.capture(
            ComposedSupport.textCapture(
                textA,
                observedAt: base.addingTimeInterval(500),
                source: "com.example.ws14composed.restart"
            )
        ))
        let canonicalCommit = try #require(
            ComposedSupport.commit(of: postRestartCapture, "WS14 post-restart capture")
        )
        #expect(
            canonicalCommit.position.rawValue == preRestartPosition + 1,
            "WS14: exactly one commit since the restart"
        )
        let coalesced = try #require(
            ComposedSupport.coalescedReference(from: postRestartCapture, "WS14 index proof")
        )
        #expect(coalesced.id == referenceA.id)
        #expect(coalesced.contentVersion == currentVersion)

        // The composed panel reflects the coalesce (copyCount moves to 3).
        let recoalesced = await ComposedSupport.waitFor {
            viewState.pinnedRows.first?.copyCount == 3
        }
        #expect(recoalesced, "WS14: the reopened panel tracks the post-restart coalesce")
        #expect(viewState.failure == nil)
    }
}
