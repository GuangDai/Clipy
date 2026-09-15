import AppKit
import ContentPreview
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import SwiftUI
@testable import ClipyApp
import Testing

@MainActor
@Suite(.serialized)
struct PreviewNativeArtifactLayoutTests {
    @Test func rasterDisplayUsesThePreparedArtifact() async throws {
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

        let cpuStart = try threadCPUTime()
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
        let cpuElapsed = try threadCPUTime() - cpuStart
        print("Raster preview initial layout/draw: wall: \(elapsed), main-thread CPU: \(cpuElapsed), pixels: 640 × 640")
    }

    @Test func collapsedAndFullReferenceContentDisplayPreparedReferences() async throws {
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

            let cpuStart = try threadCPUTime()
            let start = ContinuousClock.now
            // Replacing identity matches selecting another item. Exercise the
            // actual product view, including filename, fields and disclosure.
            host.rootView = ReferencePreviewView(reference: reference, maximumHeight: 480).id(index)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let elapsed = start.duration(to: .now)
            let cpuElapsed = try threadCPUTime() - cpuStart
            print("Collapsed reference initial layout/draw: wall: \(elapsed), main-thread CPU: \(cpuElapsed), fixture: \(fixture.name)")

            // Mount the actual disclosure content in a standard viewport.
            // SwiftUI's hosted in-process AX tree does not expose its toggle;
            // the file-reference XCUI journey separately proves the real
            // DisclosureGroup mounts these exact path/address elements.
            let expansionCPUStart = try threadCPUTime()
            let expansionStart = ContinuousClock.now
            fullHost.rootView = fullReferenceViewport(reference).id(index)
            fullHost.layoutSubtreeIfNeeded()
            fullHost.displayIfNeeded()
            let expansionElapsed = expansionStart.duration(to: .now)
            let expansionCPUElapsed = try threadCPUTime() - expansionCPUStart
            print("Full reference content initial layout/draw: wall: \(expansionElapsed), main-thread CPU: \(expansionCPUElapsed), fixture: \(fixture.name)")
        }
    }

    @Test func fullReferenceWrapsWithWidthAndReplacesThePreviousLongValue() async throws {
        let address = boundedAddress(prefix: "file:///clipy-preview-uncreated/e%CC%81/", token: "x")
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.file-url", bytes: Data(address.utf8))
        ])
        guard case .content(.reference(let reference)) = outcome else {
            Issue.record("Expected the complete file reference")
            return
        }
        #expect(Data(reference.address.utf8) == Data(address.utf8))
        let shortAddress = "file:///clipy-preview-uncreated/short"
        let shortOutcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.file-url", bytes: Data(shortAddress.utf8))
        ])
        guard case .content(.reference(let shortReference)) = shortOutcome else {
            Issue.record("Expected the replacement file reference")
            return
        }
        let measured = PreviewReferenceSizeCapture()
        let window = makeWindow()
        defer { window.close() }
        let host = NSHostingView(rootView: fullReferenceViewport(reference, capture: measured))
        host.sizingOptions = []
        window.contentView = host
        window.orderFront(nil)
        let settled = await waitFor {
            host.layoutSubtreeIfNeeded()
            return measured.size.height > 480 && measured.size.width > 0
        }
        try #require(settled)
        let originalHeight = measured.size.height
        window.setContentSize(NSSize(width: 220, height: 480))
        let wrapped = await waitFor {
            host.layoutSubtreeIfNeeded()
            return measured.size.width <= 220 && measured.size.height > originalHeight
        }
        #expect(wrapped)

        host.rootView = fullReferenceViewport(shortReference, capture: measured)
        let replaced = await waitFor {
            host.layoutSubtreeIfNeeded()
            return measured.size.height > 0 && measured.size.height < 480
        }
        #expect(replaced)
    }

    @Test func collapsedReferencesRemainCompactWithCompleteSourceSpellings() async throws {
        let window = makeWindow()
        defer { window.close() }
        for fixture in [referenceFixtures[0], referenceFixtures[2], referenceFixtures[3]] {
            let outcome = await ContentPreview().renderHistoryPane([
                PreviewRepresentation(typeIdentifier: fixture.type, bytes: Data(fixture.address.utf8))
            ])
            guard case .content(.reference(let reference)) = outcome else {
                Issue.record("Expected the bounded \(fixture.name) reference")
                return
            }
            #expect(reference.address.utf8.elementsEqual(fixture.address.utf8))
            let measured = PreviewReferenceSizeCapture()
            let host = NSHostingView(rootView:
                ReferencePreviewView(reference: reference, maximumHeight: 480)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { measured.size = $0 }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            )
            host.sizingOptions = []
            window.contentView = host
            window.orderFront(nil)
            for width in [CGFloat(340), CGFloat(180)] {
                window.setContentSize(NSSize(width: width, height: 480))
                let compact = await waitFor {
                    host.layoutSubtreeIfNeeded()
                    return measured.size.width == width
                        && measured.size.height > 0 && measured.size.height < 480
                }
                #expect(compact, "A 16 KiB reference must fit its summary, not lay out every line")
            }
        }
    }

    private func waitFor(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Adjacent samples around the unchanged synchronous wall-time interval.
    /// This suite runs that interval on the main thread without an await.
    /// Darwin's thread clock includes only this thread's user/kernel CPU;
    /// it excludes both scheduling delays and actual blocking waits. CPU is
    /// diagnostic only: shared-runner wall time is not a correctness condition.
    private func threadCPUTime() throws -> Duration {
        var value = timespec()
        let result = clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value)
        try #require(result == 0, "The native thread CPU clock must be available")
        return .seconds(value.tv_sec) + .nanoseconds(value.tv_nsec)
    }

    private func fullReferenceViewport(
        _ reference: PreviewReference, capture: PreviewReferenceSizeCapture? = nil
    ) -> some View {
        ScrollView(.vertical) {
            FullReferencePreviewContent(reference: reference)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
                .padding(12)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { capture?.size = $0 }
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

@MainActor
private final class PreviewReferenceSizeCapture {
    var size: CGSize = .zero
}
