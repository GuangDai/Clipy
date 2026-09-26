import AppKit
import XCTest

/// Uses the actual Open/Save panels and the visible library. The import file
/// deliberately reuses a saved workflow ID: admission must still create a
/// separate manual draft and exporting must omit transient test content.
final class BuiltInAutomationTransferJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testNativeImportReviewCancelAndExportKeepDefinitionsSeparateFromTestInput() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipy-workflow-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suffix = String(UUID().uuidString.prefix(8))
        let originalName = "Original transfer \(suffix)"
        let importedName = "Imported transfer \(suffix)"
        let originalInput = "  original temporary input \(suffix)  "
        let importedInput = "private transfer input \(suffix)"
        let clipboard = "clipboard unchanged by workflow transfer \(suffix)"
        let app = launch(directory: directory, clipboard: clipboard)
        defer { app.terminate(); NSPasteboard.general.clearContents() }
        let manage = openWorkflows(in: app)
        let name = app.textFields["clipy.workflow.name"]
        let source = app.textViews["clipy.workflow.source"]
        var createdIdentifiers: [String] = []
        defer {
            // Only this test's UUID-identified definitions are removed.
            // A failed file-panel assertion must not issue clicks through a
            // still-present native dialog into the underlying library.
            if name.exists && name.isHittable {
                for identifier in createdIdentifiers {
                    let row = app.buttons[identifier]
                    if row.exists && row.isHittable { delete(row, in: app) }
                }
            }
        }

        app.descendants(matching: .any)["clipy.workflow.load"].click()
        app.menuItems["New workflow"].click()
        XCTAssertTrue(name.waitForExistence(timeout: 5), app.debugDescription)
        replaceText(of: name, with: originalName)
        replaceText(of: source, with: originalInput)
        let save = app.buttons["clipy.workflow.save"]
        save.click()
        XCTAssertTrue(waitUntil { !save.isEnabled }, app.debugDescription)
        let originalRow = workflowRow(named: originalName, in: app)
        XCTAssertTrue(originalRow.waitForExistence(timeout: 5), app.debugDescription)
        let originalIdentifier = originalRow.identifier
        createdIdentifiers.append(originalIdentifier)
        let originalID = try XCTUnwrap(UUID(uuidString: String(originalIdentifier.dropFirst("clipy.workflow.row.".count))))
        let stepID = UUID()
        let inputFile = directory.appendingPathComponent("imported-definition.json")
        try fixtureData(id: originalID, stepID: stepID, name: importedName).write(to: inputFile, options: .atomic)

        // Cancelling the review does not admit a draft, save a definition,
        // switch selection or discard the selected workflow's test input.
        importFile(inputFile, in: app)
        let review = app.descendants(matching: .any)["clipy.workflow.import.review"]
        XCTAssertTrue(review.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts[importedName].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["New copies automatically"].exists, app.debugDescription)
        let cancelReview = app.buttons["clipy.workflow.import.cancel"]
        XCTAssertTrue(cancelReview.isHittable, app.debugDescription)
        cancelReview.click()
        XCTAssertTrue(waitUntil { !review.exists && name.isHittable }, app.debugDescription)
        XCTAssertEqual(name.value as? String, originalName)
        XCTAssertEqual(source.value as? String, originalInput)
        XCTAssertFalse(workflowRow(named: importedName, in: app).exists)
        XCTAssertFalse(save.isEnabled)

        importFile(inputFile, in: app)
        XCTAssertTrue(review.waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["clipy.workflow.import.confirm"].click()
        XCTAssertTrue(waitUntil {
            !review.exists && name.value as? String == importedName && save.isEnabled
        }, app.debugDescription)
        let importedRow = workflowRow(named: importedName, in: app)
        XCTAssertTrue(importedRow.waitForExistence(timeout: 5), app.debugDescription)
        let importedIdentifier = importedRow.identifier
        createdIdentifiers.append(importedIdentifier)
        XCTAssertNotEqual(importedIdentifier, originalIdentifier)
        XCTAssertTrue(app.buttons[originalIdentifier].exists, app.debugDescription)
        XCTAssertEqual(source.value as? String, "", "Import must not inherit another workflow's temporary input")
        let status = app.staticTexts["clipy.workflow.save-status"]
        XCTAssertTrue(waitUntil {
            (status.value as? String ?? status.label)
                == "Workflow imported as a manual draft. Review and save it when ready."
        }, app.debugDescription)

        let scopeTab = app.descendants(matching: .any)["clipy.workflow.configuration.scope"]
        XCTAssertTrue(scopeTab.waitForExistence(timeout: 5), app.debugDescription)
        scopeTab.click()
        let trigger = app.popUpButtons["clipy.workflow.trigger"]
        XCTAssertTrue(trigger.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(trigger.value as? String, "Manual only", app.debugDescription)
        replaceText(of: source, with: importedInput)
        save.click()
        XCTAssertTrue(waitUntil { !save.isEnabled }, app.debugDescription)

        let preview = app.buttons["clipy.workflow.preview"]
        XCTAssertTrue(waitUntil { preview.isHittable && preview.isEnabled }, app.debugDescription)
        preview.click()
        let result = app.textViews["clipy.workflow.result"]
        XCTAssertTrue(waitUntil { result.value as? String == importedInput.uppercased() }, app.debugDescription)
        let outputFile = directory.appendingPathComponent("exported-definition.json")
        exportFile(outputFile, workflowName: importedName, in: app)
        XCTAssertTrue(waitUntil { FileManager.default.fileExists(atPath: outputFile.path) }, app.debugDescription)
        let exported = try Data(contentsOf: outputFile)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["format", "version", "workflow"])
        XCTAssertEqual(object["format"] as? String, "com.clipy.workflow")
        XCTAssertEqual(object["version"] as? Int, 1)
        let definition = try XCTUnwrap(object["workflow"] as? [String: Any])
        XCTAssertEqual(Set(definition.keys), ["id", "name", "steps", "trigger", "scope"])
        XCTAssertEqual(definition["name"] as? String, importedName)
        XCTAssertEqual(definition["trigger"] as? String, "manual")
        XCTAssertEqual(definition["id"] as? String, String(importedIdentifier.dropFirst("clipy.workflow.row.".count)))
        let steps = try XCTUnwrap(definition["steps"] as? [[String: Any]])
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps.first?["operation"] as? String, "uppercase")
        XCTAssertNotEqual(steps.first?["id"] as? String, stepID.uuidString)
        let bytesAsText = String(decoding: exported, as: UTF8.self)
        for temporaryText in [originalInput, importedInput, importedInput.uppercased(), clipboard] {
            XCTAssertFalse(bytesAsText.contains(temporaryText), "Export must contain only the definition")
        }
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), clipboard)
        XCTAssertTrue(waitUntil {
            (status.value as? String ?? status.label)
                == "Workflow exported. Test input and results were not included."
        }, app.debugDescription)

        // Reopening reconstructs the library from saved definitions, proving
        // the colliding import did not merely preserve the original as a draft.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { !name.exists && manage.isHittable }, app.debugDescription)
        manage.click()
        XCTAssertTrue(name.waitForExistence(timeout: 5), app.debugDescription)
        for identifier in [originalIdentifier, importedIdentifier] {
            let row = app.buttons[identifier]
            XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
            row.click()
            XCTAssertTrue(waitUntil { !save.isEnabled && source.value as? String == "" }, app.debugDescription)
            XCTAssertEqual(name.value as? String, identifier == originalIdentifier ? originalName : importedName)
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Imported manual workflow retained beside its original"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func fixtureData(id: UUID, stepID: UUID, name: String) throws -> Data {
        // A user-authored, pretty-printed file exercises the external format,
        // independently of the app's encoder and the evolving condition DSL.
        let step: [String: Any] = [
            "id": stepID.uuidString, "operation": "uppercase", "enabled": true,
            "find": "", "replacement": "", "condition": "containsText",
            "thenSteps": [], "otherwiseSteps": [],
        ]
        let scope: [String: Any] = [
            "source": "input", "applications": "", "historyLimit": 100,
            "timeRange": "any", "startDate": 0, "endDate": 0,
        ]
        let workflow: [String: Any] = [
            "id": id.uuidString, "name": name, "trigger": "newCopies",
            "scope": scope, "steps": [step],
        ]
        let contents: [String: Any] = ["format": "com.clipy.workflow", "version": 1, "workflow": workflow]
        return try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    }

    @MainActor
    private func importFile(_ url: URL, in app: XCUIApplication) {
        app.descendants(matching: .any)["clipy.workflow.load"].click()
        let action = app.menuItems["Import workflow…"]
        XCTAssertTrue(action.waitForExistence(timeout: 5), app.debugDescription)
        action.click()
        let open = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "Import"])).firstMatch
        XCTAssertTrue(waitUntil { open.exists && open.isHittable }, app.debugDescription)
        goToPath(url.path, in: app)
        XCTAssertTrue(waitUntil { open.exists && open.isHittable && open.isEnabled }, app.debugDescription)
        open.click()
    }

    @MainActor
    private func exportFile(_ url: URL, workflowName: String, in app: XCUIApplication) {
        app.descendants(matching: .any)["clipy.workflow.actions"].click()
        let action = app.menuItems["Export workflow…"]
        XCTAssertTrue(action.waitForExistence(timeout: 5), app.debugDescription)
        action.click()
        let save = app.buttons.matching(NSPredicate(format: "label IN %@", ["Save", "Export"])).firstMatch
        XCTAssertTrue(waitUntil { save.exists && save.isHittable }, app.debugDescription)
        // Find the native filename field by its proposed filename instead of
        // depending on an undocumented AppKit accessibility identifier.
        let filename = app.textFields.matching(NSPredicate(
            format: "value BEGINSWITH %@ AND identifier != %@", workflowName, "clipy.workflow.name"
        )).firstMatch
        XCTAssertTrue(filename.waitForExistence(timeout: 5), app.debugDescription)
        replaceText(of: filename, with: url.lastPathComponent)
        goToPath(url.deletingLastPathComponent().path, in: app)
        XCTAssertTrue(waitUntil { save.exists && save.isHittable && save.isEnabled }, app.debugDescription)
        save.click()
    }

    @MainActor
    private func goToPath(_ path: String, in app: XCUIApplication) {
        // This is the native Open/Save panel's Go to Folder keyboard path.
        // The caller checks the native action becomes available again before
        // submitting the chosen file or destination.
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeKey("a", modifierFlags: .command)
        app.typeText(path)
        app.typeKey(.return, modifierFlags: [])
    }

    @MainActor
    private func openWorkflows(in app: XCUIApplication) -> XCUIElement {
        XCTAssertTrue(app.descendants(matching: .any)["clipy.panel.root"].waitForExistence(timeout: 20), app.debugDescription)
        app.typeKey(",", modifierFlags: .command)
        let automation = app.buttons["clipy.settings.category.automation"]
        XCTAssertTrue(automation.waitForExistence(timeout: 10), app.debugDescription)
        automation.click()
        let manage = app.buttons["clipy.settings.workflows.manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5), app.debugDescription)
        SettingsJourneyControls.scroll(manage, into: app.scrollViews.containing(.any, identifier: manage.identifier).firstMatch, app: app)
        manage.click()
        XCTAssertTrue(app.textFields["clipy.workflow.name"].waitForExistence(timeout: 5), app.debugDescription)
        return manage
    }

    @MainActor
    private func replaceText(of field: XCUIElement, with value: String) {
        XCTAssertTrue(field.isHittable)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(value)
    }

    @MainActor
    private func workflowRow(named name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                         "clipy.workflow.row.", name)).firstMatch
    }

    @MainActor
    private func delete(_ row: XCUIElement, in app: XCUIApplication) {
        row.rightClick()
        let remove = app.menuItems["Delete workflow"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5), app.debugDescription)
        remove.click()
        let confirm = app.buttons["clipy.workflow.confirm-delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        confirm.click()
        XCTAssertTrue(waitUntil { !row.exists }, app.debugDescription)
    }

    @MainActor
    private func launch(directory: URL, clipboard: String) -> XCUIApplication {
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString(clipboard, forType: .string))
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
