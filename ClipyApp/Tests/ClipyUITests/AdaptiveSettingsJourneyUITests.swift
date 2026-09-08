import AppKit
import XCTest

/// Native Settings navigation and resizing, through the real app window.
final class AdaptiveSettingsJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testSidebarRetainsCategoryAndDetailFollowsWindowResize() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipy-settings-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString("adaptive settings", forType: .string))
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("history.sqlite").path
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any)["clipy.panel.root"].waitForExistence(timeout: 15))
        app.typeKey(",", modifierFlags: .command)
        let appearance = app.buttons["clipy.settings.category.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 10), app.debugDescription)
        appearance.click()
        let settings = app.windows.containing(.button, identifier: "clipy.settings.category.appearance").firstMatch
        let density = app.descendants(matching: .any)["clipy.settings.appearance.row-density"]
        XCTAssertTrue(density.waitForExistence(timeout: 10), app.debugDescription)
        let detail = settings.scrollViews.containing(
            .any, identifier: "clipy.settings.appearance.row-density"
        ).firstMatch
        XCTAssertTrue(detail.exists, app.debugDescription)

        // Exercise the real Settings resize interaction and detail reflow.
        // Content bounds alone do not enable this interaction; the Settings
        // scene must also opt into windowResizeBehavior(.enabled).
        let rightEdge = settings.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.65))
            .withOffset(CGVector(dx: 2, dy: 0))
        rightEdge.press(forDuration: 0.1, thenDragTo: rightEdge.withOffset(CGVector(
            dx: 600 - settings.frame.width, dy: 0
        )))
        XCTAssertTrue(waitUntil { abs(settings.frame.width - 600) <= 3 }, app.debugDescription)
        XCTAssertTrue(appearance.isHittable, app.debugDescription)
        XCTAssertTrue(density.isHittable, app.debugDescription)
        let narrowWidth = settings.frame.width
        let narrowDetailWidth = detail.frame.width
        let narrowEdge = settings.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.65))
            .withOffset(CGVector(dx: 2, dy: 0))
        narrowEdge.press(forDuration: 0.1, thenDragTo: narrowEdge.withOffset(CGVector(dx: 100, dy: 0)))
        XCTAssertTrue(waitUntil {
            settings.frame.width > narrowWidth + 50 && detail.frame.width > narrowDetailWidth + 40
        }, app.debugDescription)

        settings.buttons["_XCUI:CloseWindow"].click()
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(density.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(appearance.isSelected, app.debugDescription)
        XCTAssertFalse(app.switches["clipy.settings.retention.age-enabled"].exists)
        app.buttons["clipy.settings.category.general"].click()
        let clearActions = app.descendants(matching: .any)["clipy.settings.general.clear-history"]
        XCTAssertTrue(clearActions.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["Clear All History…"].exists, app.debugDescription)
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }
}
