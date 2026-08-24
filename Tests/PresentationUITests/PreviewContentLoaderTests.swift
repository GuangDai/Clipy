/// PreviewContentLoaderTests — the preview loader's cancellation /
/// exact-reference fence (audit docs/reviews/2026-08-20-clipy-maccy-audit/
/// 02-spec-implementation.md §SPEC-IMPL-007; 05-recommended-target-design.md
/// §4.1 PREVIEW-FENCE-1) and its bounded off-MainActor image decode outcome
/// (01-standards.md §S-2; 02 §SPEC-IMPL-002). Driven through
/// `PausableDetailsHistory`, which suspends every `details(for:)` read until
/// the test resumes it, so reverse completion order is deterministic — no
/// sleeps on the deciding path.
import ContentPreview
import CoreGraphics
import Foundation
import HistoryCore
import PresentationUI
import Testing

@MainActor
struct PreviewContentLoaderTests {

    // MARK: - Fixtures

    /// One exact reference with a fixed literal UUID (the force unwrap
    /// cannot fail for a well-formed literal — the ScriptedHistory.swift
    /// fixture convention).
    private func reference(
        _ rawValue: String,
        version: UInt64
    ) -> HistoryItemReference {
        HistoryItemReference(
            id: HistoryItemID(rawValue: UUID(uuidString: rawValue)!),
            contentVersion: ContentVersion(rawValue: version)
        )
    }

    /// Canned details for one exact reference: the given text and/or image
    /// representations (03b §9 DTOs built through their package inits).
    private func details(
        for item: HistoryItemReference,
        text: String? = nil,
        imageBytes: Data? = nil
    ) -> HistoryDetails {
        var effective: [HistoryRepresentation] = []
        if let imageBytes {
            effective.append(
                HistoryRepresentation(typeIdentifier: "public.png", bytes: imageBytes)
            )
        }
        if let text {
            effective.append(
                HistoryRepresentation(
                    typeIdentifier: "public.utf8-plain-text",
                    bytes: Data(text.utf8)
                )
            )
        }
        return details(for: item, effective: effective)
    }

    /// Details fixture for a representation shape outside the text/image
    /// convenience above (for example a valid unsupported UTI).
    private func details(
        for item: HistoryItemReference,
        effective: [HistoryRepresentation]
    ) -> HistoryDetails {
        HistoryDetails(
            item: item,
            canonical: effective,
            effective: effective,
            revisions: [],
            occurrence: CopyOccurrenceSummary(
                firstCopiedAt: Date(timeIntervalSince1970: 1_787_000_000),
                lastCopiedAt: Date(timeIntervalSince1970: 1_787_000_600),
                count: 2,
                firstSource: "com.example.preview",
                lastSource: "com.example.preview"
            ),
            pinnedPosition: nil
        )
    }

    // MARK: - Reference fence (PREVIEW-FENCE-1)

    /// A→B selection with A completing LATE: B publishes; A's late result is
    /// discarded by the exact-reference fence and never reaches the
    /// published state (SPEC-IMPL-007's cross-item leak).
    @Test func lateResultNeverPublishesOverANewerSelection() async {
        let refA = reference("00000000-0000-0000-0000-0000000001A1", version: 1)
        let refB = reference("00000000-0000-0000-0000-0000000001B1", version: 1)
        let history = PausableDetailsHistory()
        await history.scriptDetails(details(for: refA, text: "alpha"))
        await history.scriptDetails(details(for: refB, text: "bravo"))
        let loader = PreviewContentLoader(history: history)

        Task { await loader.load(item: refA) }
        #expect(await pollUntil { await history.detailRequests.count == 1 })
        #expect(loader.phase == .loading)

        Task { await loader.load(item: refB) }
        #expect(await pollUntil { await history.detailRequests.count == 2 })
        #expect(loader.requestedItem == refB)

        // B completes FIRST and publishes.
        await history.resumeDetails(for: refB.id)
        #expect(await pollUntil { loader.phase == .content(.text("bravo")) })
        #expect(loader.occurrence?.lastSource == "com.example.preview")

        // A completes LATE: superseded, so the fence discards it — the
        // settle window lets A's completion run in full before asserting.
        await history.resumeDetails(for: refA.id)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(loader.phase == .content(.text("bravo")))
        #expect(loader.requestedItem == refB)
    }

    /// Reference equality is not enough when two retries overlap for the
    /// same exact item. The older episode may finish last, but its generation
    /// cannot overwrite the newer episode or mutate its loading state.
    @Test func olderSameReferenceEpisodeCannotPublishOverNewerEpisode() async throws {
        let ref = reference("00000000-0000-0000-0000-0000000001B2", version: 1)
        let history = OverlappingDetailsHistory()
        let loader = PreviewContentLoader(history: history)

        let olderLoad = Task { await loader.load(item: ref) }
        try #require(await pollUntil { await history.requestCount == 1 })
        let newerLoad = Task { await loader.load(item: ref) }
        try #require(await pollUntil { await history.requestCount == 2 })

        await history.resumeRequest(1, with: details(for: ref, text: "newer"))
        _ = await newerLoad.value
        #expect(loader.phase == .content(.text("newer")))

        await history.resumeRequest(0, with: details(for: ref, text: "older"))
        _ = await olderLoad.value
        #expect(loader.phase == .content(.text("newer")))
    }

    #if DEBUG
    /// PLAY-PREVIEW-A3: A has finished its History read and is parked inside
    /// the real renderer; B enters the reentrant actor and publishes text.
    /// Releasing A afterwards cannot replace B with the old raster.
    @Test func slowRasterAAfterFastTextBPublishesOnlyB() async throws {
        let refA = reference("00000000-0000-0000-0000-0000000001B3", version: 1)
        let refB = reference("00000000-0000-0000-0000-0000000001B4", version: 1)
        let history = PausableDetailsHistory()
        await history.scriptDetails(details(for: refA, imageBytes: fixturePNGData))
        await history.scriptDetails(details(for: refB, text: "current B"))
        let loader = PreviewContentLoader(history: history)
        let gate = PreviewRenderGate()
        let hook: @Sendable () async -> Void = { await gate.parkFirst() }

        try await ContentPreviewDebugInstrumentation.$renderDidStart.withValue(hook) {
            let loadA = Task { await loader.load(item: refA) }
            try #require(await pollUntil { await history.detailRequests.count == 1 })
            await history.resumeDetails(for: refA.id)
            await gate.waitUntilParked()
            let parked = await loader.rendererDebugSnapshot()
            #expect(parked.activeJobs == 1)
            #expect(parked.retainedSourceBytes == fixturePNGData.count)

            let loadB = Task { await loader.load(item: refB) }
            try #require(await pollUntil { await history.detailRequests.count == 2 })
            await history.resumeDetails(for: refB.id)
            _ = await loadB.value
            #expect(loader.phase == .content(.text("current B")))

            await gate.resume()
            _ = await loadA.value
            #expect(loader.requestedItem == refB)
            #expect(loader.phase == .content(.text("current B")))
            #expect(loader.raster == nil)
            let settled = await loader.rendererDebugSnapshot()
            #expect(settled.activeJobs == 0)
            #expect(settled.retainedSourceBytes == 0)
        }
    }

    /// PLAY-PREVIEW-A4: closing the pane while native work is parked clears
    /// publication immediately; the later old completion remains discarded.
    @Test func panelCloseFencesParkedRendererCompletion() async throws {
        let ref = reference("00000000-0000-0000-0000-0000000001B5", version: 1)
        let history = PausableDetailsHistory()
        await history.scriptDetails(details(for: ref, imageBytes: fixturePNGData))
        let loader = PreviewContentLoader(history: history)
        let gate = PreviewRenderGate()
        let hook: @Sendable () async -> Void = { await gate.parkFirst() }

        try await ContentPreviewDebugInstrumentation.$renderDidStart.withValue(hook) {
            let load = Task { await loader.load(item: ref) }
            try #require(await pollUntil { await history.detailRequests.count == 1 })
            await history.resumeDetails(for: ref.id)
            await gate.waitUntilParked()

            await loader.load(item: nil)
            #expect(loader.requestedItem == nil)
            #expect(loader.phase == .unsupported)
            #expect(loader.raster == nil)

            await gate.resume()
            _ = await load.value
            #expect(loader.phase == .unsupported)
            #expect(loader.raster == nil)
        }
    }

    /// PLAY-PREVIEW-A5: the same business ID advances from v1 to v2 while
    /// v1 rasterization is parked. v2 text publishes; v1 never returns under
    /// the new exact reference.
    @Test func revisionRetargetFencesParkedOldRaster() async throws {
        let refV1 = reference("00000000-0000-0000-0000-0000000001B6", version: 1)
        let refV2 = reference("00000000-0000-0000-0000-0000000001B6", version: 2)
        let history = PausableDetailsHistory()
        await history.scriptDetails(details(for: refV1, imageBytes: fixturePNGData))
        let loader = PreviewContentLoader(history: history)
        let gate = PreviewRenderGate()
        let hook: @Sendable () async -> Void = { await gate.parkFirst() }

        try await ContentPreviewDebugInstrumentation.$renderDidStart.withValue(hook) {
            let oldLoad = Task { await loader.load(item: refV1) }
            try #require(await pollUntil { await history.detailRequests.count == 1 })
            await history.resumeDetails(for: refV1.id)
            await gate.waitUntilParked()

            await history.scriptDetails(details(for: refV2, text: "revision v2"))
            let newLoad = Task { await loader.load(item: refV2) }
            try #require(await pollUntil { await history.detailRequests.count == 2 })
            await history.resumeDetails(for: refV2.id)
            _ = await newLoad.value
            #expect(loader.phase == .content(.text("revision v2")))

            await gate.resume()
            _ = await oldLoad.value
            #expect(loader.requestedItem == refV2)
            #expect(loader.phase == .content(.text("revision v2")))
            #expect(loader.raster == nil)
        }
    }
    #endif

    /// A cancelled load publishes nothing: the details read still completes
    /// (the double is not cancellation-aware), but the cancellation check
    /// after the await discards the result.
    @Test func cancelledLoadPublishesNothing() async throws {
        let refA = reference("00000000-0000-0000-0000-0000000001C1", version: 1)
        let history = PausableDetailsHistory()
        await history.scriptDetails(details(for: refA, text: "alpha"))
        let loader = PreviewContentLoader(history: history)

        let task = Task { await loader.load(item: refA) }
        try #require(await pollUntil { await history.detailRequests.count == 1 })
        task.cancel()
        await history.resumeDetails(for: refA.id)
        _ = await task.value  // deterministic: the discarded load ran to its end
        #expect(loader.phase == .loading)
        #expect(loader.occurrence == nil)
    }

    /// The version half of the fence: `details(for:)` reads by ID, so a
    /// revision that advanced the Content Version mid-load answers with the
    /// CURRENT reference — the loader must not publish it under the
    /// requested (now stale) one (04 §9's caller-side fence convention).
    @Test func revisedDetailsAreNotAppliedUnderTheRequestingReference() async {
        let refV1 = reference("00000000-0000-0000-0000-0000000001D1", version: 1)
        let refV2 = reference("00000000-0000-0000-0000-0000000001D1", version: 2)
        let history = PausableDetailsHistory()
        // The store answers the item's CURRENT reference (v2)…
        await history.scriptDetails(details(for: refV2, text: "revised"))
        let loader = PreviewContentLoader(history: history)

        // …to a load that started at v1.
        let task = Task { await loader.load(item: refV1) }
        #expect(await pollUntil { await history.detailRequests.count == 1 })
        await history.resumeDetails(for: refV1.id)
        _ = await task.value
        #expect(loader.phase == .failed)
        #expect(!loader.canRetryFailure)
        #expect(loader.occurrence == nil)
    }

    /// When observation advances the selected row from v1 to v2, beginning
    /// the exact v2 load immediately invalidates v1's content and metadata.
    /// The old sensitive value is never retained as the new request's
    /// placeholder, and only v2 may publish when its read completes.
    @Test func sameIDVersionRetargetInvalidatesOldContentBeforePublishingNew() async throws {
        let refV1 = reference("00000000-0000-0000-0000-0000000001D2", version: 1)
        let refV2 = reference("00000000-0000-0000-0000-0000000001D2", version: 2)
        let history = PausableDetailsHistory()
        let loader = PreviewContentLoader(history: history)

        await history.scriptDetails(details(for: refV1, text: "sensitive v1"))
        let firstLoad = Task { await loader.load(item: refV1) }
        try #require(await pollUntil { await history.detailRequests.count == 1 })
        await history.resumeDetails(for: refV1.id)
        _ = await firstLoad.value
        #expect(loader.phase == .content(.text("sensitive v1")))
        #expect(loader.occurrence != nil)

        await history.scriptDetails(details(for: refV2, text: "current v2"))
        let secondLoad = Task { await loader.load(item: refV2) }
        try #require(await pollUntil { await history.detailRequests.count == 2 })
        #expect(loader.requestedItem == refV2)
        #expect(loader.phase == .loading)
        #expect(loader.occurrence == nil)
        #expect(loader.appliedImageSize == nil)

        await history.resumeDetails(for: refV2.id)
        _ = await secondLoad.value
        #expect(loader.phase == .content(.text("current v2")))
    }

    /// A transient History read failure is retryable presentation state, not
    /// the stable unsupported state. Retrying uses the SAME exact reference;
    /// a successful answer clears the failure episode.
    @Test func transientFailureRetriesTheSameReferenceAndClearsFailure() async throws {
        let refA = reference("00000000-0000-0000-0000-0000000001E1", version: 1)
        let history = PausableDetailsHistory()
        let loader = PreviewContentLoader(history: history)

        let task = Task { await loader.load(item: refA) }
        try #require(await pollUntil { await history.detailRequests.count == 1 })
        await history.resumeDetails(
            for: refA.id,
            throwing: .temporarilyUnavailable(.dedupIndexRebuild)
        )
        _ = await task.value
        #expect(loader.requestedItem == refA)
        #expect(loader.phase == .failed)
        #expect(loader.canRetryFailure)
        #expect(loader.occurrence == nil)

        await history.scriptDetails(details(for: refA, text: "recovered"))
        let retry = Task { await loader.retry() }
        try #require(await pollUntil { await history.detailRequests.count == 2 })
        #expect(loader.requestedItem == refA)
        #expect(loader.phase == .loading)
        await history.resumeDetails(for: refA.id)
        _ = await retry.value

        #expect(loader.requestedItem == refA)
        #expect(loader.phase == .content(.text("recovered")))
        #expect(!loader.canRetryFailure)
    }

    /// A legal representation for which this phase has no renderer is a
    /// stable unsupported result. It is distinct from a failed load and
    /// therefore the view does not offer Retry.
    @Test func validNonPreviewableRepresentationIsStableUnsupported() async throws {
        let ref = reference("00000000-0000-0000-0000-0000000001E2", version: 1)
        let representation = HistoryRepresentation(
            typeIdentifier: "public.url",
            bytes: Data("https://example.com".utf8)
        )
        let history = PausableDetailsHistory()
        await history.scriptDetails(details(for: ref, effective: [representation]))
        let loader = PreviewContentLoader(history: history)

        let task = Task { await loader.load(item: ref) }
        try #require(await pollUntil { await history.detailRequests.count == 1 })
        await history.resumeDetails(for: ref.id)
        _ = await task.value

        #expect(loader.requestedItem == ref)
        #expect(loader.phase == .unsupported)
        #expect(!loader.canRetryFailure)
    }

    /// RTF/HTML are valid opaque clipboard representations but have no safe
    /// semantic renderer in this phase. They settle as unsupported, and the
    /// Card 9D retry affordance cannot start another History read.
    @Test func structuredTextWithoutPlainSiblingIsUnsupportedAndNotRetryable() async throws {
        let ref = reference("00000000-0000-0000-0000-0000000001E3", version: 1)
        let representations = [
            HistoryRepresentation(
                typeIdentifier: "public.rtf",
                bytes: Data(#"{\rtf1\ansi Literal RTF}"#.utf8)
            ),
            HistoryRepresentation(
                typeIdentifier: "public.html",
                bytes: Data("<p>Literal HTML</p>".utf8)
            ),
        ]
        let history = PausableDetailsHistory()
        await history.scriptDetails(details(for: ref, effective: representations))
        let loader = PreviewContentLoader(history: history)

        let task = Task { await loader.load(item: ref) }
        try #require(await pollUntil { await history.detailRequests.count == 1 })
        await history.resumeDetails(for: ref.id)
        _ = await task.value

        #expect(loader.phase == .unsupported)
        #expect(!loader.canRetryFailure)
        await loader.retry()
        #expect(await history.detailRequests.count == 1)
        #expect(loader.phase == .unsupported)
    }

    /// Caller-input failures are terminal for this exact preview request.
    /// They may use the failed copy, but must not expose or execute Retry:
    /// only `temporarilyUnavailable` says that retrying later is admitted.
    @Test func invalidHistoryFailureIsNotRetryable() async throws {
        let ref = reference("00000000-0000-0000-0000-0000000001E4", version: 1)
        let history = PausableDetailsHistory()
        let loader = PreviewContentLoader(history: history)

        let task = Task { await loader.load(item: ref) }
        try #require(await pollUntil { await history.detailRequests.count == 1 })
        await history.resumeDetails(
            for: ref.id,
            throwing: .invalidInput(.unsupportedRepresentationType("public.invalid"))
        )
        _ = await task.value

        #expect(loader.phase == .failed)
        #expect(!loader.canRetryFailure)
        await loader.retry()
        #expect(await history.detailRequests.count == 1)
    }

    @Test func persistenceHistoryFailureIsNotRetryable() async throws {
        let ref = reference("00000000-0000-0000-0000-0000000001E5", version: 1)
        let history = PausableDetailsHistory()
        let loader = PreviewContentLoader(history: history)

        let task = Task { await loader.load(item: ref) }
        try #require(await pollUntil { await history.detailRequests.count == 1 })
        await history.resumeDetails(
            for: ref.id,
            throwing: .persistence(.corruptStoredValue)
        )
        _ = await task.value

        #expect(loader.phase == .failed)
        #expect(!loader.canRetryFailure)
        await loader.retry()
        #expect(await history.detailRequests.count == 1)
    }

    // MARK: - Bounded off-MainActor decode (S-2/SPEC-IMPL-002)

    /// An image item publishes the BOUNDED decoded image (1×1 here — under
    /// the 640 px preview cap, so no rescale): the loader retains decoded
    /// pixels only, never the full encoded bytes.
    @Test func imageContentPublishesTheBoundedDecode() async {
        let ref = reference("00000000-0000-0000-0000-0000000001F1", version: 1)
        let history = PausableDetailsHistory()
        await history.scriptDetails(details(for: ref, imageBytes: fixturePNGData))
        let loader = PreviewContentLoader(history: history)

        let task = Task { await loader.load(item: ref) }
        #expect(await pollUntil { await history.detailRequests.count == 1 })
        await history.resumeDetails(for: ref.id)
        _ = await task.value
        #expect(loader.phase == .content(.image))
        #expect(loader.appliedImageSize == CGSize(width: 1, height: 1))
        #expect(
            loader.appliedImageAccessibilityLabel
                == "Image preview, 1 by 1 pixels"
        )
    }

    /// A supported image type whose decoder cannot produce an artifact lands
    /// on failed (not unsupported), but replaying the same malformed bytes is
    /// not admitted and therefore does not offer Retry.
    @Test func supportedImageDecodeFailureIsNotRetryable() async throws {
        let ref = reference("00000000-0000-0000-0000-0000000001F2", version: 1)
        let history = PausableDetailsHistory()
        await history.scriptDetails(
            details(for: ref, imageBytes: Data([0x00, 0x01, 0x02, 0x03]))
        )
        let loader = PreviewContentLoader(history: history)

        let task = Task { await loader.load(item: ref) }
        try #require(await pollUntil { await history.detailRequests.count == 1 })
        await history.resumeDetails(for: ref.id)
        _ = await task.value
        #expect(loader.phase == .failed)
        #expect(!loader.canRetryFailure)
        #expect(loader.appliedImageSize == nil)
    }

    /// The declared text codec is part of preview support. Invalid bytes are
    /// therefore a failed decode episode, not evidence that the UTI itself is
    /// unsupported; retrying the same invalid bytes is not admitted.
    @Test func supportedTextDecodeFailureIsNotRetryable() async throws {
        let ref = reference("00000000-0000-0000-0000-0000000001F3", version: 1)
        let representation = HistoryRepresentation(
            typeIdentifier: "public.utf8-plain-text",
            bytes: Data([0xFF, 0xFE, 0xFF])
        )
        let history = PausableDetailsHistory()
        await history.scriptDetails(details(for: ref, effective: [representation]))
        let loader = PreviewContentLoader(history: history)

        let task = Task { await loader.load(item: ref) }
        try #require(await pollUntil { await history.detailRequests.count == 1 })
        await history.resumeDetails(for: ref.id)
        _ = await task.value

        #expect(loader.phase == .failed)
        #expect(!loader.canRetryFailure)
        #expect(loader.occurrence == nil)
    }

    // MARK: - Clearing

    /// A `nil` load (selection cleared / pane closed) resets the published
    /// state synchronously.
    @Test func loadingNilClearsThePaneState() async {
        let refA = reference("00000000-0000-0000-0000-0000000001A2", version: 1)
        let history = PausableDetailsHistory()
        await history.scriptDetails(details(for: refA, text: "alpha"))
        let loader = PreviewContentLoader(history: history)

        Task { await loader.load(item: refA) }
        #expect(await pollUntil { await history.detailRequests.count == 1 })
        await history.resumeDetails(for: refA.id)
        #expect(await pollUntil { loader.phase == .content(.text("alpha")) })

        await loader.load(item: nil)
        #expect(loader.phase == .unsupported)
        #expect(loader.occurrence == nil)
        #expect(loader.requestedItem == nil)
    }
}

#if DEBUG
private actor PreviewRenderGate {
    private var isParked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func parkFirst() async {
        guard !isParked else { return }
        isParked = true
        let parkedWaiters = waiters
        waiters.removeAll()
        for waiter in parkedWaiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilParked() async {
        guard !isParked else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}
#endif

/// Allows multiple same-ID detail reads to overlap. Each continuation is
/// resumed explicitly by request order, making generation ordering observable
/// without sleeps or a second storage implementation.
private actor OverlappingDetailsHistory: ClipboardHistory {
    private var continuations: [CheckedContinuation<HistoryDetails, Error>?] = []

    var requestCount: Int { continuations.count }

    func resumeRequest(_ index: Int, with details: HistoryDetails) {
        guard continuations.indices.contains(index),
              let continuation = continuations[index]
        else { return }
        continuations[index] = nil
        continuation.resume(returning: details)
    }

    func perform(_ action: HistoryAction) async throws -> HistoryReceipt {
        .unchanged
    }

    func browse(_ request: HistoryBrowseRequest) async throws -> HistoryPage {
        HistoryPage(position: ChangePosition(rawValue: 0), rows: [], next: nil)
    }

    func observe(
        _ request: HistoryObservationRequest
    ) async -> AsyncThrowingStream<HistoryPage, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }

    func details(for id: HistoryItemID) async throws -> HistoryDetails {
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func pastePayload(for id: HistoryItemID) async throws -> PastePayload {
        throw HistoryFailure.notFound(id)
    }

    func thumbnail(
        for item: HistoryItemReference,
        pixels: PixelSize
    ) async throws -> ThumbnailPayload? {
        nil
    }

    func retentionConfiguration() async throws -> HistoryRetentionConfiguration {
        .newStoreDefaults
    }
}
