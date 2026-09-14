import AppKit
import XCTest

final class AdvancedInteractionJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testInteractionControlsPersistAndSearchChoiceAppliesOnNextOpen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipy-interaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString("clipy interaction journey", forType: .string))
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("history.sqlite").path
        app.launch()
        defer { app.terminate(); NSPasteboard.general.clearContents() }
        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        XCTAssertTrue(panel.waitForExistence(timeout: 20), app.debugDescription)
        openInteraction(in: app)
        restoreDefaults(in: app)
        let remember = app.descendants(matching: .any)["clipy.settings.interaction.rememberSearch"]
        let hover = app.descendants(matching: .any)["clipy.settings.interaction.selectOnHover"]
        let previewDelay = app.sliders["clipy.settings.interaction.previewDelay"]
        let pointerGrace = app.sliders["clipy.settings.interaction.pointerGrace"]
        XCTAssertTrue(previewDelay.exists && pointerGrace.exists, app.debugDescription)
        scrollTo(remember, in: app)
        XCTAssertEqual(remember.value as? Int, 1, app.debugDescription)
        XCTAssertEqual(hover.value as? Int, 1, app.debugDescription)
        remember.click()
        hover.click()
        XCTAssertTrue(waitUntil { remember.value as? Int == 0 && hover.value as? Int == 0 }, app.debugDescription)
        app.buttons["clipy.settings.category.general"].click()
        app.buttons["clipy.settings.category.interaction"].click()
        XCTAssertTrue(waitUntil { remember.value as? Int == 0 && hover.value as? Int == 0 }, app.debugDescription)

        closeSettingsAndSummon(in: app)
        let search = app.textFields["clipy.search.field"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), app.debugDescription)
        search.click()
        search.typeText("interaction")
        XCTAssertTrue(waitUntil { search.value as? String == "interaction" }, app.debugDescription)
        openInteraction(in: app)
        closeSettingsAndSummon(in: app)
        XCTAssertTrue(waitUntil { search.exists && search.value as? String == "" }, app.debugDescription)

        // Restoring the real controls also isolates subsequent UI journeys.
        openInteraction(in: app)
        restoreDefaults(in: app)
        closeSettingsAndSummon(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 10), app.debugDescription)
        search.click()
        search.typeText("journey")
        openInteraction(in: app)
        closeSettingsAndSummon(in: app)
        XCTAssertTrue(waitUntil { search.exists && search.value as? String == "journey" }, app.debugDescription)
        openInteraction(in: app)
        app.buttons["clipy.settings.category.general"].click()
    }

    @MainActor
    private func openInteraction(in app: XCUIApplication) {
        app.typeKey(",", modifierFlags: .command)
        let category = app.buttons["clipy.settings.category.interaction"]
        XCTAssertTrue(category.waitForExistence(timeout: 10), app.debugDescription)
        category.click()
        XCTAssertTrue(app.descendants(matching: .any)["clipy.settings.interaction.rememberSearch"]
            .waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    private func restoreDefaults(in app: XCUIApplication) {
        let reset = app.buttons["clipy.settings.interaction.restoreDefaults"]
        scrollTo(reset, in: app)
        reset.click()
    }

    @MainActor
    private func scrollTo(_ control: XCUIElement, in app: XCUIApplication) {
        SettingsJourneyControls.scroll(control, into: app.scrollViews.containing(
            .any, identifier: control.identifier
        ).firstMatch, app: app)
    }

    @MainActor
    private func closeSettingsAndSummon(in app: XCUIApplication) {
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil { !app.buttons["clipy.settings.category.interaction"].exists }, app.debugDescription)
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.descendants(matching: .any)["clipy.panel.root"].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }
}
