import AppKit
import XCTest

/// The real Settings entry, persistent side-by-side preview and clipboard
/// action. Storage, capture and copy all use the running app's production path.
final class HistoryWorkspaceEntryJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testHistoryCategoryShowsFixedPreviewAndCopyKeepsSettingsOpen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        let source = "History workspace keeps this preview available."
        XCTAssertTrue(pasteboard.setString(source, forType: .string))
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("history.sqlite").path
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any)["clipy.panel.root"].waitForExistence(timeout: 20))

        app.typeKey(",", modifierFlags: .command)
        let category = app.buttons["clipy.settings.category.history"]
        XCTAssertTrue(category.waitForExistence(timeout: 10), app.debugDescription)
        category.click()
        let settings = app.windows.containing(.button, identifier: category.identifier).firstMatch
        let workspace = settings.descendants(matching: .any)["clipy.history.workspace"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 10), app.debugDescription)
        let row = workspace.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "clipy.history.workspace.row.", "History workspace"
        )).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        row.click()

        let list = workspace.descendants(matching: .any)["clipy.history.workspace.list"]
        let preview = workspace.descendants(matching: .any)["clipy.history.workspace.preview"]
        let text = preview.descendants(matching: .any)["clipy.preview.text"]
        XCTAssertTrue(waitUntil {
            text.exists && ((text.value as? String) ?? text.label) == source
                && preview.frame.minX >= list.frame.maxX - 2
        }, "The workspace must show the selected content beside its list.\n\(app.debugDescription)")

        let sentinel = NSPasteboardItem()
        XCTAssertTrue(sentinel.setString("before-workspace-copy", forType: .string))
        XCTAssertTrue(sentinel.setData(Data(), forType: .init("org.nspasteboard.TransientType")))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([sentinel]))
        let copy = workspace.buttons["clipy.history.workspace.copy"]
        XCTAssertTrue(copy.isHittable, app.debugDescription)
        copy.click()
        XCTAssertTrue(waitUntil {
            pasteboard.string(forType: .string) == source && settings.exists && workspace.exists
        }, "Copying from History must leave Settings open.\n\(app.debugDescription)")

        // Moving to a different category stops only workspace presentation;
        // returning obtains fresh rows and the same fixed preview surface.
        settings.buttons["clipy.settings.category.general"].click()
        XCTAssertTrue(waitUntil { !workspace.exists })
        category.click()
        XCTAssertTrue(workspace.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        row.click()
        XCTAssertTrue(text.waitForExistence(timeout: 10), app.debugDescription)
        settings.buttons["clipy.settings.category.general"].click()
        settings.buttons["_XCUI:CloseWindow"].click()
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }
}
