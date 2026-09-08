import AppKit
import CoreGraphics
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

        // Establish the source's active/hovered layout before creating the
        // cooperating receiver. A fixed corner can lie under Clipy's persisted
        // status-bar-level panel, and orderFrontRegardless only orders within
        // a level; it cannot raise a floating receiver above that panel.
        let beforeHover = row.frame
        row.hover()
        let afterHover = row.frame
        // The floating NSPanel is exposed as an AX Dialog in the running app.
        let sourceWindow = app.descendants(matching: .dialog)
            .containing(.button, identifier: row.identifier).firstMatch
        XCTAssertTrue(sourceWindow.exists)
        let sourceAXFrame = sourceWindow.frame
        let desktopTop = try XCTUnwrap(NSScreen.screens.first).frame.maxY
        let sourceFrame = NSRect(
            x: sourceAXFrame.minX, y: desktopTop - sourceAXFrame.maxY,
            width: sourceAXFrame.width, height: sourceAXFrame.height
        )
        let screen = try XCTUnwrap(NSScreen.screens.first { $0.frame.intersects(sourceFrame) })
        let targetFrame = try XCTUnwrap(Self.receiverFrame(outside: sourceFrame, on: screen.visibleFrame),
            "No separate receiver area beside the actual source window: \(sourceFrame)")
        let receiver = NativeClipboardDropView(frame: NSRect(origin: .zero, size: targetFrame.size))
        let target = NSPanel(contentRect: targetFrame,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        target.isReleasedWhenClosed = false
        // NSPanel defaults to hiding when its application deactivates. The
        // XCTest runner must remain a visible drop target while Clipy is active.
        target.hidesOnDeactivate = false
        target.level = .statusBar
        target.contentView = receiver
        receiver.registerForDraggedTypes([.string, opaque])
        target.orderFrontRegardless()
        target.displayIfNeeded()
        defer { target.close() }
        let destination = target.convertPoint(toScreen: NSPoint(x: receiver.bounds.midX, y: receiver.bounds.midY))
        XCTAssertFalse(target.frame.intersects(sourceFrame))
        // orderFront/displayIfNeeded do not establish that the buffered window
        // has reached WindowServer. Let the runner's main run loop process its
        // display work, and wait for the actual occlusion/hit-test facts.
        let receiverReady = NSPredicate { _, _ in
            MainActor.assumeIsolated {
                target.isVisible && target.occlusionState.contains(.visible)
                    && NSWindow.windowNumber(at: destination, belowWindowWithWindowNumber: 0) == target.windowNumber
            }
        }
        let readiness = XCTWaiter.wait(for: [
            XCTNSPredicateExpectation(predicate: receiverReady, object: nil)
        ], timeout: 5)
        let receiverDiagnostics = Self.receiverDiagnostics(target, destination: destination)
        let receiverAttachment = XCTAttachment(string: receiverDiagnostics)
        receiverAttachment.name = "Native drag receiver readiness"
        receiverAttachment.lifetime = .keepAlways
        add(receiverAttachment)
        XCTAssertEqual(readiness, .completed, receiverDiagnostics)
        XCTAssertEqual(NSWindow.windowNumber(at: destination, belowWindowWithWindowNumber: 0), target.windowNumber,
                       "Receiver must own the physical drop point; \(receiverDiagnostics)")
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(
            dx: destination.x - row.frame.midX,
            dy: desktopTop - destination.y - row.frame.midY
        ))
        start.press(forDuration: 0.3, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        let delivered = NSPredicate { _, _ in MainActor.assumeIsolated { receiver.received != nil } }
        let delivery = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: delivered, object: nil)], timeout: 10)
        let trace = (try? String(contentsOf: traceURL, encoding: .utf8)) ?? "no source trace"
        let diagnostics = """
            row before hover: \(beforeHover), after hover: \(afterHover), source window: \(sourceFrame)
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
    /// Report only this runner's display metadata. No window titles, clipboard
    /// content, history IDs, or other applications' window records are included.
    @MainActor
    private static func receiverDiagnostics(_ target: NSWindow, destination: NSPoint) -> String {
        let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        let processID = Int(ProcessInfo.processInfo.processIdentifier)
        let fields = [kCGWindowNumber, kCGWindowLayer, kCGWindowBounds, kCGWindowAlpha, kCGWindowIsOnscreen]
            .map { $0 as String }
        let ownWindows = windows.filter {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.intValue == processID
        }.map { window in window.filter { fields.contains($0.key) } }
        return """
            runner policy: \(NSApplication.shared.activationPolicy().rawValue), running: \(NSApplication.shared.isRunning)
            receiver number: \(target.windowNumber), visible: \(target.isVisible), occlusion: \(target.occlusionState.rawValue)
            opaque: \(target.isOpaque), alpha: \(target.alphaValue), ignoresMouse: \(target.ignoresMouseEvents)
            frame: \(target.frame), destination: \(destination), topmost: \(NSWindow.windowNumber(at: destination, belowWindowWithWindowNumber: 0))
            own WindowServer records: \(ownWindows)
            """
    }

    /// Choose a real free rectangle around the measured source, in AppKit
    /// screen coordinates. Target dimensions shrink to available space; its
    /// position is never guessed from a fixed screen corner.
    private static func receiverFrame(outside source: CGRect, on screen: CGRect) -> CGRect? {
        let available = screen.insetBy(dx: 12, dy: 12)
        let occupied = source.insetBy(dx: -12, dy: -12).intersection(available)
        guard !occupied.isNull else { return nil }
        let areas = [
            CGRect(x: available.minX, y: available.minY,
                   width: occupied.minX - available.minX, height: available.height),
            CGRect(x: occupied.maxX, y: available.minY,
                   width: available.maxX - occupied.maxX, height: available.height),
            CGRect(x: available.minX, y: available.minY,
                   width: available.width, height: occupied.minY - available.minY),
            CGRect(x: available.minX, y: occupied.maxY,
                   width: available.width, height: available.maxY - occupied.maxY),
        ].filter { $0.width >= 64 && $0.height >= 64 }
        guard let area = areas.max(by: {
            min($0.width, 260) * min($0.height, 140) < min($1.width, 260) * min($1.height, 140)
        }) else { return nil }
        let size = CGSize(width: min(area.width, 260), height: min(area.height, 140))
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                      width: size.width, height: size.height)
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
