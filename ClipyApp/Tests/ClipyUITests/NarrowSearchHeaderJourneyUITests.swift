/// Real EN/ZH regular-expression search in a narrow 320-point panel
/// width. Verifies compact controls, filter clearing and continuous input.
/// The preview is a floating child window now, so the width invariant is
/// proven while the dwell-presented pane is on screen: the pane never
/// extends the main panel.
import AppKit
import XCTest

final class NarrowSearchHeaderJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testEnglishRegularExpressionSearchRemainsUsableAtNarrowWidth() throws {
        try exerciseSearch(language: "en", locale: "en_US")
    }

    @MainActor
    func testChineseRegularExpressionSearchRemainsUsableAtNarrowWidth() throws {
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
            "-clipy.appearance.previewAutoOpen", "YES",
        ]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory
            .appendingPathComponent("history.store").path
        app.launch()
        defer { app.terminate() }

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        XCTAssertTrue(panel.waitForExistence(timeout: 20), app.debugDescription)

        // Launch arguments arm production dwell for this process; the
        // width proof still requires the real floating pane to appear.
        let narrowWidth: CGFloat = 320
        if abs(panel.frame.width - narrowWidth) > 3 {
            // V2-11 permits freely chosen widths. Drag to the intended
            // test width instead of relying on an obsolete minimum clamp.
            let edge = panel.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.75))
                .withOffset(CGVector(dx: -1, dy: 0))
            edge.press(forDuration: 0.1, thenDragTo: edge.withOffset(CGVector(
                dx: narrowWidth - panel.frame.width, dy: 0
            )))
        }
        // The preview is a separate floating child window now
        // (`clipy.panel.floatingPreview`): it never extends the main panel,
        // so while the dwell-presented pane is on screen the browsing column
        // still holds the user's chosen 320-point width.
        let preview = app.descendants(matching: .any)["clipy.panel.floatingPreview"]
        XCTAssertTrue(waitUntil {
            preview.exists && abs(panel.frame.width - narrowWidth) <= 3
        }, app.debugDescription)
        let search = app.textFields["clipy.search.field"]
        let mode = panel.descendants(matching: .any)["clipy.search.mode"]
        let filter = panel.descendants(matching: .any)["clipy.search.filter"]
        let rows = panel.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "clipy.history.row."
        ))
        XCTAssertTrue(waitUntil { rows.count == 1 }, app.debugDescription)
        let emptySearchFrame = search.frame

        // No mouse focus repair: compact mode controls preserve the active
        // editor and every subsequent query character at the narrow width.
        app.typeKey("3", modifierFlags: .command)
        app.typeText("^clipy.*alpha$")
        let clear = app.buttons["clipy.search.clear"]
        XCTAssertTrue(waitUntil {
            search.value as? String == "^clipy.*alpha$" && rows.count == 1
                && clear.exists && clear.isHittable
                && search.frame.width >= 140
        }, app.debugDescription)
        XCTAssertEqual(search.frame.width, emptySearchFrame.width, accuracy: 1, app.debugDescription)
        XCTAssertEqual(search.frame.minX, emptySearchFrame.minX, accuracy: 1, app.debugDescription)
        XCTAssertGreaterThanOrEqual(clear.frame.width, 24, app.debugDescription)
        XCTAssertGreaterThanOrEqual(clear.frame.height, 24, app.debugDescription)
        for control in [search, clear, mode, filter] {
            XCTAssertTrue(control.isHittable, app.debugDescription)
            XCTAssertTrue(panel.frame.insetBy(dx: -2, dy: -2).contains(control.frame), app.debugDescription)
        }
        XCTAssertFalse(search.frame.intersects(clear.frame), app.debugDescription)
        XCTAssertFalse(search.frame.intersects(mode.frame), app.debugDescription)
        XCTAssertFalse(search.frame.intersects(filter.frame), app.debugDescription)

        clear.click()
        XCTAssertTrue(waitUntil { !clear.exists && search.value as? String == "" }, app.debugDescription)
        XCTAssertEqual(search.frame.width, emptySearchFrame.width, accuracy: 1, app.debugDescription)
        app.typeText("alpha")
        XCTAssertTrue(waitUntil {
            search.value as? String == "alpha" && rows.count == 1
                && search.frame.width >= 140
        }, app.debugDescription)
        // Compact menu symbols retain full localized choices.
        mode.click()
        XCTAssertTrue(app.menuItems[language == "en" ? "Exact" : "精确"].waitForExistence(timeout: 5), app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
        filter.click()
        let pinnedOnly = app.menuItems[language == "en" ? "Pinned Only" : "仅置顶"]
        XCTAssertTrue(pinnedOnly.waitForExistence(timeout: 5), app.debugDescription)
        pinnedOnly.click()
        let clearFilters = app.buttons["clipy.search.clear-filters"]
        XCTAssertTrue(waitUntil { clearFilters.exists && clearFilters.isHittable && rows.count == 0 }, app.debugDescription)
        XCTAssertEqual(search.value as? String, "alpha")
        clearFilters.click()
        XCTAssertTrue(waitUntil { !clearFilters.exists && rows.count == 1 }, app.debugDescription)
        XCTAssertEqual(search.value as? String, "alpha")
        // Clearing filters returns to the same editor without clearing its
        // query, and the original RegExp mode still executes the suffix.
        app.typeText("$")
        XCTAssertTrue(waitUntil { search.value as? String == "alpha$" && rows.count == 1 }, app.debugDescription)
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() }, object: nil
        )
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }
}
