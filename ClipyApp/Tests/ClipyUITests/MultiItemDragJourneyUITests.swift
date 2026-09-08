import AppKit
import XCTest

/// The receiver is a test-only AppKit process with its own application run
/// loop. The source is Clipy's actual row/native session; only a real native
/// drop can produce the ordered bytes checked below.
final class MultiItemDragJourneyUITests: XCTestCase {
    @MainActor
    func testRealRowDragsBothItemsAndAllBytesToANativeReceiver() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let opaque = NSPasteboard.PasteboardType("com.clipy.tests.drag-opaque")
        let firstText = Data("clipy-native-drag-first\0".utf8)
        let secondText = Data("clipy-native-drag-second\0".utf8)
        let originals = [NSPasteboardItem(), NSPasteboardItem()]
        XCTAssertTrue(originals[0].setData(firstText, forType: .string))
        XCTAssertTrue(originals[0].setData(Data([0, 255, 1]), forType: opaque))
        XCTAssertTrue(originals[1].setData(secondText, forType: .string))
        XCTAssertTrue(originals[1].setData(Data([255, 0, 2]), forType: opaque))
        NSPasteboard.general.clearContents()
        addTeardownBlock { @MainActor () async in NSPasteboard.general.clearContents() }
        XCTAssertTrue(NSPasteboard.general.writeObjects(originals))

        let traceURL = directory.appendingPathComponent("native-drag.trace")
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_DRAG_TRACE_PATH"] = traceURL.path
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("history.store").path
        app.launch()
        addTeardownBlock { @MainActor () async in app.terminate() }
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
        let readyURL = directory.appendingPathComponent("ready.json")
        let receivedURL = directory.appendingPathComponent("received.json")
        let receiverLogURL = directory.appendingPathComponent("receiver.log")
        try Data().write(to: receiverLogURL)
        let receiverLog = try FileHandle(forWritingTo: receiverLogURL)
        addTeardownBlock { try? receiverLog.close() }
        let receiver = Process()
        receiver.executableURL = Bundle(for: Self.self).bundleURL
            .appendingPathComponent("Contents/MacOS/ClipyDragReceiver")
        receiver.arguments = [targetFrame.minX, targetFrame.minY, targetFrame.width, targetFrame.height]
            .map { String(Double($0)) } + [directory.path]
        receiver.standardOutput = receiverLog
        receiver.standardError = receiverLog
        try receiver.run()
        // XCTest teardown also runs after continueAfterFailure=false aborts
        // the method. Register only after launch so an unstarted Process can
        // never reach waitUntilExit.
        addTeardownBlock { @MainActor () async in
            if receiver.isRunning {
                receiver.terminate()
                receiver.waitUntilExit()
            }
        }
        let receiverReady = NSPredicate { _, _ in FileManager.default.fileExists(atPath: readyURL.path) }
        let readiness = XCTWaiter.wait(for: [
            XCTNSPredicateExpectation(predicate: receiverReady, object: nil)
        ], timeout: 5)
        let readyLog = (try? String(contentsOf: receiverLogURL, encoding: .utf8)) ?? ""
        XCTAssertEqual(readiness, .completed, "Receiver ready handshake missing; running=\(receiver.isRunning); \(readyLog)")
        XCTAssertTrue(receiver.isRunning)
        let ready = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: readyURL)) as? [String: Any])
        XCTAssertEqual((ready["activationPolicy"] as? NSNumber)?.intValue, NSApplication.ActivationPolicy.accessory.rawValue)
        XCTAssertEqual(ready["isRunning"] as? Bool, true)
        let receiverWindowNumber = try XCTUnwrap((ready["windowNumber"] as? NSNumber)?.intValue)
        // AppKit's window query requires an initialized WindowServer connection.
        // The independent receiver owns it; XCTRunner does not initialize NSApp.
        // Compare the receiver's actual hit-test result, not a runner-side query.
        XCTAssertGreaterThan(receiverWindowNumber, 0)
        XCTAssertEqual((ready["hitWindowNumber"] as? NSNumber)?.intValue, receiverWindowNumber)
        let frame = try XCTUnwrap(ready["frame"] as? [String: NSNumber])
        let actualTargetFrame = try CGRect(
            x: XCTUnwrap(frame["x"]).doubleValue, y: XCTUnwrap(frame["y"]).doubleValue,
            width: XCTUnwrap(frame["width"]).doubleValue, height: XCTUnwrap(frame["height"]).doubleValue
        )
        let destination = NSPoint(x: actualTargetFrame.midX, y: actualTargetFrame.midY)
        XCTAssertFalse(actualTargetFrame.intersects(sourceFrame))
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(
            dx: destination.x - row.frame.midX,
            dy: desktopTop - destination.y - row.frame.midY
        ))
        start.press(forDuration: 0.3, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        let delivered = NSPredicate { _, _ in FileManager.default.fileExists(atPath: receivedURL.path) }
        let delivery = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: delivered, object: nil)], timeout: 10)
        let trace = (try? String(contentsOf: traceURL, encoding: .utf8)) ?? "no source trace"
        let receiverLogText = (try? String(contentsOf: receiverLogURL, encoding: .utf8)) ?? ""
        let diagnostics = """
            row before hover: \(beforeHover), after hover: \(afterHover), source window: \(sourceFrame)
            receiver running: \(receiver.isRunning), frame: \(actualTargetFrame), destination: \(destination)
            \(receiverLogText)
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
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receivedURL)) as? [String: Any])
        let items = try XCTUnwrap(result["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        let first = try Self.representations(in: items[0])
        let second = try Self.representations(in: items[1])
        XCTAssertEqual(first[NSPasteboard.PasteboardType.string.rawValue], firstText)
        XCTAssertEqual(second[NSPasteboard.PasteboardType.string.rawValue], secondText)
        XCTAssertEqual(first[opaque.rawValue], Data([0, 255, 1]))
        XCTAssertEqual(second[opaque.rawValue], Data([255, 0, 2]))
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(second.count, 2)
    }

    private static func representations(in item: [String: Any]) throws -> [String: Data] {
        let values = try XCTUnwrap(item["representations"] as? [[String: Any]])
        var result: [String: Data] = [:]
        for value in values {
            let identifier = try XCTUnwrap(value["typeIdentifier"] as? String)
            let encoded = try XCTUnwrap(value["bytes"] as? String)
            let bytes = try XCTUnwrap(Data(base64Encoded: encoded))
            XCTAssertNil(result.updateValue(bytes, forKey: identifier))
        }
        return result
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
