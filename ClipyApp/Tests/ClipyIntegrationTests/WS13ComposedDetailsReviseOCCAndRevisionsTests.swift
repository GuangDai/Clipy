/// WS13Composed — Details + revision OCC through the composed detail/edit
/// surfaces (docs/06-cross-cutting.md §8 WS13/WS6 clause shapes;
/// docs/03b-instruction-set.md §9; 02 §11): the detail read is
/// reference-exact, the editor's stale-save path (`.staleContent` from
/// `viewState.revise`) is surfaced as a typed failure, and the incoherent
/// draft (hide every representation) is rejected as
/// `.invalidInput(.incoherentRevisionDraft)` — both driven through the same
/// `HistoryViewState.revise(_:)` the ReviseEditorView sheet calls.
///
/// The WS13 transaction-injection clause (failure after row mutation,
/// before singleton update → `.persistence(.transaction)`) needs the
/// storage-side transaction-injection seam and stays in
/// `Tests/HistoryStorageTests/WS13TransactionFailureTests.swift`.
import Foundation
import HistoryCore
import HistoryStorage
import PresentationUI
import Testing

struct WS13ComposedDetailsReviseOCCAndRevisionsTests {

    /// WS13/WS6 shapes composed (03a §5; 03b §9; 02 §5.4): the details
    /// read reports the OCC token the editor must base its save on; a
    /// stale save throws `.staleContent` through the view state; a draft
    /// hiding EVERY Canonical type is rejected
    /// `.invalidInput(.incoherentRevisionDraft)`; and a coherent save
    /// appends one revision whose summary is then visible in details
    /// (revisions list with the active revision).
    @Test @MainActor
    func detailsFeedOCCEditorAndIncoherentDraftsFailClosed() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let viewState = HistoryViewState(history: history)
        defer { viewState.deactivate() }
        viewState.activate()

        // A two-representation item so the hide-everything draft has two
        // decisions to be incoherent with.
        let text = "ws13 composed canonical"
        let html = "<p>ws13 composed canonical</p>"
        let insertReceipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                text,
                observedAt: Date(timeIntervalSinceReferenceDate: 700_201_900),
                source: "com.example.ws13composed",
                extra: [(typeIdentifier: "public.html", bytes: [UInt8](html.utf8))]
            )
        ))
        let inserted = try #require(
            ComposedSupport.insertedReference(from: insertReceipt, "WS13 arrange")
        )

        // The detail read (03b §9): the reference the editor chains from —
        // item + contentVersion + canonical + effective + no revisions yet.
        let details = try await viewState.details(for: inserted.id)
        #expect(details.item == inserted)
        #expect(details.canonical.count == 2)
        #expect(details.effective == details.canonical)
        #expect(details.revisions.isEmpty)

        // The editor's Save with the CURRENT token succeeds and appends
        // exactly one revision summary (03b §9 RevisionSummary).
        let saved = try await viewState.revise(
            RevisionRequest(
                itemID: inserted.id,
                expected: details.item.contentVersion,
                intent: .replace(RevisionDraft(decisions: [
                    RevisionDecision(typeIdentifier: "public.html", action: .hide),
                    RevisionDecision(
                        typeIdentifier: ComposedSupport.plainTextTypeIdentifier,
                        action: .replace(bytes: Data("ws13 composed edited".utf8))
                    ),
                ]))
            )
        )
        let revised = try #require(
            ComposedSupport.revisedReference(from: saved, "WS13 save")
        )
        #expect(revised.contentVersion.rawValue == 2)
        let afterSave = try await viewState.details(for: inserted.id)
        #expect(afterSave.revisions.count == 1)
        #expect(afterSave.revisions.first?.isActive == true)
        #expect(afterSave.effective.count == 1, "WS13: the hidden type left Effective")

        // A SECOND save based on the now-stale token (the classic two-
        // editors race, 02 §11): `.staleContent` naming both versions.
        do {
            _ = try await viewState.revise(
                RevisionRequest(
                    itemID: inserted.id,
                    expected: details.item.contentVersion,
                    intent: .replace(RevisionDraft(decisions: [
                        RevisionDecision(typeIdentifier: "public.html", action: .hide),
                        RevisionDecision(
                            typeIdentifier: ComposedSupport.plainTextTypeIdentifier,
                            action: .replace(bytes: Data("ws13 composed loser".utf8))
                        ),
                    ]))
                )
            )
            Issue.record("WS13: expected .staleContent, got a receipt")
        } catch let failure as HistoryFailure {
            guard case let .staleContent(expected, current) = failure else {
                Issue.record("WS13: expected .staleContent, got \(failure)")
                return
            }
            #expect(expected.rawValue == 1)
            #expect(current.rawValue == 2)
        }

        // The hide-everything draft (03a §5) fails closed before any
        // mutation: still exactly one revision, version unchanged.
        do {
            _ = try await viewState.revise(
                RevisionRequest(
                    itemID: inserted.id,
                    expected: afterSave.item.contentVersion,
                    intent: .replace(RevisionDraft(decisions: [
                        RevisionDecision(typeIdentifier: "public.html", action: .hide),
                        RevisionDecision(
                            typeIdentifier: ComposedSupport.plainTextTypeIdentifier,
                            action: .hide
                        ),
                    ]))
                )
            )
            Issue.record("WS13: expected .incoherentRevisionDraft, got a receipt")
        } catch let failure as HistoryFailure {
            #expect(
                failure == .invalidInput(.incoherentRevisionDraft),
                "WS13 (03a §5): hiding every representation is rejected, got \(failure)"
            )
        }
        let afterIncoherent = try await viewState.details(for: inserted.id)
        #expect(afterIncoherent.revisions.count == 1)
        #expect(afterIncoherent.item.contentVersion.rawValue == 2)
    }
}
