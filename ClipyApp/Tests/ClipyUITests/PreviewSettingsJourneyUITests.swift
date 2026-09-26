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
        HistoryJourneyControls.selectFirst(in: app)
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
        HistoryJourneyControls.selectFirst(in: app)
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
        HistoryJourneyControls.selectFirst(in: app)
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
    func testCustomWidthAndSlowOuterEdgeDragPersistWithoutClosingThePreview() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        XCTAssertTrue(pasteboard.setString("Preview width remains adjustable.", forType: .string))
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-clipy.appearance.previewAutoOpen", "YES"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("history.sqlite").path
        app.launch()
        defer { app.terminate() }
        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        let preview = app.descendants(matching: .any)["clipy.panel.floatingPreview"]
        XCTAssertTrue(panel.waitForExistence(timeout: 20))

        var settings = openAppearance(in: app)
        let custom = app.switches["clipy.settings.preview.custom-width"]
        reveal(custom, in: app)
        if (custom.value as? String) != "1" { custom.click() }
        let width = app.textFields["clipy.settings.preview.panel-width"]
        set("100", in: width, app: app)
        let widthError = app.descendants(matching: .any)["clipy.settings.preview.width-error"]
        XCTAssertTrue(widthError.waitForExistence(timeout: 5))
        set("420", in: width, app: app)
        XCTAssertTrue(waitUntil { !widthError.exists })
        settings.buttons["_XCUI:CloseWindow"].click()
        app.typeKey("c", modifierFlags: [.command, .shift])
        HistoryJourneyControls.selectFirst(in: app)
        XCTAssertTrue(waitUntil { preview.exists && abs(preview.frame.width - 420) <= 3 }, app.debugDescription)

        let handle = app.descendants(matching: .any)["clipy.preview.resize-width"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5), app.debugDescription)
        let browsingFrame = panel.frame
        let initialWidth = preview.frame.width
        let isLeading = preview.frame.midX < panel.frame.midX
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // Holding longer than the exit grace proves resizing keeps its
        // interaction alive even while the window edge moves under the mouse.
        start.press(forDuration: 0.4, thenDragTo: start.withOffset(CGVector(
            dx: isLeading ? 64 : -64, dy: 0
        )), withVelocity: .slow, thenHoldForDuration: 0.8)
        XCTAssertTrue(waitUntil {
            preview.exists && abs(preview.frame.width - (initialWidth - 64)) <= 6
                && abs(panel.frame.width - browsingFrame.width) <= 2
                && abs(panel.frame.minX - browsingFrame.minX) <= 2
        }, "Resizing must preserve both the preview and browsing window.\n\(app.debugDescription)")
        let resizedWidth = preview.frame.width

        settings = openAppearance(in: app)
        reveal(width, in: app)
        XCTAssertTrue(waitUntil {
            guard let saved = Double(self.value(width)) else { return false }
            return abs(saved - resizedWidth) <= 2
        }, "Dragging must update the same width preference shown in Settings")
        reveal(custom, in: app)
        custom.click()
        XCTAssertFalse(width.exists)
        settings.buttons["_XCUI:CloseWindow"].click()
        app.typeKey("c", modifierFlags: [.command, .shift])
        HistoryJourneyControls.selectFirst(in: app)
        XCTAssertTrue(waitUntil { preview.exists && abs(preview.frame.width - 340) <= 3 }, app.debugDescription)

        settings = openAppearance(in: app)
        reveal(custom, in: app)
        custom.click()
        XCTAssertTrue(waitUntil {
            guard width.exists, let saved = Double(self.value(width)) else { return false }
            return abs(saved - resizedWidth) <= 2
        }, "The default-width option must preserve the last custom choice")
        let reset = app.buttons["clipy.settings.preview.reset"]
        reveal(reset, in: app)
        reset.click()
        XCTAssertTrue(waitUntil { !width.exists && (custom.value as? String) == "0" })
        settings.buttons["_XCUI:CloseWindow"].click()
    }

    @MainActor
    private func reveal(_ control: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        SettingsJourneyControls.scroll(control,
            into: app.scrollViews.containing(.any, identifier: control.identifier).firstMatch, app: app)
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
