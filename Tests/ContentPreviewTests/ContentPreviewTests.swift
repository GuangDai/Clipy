/// PLAY-PREVIEW-0/A1/A2 — behavior through the concrete ContentPreview seam.
/// Expected text and pixel dimensions are literal fixture facts; tests never
/// reproduce ImageIO selection or artifact construction.
import ContentPreview
import Foundation
import Testing

@Suite("ContentPreview concrete renderer")
struct ContentPreviewTests {
    private let renderer = ContentPreview()

    @Test("exact UTF-8 returns a capped inert text artifact")
    func exactUTF8TextArtifact() async {
        let body = String(repeating: "a", count: PreviewText.maximumCharacters + 7)
        let outcome = await renderer.renderHistoryPane([
            PreviewRepresentation(
                typeIdentifier: "public.utf8-plain-text",
                bytes: Data(body.utf8)
            ),
        ])

        guard case let .content(.text(text)) = outcome else {
            Issue.record("expected capped text, got \(outcome)")
            return
        }
        #expect(text.wasTruncated)
        #expect(text.text.count == PreviewText.maximumCharacters + 3)
        #expect(text.text.hasPrefix(String(repeating: "a", count: 50_000)))
        #expect(text.text.hasSuffix("…"))
    }

    @Test("native UTF-16 honors BOM and BOM-less arm64 little endian")
    func nativeUTF16Artifact() async {
        let fixtures: [(Data, String)] = [
            (Data([0x41, 0x00, 0xA9, 0x03]), "AΩ"),
            (Data([0xFE, 0xFF, 0x00, 0x41, 0x03, 0xA9]), "AΩ"),
        ]
        for (bytes, expected) in fixtures {
            let outcome = await renderer.renderHistoryPane([
                PreviewRepresentation(
                    typeIdentifier: "public.utf16-plain-text",
                    bytes: bytes
                ),
            ])
            guard case let .content(.text(text)) = outcome else {
                Issue.record("expected native UTF-16 text, got \(outcome)")
                continue
            }
            #expect(text.text == expected)
            #expect(!text.wasTruncated)
        }
    }

    @Test("structured source uses its later exact plain-text sibling")
    func structuredSourceUsesExactPlainSibling() async {
        for structured in ["public.rtf", "public.html"] {
            let outcome = await renderer.renderHistoryPane([
                PreviewRepresentation(
                    typeIdentifier: structured,
                    bytes: Data("opaque markup".utf8)
                ),
                PreviewRepresentation(
                    typeIdentifier: "public.utf8-plain-text",
                    bytes: Data("semantic body".utf8)
                ),
            ])
            guard case let .content(.text(text)) = outcome else {
                Issue.record("expected exact plain sibling, got \(outcome)")
                continue
            }
            #expect(text.text == "semantic body")
        }
    }

    @Test("malformed text candidate does not hide a later valid sibling")
    func malformedTextFallsThroughToLaterExactSibling() async {
        let outcome = await renderer.renderHistoryPane([
            PreviewRepresentation(
                typeIdentifier: "public.utf16-plain-text",
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

    @Test("declared codec fact alone does not expand preview admission")
    func externalUTF8RemainsUnsupported() async {
        let outcome = await renderer.renderHistoryPane([
            PreviewRepresentation(
                typeIdentifier: "public.utf8-external-plain-text",
                bytes: Data("external".utf8)
            ),
        ])
        #expect(outcome == .unavailable(.unsupported))
    }

    @Test("image route wins and returns checked eager BGRA bytes")
    func imageFirstEagerRasterArtifact() async {
        let outcome = await renderer.renderHistoryPane([
                PreviewRepresentation(
                    typeIdentifier: "public.utf8-plain-text",
                    bytes: Data("text sibling".utf8)
                ),
                PreviewRepresentation(
                    typeIdentifier: "public.png",
                    bytes: Self.onePixelPNG
                ),
            ])

        guard case let .content(.raster(raster)) = outcome else {
            Issue.record("expected eager raster, got \(outcome)")
            return
        }
        #expect(raster.width == 1)
        #expect(raster.height == 1)
        #expect(raster.rowBytes == 4)
        #expect(raster.pixels.count == 4)
        #expect(raster.rowBytes * raster.height == raster.pixels.count)
        #expect(raster.pixels == Data([0x00, 0x00, 0xFF, 0xFF]))
    }

    @Test("selected PNG payload becomes the same eager display artifact")
    func selectedPNGDisplayRasterArtifact() async {
        let outcome = await renderer.rasterizePNGForDisplay(Self.onePixelPNG)
        guard case let .content(.raster(raster)) = outcome else {
            Issue.record("expected display raster, got \(outcome)")
            return
        }
        #expect(raster.width == 1)
        #expect(raster.height == 1)
        #expect(raster.pixels.count == 4)
    }

    @Test("structured and unknown representations remain unsupported")
    func unsupportedRepresentationsStayOpaque() async {
        for identifier in ["public.rtf", "public.html", "public.url", "dyn.example"] {
            let outcome = await renderer.renderHistoryPane([
                PreviewRepresentation(
                    typeIdentifier: identifier,
                    bytes: Data("opaque".utf8)
                ),
            ])
            #expect(outcome == .unavailable(.unsupported))
        }
    }

    @Test("malformed declared text and image are retryable renderer failures")
    func malformedDeclaredRepresentationsFail() async {
        let text = await renderer.renderHistoryPane([
            PreviewRepresentation(
                typeIdentifier: "public.utf8-plain-text",
                bytes: Data([0xFF, 0xFE, 0xFF])
            ),
        ])
        #expect(text == .failed(.malformedRepresentation))

        let image = await renderer.renderHistoryPane([
            PreviewRepresentation(
                typeIdentifier: "public.png",
                bytes: Data([0x89, 0x50, 0x4E, 0x47])
            ),
        ])
        #expect(image == .failed(.malformedRepresentation))
    }

    @Test("malformed primary image does not silently fall back to text")
    func malformedPrimaryImageFailsClosed() async {
        let outcome = await renderer.renderHistoryPane([
            PreviewRepresentation(
                typeIdentifier: "public.png",
                bytes: Data([0x89, 0x50, 0x4E, 0x47])
            ),
            PreviewRepresentation(
                typeIdentifier: "public.utf8-plain-text",
                bytes: Data("must not replace image".utf8)
            ),
        ])
        #expect(outcome == .failed(.malformedRepresentation))
    }

    @Test("history-pane aggregate input is admitted through 64 MiB before routing")
    func historyPaneAggregateInputEnvelope() async {
        let maximumInputBytes = 64 * 1_048_576

        do {
            let oversized = Data(repeating: 0x61, count: maximumInputBytes + 1)
            for identifier in [
                "public.utf8-plain-text",
                "public.png",
                "com.adobe.pdf",
            ] {
                let outcome = await renderer.renderHistoryPane([
                    PreviewRepresentation(
                        typeIdentifier: identifier,
                        bytes: oversized
                    ),
                ])
                #expect(outcome == .failed(.resourceLimit))
            }
        }

        let boundaryPadding = Data(repeating: 0, count: maximumInputBytes - 1)
        let aggregateOverBoundary = await renderer.renderHistoryPane([
            PreviewRepresentation(
                typeIdentifier: "com.adobe.pdf",
                bytes: boundaryPadding
            ),
            PreviewRepresentation(
                typeIdentifier: "public.png",
                bytes: Self.onePixelPNG
            ),
        ])
        #expect(aggregateOverBoundary == .failed(.resourceLimit))

        let exactBoundary = await renderer.renderHistoryPane([
            PreviewRepresentation(
                typeIdentifier: "com.adobe.pdf",
                bytes: boundaryPadding
            ),
            PreviewRepresentation(
                typeIdentifier: "public.utf8-plain-text",
                bytes: Data("a".utf8)
            ),
        ])
        guard case let .content(.text(text)) = exactBoundary else {
            Issue.record("expected exact-boundary text, got \(exactBoundary)")
            return
        }
        #expect(text.text == "a")
        #expect(!text.wasTruncated)
    }

    #if DEBUG
    @Test("parked render reports content-free accounting and returns to zero")
    func debugAccountingTracksOnlyActiveSourceBytes() async {
        let renderer = ContentPreview()
        let gate = RenderStartGate()
        let hook: @Sendable () async -> Void = {
            await gate.parkFirst()
        }
        await ContentPreviewDebugInstrumentation.$renderDidStart.withValue(hook) {
            let task = Task {
                await renderer.renderHistoryPane([
                    PreviewRepresentation(
                        typeIdentifier: "public.png",
                        bytes: Self.onePixelPNG
                    ),
                ])
            }
            await gate.waitUntilParked()
            let active = await renderer.debugSnapshot()
            #expect(active.activeJobs == 1)
            #expect(active.retainedSourceBytes == Self.onePixelPNG.count)
            await gate.resume()
            _ = await task.value
        }
        let settled = await renderer.debugSnapshot()
        #expect(settled.activeJobs == 0)
        #expect(settled.retainedSourceBytes == 0)
    }

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
