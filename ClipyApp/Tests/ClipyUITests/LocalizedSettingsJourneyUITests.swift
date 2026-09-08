/// LocalizedSettingsJourneyUITests.swift — the first real-language
/// running-app journey: under Apple's zh-Hans launch arguments the panel,
/// the Settings sidebar titles, and the Retention surface must render the
/// packaged zh-Hans tables instead of their English development values.
/// Every asserted string is copied from the shipped tables (PanelActions,
/// GeneralAppearanceSettings, RetentionSettings); this closes the
/// running-app half of the "伪本地化/RTL 未证" row for a real language —
/// the RTL geometry half is owned by RTLPreviewGeometryJourneyUITests.
import AppKit
import XCTest

final class LocalizedSettingsJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testPanelSearchAndRetentionSettingsRenderZhHans() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        XCTAssertTrue(pasteboard.setString("clipy-zh-hans-settings-journey", forType: .string))

        let app = XCUIApplication()
        // Apple's documented language arguments select the packaged zh-Hans
        // localization for both the app bundle and the SwiftPM modules.
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory
            .appendingPathComponent("history.store").path
        app.launch()
        defer { app.terminate() }

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        XCTAssertTrue(panel.waitForExistence(timeout: 20), app.debugDescription)
        let rows = panel.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "clipy.history.row.")
        )
        XCTAssertTrue(waitUntil(timeout: 10) {
            rows.count == 1
        }, app.debugDescription)

        // PanelActions zh-Hans: the field's explicit accessibility label is
        // "搜索剪贴板历史记录", so an English fallback fails here.
        let search = panel.textFields["clipy.search.field"]
        XCTAssertTrue(waitUntil(timeout: 5) {
            search.exists && search.label == "搜索剪贴板历史记录"
        }, app.debugDescription)

        app.typeKey(",", modifierFlags: .command)
        for (category, title) in [("general", "通用"), ("appearance", "外观"), ("retention", "保留")] {
            let entry = app.buttons["clipy.settings.category.\(category)"]
            XCTAssertTrue(entry.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertEqual(entry.label, title, app.debugDescription)
        }
        app.buttons["clipy.settings.category.retention"].click()

        // RetentionSettings zh-Hans: the Items field label near the tab top.
        let keepAtMost = app.staticTexts["最多保留"]
        XCTAssertTrue(keepAtMost.waitForExistence(timeout: 10), app.debugDescription)

        // The retained-usage row loads on opening (HistoryUsageView
        // identifiers, queried the RetentionPolicyJourneyUITests way).
        let items = app.staticTexts["clipy.settings.usage.item-count"]
        let pinned = app.staticTexts["clipy.settings.usage.pinned-count"]
        let bytes = app.staticTexts["clipy.settings.usage.content-bytes"]
        XCTAssertTrue(waitUntil(timeout: 10) {
            items.exists && pinned.exists && bytes.exists
        }, app.debugDescription)

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(
            waitUntil(timeout: 5) { !keepAtMost.exists },
            app.debugDescription
        )
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(panel.waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() }, object: nil
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
