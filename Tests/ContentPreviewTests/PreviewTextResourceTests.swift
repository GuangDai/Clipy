@testable import ContentPreview
import Dispatch
import Foundation
import Testing

struct PreviewTextResourceTests {
    @Test(arguments: [(false, 4), (true, 4), (false, 12)])
    func cancellationStopsCharacterScalarAndGroupPreparation(combining: Bool, cancellationCheck: Int) async {
        let source = combining ? "e" + String(repeating: "\u{301}", count: 8_192)
            : String(repeating: "x", count: 8_192)
        let task = Task {
            var checks = 0
            do {
                _ = try PreviewText(text: source, wasTruncated: false,
                    configuration: .init(maximumCharacters: nil, segmentUTF16Budget: 2),
                    checkCancellation: {
                        checks += 1
                        if checks == cancellationCheck { withUnsafeCurrentTask { $0?.cancel() } }
                        try Task.checkCancellation()
                    })
                return false
            } catch is CancellationError {
                return checks == cancellationCheck
            } catch {
                Issue.record(error)
                return false
            }
        }
        #expect(await task.value)
    }

    @Test(arguments: ["\n", "\r", "\r\n", "\u{B}", "\u{C}", "\u{85}", "\u{2028}", "\u{2029}"])
    func shortSegmentsWithAnyUnicodeNewlineHaveTheirOwnNativeBridge(newline: String) {
        let source = "ab" + newline + "cd"
        let text = PreviewText(text: source, wasTruncated: false,
                              configuration: .init(segmentUTF16Budget: 2))
        #expect(Data(text.displaySegments.joined().utf8) == Data(source.utf8))
        #expect(text.displaySegmentGroups.allSatisfy { $0.count == 1 })
    }

    #if DEBUG
    @Test(.serialized, arguments: [false, true])
    @MainActor
    func synchronousTextWorkKeepsRasterRenderingAvailableAndQueuesMoreText(cancelOlderRender: Bool) async throws {
        let renderer = ContentPreview()
        let started = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="))
        let older = ContentPreviewDebugInstrumentation.$textRenderDidStart.withValue({
            started.signal()
            // A synchronous parser/native-font call cannot suspend to make
            // its actor available. Keep this worker synchronously occupied.
            _ = Self.waitForSignal(resume, until: .now() + 5)
        }) {
            Task {
                await renderer.renderHistoryPane([
                    PreviewRepresentation(typeIdentifier: "public.html", bytes: Data("<p>older</p>".utf8))
                ])
            }
        }
        let startDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        var didStart = false
        while !didStart, ContinuousClock.now < startDeadline {
            didStart = Self.waitForSignal(started, until: .now())
            if !didStart { try? await Task.sleep(for: .milliseconds(10)) }
        }
        if cancelOlderRender { older.cancel() }
        var imageOutcome: PreviewOutcome?
        let image = Task { imageOutcome = await renderer.rasterizePNGForDisplay(png) }
        var queuedTextOutcome: PreviewOutcome?
        let queuedText = Task {
            queuedTextOutcome = await renderer.renderHistoryPane([
                PreviewRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data("newer".utf8))
            ])
        }
        var busySnapshot: ContentPreviewDebugSnapshot?
        let observation = Task {
            while !Task.isCancelled {
                busySnapshot = await renderer.debugSnapshot()
                if busySnapshot?.queuedTextJobs == 1 { return }
                await Task.yield()
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while (imageOutcome == nil || busySnapshot?.queuedTextJobs != 1), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let imageWhileTextWasOccupied = imageOutcome
        let snapshotWhileTextWasOccupied = busySnapshot
        let textBeforeCancellation = queuedTextOutcome
        queuedText.cancel()
        let cancellationDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while queuedTextOutcome == nil, ContinuousClock.now < cancellationDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let cancelledBeforeOlderWorkerWasReleased = queuedTextOutcome
        // Join both jobs even on failure so an actor-blocking regression
        // reports its result instead of hanging the test process.
        resume.signal()
        let olderOutcome = await older.value
        await image.value
        await queuedText.value
        observation.cancel()
        await observation.value
        #expect(didStart)
        #expect(snapshotWhileTextWasOccupied?.queuedTextJobs == 1)
        #expect(textBeforeCancellation == nil)
        #expect(cancelledBeforeOlderWorkerWasReleased == .failed(.cancelled))
        if let imageWhileTextWasOccupied, case .content(.raster(let raster)) = imageWhileTextWasOccupied {
            #expect(raster.width == 1 && raster.height == 1)
        } else {
            Issue.record("The independent raster slot must remain available while the text worker is occupied")
        }
        #expect(olderOutcome == (cancelOlderRender
            ? .failed(.cancelled) : .content(.text(PreviewText(text: "older", wasTruncated: false)))))
        let settled = await renderer.debugSnapshot()
        #expect(settled.activeJobs == 0)
        #expect(settled.retainedSourceBytes == 0)
        #expect(settled.queuedTextJobs == 0)
        let retry = await renderer.renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data("retry".utf8))
        ])
        #expect(retry == .content(.text(PreviewText(text: "retry", wasTruncated: false))))
    }

    private static func waitForSignal(_ semaphore: DispatchSemaphore, until deadline: DispatchTime) -> Bool {
        semaphore.wait(timeout: deadline) == .success
    }
    #endif

    @Test func shortSegmentGroupsBoundBridgesWithoutRejoiningAnOversizedGrapheme() async throws {
        let source = "Prefix\ne" + String(repeating: "\u{301}", count: 20_000)
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(source.utf8))
        ])
        guard case .content(.text(let text)) = outcome else {
            Issue.record("Expected grouped complete text")
            return
        }
        #expect(text.displaySegments.count == 314)
        #expect(text.displaySegmentGroups.count == 41)
        #expect(text.displaySegmentGroups.first == 0..<1)
        #expect(text.displaySegmentGroups[1] == 1..<9)
        #expect(text.displaySegmentGroups.flatMap { Array($0) } == Array(text.displaySegments.indices))
        #expect(Data(text.displaySegmentGroups.flatMap { text.displaySegments[$0] }.joined().utf8) == Data(source.utf8))
        for group in text.displaySegmentGroups where group.count > 1 {
            #expect(group.count <= 8)
            #expect(group.allSatisfy { text.displaySegments[$0].utf16.count <= 64 })
            #expect(group.allSatisfy { !text.displaySegments[$0].contains(where: \.isNewline) })
        }
    }

    @Test(arguments: ["", "abcdefghij", String(repeating: "x", count: 200), String(repeating: "x\n", count: 20),
                      String(repeating: "长文本预览测试。\n", count: 50)])
    func groupingCoversEmptyShortAndMultilineValuesWithoutDroppingSegments(source: String) {
        let text = PreviewText(text: source, wasTruncated: false,
                              configuration: .init(segmentUTF16Budget: 64, segmentLineBreakBudget: 4))
        #expect(text.displaySegmentGroups.flatMap { Array($0) } == Array(text.displaySegments.indices))
        #expect(Data(text.displaySegments.joined().utf8) == Data(source.utf8))
        if source.contains(where: \.isNewline) {
            #expect(text.displaySegmentGroups.allSatisfy { $0.count == 1 })
        }
    }

    @Test func manyShortLinesAreAlsoSmallLayoutOperations() async {
        let source = String(repeating: "一二三\r\n", count: 200)
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(source.utf8))
        ], textConfiguration: PreviewTextConfiguration(maximumCharacters: nil, segmentLineBreakBudget: 8))
        guard case .content(.text(let text)) = outcome else {
            Issue.record("Expected the complete multiline text")
            return
        }
        #expect(text.displaySegments.count == 25)
        #expect(text.displaySegments.allSatisfy { $0 == String(repeating: "一二三\r\n", count: 8) })
        #expect(Data(text.displaySegments.joined().utf8) == Data(source.utf8))
        #expect(!text.wasTruncated)
    }
    @Test(arguments: [nil, 10_000, 80_000] as [Int?])
    func configuredLengthCanRetainCompleteTextOrAnyChosenPrefix(limit: Int?) async {
        let source = String(repeating: "x", count: 60_000) + "COMPLETE-TAIL"
        let representations = [
            PreviewRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(source.utf8)),
            PreviewRepresentation(typeIdentifier: "public.html", bytes: Data(("<pre>" + source + "</pre>").utf8)),
            PreviewRepresentation(typeIdentifier: "public.rtf", bytes: Data(("{\\rtf1 " + source + "}").utf8))
        ]
        for representation in representations {
            let outcome = await ContentPreview().renderHistoryPane([representation],
                textConfiguration: PreviewTextConfiguration(maximumCharacters: limit))
            guard case .content(.text(let text)) = outcome else {
                Issue.record("Expected a configured text preview")
                continue
            }
            let expected = limit == 10_000 ? String(repeating: "x", count: 10_000) : source
            #expect(Data(text.text.utf8) == Data(expected.utf8))
            #expect(Data(text.displaySegments.joined().utf8) == Data(expected.utf8))
            #expect(text.wasTruncated == (limit == 10_000))
        }
    }

    @Test func layoutWorkBudgetNeverBecomesADocumentLengthLimit() async {
        let source = String(repeating: "e\u{301}🦊", count: 800)
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(source.utf8))
        ], textConfiguration: PreviewTextConfiguration(maximumCharacters: nil, segmentUTF16Budget: 64))
        guard case .content(.text(let text)) = outcome else {
            Issue.record("Expected complete segmented Unicode text")
            return
        }
        #expect(Data(text.displaySegments.joined().utf8) == Data(source.utf8))
        #expect(text.displaySegments.allSatisfy { $0.utf16.count <= 64 })
        #expect(!text.wasTruncated)
    }

    @Test(arguments: ["public.utf8-plain-text", "public.html", "public.rtf"])
    func oversizedCombiningSequenceIsSegmentedWithoutDiscardingContent(type: String) async {
        let prefix = "Readable prefix\n"
        let marks = String(repeating: "\u{301}", count: 20_000)
        let bytes: Data
        switch type {
        case "public.html": bytes = Data(("<pre>" + prefix + "e" + marks + "</pre>").utf8)
        case "public.rtf":
            bytes = Data(("{\\rtf1 Readable prefix\\par e" + String(repeating: "\\u769?", count: 20_000) + "}").utf8)
        default: bytes = Data((prefix + "e" + marks).utf8)
        }
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: type, bytes: bytes)
        ])
        guard case .content(.text(let text)) = outcome else {
            Issue.record("Expected the readable source prefix")
            return
        }
        #expect(!text.wasTruncated)
        #expect(Data(text.text.utf8) == Data((prefix + "e" + marks).utf8))
        #expect(Data(text.displaySegments.joined().utf8) == Data(text.text.utf8))
        #expect(text.displaySegments.count > 1)
        #expect(text.displaySegments.allSatisfy { $0.utf16.count <= 64 })
    }

    @Test func oversizedGraphemeHonorsSmallerBudgetAtCompleteScalarBoundaries() async {
        // The supplementary combining mark consumes two UTF-16 units. An
        // odd work budget exercises boundaries without breaking its scalar.
        let source = "e" + String(repeating: "\u{1D165}\u{301}", count: 2_000)
        #expect(source.count == 1)
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(source.utf8))
        ], textConfiguration: PreviewTextConfiguration(segmentUTF16Budget: 63))
        guard case .content(.text(let text)) = outcome else {
            Issue.record("Expected the complete combining sequence")
            return
        }
        #expect(!text.wasTruncated)
        #expect(Data(text.text.utf8) == Data(source.utf8))
        #expect(Data(text.displaySegments.joined().utf8) == Data(source.utf8))
        #expect(text.displaySegments.allSatisfy { !$0.isEmpty && $0.utf16.count <= 63 })
    }
}
