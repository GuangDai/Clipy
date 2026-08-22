/// WS20Composed — Concurrent revision and coalescing, composed essence
/// (docs/06-cross-cutting.md §8 WS20; docs/02-domain.md §11; 05 §6.2):
/// a Copy Coalescing commit made BETWEEN a revision's phases (from the
/// caller's side: between the OCC read and the revise submit) still lets
/// the revision commit — the occurrence folds and the Content Version
/// advances exactly once — because occurrence folding never conflicts with
/// revision OCC, which guards only the Content Version.
///
/// The deterministic two-phase interleaving (parked inside the revision's
/// Authority interval) is a storage-side concurrency-harness proof and
/// stays in
/// `Tests/HistoryStorageTests/WS20ConcurrentRevisionCoalesceTests.swift`;
/// this suite proves the caller-observable contract end-to-end through the
/// composed detail/edit surfaces, including the losing interleaving — a
/// content-changing revision between the read and the submit returns
/// `.staleContent`.
import Foundation
import HistoryCore
import HistoryStorage
import PresentationUI
import Testing

struct WS20ComposedConcurrentRevisionAndCoalesceTests {

    /// WS20 (docs/06-cross-cutting.md §8): a coalescing capture between
    /// the detail read (OCC base) and the revise submit does NOT stale the
    /// revision: the revision commits at exactly one successor Content
    /// Version and the occurrence has folded to 2 in the same final state.
    @Test @MainActor
    func coalescingBetweenReadAndReviseStillCommitsAndFoldsTheOccurrence() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let viewState = HistoryViewState(history: history)
        defer { viewState.deactivate() }
        viewState.activate()

        let text = "ws20 composed original"
        let base = Date(timeIntervalSinceReferenceDate: 700_202_800)
        let insertReceipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                text, observedAt: base, source: "com.example.ws20composed.a"
            )
        ))
        let inserted = try #require(
            ComposedSupport.insertedReference(from: insertReceipt, "WS20 arrange")
        )

        // Phase 1 — the editor reads its OCC base (03b §9).
        let baseDetails = try await viewState.details(for: inserted.id)
        #expect(baseDetails.item.contentVersion == inserted.contentVersion)

        // Interleaved Copy Coalescing commit (02 §13): same bytes, later
        // observation — a Content-Version-neutral fold.
        _ = try await history.perform(.capture(
            ComposedSupport.textCapture(
                text,
                observedAt: base.addingTimeInterval(100),
                source: "com.example.ws20composed.b"
            )
        ))

        // Phase 2 — the revision based on the pre-coalesce token still
        // commits (05 §6.2: the OCC guard is the Content Version, which
        // coalescing never moves).
        let reviseReceipt = try await viewState.revise(
            RevisionRequest(
                itemID: inserted.id,
                expected: baseDetails.item.contentVersion,
                intent: .replace(RevisionDraft(decisions: [
                    RevisionDecision(
                        typeIdentifier: ComposedSupport.plainTextTypeIdentifier,
                        action: .replace(bytes: Data("ws20 composed revised".utf8))
                    ),
                ]))
            )
        )
        let revised = try #require(
            ComposedSupport.revisedReference(from: reviseReceipt, "WS20 revise")
        )
        #expect(
            revised.contentVersion.rawValue == 2,
            "WS20: the revision mints exactly one successor Content Version"
        )

        // The final state carries BOTH effects: the folded occurrence
        // (count 2) and the revised Effective Content.
        let finalDetails = try await viewState.details(for: inserted.id)
        #expect(finalDetails.occurrence.count == 2, "WS20: the occurrence folded")
        #expect(finalDetails.item.contentVersion.rawValue == 2)
        #expect(
            finalDetails.effective.first?.bytes == Data("ws20 composed revised".utf8)
        )
        #expect(viewState.failure == nil)
    }

    /// WS20 losing interleaving (02 §11; 05 §6.2): a content-CHANGING
    /// revision between the read and the submit DOES stale the first
    /// revision — `.staleContent(expected:current:)` — and nothing from
    /// the loser commits.
    @Test @MainActor
    func contentChangingRevisionBetweenReadAndReviseStalesTheFirst() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let viewState = HistoryViewState(history: history)
        defer { viewState.deactivate() }
        viewState.activate()

        let insertReceipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                "ws20 composed loser original",
                observedAt: Date(timeIntervalSinceReferenceDate: 700_202_850),
                source: "com.example.ws20composed.loser"
            )
        ))
        let inserted = try #require(
            ComposedSupport.insertedReference(from: insertReceipt, "WS20 loser arrange")
        )

        // The editor's OCC base.
        let baseDetails = try await viewState.details(for: inserted.id)

        // The interleaved WINNER: a content-changing revision from another
        // surface commits first (version 1 → 2).
        let winnerReceipt = try await history.perform(.revise(
            RevisionRequest(
                itemID: inserted.id,
                expected: inserted.contentVersion,
                intent: .replace(RevisionDraft(decisions: [
                    RevisionDecision(
                        typeIdentifier: ComposedSupport.plainTextTypeIdentifier,
                        action: .replace(bytes: Data("ws20 composed winner".utf8))
                    ),
                ]))
            )
        ))
        _ = try #require(
            ComposedSupport.revisedReference(from: winnerReceipt, "WS20 winner")
        )

        // The loser submits on the stale token: typed OCC rejection.
        do {
            _ = try await viewState.revise(
                RevisionRequest(
                    itemID: inserted.id,
                    expected: baseDetails.item.contentVersion,
                    intent: .replace(RevisionDraft(decisions: [
                        RevisionDecision(
                            typeIdentifier: ComposedSupport.plainTextTypeIdentifier,
                            action: .replace(bytes: Data("ws20 composed lost".utf8))
                        ),
                    ]))
                )
            )
            Issue.record("WS20 loser: expected .staleContent, got a receipt")
        } catch let failure as HistoryFailure {
            guard case let .staleContent(expected, current) = failure else {
                Issue.record("WS20 loser: expected .staleContent, got \(failure)")
                return
            }
            #expect(expected.rawValue == 1)
            #expect(current.rawValue == 2)
        }

        // Nothing from the loser committed: Effective Content is the
        // winner's, one revision only.
        let finalDetails = try await viewState.details(for: inserted.id)
        #expect(finalDetails.revisions.count == 1)
        #expect(
            finalDetails.effective.first?.bytes == Data("ws20 composed winner".utf8)
        )
    }
}
