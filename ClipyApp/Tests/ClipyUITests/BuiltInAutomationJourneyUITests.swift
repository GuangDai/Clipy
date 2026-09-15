import AppKit
import XCTest

/// Real pasteboard capture → Details → editor → app-local workflow. Copying
/// from Details checks the saved bytes and item identity, independently of
/// the workflow's displayed preview and the editor's temporary draft.
final class BuiltInAutomationJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testPreviewCancelPreservesContentAndApplyRequiresSaveRevision() throws {
        let original = "  clipy workflow original  "
        let expected = "clipy workflow original"
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = launch(capturing: original, directory: directory)
        defer { app.terminate(); NSPasteboard.general.clearContents() }

        let row = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "clipy.history.row."
        )).firstMatch
        XCTAssertTrue(waitUntil { row.exists && row.isHittable && row.label.contains(expected) }, app.debugDescription)
        let itemID = try XCTUnwrap(UUID(uuidString: String(row.identifier.dropFirst("clipy.history.row.".count))))
        row.rightClick()
        let details = app.menuItems["Show Details"]
        XCTAssertTrue(details.waitForExistence(timeout: 5), app.debugDescription)
        details.click()
        openEditor(in: app)
        let replacement = app.descendants(matching: .any)["clipy.editor.replacement.public.utf8-plain-text"]
        XCTAssertTrue(waitUntil { replacement.exists && replacement.value as? String == original }, app.debugDescription)

        // Default workflow is the visible Trim surrounding whitespace step.
        // Merely previewing it must leave both the draft and stored item alone.
        openWorkflowAndPreview(in: app)
        let apply = app.buttons["clipy.workflow.apply"]
        XCTAssertTrue(waitUntil { apply.exists && apply.isEnabled }, app.debugDescription)
        // Close's native cancel shortcut targets the active attached sheet,
        // without confusing it with the Details window's own Close button.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { !apply.exists && replacement.value as? String == original }, app.debugDescription)
        app.buttons["clipy.editor.cancel"].click()
        XCTAssertTrue(waitUntil { !replacement.exists }, app.debugDescription)
        XCTAssertFalse(app.buttons["clipy.editor.confirm-discard"].exists, app.debugDescription)
        try copyDetailsAndAssert(original, itemID: itemID, in: app)

        // Applying the same preview authors a draft; the pasteboard still
        // contains the original until the explicit Save and Copy actions.
        reopenDetails(itemID: itemID, in: app)
        openEditor(in: app)
        openWorkflowAndPreview(in: app)
        XCTAssertTrue(waitUntil { apply.exists && apply.isEnabled }, app.debugDescription)
        apply.click()
        XCTAssertTrue(waitUntil {
            !apply.exists && replacement.exists && replacement.value as? String == expected
        }, app.debugDescription)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), original)
        let save = app.buttons["clipy.editor.save"]
        XCTAssertTrue(waitUntil { save.isEnabled && save.isHittable }, app.debugDescription)
        save.click()
        XCTAssertTrue(waitUntil { !replacement.exists && app.descendants(matching: .any)["clipy.details.root"].exists }, app.debugDescription)
        try copyDetailsAndAssert(expected, itemID: itemID, in: app)
    }

    @MainActor
    func testSettingsWorkflowPlaygroundPreviewsWithoutOfferingHistoryApply() throws {
        let original = "clipy workflow playground history"
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = launch(capturing: original, directory: directory)
        defer { app.terminate(); NSPasteboard.general.clearContents() }
        XCTAssertTrue(app.descendants(matching: .any)["clipy.panel.root"].waitForExistence(timeout: 20), app.debugDescription)
        app.typeKey(",", modifierFlags: .command)
        let category = app.buttons["clipy.settings.category.automation"]
        XCTAssertTrue(category.waitForExistence(timeout: 10), app.debugDescription)
        category.click()
        let manage = app.buttons["clipy.settings.workflows.manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5), app.debugDescription)
        SettingsJourneyControls.scroll(manage, into: app.scrollViews.containing(
            .any, identifier: manage.identifier
        ).firstMatch, app: app)
        manage.click()
        app.descendants(matching: .any)["clipy.workflow.load"].click()
        app.menuItems["New workflow"].click()
        let source = app.textViews["clipy.workflow.source"]
        XCTAssertTrue(source.waitForExistence(timeout: 5), app.debugDescription)
        source.click()
        // This raw-text playground must preserve literal input: macOS can
        // otherwise replace the trailing spaces with a period before Preview.
        // Check input separately so substitutions cannot masquerade as a
        // workflow or preview-rendering failure.
        let testText = "  playground result  "
        source.typeText(testText)
        XCTAssertTrue(waitUntil { source.value as? String == testText },
                      "Literal input changed: \(String(reflecting: source.value as? String)); expected \(String(reflecting: testText))\n\(app.debugDescription)")
        clickPreview(in: app)
        let result = app.textViews["clipy.workflow.result"]
        XCTAssertTrue(waitUntil {
            result.exists && result.value as? String == "playground result"
        }, app.debugDescription)
        // Smart quotes, dashes and ellipses must likewise remain literal;
        // the workflow, not the text system, owns any transformation.
        let punctuation = "  \"playground\" -- result...  "
        source.click()
        source.typeKey("a", modifierFlags: .command)
        source.typeText(punctuation)
        XCTAssertTrue(waitUntil { source.value as? String == punctuation },
                      "Literal punctuation changed: \(String(reflecting: source.value as? String)); expected \(String(reflecting: punctuation))\n\(app.debugDescription)")
        clickPreview(in: app)
        XCTAssertTrue(waitUntil {
            result.exists && result.value as? String == "\"playground\" -- result..."
        }, app.debugDescription)
        XCTAssertFalse(app.buttons["clipy.workflow.apply"].exists, app.debugDescription)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Native workflow editor and preview"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), original)
        // Exercise NSTextView's own native selection/Copy path, independently
        // of the workflow's separate Copy result action and pasteboard writer.
        result.click()
        result.typeKey("a", modifierFlags: .command)
        result.typeKey("c", modifierFlags: .command)
        XCTAssertTrue(waitUntil {
            NSPasteboard.general.string(forType: .string) == "\"playground\" -- result..."
        }, app.debugDescription)
        XCTAssertEqual(result.value as? String, "\"playground\" -- result...",
                       "Copying a read-only result must leave its text unchanged")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { !source.exists && manage.isHittable }, app.debugDescription)
        app.buttons["clipy.settings.category.general"].click()
    }

    @MainActor
    func testConditionalPresetShowsMatchAndKeepsAutomaticTriggerSeparateFromManualRun() throws {
        let original = "clipy condition journey retained clipboard"
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = launch(capturing: original, directory: directory)
        defer { app.terminate(); NSPasteboard.general.clearContents() }
        XCTAssertTrue(app.descendants(matching: .any)["clipy.panel.root"].waitForExistence(timeout: 20))
        app.typeKey(",", modifierFlags: .command)
        let category = app.buttons["clipy.settings.category.automation"]
        XCTAssertTrue(category.waitForExistence(timeout: 10))
        category.click()
        let manage = app.buttons["clipy.settings.workflows.manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5))
        SettingsJourneyControls.scroll(manage, into: app.scrollViews.containing(.any, identifier: manage.identifier).firstMatch, app: app)
        manage.click()
        let load = app.descendants(matching: .any)["clipy.workflow.load"]
        XCTAssertTrue(load.waitForExistence(timeout: 5))
        load.click()
        let preset = app.menuItems["Notify about TODO"]
        XCTAssertTrue(preset.waitForExistence(timeout: 5))
        preset.click()
        let source = app.textViews["clipy.workflow.source"]
        source.click()
        source.typeText("ordinary text")
        clickPreview(in: app)
        let copy = app.buttons["clipy.workflow.copy"]
        XCTAssertTrue(waitUntil {
            app.staticTexts["Conditions did not match. No notification was sent."].exists && !copy.isEnabled
        }, app.debugDescription)
        source.click()
        source.typeKey("a", modifierFlags: .command)
        source.typeText("TODO: 42")
        clickPreview(in: app)
        XCTAssertTrue(waitUntil {
            app.descendants(matching: .any)["clipy.workflow.conditions-matched"].exists && copy.isEnabled
        }, app.debugDescription)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), original,
                       "Preview must not rewrite the clipboard")

        let trigger = app.popUpButtons["clipy.workflow.trigger"]
        let scopeTab = app.descendants(matching: .any)["clipy.workflow.configuration"]
            .descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Trigger and scope")).firstMatch
        XCTAssertTrue(scopeTab.waitForExistence(timeout: 5), app.debugDescription)
        scopeTab.click()
        XCTAssertTrue(trigger.waitForExistence(timeout: 5), app.debugDescription)
        trigger.click()
        app.menuItems["New copies automatically"].click()
        XCTAssertFalse(app.buttons["clipy.workflow.run"].isEnabled)
        XCTAssertTrue(app.buttons["clipy.workflow.preview"].isEnabled)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Conditional workflow trigger and scope"
        attachment.lifetime = .keepAlways
        add(attachment)
        // The definition is deliberately unsaved, so this UI test never
        // schedules a real OS notification or changes automatic workflows.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { !source.exists && manage.isHittable })
    }

    @MainActor
    func testMultipleWorkflowDraftsKeepInputAndPersistVisibleExecutionOrder() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = launch(capturing: "clipboard unchanged by workflow editing", directory: directory)
        defer { app.terminate(); NSPasteboard.general.clearContents() }
        XCTAssertTrue(app.descendants(matching: .any)["clipy.panel.root"].waitForExistence(timeout: 20))
        app.typeKey(",", modifierFlags: .command)
        let category = app.buttons["clipy.settings.category.automation"]
        XCTAssertTrue(category.waitForExistence(timeout: 10))
        category.click()
        let manage = app.buttons["clipy.settings.workflows.manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5))
        SettingsJourneyControls.scroll(manage, into: app.scrollViews.containing(.any, identifier: manage.identifier).firstMatch, app: app)
        manage.click()
        let source = app.textViews["clipy.workflow.source"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["clipy.workflow.read-clipboard"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["clipy.workflow.input-type"].exists)
        let name = app.textFields["clipy.workflow.name"]
        let firstName = "First workflow " + String(UUID().uuidString.prefix(8))
        let secondName = "Second workflow " + String(UUID().uuidString.prefix(8))
        defer {
            if !source.exists && manage.isHittable { manage.click() }
            for title in [firstName, secondName] {
                let row = workflowRow(named: title, in: app)
                if row.exists {
                    row.rightClick()
                    let remove = app.menuItems["Delete workflow"]
                    if remove.exists { remove.click() }
                }
            }
        }
        app.descendants(matching: .any)["clipy.workflow.load"].click()
        app.menuItems["New workflow"].click()
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText(firstName)
        let literal = "  first line\n" + String(repeating: "long text to compare ", count: 8) + "\nlast line  "
        source.click()
        source.typeText(literal)

        // Adding another definition keeps the first unsaved definition and its
        // transient test input in this window. Neither source is persisted.
        app.descendants(matching: .any)["clipy.workflow.load"].click()
        app.menuItems["Notify about TODO"].click()
        XCTAssertTrue(app.staticTexts["If"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Then"].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["Otherwise"].exists, app.debugDescription)
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText(secondName)
        app.buttons["clipy.workflow.save"].click()
        XCTAssertTrue(waitUntil { !app.buttons["clipy.workflow.save"].isEnabled })
        let first = workflowRow(named: firstName, in: app)
        let second = workflowRow(named: secondName, in: app)
        XCTAssertTrue(first.exists && second.exists, app.debugDescription)
        first.click()
        XCTAssertTrue(waitUntil { name.value as? String == firstName && source.value as? String == literal }, app.debugDescription)
        XCTAssertTrue(app.buttons["clipy.workflow.save"].isEnabled)
        app.buttons["clipy.workflow.save"].click()
        clickPreview(in: app)
        let result = app.textViews["clipy.workflow.result"]
        XCTAssertTrue(waitUntil { result.value as? String == literal.trimmingCharacters(in: .whitespacesAndNewlines) }, app.debugDescription)
        XCTAssertEqual(source.frame.width, result.frame.width, accuracy: 1)
        XCTAssertEqual(source.frame.minY, result.frame.minY, accuracy: 1)
        let comparison = XCTAttachment(screenshot: app.screenshot())
        comparison.name = "Multiple workflows with aligned multiline before and after"
        comparison.lifetime = .keepAlways
        add(comparison)

        app.descendants(matching: .any)["clipy.workflow.actions"].click()
        app.menuItems["Move workflow down"].click()
        XCTAssertTrue(waitUntil { second.frame.minY < first.frame.minY }, app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { !source.exists && manage.isHittable })
        manage.click()
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertTrue(second.frame.minY < first.frame.minY, "Saved order must match automatic execution priority")
        let branches = XCTAttachment(screenshot: app.screenshot())
        branches.name = "Saved workflow priority with explicit If Then Otherwise branches"
        branches.lifetime = .keepAlways
        add(branches)
        // Both workflows are manual and no real notification is requested.
        // Remove the test definitions through the same visible library controls.
        for row in [first, second] {
            row.rightClick()
            app.menuItems["Delete workflow"].click()
        }
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    private func workflowRow(named name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                         "clipy.workflow.row.", name)).firstMatch
    }

    @MainActor
    private func clickPreview(in app: XCUIApplication) {
        let preview = app.buttons["clipy.workflow.preview"]
        XCTAssertTrue(waitUntil { preview.exists && preview.isEnabled && preview.isHittable },
                      "Preview must remain reachable within the display, including an attached Settings sheet.\n" + app.debugDescription)
        preview.click()
    }

    @MainActor
    private func openEditor(in app: XCUIApplication) {
        let edit = app.buttons["Edit Content"]
        XCTAssertTrue(waitUntil { edit.exists && edit.isHittable }, app.debugDescription)
        edit.click()
        XCTAssertTrue(app.buttons["clipy.editor.cancel"].waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    private func openWorkflowAndPreview(in app: XCUIApplication) {
        let workflow = app.buttons["clipy.editor.workflow.public.utf8-plain-text"]
        XCTAssertTrue(waitUntil { workflow.exists && workflow.isHittable && workflow.isEnabled }, app.debugDescription)
        workflow.click()
        let preview = app.buttons["clipy.workflow.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["clipy.workflow.apply"].isEnabled, app.debugDescription)
        clickPreview(in: app)
    }

    @MainActor
    private func copyDetailsAndAssert(_ expected: String, itemID: UUID, in app: XCUIApplication) throws {
        // Copy is in the persistent Details footer, outside the content Form.
        let copy = app.buttons["clipy.details.copy"]
        XCTAssertTrue(waitUntil { copy.exists && copy.isEnabled && copy.isHittable }, app.debugDescription)
        copy.click()
        let marker = NSPasteboard.PasteboardType("com.clipy.lineageHint")
        XCTAssertTrue(waitUntil {
            NSPasteboard.general.data(forType: .string) == Data(expected.utf8)
                && NSPasteboard.general.data(forType: marker) == Data(itemID.uuidString.utf8)
        }, app.debugDescription)
    }

    @MainActor
    private func reopenDetails(itemID: UUID, in app: XCUIApplication) {
        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        // The production Copy handoff dismisses the panel after success.
        XCTAssertTrue(waitUntil { !panel.exists }, app.debugDescription)
        app.typeKey("c", modifierFlags: [.command, .shift])
        let row = app.descendants(matching: .any)["clipy.history.row." + itemID.uuidString]
        XCTAssertTrue(waitUntil { row.exists && row.isHittable }, app.debugDescription)
        row.rightClick()
        let details = app.menuItems["Show Details"]
        XCTAssertTrue(details.waitForExistence(timeout: 5), app.debugDescription)
        details.click()
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipy-workflow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    private func launch(capturing text: String, directory: URL) -> XCUIApplication {
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setData(Data(text.utf8), forType: .string))
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("history.sqlite").path
        app.launch()
        return app
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }
}
