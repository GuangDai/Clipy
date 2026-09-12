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

    @Test func initialAndExpandedReferencesFitTwoFramesAfterBaselineWarmup() async throws {
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

            // Drive the product's own DisclosureGroup through its public
            // in-process accessibility action. No test state binding or
            // replacement implementation can bypass the actual expansion.
            let collapsedElements = accessibilityElements(in: host)
            let group = try #require(collapsedElements.first {
                $0.accessibilityIdentifier() == "clipy.preview.reference.full"
            })
            let disclosure = try #require(accessibilityElements(in: group).first {
                $0.accessibilityRole() == .disclosureTriangle
            })
            #expect(!isExpanded(disclosure))
            let initialAddressCount = exactTextCount(reference.address, in: collapsedElements)
            let initialPathCount = reference.filePath.map { exactTextCount($0, in: collapsedElements) }

            let expansionStart = ContinuousClock.now
            let pressed = disclosure.accessibilityPerformPress()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let expansionElapsed = expansionStart.duration(to: .now)
            print("Full reference expansion/layout/draw: \(expansionElapsed), fixture: \(fixture.name)")
            #expect(pressed)
            #expect(expansionElapsed < .milliseconds(34))

            // A successful AX press means only that the action was accepted.
            // Also require expansion and a newly exposed exact full spelling;
            // the collapsed, two-line field already exposes one text value.
            let expandedElements = accessibilityElements(in: host)
            let expandedDisclosure = try #require(expandedElements.first {
                $0.accessibilityRole() == .disclosureTriangle
            })
            #expect(isExpanded(expandedDisclosure))
            #expect(exactTextCount(reference.address, in: expandedElements) > initialAddressCount)
            if let path = reference.filePath, let initialPathCount {
                #expect(exactTextCount(path, in: expandedElements) > initialPathCount)
            }
        }
    }

    private func accessibilityElements(in root: any NSAccessibilityProtocol) -> [any NSAccessibilityProtocol] {
        var elements: [any NSAccessibilityProtocol] = [root]
        var index = 0
        while index < elements.count && index < 4_096 {
            let children = elements[index].accessibilityChildren() ?? []
            elements.append(contentsOf: children.compactMap { $0 as? any NSAccessibilityProtocol })
            index += 1
        }
        return elements
    }

    private func isExpanded(_ element: any NSAccessibilityProtocol) -> Bool {
        element.isAccessibilityExpanded() || (element.accessibilityValue() as? NSNumber)?.boolValue == true
    }

    private func exactTextCount(_ text: String, in elements: [any NSAccessibilityProtocol]) -> Int {
        let bytes = Data(text.utf8)
        return elements.filter { element in
            let value = element.accessibilityValue() as? String
            return value.map { Data($0.utf8) == bytes } == true
                || element.accessibilityLabel().map { Data($0.utf8) == bytes } == true
        }.count
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
