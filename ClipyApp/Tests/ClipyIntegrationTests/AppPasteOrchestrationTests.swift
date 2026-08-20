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
///
/// SPEC-IMPL-005 coverage: the second test drives the same wiring through
/// the adapter's deterministic write-failure seam and proves the
/// panel-close hook runs only after a VERIFIED full write — a refused
/// write surfaces `PasteboardWriteFailure` and leaves the panel open.
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
                // The write half of the composition's wiring (01 §5.6;
                // audit SPEC-IMPL-005): the panel-close hook runs only
                // after a verified full write — a refused write throws
                // and skips it. This suite's write succeeds.
                do {
                    try adapter.write(payload)
                } catch {
                    continue
                }
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

    /// SPEC-IMPL-005 + 01 §5.6: a paste whose write is REFUSED (the
    /// adapter's deterministic seam injects the `setData`-false outcome
    /// Apple documents as an ownership change) surfaces the typed
    /// `PasteboardWriteFailure` and does NOT run the completion hook — the
    /// panel stays open rather than closing over a partial paste. A retry
    /// with the refusal cleared writes fully and runs the hook: the gating
    /// distinguishes failure from success.
    @Test @MainActor
    func pasteWriteFailureSkipsTheCompletionHookUntilAVerifiedFullWrite() async throws {
        try ComposedSupport.requireUsablePasteboard()
        let history = try await ComposedSupport.openMemoryHistory()

        // The same composed wiring as the success-path test above — the
        // composition's own sequence (AppComposition.paste) with the
        // pasteboard substituted and the panel-close hook modeled by a
        // flag — plus the adapter's failure-injection seam.
        let pasteboard = ComposedSupport.makePasteboard()
        var adapter = PasteboardAdapter(pasteboard: pasteboard)
        adapter.simulatedRejectedWriteTypeIdentifiers = [
            ComposedSupport.plainTextTypeIdentifier
        ]
        let viewState = HistoryViewState(history: history)
        let (pasteStream, pasteContinuation) =
            AsyncStream<HistoryItemReference>.makeStream()
        defer {
            viewState.deactivate()
            pasteContinuation.finish()
        }

        var writeFailures: [PasteboardWriteFailure] = []
        var pasteCompleted = false
        viewState.onPaste = { item in
            pasteContinuation.yield(item)
        }
        Task { @MainActor in
            for await item in pasteStream {
                guard let payload = try? await history.pastePayload(for: item.id) else {
                    continue
                }
                do {
                    try adapter.write(payload)
                } catch let failure as PasteboardWriteFailure {
                    writeFailures.append(failure)
                    continue
                } catch {
                    continue
                }
                pasteCompleted = true
            }
        }

        // Arrange one plain-text item through the real capture seam.
        let sourcePasteboard = ComposedSupport.makePasteboard()
        ComposedSupport.setPasteboardContents(
            "orchestration refused write",
            on: sourcePasteboard
        )
        let capture = try #require(
            PasteboardAdapter(pasteboard: sourcePasteboard)
                .capture(observedAt: Date(timeIntervalSinceReferenceDate: 700_204_000))
        )
        let insertReceipt = try await history.perform(.capture(capture))
        let inserted = try #require(
            ComposedSupport.insertedReference(
                from: insertReceipt,
                "paste failure arrange"
            )
        )

        // Phase 1 — refused write: the typed failure surfaces and the
        // completion hook does NOT run (the panel stays open).
        viewState.requestPaste(inserted)
        let failureSurfaced = await ComposedSupport.waitFor {
            !writeFailures.isEmpty
        }
        #expect(failureSurfaced, "SPEC-IMPL-005: the refused write surfaces")
        #expect(
            writeFailures.first
                == .representationsRejected(
                    typeIdentifiers: [ComposedSupport.plainTextTypeIdentifier]
                ),
            "SPEC-IMPL-005: the failure names the refused representation"
        )
        #expect(
            !pasteCompleted,
            "01 §5.6/SPEC-IMPL-005: no panel close over a partial paste"
        )
        // The refused representation never landed; the board holds only
        // what the system accepted (here: the lineage hint alone).
        #expect(
            pasteboard.pasteboardItems?.first?.data(forType: .string) == nil,
            "SPEC-IMPL-005: a refused write leaves no content bytes behind"
        )

        // Phase 2 — refusal cleared: the retry writes fully and runs the
        // hook, proving the gating keys on the write outcome.
        adapter.simulatedRejectedWriteTypeIdentifiers = []
        viewState.requestPaste(inserted)
        let completedAfterRetry = await ComposedSupport.waitFor {
            pasteCompleted
        }
        #expect(
            completedAfterRetry,
            "01 §5.6: a verified full write runs the completion hook"
        )
        #expect(
            pasteboard.pasteboardItems?.first?.data(forType: .string)
                == Data("orchestration refused write".utf8)
        )
    }
}
