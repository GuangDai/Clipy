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
            "-clipy.appearance.rowDensity", language == "en" ? "comfortable" : "compact",
            "-clipy.appearance.snippetLineCount", "automatic",
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
            exerciseSourceCorrection(in: app, search: search, dates: dates, rows: rows)
            exerciseFuzzyLimit(in: app, search: search, sort: sort, rows: rows, pasteboard: pasteboard)
            exerciseUniformSearchRows(in: app, panel: panel, search: search, sort: sort, rows: rows, pasteboard: pasteboard)
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
    private func exerciseSourceCorrection(
        in app: XCUIApplication, search: XCUIElement, dates: XCUIElement, rows: XCUIElementQuery
    ) {
        let source = app.textFields["clipy.search.source.field"]
        let apply = app.buttons["clipy.search.options.apply"]
        let editSource = app.links["clipy.search.source.issue"]
        let unavailableSource = "clipy-no-app-40f17"

        dates.click()
        XCTAssertTrue(waitUntil { source.exists && source.isHittable }, app.debugDescription)
        source.click()
        app.typeText(unavailableSource)
        apply.click()
        XCTAssertTrue(waitUntil { editSource.exists && editSource.isHittable && rows.count == 0 }, app.debugDescription)

        editSource.click()
        XCTAssertTrue(waitUntil { source.exists && source.value as? String == unavailableSource }, app.debugDescription)
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertEqual(source.value as? String, "", app.debugDescription)
        apply.click()
        XCTAssertTrue(waitUntil {
            !editSource.exists && search.value as? String == "alpha$" && rows.count == 1
                && app.buttons["clipy.search.clear-filter.date"].exists
        }, app.debugDescription)
    }

    @MainActor
    private func exerciseFuzzyLimit(
        in app: XCUIApplication, search: XCUIElement, sort: XCUIElement,
        rows: XCUIElementQuery, pasteboard: NSPasteboard
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
        app.typeKey("2", modifierFlags: .command)
        app.typeText(String(sharedPrefix.prefix(8)))
        XCTAssertTrue(waitUntil { rows.count == 2 }, app.debugDescription)
        sort.click()
        let relevance = app.menuItems["Pinned, then relevance"]
        XCTAssertTrue(relevance.waitForExistence(timeout: 5), app.debugDescription)
        relevance.click()
        XCTAssertTrue(waitUntil { sort.value as? String == "Pinned, then relevance" }, app.debugDescription)

        search.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText(longText)

        let useExact = app.links["clipy.search.fuzzy.use-exact"]
        XCTAssertTrue(useExact.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(search.value as? String, longText)
        XCTAssertFalse(app.descendants(matching: .any)["clipy.history.query-issue"].exists)
        useExact.click()
        XCTAssertTrue(waitUntil {
            !useExact.exists && search.value as? String == longText
                && rows.count == 1 && rows.firstMatch.label.contains(longText)
                && sort.value as? String == "Pinned first"
        }, app.debugDescription)
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() }, object: nil
        )
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }

    @MainActor
    private func exerciseUniformSearchRows(
        in app: XCUIApplication, panel: XCUIElement, search: XCUIElement, sort: XCUIElement,
        rows: XCUIElementQuery, pasteboard: NSPasteboard
    ) {
        let term = "layoutneedle"
        let shortTitle = "\(term) short"
        let bodyTitle = "A multiline note"
        let bodyMatch = "\(term) on the second line"
        let bodyText = "\(bodyTitle)\n\(bodyMatch)\nThird line of the original note"
        let longTitle = "\(term) long " + String(repeating: "Content that wraps at this window width. ", count: 5)
        app.buttons["clipy.search.clear"].click()
        app.buttons["clipy.search.clear-filters"].click()
        XCTAssertTrue(waitUntil { search.value as? String == "" && rows.count == 3 }, app.debugDescription)

        for (text, title) in [(shortTitle, shortTitle), (bodyText, bodyTitle), (longTitle, "\(term) long")] {
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.setString(text, forType: .string))
            XCTAssertTrue(waitUntil { rows.allElementsBoundByIndex.contains { $0.label.contains(title) } },
                          app.debugDescription)
        }

        sort.click()
        let newest = app.menuItems["Newest first"]
        XCTAssertTrue(newest.waitForExistence(timeout: 5), app.debugDescription)
        newest.click()
        search.click()
        app.typeText(term)
        XCTAssertTrue(waitUntil {
            rows.count == 3 && rows.element(boundBy: 0).label.contains("\(term) long")
                && rows.element(boundBy: 1).label.contains(bodyMatch)
                && rows.element(boundBy: 2).label.contains(shortTitle)
        }, app.debugDescription)

        let bodyRow = rows.element(boundBy: 1)
        XCTAssertTrue(bodyRow.label.contains(bodyTitle))
        let frames = rows.allElementsBoundByIndex.map(\.frame)
        for frame in frames {
            XCTAssertFalse(frame.isEmpty)
            XCTAssertEqual(frame.height, frames[0].height, accuracy: 1, app.debugDescription)
        }
        let screenshot = XCTAttachment(screenshot: panel.screenshot())
        screenshot.name = "Uniform title and body search results at narrow width"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let sentinel = NSPasteboardItem()
        XCTAssertTrue(sentinel.setString("before copying the body match", forType: .string))
        XCTAssertTrue(sentinel.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([sentinel]))
        let before = pasteboard.changeCount
        bodyRow.click()
        XCTAssertTrue(waitUntil {
            !panel.exists && pasteboard.changeCount != before && pasteboard.data(forType: .string) == Data(bodyText.utf8)
        }, app.debugDescription)
    }
}
