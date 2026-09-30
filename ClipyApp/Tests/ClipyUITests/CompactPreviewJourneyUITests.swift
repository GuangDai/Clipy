import AppKit
import XCTest

/// Actual equal-height windows, scrolling content, and direct preview actions.
final class CompactPreviewJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testShortAndLongPreviewsShareTheHistoryHeightAndOfferDirectActions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        addTeardownBlock { @MainActor () async in pasteboard.clearContents() }
        let short = "A small thought."
        XCTAssertTrue(pasteboard.setString(short, forType: .string))

        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-clipy.language", "system",
            "-clipy.appearance.previewAutoOpen", "YES",
            // Scrolling and direct Copy retain the complete long fixture.
            "-clipy.preview.isTextLengthLimited", "YES",
            "-clipy.preview.maximumTextCharacters", "50000",
            "-clipy.appearance.rowDensity", "compact",
            "-clipy.appearance.rowFontSize", "medium",
            "-clipy.appearance.snippetLineCount", "automatic",
            "-clipy.panelContentWidth", "360", "-clipy.panelHeight", "420",
        ]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("history.store").path
        addTeardownBlock { @MainActor () async in app.terminate() }
        app.launch()

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        let preview = app.descendants(matching: .any)["clipy.preview.root"]
        let pane = app.descendants(matching: .any)["clipy.panel.floatingPreview"]
        HistoryJourneyControls.selectFirst(in: app)
        let text = preview.descendants(matching: .any)["clipy.preview.text"]
        XCTAssertTrue(panel.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil {
            text.exists && self.value(text) == short
                && pane.exists && abs(pane.frame.height - panel.frame.height) < 3
        }, app.debugDescription)
        XCTAssertFalse(panel.staticTexts["Recent"].exists)
        let initialRow = panel.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "clipy.history.row."
        )).firstMatch
        XCTAssertTrue(waitUntil {
            initialRow.exists && panel.frame.contains(initialRow.frame)
        }, "The compact list must not clip its last row.\n\(app.debugDescription)")
        let toolbarHeight = initialRow.frame.minY - panel.frame.minY
        XCTAssertGreaterThanOrEqual(panel.frame.height + 2, toolbarHeight + 5 * initialRow.frame.height,
                                    "A short history must retain room for its toolbar and five compact records.")
        let shortPanelHeight = panel.frame.height
        let shortImage = XCTAttachment(screenshot: app.screenshot())
        shortImage.name = "Compact short text"
        shortImage.lifetime = .keepAlways
        add(shortImage)

        let pin = preview.buttons["clipy.preview.pin"]
        XCTAssertTrue(pin.exists && pin.isHittable)
        pin.click()
        XCTAssertTrue(waitUntil { pin.exists && pin.label == "Unpin" }, app.debugDescription)
        XCTAssertTrue(waitUntil {
            abs(panel.frame.height - shortPanelHeight) < 3
                && abs(pane.frame.height - panel.frame.height) < 3
                && panel.frame.contains(initialRow.frame)
        }, app.debugDescription)
        pin.click()
        XCTAssertTrue(waitUntil { pin.exists && pin.label == "Pin" })

        // A long capture scrolls inside the same fixed pane. Its final line
        // must remain reachable and Copy must retain every original byte.
        let tailMarker = "Final line preserved."
        let long = "A longer thought.\n" + String(repeating: "Content earns its space.\n", count: 80) + tailMarker
        let longItem = NSPasteboardItem()
        XCTAssertTrue(longItem.setString(long, forType: .string))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([longItem]))
        let longRow = panel.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "clipy.history.row.", "A longer thought."
        )).firstMatch
        XCTAssertTrue(longRow.waitForExistence(timeout: 10))
        HistoryJourneyControls.select(longRow, in: app)
        XCTAssertTrue(waitUntil {
            text.exists && self.value(text).contains("Content earns its space.")
                && pane.exists && abs(pane.frame.height - panel.frame.height) < 3
        }, app.debugDescription)
        let textScroll = preview.scrollViews.firstMatch
        XCTAssertTrue(textScroll.exists && textScroll.isHittable, app.debugDescription)
        let tail = preview.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (value CONTAINS %@ OR label CONTAINS %@)",
            "clipy.preview.text", tailMarker, tailMarker
        )).firstMatch
        textScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .scroll(byDeltaX: 0, deltaY: -textScroll.frame.height * CGFloat(long.split(separator: "\n").count))
        XCTAssertTrue(waitUntil {
            tail.exists && tail.isHittable
                && tail.frame.maxY <= textScroll.frame.maxY + 2
                && tail.frame.maxY >= textScroll.frame.minY
                && abs(pane.frame.height - panel.frame.height) < 3
        }, "The final text must be readable without growing the floating window.\n\(app.debugDescription)")
        let shortRow = panel.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "clipy.history.row.", short
        )).firstMatch
        // Pinning preserves both visible records and the shared height;
        // grouping chrome can use the room already reserved by the floor.
        pin.click()
        XCTAssertTrue(waitUntil {
            pin.label == "Unpin" && shortRow.exists && longRow.exists
                && panel.frame.contains(shortRow.frame) && panel.frame.contains(longRow.frame)
                && abs(pane.frame.height - panel.frame.height) < 3
        }, app.debugDescription)
        XCTAssertFalse(panel.staticTexts["Pinned"].exists)
        XCTAssertFalse(panel.staticTexts["Recent"].exists)
        let longImage = XCTAttachment(screenshot: app.screenshot())
        longImage.name = "Compact history with scrolling preview"
        longImage.lifetime = .keepAlways
        add(longImage)
        pin.click()
        XCTAssertTrue(waitUntil { pin.label == "Pin" })

        let longSentinel = NSPasteboardItem()
        XCTAssertTrue(longSentinel.setString("before-long-direct-copy", forType: .string))
        XCTAssertTrue(longSentinel.setData(Data(), forType: .init("org.nspasteboard.TransientType")))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([longSentinel]))
        let copy = preview.buttons["clipy.preview.copy"]
        XCTAssertTrue(copy.exists && copy.isHittable)
        copy.click()
        XCTAssertTrue(waitUntil {
            !panel.exists && !pane.exists && pasteboard.data(forType: .string) == Data(long.utf8)
        }, "Copy must retain the complete original long text after scrolling.\n\(app.debugDescription)")
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil { panel.exists && shortRow.exists && longRow.exists }, app.debugDescription)
        HistoryJourneyControls.select(shortRow, in: app)
        XCTAssertTrue(waitUntil {
            text.exists && self.value(text) == short
                && pane.exists && abs(pane.frame.height - panel.frame.height) < 3
        }, app.debugDescription)

        let sentinel = NSPasteboardItem()
        XCTAssertTrue(sentinel.setString("before-direct-copy", forType: .string))
        XCTAssertTrue(sentinel.setData(Data(), forType: .init("org.nspasteboard.TransientType")))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([sentinel]))
        XCTAssertTrue(copy.exists && copy.isHittable)
        XCTAssertGreaterThanOrEqual(copy.frame.width, 24)
        XCTAssertGreaterThanOrEqual(copy.frame.height, 24)
        copy.click()
        XCTAssertTrue(waitUntil { !panel.exists && pasteboard.data(forType: .string) == Data(short.utf8) },
            "Copy result: \(pasteboard.string(forType: .string) ?? "nil").\n\(app.debugDescription)")
    }

    @MainActor private func value(_ element: XCUIElement) -> String {
        (element.value as? String) ?? element.label
    }

    @MainActor private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }
}
