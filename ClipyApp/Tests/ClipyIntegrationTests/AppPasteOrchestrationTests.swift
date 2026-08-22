/// AppPasteOrchestrationTests — the paste-orchestration guarantee in
/// composed form (docs/01-architecture.md §5.6; docs/03b-instruction-set.md
/// §9/§12; docs/04-coherence.md §8; roadmap 06-clipyapp.md "Acceptance"):
/// a paste selection traveling the app's real wiring —
/// `viewState.onPaste` → the composition's owned copy lane →
/// `pastePayload(for:)` → `adapter.write` — lands the item's current
/// Effective Content PLUS the lineage hint on the pasteboard, outside any
/// History transaction, and the hint is what lets the next capture
/// coalesce (WS4's composed round trip, reached through `AppComposition`
/// itself). These tests construct `AppComposition` with production concrete
/// dependencies over a private pasteboard and invoke its real `start()`;
/// they never reproduce the copy pump.
///
/// The copy lane is driven through the composition's OWN UI wiring
/// (`viewState.requestPaste(_:)`, the panel's ⏎/double-click command);
/// `NSApp.hide` is a window effect the hosted environment must not
/// exercise, and `AppComposition.open` builds its observer over the
/// GENERAL pasteboard; the suite substitutes a PRIVATE pasteboard while
/// retaining the real composition owner and orchestration sequence.
///
/// SPEC-IMPL-005 coverage: the write-failure test drives the same wiring
/// through the adapter's deterministic Debug seam and proves the
/// panel-close hook runs only after a VERIFIED full write — a refused
/// write surfaces `PasteboardWriteFailure` and leaves the panel open.
import AppKit
import Foundation
import HistoryCore
import HistoryStorage
import PasteboardAdapter
import PresentationUI
import Testing
@testable import ClipyApp

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

        // Construct the production owner with its real concrete dependencies.
        // The only substitution is a private pasteboard (never `.general`).
        let pasteboard = ComposedSupport.makePasteboard()
        let adapter = PasteboardAdapter(pasteboard: pasteboard)
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: adapter
        )
        let viewState = composition.viewState
        var completionCount = 0
        var failures: [ClipyPasteFailure] = []
        composition.onPasteCompleted = { completionCount += 1 }
        composition.onPasteFailed = { failures.append($0) }
        defer { composition.stop() }

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

        // Submit the PRE-revision reference deliberately: the frozen v1
        // product rule is current-by-ID, so the lane resolves and writes the
        // current revision without labelling it as the requested version.
        viewState.requestPaste(inserted)

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
        #expect(completionCount == 1, "verified success closes exactly once")
        #expect(failures.isEmpty)
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

    /// REVIEW Card 7 / CLIP-5: admission is exclusive first-accepted. A is
    /// accepted synchronously before the first suspension. A's read is parked
    /// by a test-only forwarding adapter over the REAL memory History, then B
    /// arrives. B is reported busy, never queued, and only A may reach the
    /// private pasteboard or close the panel.
    @Test @MainActor
    func activePasteRejectsASecondRequestWithoutReorderingOrQueueing() async throws {
        try ComposedSupport.requireUsablePasteboard()
        let history = try await ComposedSupport.openMemoryHistory()
        let firstReceipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                "first accepted",
                observedAt: Date(timeIntervalSinceReferenceDate: 700_203_200)
            )
        ))
        let first = try #require(
            ComposedSupport.insertedReference(from: firstReceipt, "first arrange")
        )
        let secondReceipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                "second rejected",
                observedAt: Date(timeIntervalSinceReferenceDate: 700_203_201)
            )
        ))
        let second = try #require(
            ComposedSupport.insertedReference(from: secondReceipt, "second arrange")
        )

        let pasteboard = ComposedSupport.makePasteboard()
        let adapter = PasteboardAdapter(pasteboard: pasteboard)
        let pausingHistory = PausingPastePayloadHistory(base: history)
        let composition = AppComposition.makeForTesting(
            history: pausingHistory,
            adapter: adapter
        )
        let viewState = composition.viewState
        var completionCount = 0
        var failures: [ClipyPasteFailure] = []
        composition.onPasteCompleted = { completionCount += 1 }
        composition.onPasteFailed = { failures.append($0) }
        defer { composition.stop() }

        // A owns the one slot before its payload read starts. The forwarding
        // adapter stops exactly at that read without replacing any History
        // behavior or receipt, making B's arrival deterministic.
        viewState.requestPaste(first)
        await pausingHistory.waitUntilPastePayloadIsPaused()
        viewState.requestPaste(second)

        #expect(failures == [.busy])
        await pausingHistory.resumePastePayload()
        let firstWritten = await ComposedSupport.waitFor {
            pasteboard.pasteboardItems?.first?.data(forType: .string)
                == Data("first accepted".utf8)
        }
        #expect(firstWritten)
        #expect(completionCount == 1)
        #expect(failures == [.busy])
        #expect(
            pasteboard.pasteboardItems?.first?.data(forType: .string)
                != Data("second rejected".utf8)
        )
    }

    /// App shutdown cancels the owned slot. Even when the underlying History
    /// read ignores cancellation and returns later, it cannot touch the
    /// pasteboard or publish success/failure callbacks.
    @Test @MainActor
    func stoppedCompositionDiscardsLateNonCooperativePasteResolution() async throws {
        try ComposedSupport.requireUsablePasteboard()
        let history = try await ComposedSupport.openMemoryHistory()
        let receipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                "must not write after stop",
                observedAt: Date(timeIntervalSinceReferenceDate: 700_203_250)
            )
        ))
        let item = try #require(
            ComposedSupport.insertedReference(from: receipt, "stop arrange")
        )

        let pasteboard = ComposedSupport.makePasteboard()
        let pausingHistory = PausingPastePayloadHistory(base: history)
        let composition = AppComposition.makeForTesting(
            history: pausingHistory,
            adapter: PasteboardAdapter(pasteboard: pasteboard)
        )
        var completionCount = 0
        var failures: [ClipyPasteFailure] = []
        composition.onPasteCompleted = { completionCount += 1 }
        composition.onPasteFailed = { failures.append($0) }
        let changeCountBeforeRequest = pasteboard.changeCount

        composition.viewState.requestPaste(item)
        await pausingHistory.waitUntilPastePayloadIsPaused()
        composition.stop()
        await pausingHistory.resumePastePayload()
        await pausingHistory.waitUntilPastePayloadCompleted()
        await Task.yield()

        #expect(pasteboard.changeCount == changeCountBeforeRequest)
        #expect(pasteboard.pasteboardItems?.isEmpty ?? true)
        #expect(completionCount == 0)
        #expect(failures.isEmpty)
    }

    /// A current-by-ID resolution failure is part of the copy lane's typed,
    /// content-free outcome. It is visible to the app owner, never touches
    /// the pasteboard, and never invokes the success/close hook.
    @Test @MainActor
    func missingPasteItemSurfacesHistoryFailureWithoutWritingOrClosing() async throws {
        try ComposedSupport.requireUsablePasteboard()
        let history = try await ComposedSupport.openMemoryHistory()
        let receipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                "removed before copy",
                observedAt: Date(timeIntervalSinceReferenceDate: 700_203_300)
            )
        ))
        let inserted = try #require(
            ComposedSupport.insertedReference(from: receipt, "missing arrange")
        )
        _ = try await history.perform(.remove(inserted.id))

        let pasteboard = ComposedSupport.makePasteboard()
        let adapter = PasteboardAdapter(pasteboard: pasteboard)
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: adapter
        )
        let viewState = composition.viewState
        var completionCount = 0
        var failures: [ClipyPasteFailure] = []
        composition.onPasteCompleted = { completionCount += 1 }
        composition.onPasteFailed = { failures.append($0) }
        defer { composition.stop() }
        let changeCountBeforeRequest = pasteboard.changeCount

        viewState.requestPaste(inserted)

        let failed = await ComposedSupport.waitFor { !failures.isEmpty }
        #expect(failed)
        #expect(failures == [.history(.notFound(inserted.id))])
        #expect(completionCount == 0)
        #expect(pasteboard.changeCount == changeCountBeforeRequest)
        #expect(pasteboard.pasteboardItems?.isEmpty ?? true)
    }

    #if DEBUG
    /// REVIEW Card 7 / SPEC-IMPL-005: refusal of the staged item at the
    /// pasteboard ownership boundary is a visible write failure, never a
    /// successful copy. The real composition must keep the panel open and
    /// must not leave the requested bytes on the board after the rejected
    /// whole-item commit.
    @Test @MainActor
    func wholeItemWriteRefusalSurfacesFailureWithoutClosing() async throws {
        try ComposedSupport.requireUsablePasteboard()
        let history = try await ComposedSupport.openMemoryHistory()
        let receipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                "whole item must be accepted",
                observedAt: Date(timeIntervalSinceReferenceDate: 700_203_400)
            )
        ))
        let inserted = try #require(
            ComposedSupport.insertedReference(from: receipt, "item refusal arrange")
        )

        let pasteboard = ComposedSupport.makePasteboard()
        ComposedSupport.setPasteboardContents("previous owner", on: pasteboard)
        var adapter = PasteboardAdapter(pasteboard: pasteboard)
        adapter.simulatedItemWriteRejected = true
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: adapter
        )
        var completionCount = 0
        var failures: [ClipyPasteFailure] = []
        composition.onPasteCompleted = { completionCount += 1 }
        composition.onPasteFailed = { failures.append($0) }
        defer { composition.stop() }

        composition.viewState.requestPaste(inserted)

        let failed = await ComposedSupport.waitFor { !failures.isEmpty }
        #expect(failed, "the production failure callback receives final refusal")
        #expect(failures == [.write(.itemRejected)])
        #expect(completionCount == 0, "a rejected item must not close the panel")
        #expect(
            pasteboard.pasteboardItems?.isEmpty ?? true,
            "the rejected item must not be reported by pasteboard contents as copied"
        )
    }

    /// SPEC-IMPL-005 + 01 §5.6: a paste whose write is REFUSED (the
    /// adapter's deterministic seam injects the `setData`-false outcome
    /// Apple documents as an ownership change) surfaces the typed
    /// `PasteboardWriteFailure` and does NOT run the completion hook — the
    /// panel stays open rather than closing over a partial paste. A second
    /// explicit request is admitted after failure, proving the lane releases
    /// its exclusive slot for retry instead of wedging.
    @Test @MainActor
    func pasteWriteFailureSkipsTheCompletionHookUntilAVerifiedFullWrite() async throws {
        try ComposedSupport.requireUsablePasteboard()
        let history = try await ComposedSupport.openMemoryHistory()

        // Production composition with the pasteboard substituted and the
        // adapter's Debug-only refusal seam configured before construction.
        let pasteboard = ComposedSupport.makePasteboard()
        var adapter = PasteboardAdapter(pasteboard: pasteboard)
        adapter.simulatedRejectedWriteTypeIdentifiers = [
            ComposedSupport.plainTextTypeIdentifier
        ]
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: adapter
        )
        let viewState = composition.viewState
        defer { composition.stop() }

        var failures: [ClipyPasteFailure] = []
        var completionCount = 0
        composition.onPasteFailed = { failures.append($0) }
        composition.onPasteCompleted = { completionCount += 1 }
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

        let changeCountBeforeFailure = pasteboard.changeCount

        // Phase 1 — refused staging: the typed failure surfaces and the
        // completion hook does NOT run (the panel stays open).
        viewState.requestPaste(inserted)
        let failureSurfaced = await ComposedSupport.waitFor {
            !failures.isEmpty
        }
        #expect(failureSurfaced, "SPEC-IMPL-005: the refused write surfaces")
        #expect(
            failures.first
                == .write(.representationsRejected(
                    typeIdentifiers: [ComposedSupport.plainTextTypeIdentifier]
                )),
            "SPEC-IMPL-005: the failure names the refused representation"
        )
        #expect(
            completionCount == 0,
            "01 §5.6/SPEC-IMPL-005: no panel close over a failed copy"
        )
        // Staging happened on an unbound item, before clear/writeObjects.
        #expect(pasteboard.changeCount == changeCountBeforeFailure)
        #expect(
            pasteboard.pasteboardItems?.isEmpty ?? true,
            "SPEC-IMPL-005: refused staging preserves the previous board"
        )

        // Phase 2 — failure released the exclusive slot, so an explicit
        // retry is admitted. This immutable adapter is still configured to
        // refuse; a second visible failure proves the lane did not wedge.
        viewState.requestPaste(inserted)
        let retryFailed = await ComposedSupport.waitFor {
            failures.count == 2
        }
        #expect(retryFailed)
        #expect(completionCount == 0)
    }
    #endif
}

/// Test-only scheduling control around the real `SwiftDataHistory`: every
/// operation delegates unchanged, and only the first paste-payload read is
/// suspended. This is not a second writer or a scripted History substitute;
/// it makes the production copy-lane race reproducible without sleeps.
private actor PausingPastePayloadHistory: ClipboardHistory {
    private let base: SwiftDataHistory
    private var didPause = false
    private var pauseContinuation: CheckedContinuation<Void, Never>?
    private var observerContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var completedPastePayloadCount = 0
    private var completionContinuations: [CheckedContinuation<Void, Never>] = []

    init(base: SwiftDataHistory) {
        self.base = base
    }

    func waitUntilPastePayloadIsPaused() async {
        guard !didPause else { return }
        await withCheckedContinuation { continuation in
            observerContinuations.append(continuation)
        }
    }

    func resumePastePayload() {
        pauseContinuation?.resume()
        pauseContinuation = nil
    }

    func waitUntilPastePayloadCompleted() async {
        guard completedPastePayloadCount == 0 else { return }
        await withCheckedContinuation { continuation in
            completionContinuations.append(continuation)
        }
    }

    func perform(_ action: HistoryAction) async throws -> HistoryReceipt {
        try await base.perform(action)
    }

    func browse(_ request: HistoryBrowseRequest) async throws -> HistoryPage {
        try await base.browse(request)
    }

    func observe(
        _ request: HistoryObservationRequest
    ) async -> AsyncThrowingStream<HistoryPage, Error> {
        await base.observe(request)
    }

    func details(for id: HistoryItemID) async throws -> HistoryDetails {
        try await base.details(for: id)
    }

    func pastePayload(for id: HistoryItemID) async throws -> PastePayload {
        // Resolve through the real store first, then hold the immutable result
        // at the system-boundary return. Cancellation during the park is
        // deliberately non-cooperative, which proves AppComposition's
        // post-await fence rather than relying on storage cancellation.
        let payload = try await base.pastePayload(for: id)
        if !didPause {
            didPause = true
            let observers = observerContinuations
            observerContinuations.removeAll()
            for continuation in observers {
                continuation.resume()
            }
            await withCheckedContinuation { continuation in
                pauseContinuation = continuation
            }
        }
        completedPastePayloadCount += 1
        let completions = completionContinuations
        completionContinuations.removeAll()
        for continuation in completions {
            continuation.resume()
        }
        return payload
    }

    func thumbnail(
        for item: HistoryItemReference,
        pixels: PixelSize
    ) async throws -> ThumbnailPayload? {
        try await base.thumbnail(for: item, pixels: pixels)
    }

    func retentionConfiguration() async throws -> HistoryRetentionConfiguration {
        try await base.retentionConfiguration()
    }
}
