import AppKit
import Foundation
@testable import ClipyApp
import Testing

@MainActor
struct BuiltInAutomationClipboardTests {
    @Test func imagePreferenceStillLetsTextClipboardTakeOtherwise() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        #expect(pasteboard.setString("Mixed text", forType: .string))
        let steps: [BuiltInAutomationStep] = [
            .init(operation: .conditional, condition: .isImage,
                  thenSteps: [.init(operation: .recognizeText)], otherwiseSteps: [.init(operation: .uppercase)])
        ]
        let input = try BuiltInAutomationClipboard.read(image: BuiltInAutomation.prefersImage(steps), from: pasteboard)
        let output = try await BuiltInAutomation.run(input, steps: steps)
        #expect(output.originalInput == .text("Mixed text"))
        #expect(output.value.text == "MIXED TEXT")
        #expect(output.matchedConditions)
    }

    @Test func textPreferenceStillLetsImageClipboardTakeOtherwise() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let bytes = try imageBytes()
        #expect(pasteboard.setData(bytes, forType: .png))
        let steps: [BuiltInAutomationStep] = [
            .init(operation: .conditional, condition: .isText,
                  thenSteps: [.init(operation: .uppercase)], otherwiseSteps: [.init(operation: .notify)])
        ]
        let input = try BuiltInAutomationClipboard.read(image: BuiltInAutomation.prefersImage(steps), from: pasteboard)
        let output = try await BuiltInAutomation.run(input, steps: steps)
        #expect(output.originalInput == .image(bytes))
        #expect(output.value == .image(bytes))
        #expect(output.matchedConditions && output.requestsNotification)
        #expect(pasteboard.data(forType: .png) == bytes)
    }

    @Test func preferredPresentCorruptImageDoesNotFallBackToText() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        #expect(item.setData(Data("not an image".utf8), forType: .png))
        #expect(item.setString("valid text", forType: .string))
        #expect(pasteboard.writeObjects([item]))
        #expect(throws: BuiltInAutomationFailure.invalidImage) {
            try BuiltInAutomationClipboard.read(image: true, from: pasteboard)
        }
        #expect(try BuiltInAutomationClipboard.read(image: false, from: pasteboard) == .text("valid text"))
    }

    @Test func preferredOversizedTextDoesNotFallBackToValidImage() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        #expect(item.setString(String(repeating: "x", count: BuiltInAutomation.maximumBytes + 1), forType: .string))
        #expect(item.setData(try imageBytes(), forType: .png))
        #expect(pasteboard.writeObjects([item]))
        #expect(throws: BuiltInAutomationFailure.textTooLarge) {
            try BuiltInAutomationClipboard.read(image: false, from: pasteboard)
        }
    }

    private func imageBytes() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.setColor(.white, atX: 0, y: 0)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
