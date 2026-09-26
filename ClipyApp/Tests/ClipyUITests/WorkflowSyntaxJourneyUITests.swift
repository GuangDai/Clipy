import AppKit
import XCTest

/// The real workflow sheet keeps pending rule text through mode/tab changes,
/// and only a successful Apply makes that text the workflow's visual steps.
final class WorkflowSyntaxJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testRuleDraftSurvivesSwitchesAndCloseWhileInvalidTextCannotReplaceSteps() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString("workflow syntax journey", forType: .string))
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-clipy.language", "en"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("history.sqlite").path
        app.launch()
        defer { app.terminate(); NSPasteboard.general.clearContents() }
        XCTAssertTrue(app.descendants(matching: .any)["clipy.panel.root"].waitForExistence(timeout: 20))
        app.typeKey(",", modifierFlags: .command)
        let category = app.buttons["clipy.settings.category.automation"]
        XCTAssertTrue(category.waitForExistence(timeout: 10))
        category.click()
        let manage = app.buttons["clipy.settings.workflows.manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5))
        SettingsJourneyControls.scroll(manage, into: app.scrollViews.containing(
            .any, identifier: manage.identifier
        ).firstMatch, app: app)
        manage.click()
        app.descendants(matching: .any)["clipy.workflow.load"].click()
        app.menuItems["New workflow"].click()
        let name = app.textFields["clipy.workflow.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("Unsaved syntax journey")
        let save = app.buttons["clipy.workflow.save"]
        XCTAssertTrue(waitUntil { save.isEnabled })

        let syntaxMode = app.descendants(matching: .any)["clipy.workflow.steps.syntax"]
        XCTAssertTrue(syntaxMode.waitForExistence(timeout: 5))
        syntaxMode.click()
        let editor = app.textViews["clipy.workflow.syntax.source"]
        XCTAssertTrue(waitUntil { editor.exists && editor.value as? String == "trim()\n" }, app.debugDescription)
        let invalid = "trim()\n  unknown_action()"
        replaceRuleText(in: editor, with: invalid)
        let applyRule = app.buttons["clipy.workflow.syntax.apply"]
        XCTAssertTrue(waitUntil { applyRule.isEnabled && !save.isEnabled }, app.debugDescription)
        reveal(applyRule, in: app)
        applyRule.click()
        let error = app.descendants(matching: .any)["clipy.workflow.syntax.error"]
        XCTAssertTrue(waitUntil { error.exists && error.label.contains("Line 2") }, app.debugDescription)
        XCTAssertEqual(editor.value as? String, invalid)
        let goToError = app.buttons["clipy.workflow.syntax.go-to-error"]
        reveal(goToError, in: app)
        goToError.click()

        let visualMode = app.descendants(matching: .any)["clipy.workflow.steps.visual"]
        reveal(visualMode, in: app)
        visualMode.click()
        XCTAssertTrue(app.descendants(matching: .any)["clipy.workflow.syntax.pending"].waitForExistence(timeout: 5))
        let operation = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "clipy.workflow.operation."
        )).firstMatch
        XCTAssertTrue(operation.exists)
        XCTAssertEqual(operation.value as? String, "Trim surrounding whitespace")
        syntaxMode.click()
        XCTAssertTrue(waitUntil { editor.exists && editor.value as? String == invalid })
        app.descendants(matching: .any)["clipy.workflow.configuration.scope"].click()
        app.descendants(matching: .any)["clipy.workflow.configuration.steps"].click()
        XCTAssertTrue(waitUntil { editor.exists && editor.value as? String == invalid })

        app.typeKey(.escape, modifierFlags: [])
        let keepEditing = app.sheets.buttons["Keep editing"].firstMatch
        XCTAssertTrue(keepEditing.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.sheets.buttons["Save all and close"].firstMatch.isEnabled)
        keepEditing.click()
        XCTAssertTrue(waitUntil { editor.exists && editor.value as? String == invalid })

        let valid = "if is_text():\n    uppercase()\nelse:\n    trim()\n"
        replaceRuleText(in: editor, with: valid)
        reveal(applyRule, in: app)
        applyRule.click()
        XCTAssertTrue(waitUntil {
            app.descendants(matching: .any)["clipy.workflow.syntax.applied"].exists && save.isEnabled
        }, app.debugDescription)
        reveal(visualMode, in: app)
        visualMode.click()
        XCTAssertFalse(app.descendants(matching: .any)["clipy.workflow.syntax.pending"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "clipy.workflow.branch."
        )).firstMatch.exists)
        app.typeKey(.escape, modifierFlags: [])
        let discard = app.buttons["clipy.workflow.discard-close"]
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        discard.click()
        XCTAssertTrue(waitUntil { !name.exists && manage.exists })
    }

    @MainActor
    private func reveal(_ control: XCUIElement, in app: XCUIApplication) {
        if control.isHittable { return }
        let scroll = app.scrollViews.containing(.any, identifier: control.identifier).firstMatch
        SettingsJourneyControls.scroll(control, into: scroll, app: app)
    }

    @MainActor
    private func replaceRuleText(in editor: XCUIElement, with source: String) {
        let value = NSPasteboardItem()
        XCTAssertTrue(value.setString(source, forType: .string))
        XCTAssertTrue(value.setData(Data(), forType: .init("org.nspasteboard.TransientType")))
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.writeObjects([value]))
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(waitUntil { editor.value as? String == source })
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }
}
