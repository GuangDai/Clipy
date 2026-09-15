import AppKit
import ContentPreview
import Darwin
import SwiftUI
@testable import ClipyApp
import Testing

@MainActor
@Suite(.serialized)
struct PreviewTextLayoutTests {
    @Test func swiftUITextWrapsAtTheAvailableWidthAndUpdatesWithoutAFieldEditor() async throws {
        let source = String(repeating: "Café e\u{301} selectable words 中文。 ", count: 8)
        let measured = PreviewTextSizeCapture()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: measuredViewport([source[...]], capture: measured))
        host.sizingOptions = []
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        let settled = await waitFor {
            host.layoutSubtreeIfNeeded()
            return measured.size.height > 24 && measured.size.height < 480
        }
        try #require(settled)
        let originalHeight = measured.size.height

        window.setContentSize(NSSize(width: 180, height: 480))
        let wrapped = await waitFor {
            host.layoutSubtreeIfNeeded()
            return measured.size.width <= 180 && measured.size.height > originalHeight
        }
        #expect(wrapped)
        let narrowHeight = measured.size.height
        host.rootView = measuredViewport([source[...]], direction: .rightToLeft, capture: measured)
        host.layoutSubtreeIfNeeded()
        // Leading alignment follows the environment; changing writing
        // direction cannot substitute a different font or line spacing.
        #expect(abs(measured.size.height - narrowHeight) <= 1)

        host.rootView = measuredViewport(["Replacement"], capture: measured)
        let replaced = await waitFor {
            host.layoutSubtreeIfNeeded()
            return measured.size.height < originalHeight
        }
        #expect(replaced)
        #expect(measured.size.height > 0)
    }

    @Test func shortGroupsKeepIndependentCombiningSegmentsAndFiniteLayout() async throws {
        let values = ["", "Café e\u{301}", "e" + String(repeating: "\u{301}", count: 63),
                      String(repeating: "\u{301}", count: 64), String(repeating: "words ", count: 10),
                      "中文", "RTL العربية", "last"]
        let segments = values.map { $0[...] }
        let measured = PreviewTextSizeCapture()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: measuredViewport(segments, capture: measured))
        host.sizingOptions = []
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        let settled = await waitFor {
            host.layoutSubtreeIfNeeded()
            return measured.size.height > 24 && measured.size.height < 480
        }
        try #require(settled)
        let originalHeight = measured.size.height
        window.setContentSize(NSSize(width: 180, height: 480))
        let wrapped = await waitFor {
            host.layoutSubtreeIfNeeded()
            return measured.size.width <= 180 && measured.size.height > originalHeight
        }
        #expect(wrapped)
        #expect(measured.size.height.isFinite)
        host.rootView = measuredViewport(Array(segments.prefix(2)), capture: measured)
        let reduced = await waitFor {
            host.layoutSubtreeIfNeeded()
            return measured.size.height < originalHeight
        }
        #expect(reduced)
        #expect(measured.size.height > 0)
    }

    private func measuredViewport(
        _ segments: [Substring], direction: LayoutDirection = .leftToRight,
        capture: PreviewTextSizeCapture
    ) -> some View {
        PreviewTextBody(segments: segments, groups: [segments.indices], maximumHeight: 480)
            .environment(\.layoutDirection, direction)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { capture.size = $0 }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func waitFor(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func longTextLayoutFitsTwoFramesAfterWarmup() async throws {
        // Exercise the same view as both preview surfaces, including native
        // hosting, constrained-width layout and drawing. Renderer-only timing
        // misses the synchronous work that prevents selection from changing.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 480),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: PreviewTextBody(segments: ["Warm up"], groups: [0..<1], maximumHeight: 480).id(-1))
        host.sizingOptions = []
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        let sources = [String(repeating: "x", count: 50_000),
                       String(repeating: "长文本预览测试。\n", count: 5_000),
                       String(repeating: "中文快速预览。\n", count: 5_000),
                       String(repeating: "\n", count: 20_000),
                       "Prefix\ne" + String(repeating: "\u{301}", count: 20_000)]
        for (index, source) in sources.enumerated() {
            let preparationStart = ContinuousClock.now
            let outcome = await ContentPreview().renderHistoryPane([
                PreviewRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(source.utf8))
            ])
            print("Preview preparation: \(preparationStart.duration(to: .now)), UTF-16 units: \(source.utf16.count)")
            guard case .content(.text(let text)) = outcome else {
                Issue.record("Expected text fixture")
                return
            }
            #if DEBUG
            var preview = PreviewTextBody(segments: text.displaySegments, groups: text.displaySegmentGroups,
                                          maximumHeight: 480)
            var materialized: Set<Int> = []
            var materializationCalls = 0
            var materializedGroups: Set<Int> = []
            preview.onSegmentMaterialized = {
                materialized.insert($0)
                materializationCalls += 1
            }
            preview.onGroupMaterialized = { materializedGroups.insert($0) }
            #else
            let preview = PreviewTextBody(segments: text.displaySegments, groups: text.displaySegmentGroups,
                                          maximumHeight: 480)
            #endif
            let cpuStart = try threadCPUTime()
            let start = ContinuousClock.now
            // The actual floating pane replaces its view identity on item
            // changes. Include that construction and retirement work here.
            host.rootView = preview.id(index)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let elapsed = start.duration(to: .now)
            let cpuElapsed = try threadCPUTime() - cpuStart
            print("Preview initial layout: wall: \(elapsed), main-thread CPU: \(cpuElapsed), UTF-16 units: \(source.utf16.count)")
            #if DEBUG
            print("[DEBUG-preview-layout] materialized=\(materialized.count) total=\(text.displaySegments.count) calls=\(materializationCalls) lazyGroups=\(materializedGroups.count) totalGroups=\(text.displaySegmentGroups.count)")
            #endif
            #expect(elapsed < .milliseconds(34))
            // Whole-process figures are observations, not per-view memory
            // accounting: the hosted runner also owns other test fixtures.
            let memory = try await ProcessMemoryReader().read()
            print("Preview process memory: resident \(memory.residentBytes), peak \(memory.peakResidentBytes), footprint \(memory.footprintBytes)")
        }
    }

    private func threadCPUTime() throws -> Duration {
        var value = timespec()
        try #require(clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value) == 0)
        return .seconds(value.tv_sec) + .nanoseconds(value.tv_nsec)
    }
}

@MainActor
private final class PreviewTextSizeCapture {
    var size: CGSize = .zero
}
