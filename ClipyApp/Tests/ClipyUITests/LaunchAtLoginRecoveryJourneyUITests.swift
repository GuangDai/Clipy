import XCTest

/// The reported unavailable state must allow a first registration. Only the
/// operating-system service is substituted; the real Settings toggle and
/// controller drive registration and refresh the displayed state.
final class LaunchAtLoginRecoveryJourneyUITests: XCTestCase {
    @MainActor
    func testPreviouslyUnseenServiceCanBeEnabledFromSettings() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("history.store").path
        app.launchEnvironment["CLIPY_UI_TEST_LAUNCH_AT_LOGIN_STATUS"] = "not-found"
        app.launchEnvironment["CLIPY_UI_TEST_LOGIN_ITEMS_SETTINGS_MARKER_PATH"] = directory.appendingPathComponent("login-items-settings-opened").path
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any)["clipy.panel.root"].waitForExistence(timeout: 20))
        app.typeKey(",", modifierFlags: .command)
        let general = app.buttons["clipy.settings.category.general"]
        XCTAssertTrue(general.waitForExistence(timeout: 10))
        general.click()
        let toggle = app.switches["clipy.settings.launch-at-login"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(toggle.isEnabled, "A never-registered service must not disable its own registration control")
        XCTAssertFalse(app.descendants(matching: .any)["clipy.settings.launch-at-login.unavailable"].exists)
        toggle.click()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            toggle.isEnabled && ((toggle.value as? Int) == 1 || (toggle.value as? String) == "1")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed, app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["clipy.settings.launch-at-login.operation-failed"].exists)
    }
}
