import AppKit
import XCTest

/// Actual window geometry, independent content fitting, and the two common
/// preview actions. No fixed-size fixture stands in for a rendered preview.
final class CompactPreviewJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testShortAndLongPreviewsFitTheirContentAndOfferDirectActions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        let short = "A small thought."
        XCTAssertTrue(pasteboard.setString(short, forType: .string))

        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-clipy.appearance.previewAutoOpen", "YES",
            "-clipy.appearance.rowDensity", "compact",
            "-clipy.appearance.rowFontSize", "medium",
            "-clipy.panelContentWidth", "360", "-clipy.panelHeight", "420",
        ]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("history.store").path
        app.launch()
        defer { app.terminate() }

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        let preview = app.descendants(matching: .any)["clipy.preview.root"]
        let text = preview.descendants(matching: .any)["clipy.preview.text"]
        XCTAssertTrue(panel.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil {
            text.exists && self.value(text) == short
                && preview.frame.height > 30 && preview.frame.height < 140
                && panel.frame.height > 30 && panel.frame.height < 100
        }, app.debugDescription)
        XCTAssertFalse(panel.staticTexts["Recent"].exists)
        let initialRow = panel.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "clipy.history.row."
        )).firstMatch
        XCTAssertTrue(waitUntil {
            initialRow.exists && initialRow.frame.maxY <= panel.frame.maxY
        }, "The compact list must not clip its last row.\n\(app.debugDescription)")
        let shortHeight = preview.frame.height
        let shortPanelHeight = panel.frame.height
        let shortImage = XCTAttachment(screenshot: app.screenshot())
        shortImage.name = "Compact short text"
        shortImage.lifetime = .keepAlways
        add(shortImage)

        let pin = preview.buttons["clipy.preview.pin"]
        XCTAssertTrue(pin.exists && pin.isHittable)
        pin.click()
        XCTAssertTrue(waitUntil { pin.exists && pin.label == "Unpin" }, app.debugDescription)
        XCTAssertTrue(waitUntil { abs(panel.frame.height - shortPanelHeight) < 3 })
        pin.click()
        XCTAssertTrue(waitUntil { pin.exists && pin.label == "Pin" })

        // A long capture grows its own preview while the two-row history
        // stays small. Clearing the selection's search is not required.
        let long = "A longer thought.\n" + String(repeating: "Content earns its space.\n", count: 80)
        let longItem = NSPasteboardItem()
        XCTAssertTrue(longItem.setString(long, forType: .string))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([longItem]))
        let longRow = panel.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "clipy.history.row.", "A longer thought."
        )).firstMatch
        XCTAssertTrue(longRow.waitForExistence(timeout: 10))
        longRow.click()
        XCTAssertTrue(waitUntil {
            text.exists && self.value(text).contains("Content earns its space.")
                && preview.frame.height > shortHeight + 100
                && preview.frame.height <= 423 && panel.frame.height < 140
        }, app.debugDescription)
        let longImage = XCTAttachment(screenshot: app.screenshot())
        longImage.name = "Compact history with scrolling preview"
        longImage.lifetime = .keepAlways
        add(longImage)

        let shortRow = panel.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "clipy.history.row.", short
        )).firstMatch
        shortRow.click()
        XCTAssertTrue(waitUntil {
            text.exists && self.value(text) == short && abs(preview.frame.height - shortHeight) < 3
        }, app.debugDescription)

        let sentinel = NSPasteboardItem()
        XCTAssertTrue(sentinel.setString("before-direct-copy", forType: .string))
        XCTAssertTrue(sentinel.setData(Data(), forType: .init("org.nspasteboard.TransientType")))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([sentinel]))
        let copy = preview.buttons["clipy.preview.copy"]
        XCTAssertTrue(copy.exists && copy.isHittable)
        XCTAssertGreaterThanOrEqual(copy.frame.width, 24)
        XCTAssertGreaterThanOrEqual(copy.frame.height, 24)
        copy.click()
        XCTAssertTrue(waitUntil { !panel.exists && pasteboard.string(forType: .string) == short })
    }

    @MainActor private func value(_ element: XCUIElement) -> String {
        (element.value as? String) ?? element.label
    }

    @MainActor private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }
}
