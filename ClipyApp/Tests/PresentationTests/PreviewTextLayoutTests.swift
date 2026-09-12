import AppKit
import ContentPreview
import SwiftUI
@testable import ClipyApp
import Testing

@MainActor
struct PreviewTextLayoutTests {
    @Test func nativeSegmentKeepsSelectableBytesAndRemeasuresWrapping() throws {
        let source = String(repeating: "Café e\u{301} selectable words 中文。 ", count: 12)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: segmentViewport(source))
        host.sizingOptions = []
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()

        let field = try #require(textField(in: host))
        #expect(field.stringValue.utf8.elementsEqual(source.utf8))
        #expect(field.isSelectable)
        #expect(!field.isEditable)
        #expect(field.maximumNumberOfLines == 0)
        let originalHeight = field.frame.height

        window.setContentSize(NSSize(width: 180, height: 480))
        host.layoutSubtreeIfNeeded()
        #expect(field.frame.height > originalHeight)
        let cell = try #require(field.cell)
        let completeSize = cell.cellSize(forBounds: NSRect(
            x: 0, y: 0, width: field.bounds.width, height: .greatestFiniteMagnitude
        ))
        #expect(field.bounds.height >= completeSize.height)
        #expect(field.stringValue.utf8.elementsEqual(source.utf8))

        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(editor.selectedRange() == NSRange(location: 0, length: (source as NSString).length))
        let copiedEntireValue = editor.writeSelection(to: pasteboard, types: editor.writablePasteboardTypes)
        #expect(copiedEntireValue)
        #expect(pasteboard.string(forType: .string).map { Data($0.utf8) } == Data(source.utf8))
        // Copy through visual wraps without changing the composed/decomposed
        // spellings or introducing presentation-only line breaks.
        let range = NSRange(location: 0, length: (source as NSString).length - 2)
        editor.setSelectedRange(range)
        pasteboard.clearContents()
        let copiedRange = editor.writeSelection(to: pasteboard, types: editor.writablePasteboardTypes)
        #expect(copiedRange)
        #expect(pasteboard.string(forType: .string).map { Data($0.utf8) }
            == Data((source as NSString).substring(with: range).utf8))
        window.endEditing(for: nil)

        host.rootView = segmentViewport(source, direction: .rightToLeft)
        host.layoutSubtreeIfNeeded()
        let rightToLeftField = try #require(textField(in: host))
        #expect(rightToLeftField.alignment == .right)
        host.rootView = segmentViewport("Replacement")
        host.layoutSubtreeIfNeeded()
        let replacement = try #require(textField(in: host))
        #expect(replacement.stringValue == "Replacement")
        #expect(replacement.alignment == .left)
        #expect(replacement.frame.height < originalHeight)

        host.rootView = segmentViewport(String(repeating: "\u{301}", count: 64))
        host.layoutSubtreeIfNeeded()
        let combiningField = try #require(textField(in: host))
        #expect(combiningField.frame.height > 0)
    }

    private func segmentViewport(_ source: String, direction: LayoutDirection = .leftToRight) -> some View {
        PreviewTextBody(segments: [source[...]], maximumHeight: 480)
            .environment(\.layoutDirection, direction)
    }

    private func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField,
           field.accessibilityIdentifier() == "clipy.preview.text" { return field }
        for child in view.subviews {
            if let field = textField(in: child) { return field }
        }
        return nil
    }

    @Test func longTextLayoutFitsTwoFramesAfterWarmup() async throws {
        // Exercise the same view as both preview surfaces, including native
        // hosting, constrained-width layout and drawing. Renderer-only timing
        // misses the synchronous work that prevents selection from changing.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 480),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: PreviewTextBody(segments: ["Warm up"], maximumHeight: 480).id(-1))
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
            var preview = PreviewTextBody(segments: text.displaySegments, maximumHeight: 480)
            var materialized: Set<Int> = []
            var materializationCalls = 0
            preview.onSegmentMaterialized = {
                materialized.insert($0)
                materializationCalls += 1
            }
            #else
            let preview = PreviewTextBody(segments: text.displaySegments, maximumHeight: 480)
            #endif
            let start = ContinuousClock.now
            // The actual floating pane replaces its view identity on item
            // changes. Include that construction and retirement work here.
            host.rootView = preview.id(index)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let elapsed = start.duration(to: .now)
            print("Preview initial layout: \(elapsed), UTF-16 units: \(source.utf16.count)")
            #if DEBUG
            print("[DEBUG-preview-layout] materialized=\(materialized.count) total=\(text.displaySegments.count) calls=\(materializationCalls)")
            #endif
            #expect(elapsed < .milliseconds(34))
            // Whole-process figures are observations, not per-view memory
            // accounting: the hosted runner also owns other test fixtures.
            let memory = try await ProcessMemoryReader().read()
            print("Preview process memory: resident \(memory.residentBytes), peak \(memory.peakResidentBytes), footprint \(memory.footprintBytes)")
        }
    }
}
