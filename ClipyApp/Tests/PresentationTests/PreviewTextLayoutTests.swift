import AppKit
import ContentPreview
import SwiftUI
@testable import ClipyApp
import Testing

@MainActor
struct PreviewTextLayoutTests {
    @Test func longTextLayoutFitsTwoFramesAfterWarmup() async throws {
        // Exercise the same view as both preview surfaces, including native
        // hosting, constrained-width layout and drawing. Renderer-only timing
        // misses the synchronous work that prevents selection from changing.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 480),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: PreviewTextBody(segments: ["Warm up"], maximumHeight: 480))
        host.sizingOptions = []
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        for source in [String(repeating: "x", count: 50_000),
                       String(repeating: "长文本预览测试。\n", count: 5_000),
                       String(repeating: "中文快速预览。\n", count: 5_000),
                       String(repeating: "\n", count: 20_000),
                       "Prefix\ne" + String(repeating: "\u{301}", count: 20_000)] {
            let outcome = await ContentPreview().renderHistoryPane([
                PreviewRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(source.utf8))
            ])
            guard case .content(.text(let text)) = outcome else {
                Issue.record("Expected text fixture")
                return
            }
            let start = ContinuousClock.now
            host.rootView = PreviewTextBody(segments: text.displaySegments, maximumHeight: 480)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let elapsed = start.duration(to: .now)
            print("Preview initial layout: \(elapsed), UTF-16 units: \(source.utf16.count)")
            #expect(elapsed < .milliseconds(34))
            // Whole-process figures are observations, not per-view memory
            // accounting: the hosted runner also owns other test fixtures.
            let memory = try await ProcessMemoryReader().read()
            print("Preview process memory: resident \(memory.residentBytes), peak \(memory.peakResidentBytes), footprint \(memory.footprintBytes)")
        }
    }
}
