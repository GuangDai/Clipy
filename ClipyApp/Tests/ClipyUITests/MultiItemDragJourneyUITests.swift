import AppKit
import XCTest

/// The receiver lives in the XCTest runner process. The source is Clipy's
/// actual row and native dragging session, so no fabricated session/callback
/// can satisfy the ordered cross-process pasteboard assertions below.
final class MultiItemDragJourneyUITests: XCTestCase {
    @MainActor
    func testRealRowDragsBothItemsAndAllBytesToANativeReceiver() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let opaque = NSPasteboard.PasteboardType("com.clipy.tests.drag-opaque")
        let firstText = Data("clipy-native-drag-first\0".utf8)
        let secondText = Data("clipy-native-drag-second\0".utf8)
        let originals = [NSPasteboardItem(), NSPasteboardItem()]
        XCTAssertTrue(originals[0].setData(firstText, forType: .string))
        XCTAssertTrue(originals[0].setData(Data([0, 255, 1]), forType: opaque))
        XCTAssertTrue(originals[1].setData(secondText, forType: .string))
        XCTAssertTrue(originals[1].setData(Data([255, 0, 2]), forType: opaque))
        NSPasteboard.general.clearContents()
        defer { NSPasteboard.general.clearContents() }
        XCTAssertTrue(NSPasteboard.general.writeObjects(originals))

        let traceURL = directory.appendingPathComponent("native-drag.trace")
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_DRAG_TRACE_PATH"] = traceURL.path
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("history.store").path
        app.launch()
        defer { app.terminate() }
        let row = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "clipy.history.row."
        )).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "The real multi-item row must be captured before dragging")
        XCTAssertTrue(row.isHittable)

        let screen = try XCTUnwrap(NSScreen.screens.first)
        let receiver = NativeClipboardDropView(frame: NSRect(x: 0, y: 0, width: 260, height: 140))
        let target = NSPanel(contentRect: NSRect(
            x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 20,
            width: 260, height: 140
        ), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        target.isReleasedWhenClosed = false
        target.level = .floating
        target.contentView = receiver
        target.orderFrontRegardless()
        defer { target.close() }
        receiver.registerForDraggedTypes([.string, opaque])
        let destination = target.convertPoint(toScreen: NSPoint(x: 130, y: 70))
        // Hover can activate the source window and open its preview pane.
        // Resolve both coordinates after that layout, not from the old row.
        let beforeHover = row.frame
        row.hover()
        target.orderFrontRegardless()
        target.displayIfNeeded()
        XCTAssertTrue(target.isVisible)
        XCTAssertEqual(NSWindow.windowNumber(at: destination, belowWindowWithWindowNumber: 0), target.windowNumber,
                       "The receiver must own the physical destination point before synthesizing a drag")
        let afterHover = row.frame
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(
            dx: destination.x - row.frame.midX,
            dy: screen.frame.maxY - destination.y - row.frame.midY
        ))
        start.press(forDuration: 0.3, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        let delivered = NSPredicate { _, _ in MainActor.assumeIsolated { receiver.received != nil } }
        let delivery = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: delivered, object: nil)], timeout: 10)
        let trace = (try? String(contentsOf: traceURL, encoding: .utf8)) ?? "no source trace"
        let diagnostics = """
            row before hover: \(beforeHover), after hover: \(afterHover)
            receiver visible: \(target.isVisible), frame: \(target.frame), destination: \(destination)
            receiver entered: \(receiver.enteredCount), prepared: \(receiver.preparedCount), performed: \(receiver.performedCount)
            \(trace)
            """
        let attachment = XCTAttachment(string: diagnostics)
        attachment.name = "Native drag stages"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Pin the previously missing row→list hand-off separately from the
        // end-to-end delivery assertion; the receiver/session are unchanged.
        XCTAssertTrue(trace.contains("hover-enter"), diagnostics)
        XCTAssertTrue(trace.contains("pressed-admitted"), diagnostics)
        XCTAssertEqual(delivery, .completed, diagnostics)
        let items = try XCTUnwrap(receiver.received)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0][NSPasteboard.PasteboardType.string.rawValue], firstText)
        XCTAssertEqual(items[1][NSPasteboard.PasteboardType.string.rawValue], secondText)
        XCTAssertEqual(items[0][opaque.rawValue], Data([0, 255, 1]))
        XCTAssertEqual(items[1][opaque.rawValue], Data([255, 0, 2]))
    }
}

@MainActor
private final class NativeClipboardDropView: NSView {
    var received: [[String: Data]]?
    var enteredCount = 0
    var preparedCount = 0
    var performedCount = 0

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        enteredCount += 1
        return .copy
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        preparedCount += 1
        return true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        performedCount += 1
        guard let items = sender.draggingPasteboard.pasteboardItems else { return false }
        received = items.map { item in
            var representations: [String: Data] = [:]
            for type in item.types {
                if let bytes = item.data(forType: type) { representations[type.rawValue] = bytes }
            }
            return representations
        }
        return true
    }
}
