import AppKit
import XCTest

final class CapturePrivacyJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testApplicationChooserCancelsAndManualIdentifierRemainsAvailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipy-privacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identifier = "org.clipy.fixture." + UUID().uuidString.lowercased()
        NSPasteboard.general.clearContents()
        defer { NSPasteboard.general.clearContents() }
        XCTAssertTrue(NSPasteboard.general.setString("privacy settings", forType: .string))
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = root.appendingPathComponent("history.sqlite").path
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any)["clipy.panel.root"].waitForExistence(timeout: 15))
        app.typeKey(",", modifierFlags: .command)
        let general = app.buttons["clipy.settings.category.general"]
        XCTAssertTrue(general.waitForExistence(timeout: 10), app.debugDescription)
        general.click()
        let choose = app.buttons["clipy.settings.privacy.choose-applications"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5), app.debugDescription)
        let form = app.scrollViews.containing(.button, identifier: choose.identifier).firstMatch
        SettingsJourneyControls.scroll(choose, into: form, app: app)
        choose.click()
        let picker = app.sheets.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { !picker.exists && choose.isEnabled }, app.debugDescription)
        let field = app.textFields["clipy.settings.privacy.bundle-identifier"]
        SettingsJourneyControls.reveal(field, byExpanding: "clipy.settings.privacy.manual-entry", in: app)
        SettingsJourneyControls.scroll(field, into: form, app: app)
        field.click()
        field.typeText(identifier)
        app.buttons["clipy.settings.privacy.add-ignore"].click()
        let ignored = app.descendants(matching: .any)["clipy.settings.privacy.application." + identifier]
        XCTAssertTrue(ignored.waitForExistence(timeout: 5), app.debugDescription)
        // A category change reconstructs the section from the persisted list.
        app.buttons["clipy.settings.category.appearance"].click()
        general.click()
        XCTAssertTrue(ignored.waitForExistence(timeout: 5), app.debugDescription)
        let remove = app.buttons["clipy.settings.privacy.application." + identifier + ".remove"]
        XCTAssertTrue(remove.exists, app.debugDescription)
        SettingsJourneyControls.scroll(remove, into: form, app: app)
        remove.click()
        XCTAssertTrue(waitUntil { !ignored.exists }, app.debugDescription)
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }
}
