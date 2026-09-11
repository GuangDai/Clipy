import AppKit
import SwiftUI
@testable import ClipyApp
import Testing

@MainActor
struct PreviewTextLayoutTests {
    @Test func longTextLayoutFitsTwoFramesAfterWarmup() {
        // Exercise the same view as both preview surfaces, including native
        // hosting, constrained-width layout and drawing. Renderer-only timing
        // misses the synchronous work that prevents selection from changing.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 480),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: PreviewTextBody(text: "Warm up", maximumHeight: 480))
        host.sizingOptions = []
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        for source in [String(repeating: "x", count: 50_000),
                       String(repeating: "长文本预览测试。\n", count: 5_000)] {
            let start = ContinuousClock.now
            host.rootView = PreviewTextBody(text: source, maximumHeight: 480)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let elapsed = start.duration(to: .now)
            print("Preview initial layout: \(elapsed), UTF-16 units: \(source.utf16.count)")
            #expect(elapsed < .milliseconds(34))
        }
    }
}
