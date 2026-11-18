/// PLAY-PREVIEW-0/A1/A2 — behavior through the concrete ContentPreview seam.
/// Expected text and pixel dimensions are literal fixture facts; tests never
/// reproduce ImageIO selection or artifact construction.
import ContentPreview
import Foundation
import Testing

@Suite("ContentPreview concrete renderer")
struct ContentPreviewTests {
    private let renderer = ContentPreview()

    @Test(arguments: ["public.utf16-plain-text", "public.utf16-external-plain-text"])
    func malformedTextFallsThroughToLaterExactSibling(identifier: String) async {
        let outcome = await renderer.renderHistoryPane([
            PreviewRepresentation(
                typeIdentifier: identifier,
                bytes: Data([0x41])
            ),
            PreviewRepresentation(
                typeIdentifier: "public.utf8-plain-text",
                bytes: Data("valid sibling".utf8)
            ),
        ])
        guard case let .content(.text(text)) = outcome else {
            Issue.record("expected later valid sibling, got \(outcome)")
            return
        }
        #expect(text.text == "valid sibling")
    }

    @Test("the old invented external UTF-8 identifier remains opaque")
    func inventedExternalUTF8RemainsUnsupported() async {
        let outcome = await renderer.renderHistoryPane([
            PreviewRepresentation(
                typeIdentifier: "public.utf8-external-plain-text",
                bytes: Data("external".utf8)
            ),
        ])
        #expect(outcome == .unavailable(.unsupported))
    }

    @Test(arguments: [
        ("public.utf8-plain-text", 64 * 1_048_576),
        ("public.png", 64 * 1_048_576),
        ("public.rtf", 1_048_576),
        ("public.html", 1_048_576),
        ("public.file-url", 16 * 1_024),
    ])
    func sourceBudgetIsCheckedFromMetadataWithoutAllocatingPayload(type: String, maximum: Int) throws {
        let accepted = try #require(ContentPreview.prepareHistoryPane([
            PreviewRepresentationMetadata(typeIdentifier: type, byteCount: maximum),
        ]).first)
        #expect(accepted.preflightFailure == nil)
        let rejected = try #require(ContentPreview.prepareHistoryPane([
            PreviewRepresentationMetadata(typeIdentifier: type, byteCount: maximum + 1),
        ]).first)
        #expect(rejected.preflightFailure == .failed(.resourceLimit))
    }

    @Test func largeUnselectedRepresentationDoesNotConsumeSelectedSourceBudget() async throws {
        let sources = ContentPreview.prepareHistoryPane([
            PreviewRepresentationMetadata(typeIdentifier: "com.adobe.pdf", byteCount: 64 * 1_048_576),
            PreviewRepresentationMetadata(typeIdentifier: "public.png", byteCount: Self.onePixelPNG.count),
        ])
        let selected = try #require(sources.first)
        #expect(sources.count == 1)
        #expect(selected.representationIndex == 1)
        #expect(selected.preflightFailure == nil)
        let outcome = await renderer.renderSelectedHistoryPane(selected, representation: PreviewRepresentation(
            typeIdentifier: "public.png", bytes: Self.onePixelPNG
        ))
        guard case .content(.raster(let raster)) = outcome else {
            Issue.record("Expected only the selected PNG to render, got \(outcome)")
            return
        }
        #expect(raster.width == 1 && raster.height == 1)
    }

    @Test func inMemoryInputBudgetIncludesUnselectedRepresentations() async {
        // Shared immutable storage keeps the fixture small while its complete
        // representation input exceeds the renderer's 64 MiB budget.
        let opaque = PreviewRepresentation(
            typeIdentifier: "com.example.opaque", bytes: Data(repeating: 0, count: 1_048_576)
        )
        let representations = [PreviewRepresentation(typeIdentifier: "public.png", bytes: Self.onePixelPNG)]
            + Array(repeating: opaque, count: 64)
        let outcome = await renderer.renderHistoryPane(representations)
        #expect(outcome == .failed(.resourceLimit))
    }

    @Test func selectedSourceRejectsMismatchedPayload() async throws {
        let sources = ContentPreview.prepareHistoryPane([
            PreviewRepresentationMetadata(typeIdentifier: "public.utf8-plain-text", byteCount: 1),
        ])
        let text = try #require(sources.first)
        let mismatch = await renderer.renderSelectedHistoryPane(text, representation: PreviewRepresentation(
            typeIdentifier: "public.utf8-plain-text", bytes: Data("too many bytes".utf8)
        ))
        #expect(mismatch == .failed(.malformedRepresentation))
    }

    #if DEBUG
    @Test("one native raster slot queues and then hands off a second render")
    func nativeRasterSlotIsSingleAndHandsOff() async {
        let renderer = ContentPreview()
        let gate = RenderStartGate()
        let hook: @Sendable () async -> Void = { await gate.parkFirst() }

        await ContentPreviewDebugInstrumentation.$renderDidStart.withValue(hook) {
            let first = Task {
                await renderer.rasterizePNGForDisplay(Self.onePixelPNG)
            }
            await gate.waitUntilParked()

            let second = Task {
                await renderer.rasterizePNGForDisplay(Self.onePixelPNG)
            }
            var queued = false
            for _ in 0..<1_000 {
                if await renderer.debugSnapshot().activeJobs == 2 {
                    queued = true
                    break
                }
                await Task.yield()
            }
            let entryCountBeforeRelease = await gate.entryCount

            await gate.resume()
            _ = await first.value
            _ = await second.value
            #expect(queued)
            #expect(entryCountBeforeRelease == 1)
            #expect(await gate.entryCount == 2)
        }

        let settled = await renderer.debugSnapshot()
        #expect(settled.activeJobs == 0)
        #expect(settled.retainedSourceBytes == 0)
    }

    @Test("cancelling queued raster work releases its source without releasing the occupied slot", arguments: [false, true])
    @MainActor
    func cancelledWaiterFinishesBeforeTheActiveRasterAndDoesNotAdmitTheNextWaiter(selectedOnly: Bool) async {
        let renderer = ContentPreview()
        let gate = RenderStartGate()
        let hook: @Sendable () async -> Void = { await gate.parkFirst() }
        let pngBytes = Self.onePixelPNG.count

        await ContentPreviewDebugInstrumentation.$renderDidStart.withValue(hook) {
            let first = Task { await renderer.rasterizePNGForDisplay(Self.onePixelPNG) }
            await gate.waitUntilParked()

            var cancelledOutcome: PreviewOutcome?
            let second = Task {
                let outcome: PreviewOutcome
                if selectedOnly {
                    let source = ContentPreview.prepareHistoryPane([
                        PreviewRepresentationMetadata(typeIdentifier: "public.png", byteCount: pngBytes),
                        PreviewRepresentationMetadata(typeIdentifier: "com.example.opaque", byteCount: 4_096),
                    ])[0]
                    outcome = await renderer.renderSelectedHistoryPane(source, representation: PreviewRepresentation(
                        typeIdentifier: "public.png", bytes: Self.onePixelPNG
                    ))
                } else {
                    outcome = await renderer.renderHistoryPane([
                        PreviewRepresentation(typeIdentifier: "public.png", bytes: Self.onePixelPNG),
                        PreviewRepresentation(typeIdentifier: "com.example.opaque", bytes: Data(repeating: 0, count: 4_096)),
                    ])
                }
                cancelledOutcome = outcome
                return outcome
            }
            var secondQueued = false
            for _ in 0..<10_000 {
                if await renderer.debugSnapshot().queuedRasterJobs == 1 {
                    secondQueued = true
                    break
                }
                await Task.yield()
            }
            let withQueuedInput = await renderer.debugSnapshot()
            second.cancel()
            for _ in 0..<10_000 {
                if cancelledOutcome != nil { break }
                await Task.yield()
            }
            let cancelledBeforeFirstFinished = cancelledOutcome == .failed(.cancelled)
            let afterCancellation = await renderer.debugSnapshot()

            let third = Task { await renderer.rasterizePNGForDisplay(Self.onePixelPNG) }
            var thirdQueued = false
            for _ in 0..<10_000 {
                if await renderer.debugSnapshot().queuedRasterJobs == 1 {
                    thirdQueued = true
                    break
                }
                await Task.yield()
            }
            let nativeEntriesBeforeRelease = await gate.entryCount

            // Always release the native owner and join every task, even when
            // a regression kept the cancelled waiter suspended. Failure must
            // report the premature retention rather than hang the suite.
            await gate.resume()
            let firstOutcome = await first.value
            _ = await second.value
            let thirdOutcome = await third.value

            #expect(secondQueued)
            // The full-data caller retains its whole array across the await;
            // the metadata path never loads the opaque sibling at all.
            if selectedOnly {
                #expect(withQueuedInput.retainedSourceBytes == 2 * pngBytes)
            } else {
                #expect(withQueuedInput.retainedSourceBytes == 2 * pngBytes + 4_096)
            }
            #expect(cancelledBeforeFirstFinished)
            #expect(afterCancellation.activeJobs == 1)
            #expect(afterCancellation.retainedSourceBytes == pngBytes)
            #expect(afterCancellation.queuedRasterJobs == 0)
            #expect(thirdQueued)
            #expect(nativeEntriesBeforeRelease == 1)
            #expect(await gate.entryCount == 2)
            guard case .content(.raster) = firstOutcome,
                  case .content(.raster) = thirdOutcome else {
                Issue.record("The active and subsequent uncancelled raster requests must succeed")
                return
            }
        }

        let settled = await renderer.debugSnapshot()
        #expect(settled.activeJobs == 0)
        #expect(settled.retainedSourceBytes == 0)
    }

    @Test("an occupied native slot expires queued previews without admitting overlapping work", arguments: [false, true])
    @MainActor
    func nativeSlotTimeoutReleasesQueuedInputAndAllowsRetry(cancelActiveRender: Bool) async {
        let renderer = ContentPreview()
        let gate = RenderStartGate()
        let hook: @Sendable () async -> Void = { await gate.parkFirst() }
        await ContentPreviewDebugInstrumentation.$renderDidStart.withValue(hook) {
            let active = Task { await renderer.rasterizePNGForDisplay(Self.onePixelPNG) }
            await gate.waitUntilParked()
            // The parked native operation deliberately ignores cancellation,
            // just like a synchronous ImageIO decode that has not returned yet.
            if cancelActiveRender { active.cancel() }

            var imageOutcome: PreviewOutcome?
            var malformedImageOutcome: PreviewOutcome?
            let image = Task {
                imageOutcome = await renderer.renderHistoryPane([
                    PreviewRepresentation(typeIdentifier: "public.png", bytes: Self.onePixelPNG),
                    PreviewRepresentation(typeIdentifier: "com.example.opaque", bytes: Data(repeating: 0, count: 4_096)),
                ])
            }
            let malformedImage = Task {
                // No image decoding should occur while the slot is occupied;
                // even malformed input must report renderer availability here.
                malformedImageOutcome = await renderer.renderHistoryPane([
                    PreviewRepresentation(typeIdentifier: "public.png", bytes: Data("invalid image".utf8)),
                ])
            }
            let text = await renderer.renderHistoryPane([
                PreviewRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data("still available".utf8)),
            ])
            if case .content(.text(let artifact)) = text {
                #expect(artifact.text == "still available")
                #expect(!artifact.wasTruncated)
            } else {
                Issue.record("Text preview must remain available while rasterization is occupied.")
            }

            // Bound the observation separately from the product's two-second
            // wait. A regression must fail and release the parked renderer,
            // rather than leave the test suite suspended forever.
            let observationDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while (imageOutcome == nil || malformedImageOutcome == nil), ContinuousClock.now < observationDeadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            let imageBeforeRelease = imageOutcome
            let malformedImageBeforeRelease = malformedImageOutcome
            let afterTimeout = await renderer.debugSnapshot()
            let nativeEntriesBeforeRelease = await gate.entryCount
            await gate.resume()
            _ = await active.value
            await image.value
            await malformedImage.value

            #expect(imageBeforeRelease == .failed(.renderer))
            #expect(malformedImageBeforeRelease == .failed(.renderer))
            #expect(afterTimeout.activeJobs == 1)
            #expect(afterTimeout.queuedRasterJobs == 0)
            #expect(afterTimeout.retainedSourceBytes == Self.onePixelPNG.count)
            #expect(nativeEntriesBeforeRelease == 1)

            let retry = await renderer.rasterizePNGForDisplay(Self.onePixelPNG)
            guard case .content(.raster) = retry else {
                Issue.record("Retry must render after the original native owner releases its slot")
                return
            }
            #expect(await gate.entryCount == 2)
        }
        let settled = await renderer.debugSnapshot()
        #expect(settled.activeJobs == 0)
        #expect(settled.retainedSourceBytes == 0)
        #expect(settled.queuedRasterJobs == 0)
    }
    #endif

    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
    )!
}

#if DEBUG
private actor RenderStartGate {
    private var isParked = false
    private(set) var entryCount = 0
    private var didParkWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func parkFirst() async {
        entryCount += 1
        guard !isParked else { return }
        isParked = true
        let waiters = didParkWaiters
        didParkWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilParked() async {
        guard !isParked else { return }
        await withCheckedContinuation { continuation in
            didParkWaiters.append(continuation)
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}
#endif
