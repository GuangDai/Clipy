import AppKit
import ContentPreview
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
@testable import ClipyApp
import Testing

@MainActor
@Suite(.serialized)
struct PreviewNativeArtifactLayoutTests {
    @Test func rasterDisplayFitsTwoFramesAfterBaselineWarmup() async throws {
        let window = makeWindow()
        defer { window.close() }
        let baseline = PreviewRaster(
            pixels: Data([0, 0, 0, 255]), width: 1, height: 1, rowBytes: 4
        )
        let baselineImage = try #require(PreviewRasterDisplay.image(
            baseline, scale: 1, label: Text("Warm up")
        ))
        let host = NSHostingView(rootView: baselineImage.resizable().scaledToFit().id(-1))
        host.sizingOptions = []
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        // Source creation and background rendering are separate from the
        // MainActor display cost. Do not warm the measured 640-point artifact.
        let bytes = try imageData()
        let preparationStart = ContinuousClock.now
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.png", bytes: bytes)
        ])
        print("Raster preview preparation: \(preparationStart.duration(to: .now)), input bytes: \(bytes.count)")
        guard case .content(.raster(let raster)) = outcome else {
            Issue.record("Expected the PNG fixture to produce a raster")
            return
        }
        #expect(raster.width == 640)
        #expect(raster.height == 640)
        #expect(raster.rowBytes == 640 * 4)
        #expect(raster.pixels.count == 640 * 640 * 4)

        let start = ContinuousClock.now
        // Use the actual display edge shared by the pane, Details and rows;
        // include its provider/CGImage construction in first display timing.
        guard let image = PreviewRasterDisplay.image(
            raster, scale: 1, label: Text("640 by 640 image")
        ) else {
            Issue.record("The renderer's raster must be displayable")
            return
        }
        host.rootView = image.resizable().scaledToFit().id(0)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let elapsed = start.duration(to: .now)
        print("Raster preview initial layout/draw: \(elapsed), pixels: 640 × 640")
        #expect(elapsed < .milliseconds(34))
    }

    @Test func collapsedAndFullReferenceContentFitTwoFramesAfterBaselineWarmup() async throws {
        let baselineOutcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.url", bytes: Data("https://example.invalid/".utf8))
        ])
        guard case .content(.reference(let baseline)) = baselineOutcome else {
            Issue.record("Expected the baseline URL to resolve")
            return
        }
        let window = makeWindow()
        defer { window.close() }
        let host = NSHostingView(rootView: ReferencePreviewView(reference: baseline, maximumHeight: 480).id(-1))
        host.sizingOptions = []
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        let fullWindow = makeWindow()
        defer { fullWindow.close() }
        // Keep both measured hosts visible so one cannot occlude the other.
        fullWindow.setFrameOrigin(NSPoint(x: 360, y: 0))
        let fullHost = NSHostingView(rootView: fullReferenceViewport(baseline).id(-1))
        fullHost.sizingOptions = []
        fullWindow.contentView = fullHost
        fullWindow.orderFront(nil)
        fullHost.layoutSubtreeIfNeeded()
        fullHost.displayIfNeeded()

        for (index, fixture) in referenceFixtures.enumerated() {
            let bytes = Data(fixture.address.utf8)
            // Exact references admit at most 16 KiB. Percent-encoded marks
            // keep URLs valid and become combining scalars in the file path.
            #expect(bytes.count <= 16 * 1_024)
            #expect(bytes.count >= 16 * 1_024 - 6)
            let preparationStart = ContinuousClock.now
            let outcome = await ContentPreview().renderHistoryPane([
                PreviewRepresentation(typeIdentifier: fixture.type, bytes: bytes)
            ])
            print("Reference preview preparation: \(preparationStart.duration(to: .now)), fixture: \(fixture.name), input bytes: \(bytes.count)")
            guard case .content(.reference(let reference)) = outcome else {
                Issue.record("Expected the bounded \(fixture.name) reference to resolve")
                return
            }
            #expect(Data(reference.address.utf8) == bytes)
            #expect(reference.kind == (fixture.type == "public.file-url" ? .file : .url))
            if fixture.name == "file-combining" {
                #expect(reference.filePath?.unicodeScalars.contains(where: { $0.value == 0x301 }) == true)
            }

            let start = ContinuousClock.now
            // Replacing identity matches selecting another item. Exercise the
            // actual product view, including filename, fields and disclosure.
            host.rootView = ReferencePreviewView(reference: reference, maximumHeight: 480).id(index)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let elapsed = start.duration(to: .now)
            print("Collapsed reference initial layout/draw: \(elapsed), fixture: \(fixture.name)")
            #expect(elapsed < .milliseconds(34))

            // Mount the actual disclosure content in a standard viewport.
            // SwiftUI's hosted in-process AX tree does not expose its toggle;
            // the file-reference XCUI journey separately proves the real
            // DisclosureGroup mounts these exact path/address elements.
            let expansionStart = ContinuousClock.now
            fullHost.rootView = fullReferenceViewport(reference).id(index)
            fullHost.layoutSubtreeIfNeeded()
            fullHost.displayIfNeeded()
            let expansionElapsed = expansionStart.duration(to: .now)
            print("Full reference content initial layout/draw: \(expansionElapsed), fixture: \(fixture.name)")
            #expect(expansionElapsed < .milliseconds(34))
        }
    }

    @Test func fullReferenceWrapsAndCopiesCompleteNativeSelections() async throws {
        let address = boundedAddress(
            prefix: "file:///clipy-preview-uncreated/e%CC%81/", token: "x"
        )
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.file-url", bytes: Data(address.utf8))
        ])
        guard case .content(.reference(let reference)) = outcome else {
            Issue.record("Expected the complete file reference")
            return
        }
        let path = try #require(reference.filePath)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: fullReferenceViewport(reference))
        host.sizingOptions = []
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        let fields = nativeReferenceFields(in: host)
        #expect(fields.count == 2)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for (identifier, value) in [
            ("clipy.preview.reference.full.path", path),
            ("clipy.preview.reference.full.address", address)
        ] {
            let field = try #require(fields.first { $0.accessibilityIdentifier() == identifier })
            #expect(Data(field.stringValue.utf8) == Data(value.utf8))
            #expect(field.isSelectable)
            #expect(!field.isEditable)
            #expect(field.frame.width <= 340)
            // Both 16 KiB spellings occupy many wrapped lines. A short or
            // clipped label cannot satisfy the content-height assertion.
            #expect(field.frame.height > 480)
            let originalHeight = field.frame.height
            window.setContentSize(NSSize(width: 220, height: 480))
            host.layoutSubtreeIfNeeded()
            #expect(field.frame.height > originalHeight)

            // Use AppKit's actual field editor and copy serialization, on a
            // private pasteboard so this proof cannot disturb capture tests.
            field.selectText(nil)
            let editor = try #require(field.currentEditor() as? NSTextView)
            #expect(editor.selectedRange() == NSRange(location: 0, length: (value as NSString).length))
            pasteboard.clearContents()
            let copiedEntireValue = editor.writeSelection(to: pasteboard, types: [.string])
            #expect(copiedEntireValue)
            #expect(pasteboard.string(forType: .string).map { Data($0.utf8) } == Data(value.utf8))

            // A contiguous range spanning many visual lines copies unchanged,
            // without inserting the line breaks used only for presentation.
            let range = NSRange(location: 2, length: (value as NSString).length - 4)
            editor.setSelectedRange(range)
            pasteboard.clearContents()
            let copiedRange = editor.writeSelection(to: pasteboard, types: [.string])
            #expect(copiedRange)
            #expect(pasteboard.string(forType: .string).map { Data($0.utf8) }
                == Data((value as NSString).substring(with: range).utf8))
            window.endEditing(for: nil)
            window.setContentSize(NSSize(width: 340, height: 480))
            host.layoutSubtreeIfNeeded()
        }
    }

    private func nativeReferenceFields(in view: NSView) -> [NSTextField] {
        let own = (view as? NSTextField).map { [$0] } ?? []
        return own + view.subviews.flatMap { nativeReferenceFields(in: $0) }
    }

    private func fullReferenceViewport(_ reference: PreviewReference) -> some View {
        ScrollView(.vertical) {
            FullReferencePreviewContent(reference: reference)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
                .padding(12)
        }
    }

    private var referenceFixtures: [(name: String, type: String, address: String)] {
        [
            ("url-ascii", "public.url", boundedAddress(prefix: "https://example.invalid/", token: "x")),
            ("url-combining", "public.url", boundedAddress(prefix: "https://example.invalid/e", token: "%CC%81")),
            ("file-ascii", "public.file-url", boundedAddress(prefix: "file:///clipy-preview-uncreated/", token: "x")),
            ("file-combining", "public.file-url", boundedAddress(prefix: "file:///clipy-preview-uncreated/e", token: "%CC%81"))
        ]
    }

    private func boundedAddress(prefix: String, token: String) -> String {
        prefix + String(repeating: token, count: (16 * 1_024 - prefix.utf8.count) / token.utf8.count)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 480),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func imageData() throws -> Data {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 640, height: 640, bitsPerComponent: 8,
            bytesPerRow: 640 * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 640))
        context.setFillColor(red: 0.8, green: 0.4, blue: 0.2, alpha: 0.5)
        context.fillEllipse(in: CGRect(x: 80, y: 80, width: 480, height: 480))
        let image = try #require(context.makeImage())
        let data = try #require(CFDataCreateMutable(kCFAllocatorDefault, 0))
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
