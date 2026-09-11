import AppKit
import XCTest

/// Real preference controls, text readback and adjoining window geometry.
final class PreviewSettingsJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testCompleteTextPreservesCustomLengthAndZeroGapJoinsThePanels() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        let source = "Prefix with a complete tail"
        XCTAssertTrue(pasteboard.setString(source, forType: .string))
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-clipy.appearance.previewAutoOpen", "YES"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("history.sqlite").path
        app.launch()
        defer { app.terminate() }
        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        let preview = app.descendants(matching: .any)["clipy.preview.root"]
        let text = preview.descendants(matching: .any)["clipy.preview.text"]
        let notice = preview.descendants(matching: .any)["clipy.preview.truncation-notice"]
        XCTAssertTrue(panel.waitForExistence(timeout: 20))

        var settings = openAppearance(in: app)
        let gap = app.textFields["clipy.settings.preview.panel-gap"]
        set("0", in: gap, app: app)
        let complete = revealCompleteToggle(in: app)
        if (complete.value as? String) == "1" { complete.click() }
        let count = app.textFields["clipy.settings.preview.character-count"]
        set("6", in: count, app: app)
        let screenshot = XCTAttachment(screenshot: settings.screenshot())
        screenshot.name = "Advanced preview preferences"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        settings.buttons["_XCUI:CloseWindow"].click()
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil {
            text.exists && self.value(text) == "Prefix" && notice.exists
        }, app.debugDescription)
        XCTAssertTrue(waitUntil {
            let gap = min(abs(preview.frame.minX - panel.frame.maxX),
                abs(panel.frame.minX - preview.frame.maxX))
            return gap <= 2
        }, "A zero gap must join the actual windows")

        settings = openAppearance(in: app)
        revealCompleteToggle(in: app).click()
        settings.buttons["_XCUI:CloseWindow"].click()
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil {
            text.exists && self.value(text) == source && !notice.exists
        }, app.debugDescription)

        settings = openAppearance(in: app)
        revealCompleteToggle(in: app).click()
        XCTAssertTrue(waitUntil { count.exists && self.value(count) == "6" },
            "Toggling complete text must preserve the previous custom length")
        // Restore preferences through the same product control for subsequent
        // journeys in this runner's desktop session.
        let reset = app.buttons["clipy.settings.preview.reset"]
        SettingsJourneyControls.scroll(reset,
            into: app.scrollViews.containing(.button, identifier: reset.identifier).firstMatch, app: app)
        reset.click()
        settings.buttons["_XCUI:CloseWindow"].click()
    }

    @MainActor
    private func revealCompleteToggle(in app: XCUIApplication) -> XCUIElement {
        let toggle = app.switches["clipy.settings.preview.complete-text"]
        SettingsJourneyControls.reveal(toggle,
            byExpanding: "clipy.settings.appearance.advanced-preview", in: app)
        SettingsJourneyControls.scroll(toggle,
            into: app.scrollViews.containing(.any, identifier: toggle.identifier).firstMatch, app: app)
        return toggle
    }

    @MainActor
    private func openAppearance(in app: XCUIApplication) -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let category = app.buttons["clipy.settings.category.appearance"]
        XCTAssertTrue(category.waitForExistence(timeout: 10))
        category.click()
        return app.windows.containing(.button, identifier: category.identifier).firstMatch
    }

    @MainActor
    private func set(_ value: String, in field: XCUIElement, app: XCUIApplication) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        SettingsJourneyControls.scroll(field,
            into: app.scrollViews.containing(.textField, identifier: field.identifier).firstMatch, app: app)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(value)
        field.typeKey(.tab, modifierFlags: [])
    }

    @MainActor
    private func value(_ element: XCUIElement) -> String {
        (element.value as? String) ?? element.label
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }
}
