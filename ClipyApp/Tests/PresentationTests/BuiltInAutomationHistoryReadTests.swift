import AppKit
import Foundation
import HistoryCore
@testable import HistoryStorage
import Testing
@testable import ClipyApp

@MainActor
struct BuiltInAutomationHistoryReadTests {
    @Test func manualHistoryKeepsItemAndCodecFallbackWithoutReadingUnselectedFormats() async throws {
        let text = "target e\u{301}😀"
        let (history, item) = try await capture([
            .init(typeIdentifier: "public.utf8-plain-text", bytes: Data("unmatched".utf8)),
            .init(typeIdentifier: "public.png", bytes: Data(repeating: 0x41, count: 131_073)),
            .init(typeIdentifier: "com.example.opaque", bytes: Data(repeating: 0x42, count: 131_073)),
            // The exact persisted order tries the external UTF-16 format
            // first. Its odd byte fails decoding, then native UTF-16 works.
            .init(typeIdentifier: "public.utf16-external-plain-text", bytes: Data([0x41]), pasteboardItemIndex: 1),
            .init(typeIdentifier: "public.utf16-plain-text", bytes: utf16(text), pasteboardItemIndex: 1),
            .init(typeIdentifier: "public.utf8-plain-text", bytes: Data("later unused format".utf8), pasteboardItemIndex: 1),
        ])
        let workflow = historyWorkflow(steps: [.init(operation: .containsText, find: "target")])
        let payload = try await history.pastePayload(for: item.id)
        let expected = try await BuiltInAutomation.evaluate(
            BuiltInAutomation.inputs(from: payload.representations, workflow: workflow), workflow: workflow
        )
        for (index, type) in [(0, "public.png"), (0, "com.example.opaque"), (1, "public.utf8-plain-text")] {
            try await history.authority.makeWorkflowPayloadUnavailable(item.id, index: index, type: type)
        }
        let before = try await history.usage()
        let result = try await BuiltInAutomation.evaluateManual(input: .text("unused"), workflow: workflow, history: history)
        #expect(result.value == expected.value)
        #expect(result.originalInput == .text(text))
        #expect(result.matchedItemCount == 1)
        #expect(result.matchedConditions)
        #expect(try await history.usage() == before)
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.pastePayload(for: item.id)
        }
    }

    @Test(arguments: [false, true])
    func imagePreferenceStillUsesTextOtherwiseWithoutLoadingUnrelatedPayloads(hasImage: Bool) async throws {
        let image = try imageBytes()
        let text = "fallback text"
        var representations: [CapturedRepresentation] = [
            .init(typeIdentifier: "public.utf16-plain-text", bytes: utf16(text)),
            .init(typeIdentifier: "com.example.opaque", bytes: Data(repeating: 0x41, count: 131_073)),
        ]
        if hasImage { representations.append(.init(typeIdentifier: "public.png", bytes: image)) }
        let (history, item) = try await capture(representations)
        let workflow = historyWorkflow(steps: [
            .init(operation: .conditional, condition: .isImage,
                  thenSteps: [.init(operation: .notify)], otherwiseSteps: [.init(operation: .uppercase)]),
        ])
        try await history.authority.makeWorkflowPayloadUnavailable(item.id, index: 0, type: "com.example.opaque")
        if hasImage {
            try await history.authority.makeWorkflowPayloadUnavailable(item.id, index: 0, type: "public.utf16-plain-text")
        }
        let result = try await BuiltInAutomation.evaluateManual(input: .text("unused"), workflow: workflow, history: history)
        #expect(result.value == (hasImage ? .image(image) : .text(text.uppercased())))
        #expect(result.originalInput == (hasImage ? .image(image) : .text(text)))
        #expect(result.requestsNotification == hasImage)
        #expect(result.matchedConditions)
    }

#if DEBUG
    @Test(arguments: [false, true])
    func revisionsBetweenBrowseMetadataAndSelectedBytesKeepTheSameUnavailableFailure(beforeMetadata: Bool) async throws {
        let (history, item) = try await capture([
            .init(typeIdentifier: "public.utf8-plain-text", bytes: Data("original".utf8)),
        ])
        let workflow = historyWorkflow(steps: [.init(operation: .uppercase)])
        let revise: @Sendable () async throws -> Void = {
            _ = try await history.perform(.revise(.init(
                itemID: item.id, expected: item.contentVersion,
                intent: .replace(.init(decisions: [
                    .init(typeIdentifier: "public.utf8-plain-text", action: .replace(bytes: Data("changed".utf8))),
                ]))
            )))
            // A stale read must fail at its version check before attempting
            // even the now-unavailable selected representation's bytes.
            try await history.authority.makeWorkflowPayloadUnavailable(item.id, index: 0, type: "public.utf8-plain-text")
        }
        await #expect(throws: BuiltInAutomationFailure.historyUnavailable) {
            if beforeMetadata {
                _ = try await BuiltInAutomationHistoryDebugInstrumentation.$afterHistoryBrowse.withValue(revise) {
                    try await BuiltInAutomation.evaluateManual(input: .text(""), workflow: workflow, history: history)
                }
            } else {
                _ = try await BuiltInAutomationHistoryDebugInstrumentation.$afterInputMetadata.withValue(revise) {
                    try await BuiltInAutomation.evaluateManual(input: .text(""), workflow: workflow, history: history)
                }
            }
        }
    }

    @Test func cancellationAfterInputMetadataDoesNotOpenUnavailableSelectedBytes() async throws {
        let (history, item) = try await capture([
            .init(typeIdentifier: "public.utf8-plain-text", bytes: Data("original".utf8)),
        ])
        try await history.authority.makeWorkflowPayloadUnavailable(item.id, index: 0, type: "public.utf8-plain-text")
        let workflow = historyWorkflow(steps: [.init(operation: .uppercase)])
        let operation = Task {
            try await BuiltInAutomationHistoryDebugInstrumentation.$afterInputMetadata.withValue({
                withUnsafeCurrentTask { $0?.cancel() }
            }) {
                try await BuiltInAutomation.evaluateManual(input: .text(""), workflow: workflow, history: history)
            }
        }
        await #expect(throws: CancellationError.self) { try await operation.value }
    }
#endif

    @Test func cancelledOCRPreservesCancellationWhenTheOperationThrowsAnotherError() async throws {
        let image = try imageBytes()
        let operation = Task {
            try await BuiltInAutomation.run(.image(image), steps: [.init(operation: .recognizeText)]) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                throw WorkflowOCRFailure.failed
            }
        }
        await #expect(throws: CancellationError.self) { try await operation.value }
    }

    private func historyWorkflow(steps: [BuiltInAutomationStep]) -> BuiltInAutomationWorkflow {
        var workflow = BuiltInAutomationWorkflow(name: "History inputs", steps: steps)
        workflow.scope.source = .history
        return workflow
    }

    private func capture(_ representations: [CapturedRepresentation]) async throws -> (SQLiteHistory, HistoryItemReference) {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let receipt = try await history.perform(.capture(.init(
            representations: representations, origin: .init(sourceApplication: nil, lineageHint: nil), observedAt: Date()
        )))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return (history, item)
    }

    private func utf16(_ text: String) -> Data {
        var bytes = Data([0xFF, 0xFE])
        for unit in text.utf16 {
            bytes.append(UInt8(truncatingIfNeeded: unit))
            bytes.append(UInt8(truncatingIfNeeded: unit >> 8))
        }
        return bytes
    }

    private func imageBytes() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.setColor(.white, atX: 0, y: 0)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}

private enum WorkflowOCRFailure: Error { case failed }

private extension HistoryAuthority {
    func makeWorkflowPayloadUnavailable(_ item: HistoryItemID, index: Int, type: String) throws {
        try database.writeTransaction {
            try database.execute("""
                UPDATE representations SET inlineBytes=NULL, blobID=?
                WHERE contentID=(SELECT currentContentID FROM history_items WHERE id=?)
                  AND pasteboardItemIndex=? AND exactType=?
                """, bindings: [.text(UUID().uuidString), .text(item.rawValue.uuidString), .integer(Int64(index)), .text(type)])
            guard try database.changedRowCount == 1 else { throw HistoryFailure.persistence(.invariantViolation) }
        }
    }
}
