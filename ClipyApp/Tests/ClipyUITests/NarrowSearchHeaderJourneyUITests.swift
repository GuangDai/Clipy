/// Real EN/ZH regular-expression search at the product's 360-point minimum
/// width. Verifies controls and input focus through the actual adaptive header.
import AppKit
import XCTest

final class NarrowSearchHeaderJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testEnglishRegularExpressionSearchRemainsUsableAtMinimumWidth() throws {
        try exerciseSearch(language: "en", locale: "en_US")
    }

    @MainActor
    func testChineseRegularExpressionSearchRemainsUsableAtMinimumWidth() throws {
        try exerciseSearch(language: "zh-Hans", locale: "zh_CN")
    }

    @MainActor
    private func exerciseSearch(language: String, locale: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        XCTAssertTrue(pasteboard.setString("clipy-narrow-header-alpha", forType: .string))

        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(\(language))", "-AppleLocale", locale,
        ]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory
            .appendingPathComponent("history.store").path
        app.launch()
        defer { app.terminate() }

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        XCTAssertTrue(panel.waitForExistence(timeout: 20), app.debugDescription)
        let preview = panel.descendants(matching: .any)["clipy.preview.root"]
        if panel.frame.width > 363 {
            // Use the actual resizable NSPanel edge. Drag beyond the minimum
            // so AppKit applies the product's 360-point resize constraint.
            let edge = panel.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.75))
                .withOffset(CGVector(dx: -1, dy: 0))
            edge.press(forDuration: 0.1, thenDragTo: edge.withOffset(CGVector(
                dx: -(panel.frame.width - 360 + 80), dy: 0
            )))
        }
        // The preview adds its own width and one divider point to the
        // window. The product minimum constrains the browsing column, not
        // that complete window (e.g. 360 + 1 + 320 = 681 with preview open).
        XCTAssertTrue(waitUntil {
            let previewExtension = preview.exists ? preview.frame.width + 1 : 0
            return abs(panel.frame.width - previewExtension - 360) <= 3
        }, app.debugDescription)
        let search = app.textFields["clipy.search.field"]
        let mode = panel.descendants(matching: .any)["clipy.search.mode"]
        let filter = panel.descendants(matching: .any)["clipy.search.filter"]
        let rows = panel.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "clipy.history.row."
        ))
        XCTAssertTrue(waitUntil { rows.count == 1 }, app.debugDescription)

        // No mouse focus repair: changing mode and then adding the result
        // caption may move the controls to another line, but must preserve
        // the active text editor and every subsequent query character.
        app.typeKey("3", modifierFlags: .command)
        app.typeText("^clipy.*alpha$")
        let clear = app.buttons["clipy.search.clear"]
        XCTAssertTrue(waitUntil {
            search.value as? String == "^clipy.*alpha$" && rows.count == 1
                && clear.exists && clear.isHittable
                && search.frame.width >= 140
        }, app.debugDescription)
        for control in [search, clear, mode, filter] {
            XCTAssertTrue(control.isHittable, app.debugDescription)
            XCTAssertTrue(panel.frame.insetBy(dx: -2, dy: -2).contains(control.frame), app.debugDescription)
        }
        XCTAssertFalse(search.frame.intersects(clear.frame), app.debugDescription)
        XCTAssertFalse(search.frame.intersects(mode.frame), app.debugDescription)
        XCTAssertFalse(search.frame.intersects(filter.frame), app.debugDescription)

        clear.click()
        app.typeText("alpha")
        XCTAssertTrue(waitUntil {
            search.value as? String == "alpha" && rows.count == 1
                && search.frame.width >= 140
        }, app.debugDescription)
        // Both real menus must still open beside the long selected mode.
        mode.click()
        XCTAssertTrue(app.menuItems[language == "en" ? "Exact" : "精确"].waitForExistence(timeout: 5), app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
        filter.click()
        XCTAssertTrue(app.menuItems[language == "en" ? "Pinned Only" : "仅置顶"].waitForExistence(timeout: 5), app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() }, object: nil
        )
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }
}
