import AppKit
import XCTest

final class HistoryBackupJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testMaintenanceExplainsBackupScopeAndCancellingDestinationReturnsToSettings() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipy-backup-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString("backup-test", forType: .string))
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = root.appendingPathComponent("history.sqlite").path
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launch()
        defer { app.terminate() }
        let row = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "clipy.history.row."
        )).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), app.debugDescription)
        app.typeKey(",", modifierFlags: .command)
        let maintenance = app.buttons["clipy.settings.category.maintenance"]
        XCTAssertTrue(maintenance.waitForExistence(timeout: 10), app.debugDescription)
        maintenance.click()
        let disclosure = app.staticTexts["clipy.settings.maintenance.backup-disclosure"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 10), app.debugDescription)
        let scope = disclosure.value as? String ?? disclosure.label
        XCTAssertTrue(scope.contains("original content and revisions"), scope)
        XCTAssertTrue(scope.contains("not encrypted"), scope)
        let backup = app.buttons["clipy.settings.maintenance.backup"]
        XCTAssertTrue(backup.isHittable, app.debugDescription)
        backup.click()
        let chooser = app.sheets.firstMatch
        XCTAssertTrue(chooser.waitForExistence(timeout: 10), app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
        let status = app.staticTexts["clipy.settings.maintenance.backup-status"]
        let cancelled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            status.exists && (status.value as? String ?? status.label) == "Backup cancelled."
                && backup.isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 10), .completed, app.debugDescription)
        XCTAssertFalse(app.buttons["clipy.settings.maintenance.backup-reveal"].exists)
    }
}
