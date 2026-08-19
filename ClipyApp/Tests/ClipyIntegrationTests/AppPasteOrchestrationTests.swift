/// AppPasteOrchestrationTests — the paste-orchestration guarantee in
/// composed form (docs/01-architecture.md §5.6; docs/03b-instruction-set.md
/// §9/§12; docs/04-coherence.md §8; roadmap 06-clipyapp.md "Acceptance"):
/// a paste selection traveling the app's real wiring —
/// `viewState.onPaste` → the composition's mailbox →
/// `pastePayload(for:)` → `adapter.write` — lands the item's current
/// Effective Content PLUS the lineage hint on the pasteboard, outside any
/// History transaction, and the hint is what lets the next capture
/// coalesce (WS4's composed round trip, reached through `AppComposition`
/// itself).
///
/// `paste(_:)` is driven through the composition's OWN public wiring
/// (`viewState.requestPaste(_:)`, the panel's ⏎/double-click command);
/// `NSApp.hide` is a window effect the hosted environment must not
/// exercise, and `AppComposition.open` builds its observer over the
/// GENERAL pasteboard, so this suite constructs the same wiring manually
/// over a PRIVATE pasteboard — the identical orchestration sequence the
/// composition runs (AppComposition.start/paste), with the pasteboard
/// substituted, exactly the adapter's own test stance.
import AppKit
import Foundation
import HistoryCore
import HistoryStorage
import PasteboardAdapter
import PresentationUI
import Testing

struct AppPasteOrchestrationTests {

    /// 01 §5.6 (paste flow) + 03b §9 + 04 §8: a paste request through the
    /// view state's hand-off writes the item's current Effective Content
    /// representations and the lineage hint to the pasteboard — byte-exact
    /// — and History's durable state is untouched by the paste itself (a
    /// paste is a clipboard side effect, never durable History state).
    @Test @MainActor
    func pasteSelectionWritesEffectiveContentAndLineageHintToPasteboard() async throws {
        try ComposedSupport.requireUsablePasteboard()
        let history = try await ComposedSupport.openMemoryHistory()

        // The composed wiring, exactly as AppComposition.start assembles it
        // (01 §5.6): the @Sendable hand-off crosses only through a Sendable
        // `AsyncStream` mailbox — it cannot capture the MainActor `adapter`
        // — and a MainActor pump resolves the payload and writes it through
        // the adapter. The real composition targets the general pasteboard;
        // the substitute here is the private one (never .general).
        let pasteboard = ComposedSupport.makePasteboard()
        let adapter = PasteboardAdapter(pasteboard: pasteboard)
        let viewState = HistoryViewState(history: history)
        let (pasteStream, pasteContinuation) =
            AsyncStream<HistoryItemReference>.makeStream()
        defer {
            viewState.deactivate()
            pasteContinuation.finish()
        }

        viewState.onPaste = { item in
            pasteContinuation.yield(item)
        }
        Task { @MainActor in
            for await item in pasteStream {
                guard let payload = try? await history.pastePayload(for: item.id) else {
                    continue
                }
                adapter.write(payload)
            }
        }

        // A rich item, revised once, so Effective ≠ Canonical: the paste
        // must carry the REVISED bytes and hide the hidden type (03b §9).
        let text = "orchestration canonical"
        let html = "<p>orchestration canonical</p>"
        let revisedText = "orchestration revised"
        let pasteboardItem = ComposedSupport.makePasteboard()
        ComposedSupport.setPasteboardContents(text, html: html, on: pasteboardItem)
        let capture = try #require(
            PasteboardAdapter(pasteboard: pasteboardItem)
                .capture(observedAt: Date(timeIntervalSinceReferenceDate: 700_203_000))
        )
        let insertReceipt = try await history.perform(.capture(capture))
        let inserted = try #require(
            ComposedSupport.insertedReference(from: insertReceipt, "paste arrange")
        )
        let reviseReceipt = try await history.perform(.revise(
            RevisionRequest(
                itemID: inserted.id,
                expected: inserted.contentVersion,
                intent: .replace(RevisionDraft(decisions: [
                    RevisionDecision(typeIdentifier: "public.html", action: .hide),
                    RevisionDecision(
                        typeIdentifier: ComposedSupport.plainTextTypeIdentifier,
                        action: .replace(bytes: Data(revisedText.utf8))
                    ),
                ]))
            )
        ))
        let revised = try #require(
            ComposedSupport.revisedReference(from: reviseReceipt, "paste arrange")
        )

        // The durable position BEFORE the paste: a paste must not commit
        // anything (04 §8 — outside any History transaction).
        let positionBeforePaste = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 1)
        ).position

        // The panel's copy command (03b §12): requestPaste → onPaste.
        viewState.requestPaste(revised)

        // The write lands on the pasteboard (the adapter clears first and
        // writes every representation plus the hint).
        let written = await ComposedSupport.waitFor {
            pasteboard.pasteboardItems?.first?.data(forType: .string)
                == Data(revisedText.utf8)
        }
        #expect(
            written,
            "01 §5.6: the pasted Effective Content is on the pasteboard"
        )
        let writtenItem = try #require(pasteboard.pasteboardItems?.first)
        #expect(
            writtenItem.data(
                forType: NSPasteboard.PasteboardType("com.clipy.lineageHint")
            ) == Data(revised.id.rawValue.uuidString.utf8),
            "01 §5.6/03b §9: the lineage hint equals the item ID"
        )
        #expect(
            writtenItem.types.map(\.rawValue).contains("public.html") == false,
            "01 §5.6: hidden representations stay off the pasteboard"
        )

        // The paste committed nothing: the position is unchanged
        // (04 §8 — and observation did not fire for the paste itself).
        let positionAfterPaste = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 1)
        ).position
        #expect(
            positionAfterPaste == positionBeforePaste,
            "04 §8: a paste is never durable History state"
        )

        // The hint's purpose (03b §9; WS4's composed essence at the app
        // seam): re-capturing the pasted content through the adapter
        // yields the hint in the origin and coalesces into the item.
        let recapture = try #require(
            adapter.capture(observedAt: Date(timeIntervalSinceReferenceDate: 700_203_100))
        )
        #expect(recapture.origin.lineageHint == revised.id)
        let roundTripReceipt = try await history.perform(.capture(recapture))
        let coalesced = try #require(
            ComposedSupport.coalescedReference(from: roundTripReceipt, "paste round trip")
        )
        #expect(
            coalesced.id == revised.id,
            "01 §5.6/WS4: the app's own paste coalesces back via the hint"
        )
    }
}
