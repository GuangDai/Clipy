/// PreviewContentLoaderTests — the preview loader's cancellation /
/// exact-reference fence (audit docs/reviews/2026-08-20-clipy-maccy-audit/
/// 02-spec-implementation.md §SPEC-IMPL-007; 05-recommended-target-design.md
/// §4.1 PREVIEW-FENCE-1) and its bounded off-MainActor image decode outcome
/// (01-standards.md §S-2; 02 §SPEC-IMPL-002). Driven through
/// `PausableDetailsHistory`, which suspends every `details(for:)` read until
/// the test resumes it, so reverse completion order is deterministic — no
/// sleeps on the deciding path.
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
        return HistoryDetails(
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
        #expect(loader.isLoading)

        Task { await loader.load(item: refB) }
        #expect(await pollUntil { await history.detailRequests.count == 2 })
        #expect(loader.requestedItem == refB)

        // B completes FIRST and publishes.
        await history.resumeDetails(for: refB.id)
        #expect(await pollUntil { loader.content == .text("bravo") })
        #expect(loader.occurrence?.lastSource == "com.example.preview")
        #expect(!loader.isLoading)

        // A completes LATE: superseded, so the fence discards it — the
        // settle window lets A's completion run in full before asserting.
        await history.resumeDetails(for: refA.id)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(loader.content == .text("bravo"))
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
        #expect(loader.content == .text("newer"))
        #expect(!loader.isLoading)

        await history.resumeRequest(0, with: details(for: ref, text: "older"))
        _ = await olderLoad.value
        #expect(loader.content == .text("newer"))
        #expect(!loader.isLoading)
    }

    /// A cancelled load publishes nothing: the details read still completes
    /// (the double is not cancellation-aware), but the cancellation check
    /// after the await discards the result.
    @Test func cancelledLoadPublishesNothing() async {
        let refA = reference("00000000-0000-0000-0000-0000000001C1", version: 1)
        let history = PausableDetailsHistory()
        await history.scriptDetails(details(for: refA, text: "alpha"))
        let loader = PreviewContentLoader(history: history)

        let task = Task { await loader.load(item: refA) }
        #expect(await pollUntil { await history.detailRequests.count == 1 })
        task.cancel()
        await history.resumeDetails(for: refA.id)
        _ = await task.value  // deterministic: the discarded load ran to its end
        #expect(loader.content == .unavailable)
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
        #expect(loader.content == .unavailable)
        #expect(loader.occurrence == nil)
        #expect(
            !loader.isLoading,
            "a current-generation reference mismatch must settle instead of spinning forever"
        )
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
        #expect(loader.content == .text("sensitive v1"))
        #expect(loader.occurrence != nil)

        await history.scriptDetails(details(for: refV2, text: "current v2"))
        let secondLoad = Task { await loader.load(item: refV2) }
        try #require(await pollUntil { await history.detailRequests.count == 2 })
        #expect(loader.requestedItem == refV2)
        #expect(loader.isLoading)
        #expect(loader.content == .unavailable)
        #expect(loader.occurrence == nil)
        #expect(loader.appliedImageSize == nil)

        await history.resumeDetails(for: refV2.id)
        _ = await secondLoad.value
        #expect(loader.content == .text("current v2"))
        #expect(!loader.isLoading)
    }

    /// A typed failure renders as unavailable (the preview is a convenience
    /// surface, not an error owner — 03b §10 stays with the panel's banner)
    /// and clears the spinner.
    @Test func typedFailureRendersUnavailable() async {
        let refA = reference("00000000-0000-0000-0000-0000000001E1", version: 1)
        let history = PausableDetailsHistory()
        let loader = PreviewContentLoader(history: history)

        let task = Task { await loader.load(item: refA) }
        #expect(await pollUntil { await history.detailRequests.count == 1 })
        await history.resumeDetails(
            for: refA.id,
            throwing: .temporarilyUnavailable(.dedupIndexRebuild)
        )
        _ = await task.value
        #expect(loader.content == .unavailable)
        #expect(loader.occurrence == nil)
        #expect(!loader.isLoading)
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
        #expect(loader.content == .image)
        #expect(loader.appliedImageSize == CGSize(width: 1, height: 1))
        #expect(!loader.isLoading)
    }

    /// Bytes that look decodable but are not land on the decode-failure
    /// state, never on a partial publish.
    @Test func undecodableImageBytesRenderAsDecodeFailure() async {
        let ref = reference("00000000-0000-0000-0000-0000000001F2", version: 1)
        let history = PausableDetailsHistory()
        await history.scriptDetails(
            details(for: ref, imageBytes: Data([0x00, 0x01, 0x02, 0x03]))
        )
        let loader = PreviewContentLoader(history: history)

        let task = Task { await loader.load(item: ref) }
        #expect(await pollUntil { await history.detailRequests.count == 1 })
        await history.resumeDetails(for: ref.id)
        _ = await task.value
        #expect(loader.content == .imageDecodeFailed)
        #expect(loader.appliedImageSize == nil)
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
        #expect(await pollUntil { loader.content == .text("alpha") })

        await loader.load(item: nil)
        #expect(loader.content == .unavailable)
        #expect(loader.occurrence == nil)
        #expect(loader.requestedItem == nil)
        #expect(!loader.isLoading)
    }
}

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
