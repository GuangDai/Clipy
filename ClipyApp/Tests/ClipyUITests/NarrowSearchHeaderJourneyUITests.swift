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
            "-clipy.language", "system",
            "-clipy.appearance.previewAutoOpen", "YES",
            // Keep the native resize edge away from the screen boundary,
            // independent of where a preceding GUI journey left the pointer.
            "-panelPosition", "center",
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
        HistoryJourneyControls.selectFirst(in: app)
        let preview = app.descendants(matching: .any)["clipy.panel.floatingPreview"]
        XCTAssertTrue(waitUntil {
            preview.exists && abs(panel.frame.width - narrowWidth) <= 3
        }, app.debugDescription)
        let search = app.textFields["clipy.search.field"]
        let mode = panel.descendants(matching: .any)["clipy.search.mode"]
        let sort = panel.descendants(matching: .any)["clipy.search.sort"]
        let dates = panel.buttons["clipy.search.date-options"]
        let filter = panel.descendants(matching: .any)["clipy.search.filter"]
        let rows = panel.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "clipy.history.row."
        ))
        XCTAssertTrue(waitUntil { rows.count == 1 }, app.debugDescription)
        let emptySearchFrame = search.frame

        // Return from the preview-inspection setup to Search. From this
        // point, mode changes must preserve the active editor without repair.
        search.click()
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
        for control in [search, clear, mode, sort, dates, filter] {
            XCTAssertTrue(control.isHittable, app.debugDescription)
            XCTAssertTrue(panel.frame.insetBy(dx: -2, dy: -2).contains(control.frame), app.debugDescription)
        }
        XCTAssertFalse(search.frame.intersects(clear.frame), app.debugDescription)
        XCTAssertFalse(search.frame.intersects(mode.frame), app.debugDescription)
        XCTAssertFalse(search.frame.intersects(sort.frame), app.debugDescription)
        XCTAssertFalse(search.frame.intersects(dates.frame), app.debugDescription)
        XCTAssertFalse(search.frame.intersects(filter.frame), app.debugDescription)

        clear.click()
        XCTAssertTrue(waitUntil { !clear.exists && search.value as? String == "" }, app.debugDescription)
        XCTAssertEqual(search.frame.width, emptySearchFrame.width, accuracy: 1, app.debugDescription)
        app.typeText("alpha")
        XCTAssertTrue(waitUntil {
            search.value as? String == "alpha" && rows.count == 1
                && search.frame.width >= 140
        }, app.debugDescription)
        // Compact menu labels retain full localized choices.
        mode.click()
        XCTAssertTrue(app.menuItems[language == "en" ? "Exact" : "精确"].waitForExistence(timeout: 5), app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
        sort.click()
        XCTAssertTrue(app.menuItems[language == "en" ? "Newest first" : "最新优先"].waitForExistence(timeout: 5),
                      app.debugDescription)
        XCTAssertTrue(app.menuItems[language == "en" ? "Pinned first" : "置顶优先"].exists, app.debugDescription)
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
        if language == "en" {
            exerciseDateConfirmation(in: app, dates: dates)
            exerciseFuzzyLimit(in: app, search: search, rows: rows, pasteboard: pasteboard)
        }
    }

    @MainActor
    private func exerciseDateConfirmation(in app: XCUIApplication, dates: XCUIElement) {
        let range = app.descendants(matching: .any)["clipy.search.date.range"]
        let activeDate = app.buttons["clipy.search.clear-filter.date"]

        for applies in [false, true] {
            dates.click()
            XCTAssertTrue(range.waitForExistence(timeout: 5), app.debugDescription)
            range.click()
            let recentDays = app.menuItems["Last 7 days"]
            XCTAssertTrue(recentDays.waitForExistence(timeout: 5), app.debugDescription)
            recentDays.click()
            let action = app.buttons[applies ? "clipy.search.options.apply" : "clipy.search.options.cancel"]
            XCTAssertTrue(action.isHittable, app.debugDescription)
            action.click()
            XCTAssertTrue(waitUntil { !range.exists && activeDate.exists == applies }, app.debugDescription)
        }
    }

    @MainActor
    private func exerciseFuzzyLimit(
        in app: XCUIApplication, search: XCUIElement, rows: XCUIElementQuery, pasteboard: NSPasteboard
    ) {
        let sharedPrefix = String(repeating: "x", count: 64)
        let longText = sharedPrefix + "a"
        let distractor = sharedPrefix + "b"
        app.buttons["clipy.search.clear"].click()
        XCTAssertTrue(waitUntil { search.value as? String == "" }, app.debugDescription)
        for sample in [longText, distractor] {
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.setString(sample, forType: .string))
            XCTAssertTrue(waitUntil { rows.allElementsBoundByIndex.contains { $0.label.contains(sample) } },
                          app.debugDescription)
        }

        search.click()
        app.typeText(longText)
        app.typeKey("2", modifierFlags: .command)

        let useExact = app.links["clipy.search.fuzzy.use-exact"]
        XCTAssertTrue(useExact.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(search.value as? String, longText)
        XCTAssertFalse(app.descendants(matching: .any)["clipy.history.query-issue"].exists)
        useExact.click()
        XCTAssertTrue(waitUntil {
            !useExact.exists && search.value as? String == longText
                && rows.count == 1 && rows.firstMatch.label.contains(longText)
        }, app.debugDescription)
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() }, object: nil
        )
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }
}
