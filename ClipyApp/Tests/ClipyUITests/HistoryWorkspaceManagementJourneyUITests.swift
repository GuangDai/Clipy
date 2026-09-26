import AppKit
import HistoryCore
import HistoryStorage
import XCTest

/// Management runs through the real Settings controls. The larger paging
/// fixture uses the production writer before app launch, then relinquishes it;
/// no fake browse source or second live History writer participates in the UI.
final class HistoryWorkspaceManagementJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testNativeMultipleSelectionAndPageSelectionPinUnpinAndConfirmedRemoval() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("history.sqlite")
        let values = ["Workspace management alpha", "Workspace management beta", "Workspace management gamma"]
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString(values[0], forType: .string))
        let app = launch(storeURL: storeURL, captureAccess: "allowed")
        defer { app.terminate(); NSPasteboard.general.clearContents() }
        let workspace = openWorkspace(in: app)
        XCTAssertTrue(row(named: values[0], in: workspace).waitForExistence(timeout: 10), app.debugDescription)
        for value in values.dropFirst() {
            NSPasteboard.general.clearContents()
            XCTAssertTrue(NSPasteboard.general.setString(value, forType: .string))
            XCTAssertTrue(row(named: value, in: workspace).waitForExistence(timeout: 10), app.debugDescription)
        }

        let alpha = row(named: values[0], in: workspace)
        let beta = row(named: values[1], in: workspace)
        let gamma = row(named: values[2], in: workspace)
        alpha.click()
        assertSelectionCount(1, in: workspace, app: app)
        assertPreview(values[0], in: workspace, app: app)
        XCUIElement.perform(withKeyModifiers: .command) { beta.click() }
        assertSelectionCount(2, in: workspace, app: app)
        XCTAssertFalse(workspace.buttons["clipy.history.workspace.copy"].isEnabled,
                       "Multiple selection must not turn the single-item Copy action into bulk copying.")

        workspace.buttons["clipy.history.workspace.clear-selection"].click()
        gamma.click()
        XCUIElement.perform(withKeyModifiers: .shift) { alpha.click() }
        assertSelectionCount(3, in: workspace, app: app)
        workspace.buttons["clipy.history.workspace.clear-selection"].click()
        assertSelectionCount(0, in: workspace, app: app)

        let selectPage = workspace.buttons["clipy.history.workspace.select-page"]
        selectPage.click()
        assertSelectionCount(3, in: workspace, app: app)
        workspace.buttons["clipy.history.workspace.batch.pin"].click()
        assertBatchCompleted(3, operation: "Pin", in: workspace, app: app)
        assertPinState("Unpin", for: values, in: workspace, app: app)
        attachScreenshot(app, name: "History workspace after pinning three selected items")

        selectPage.click()
        assertSelectionCount(3, in: workspace, app: app)
        workspace.buttons["clipy.history.workspace.batch.unpin"].click()
        assertBatchCompleted(3, operation: "Unpin", in: workspace, app: app)
        assertPinState("Pin", for: values, in: workspace, app: app)

        selectPage.click()
        workspace.buttons["clipy.history.workspace.batch.remove"].click()
        let confirmation = app.sheets.containing(.button, identifier: "clipy.history.workspace.confirm-batch-remove").firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(confirmation.staticTexts["Remove 3 selected items?"].exists,
                      "The confirmation must disclose the selected count.\n" + app.debugDescription)
        confirmation.buttons["clipy.history.workspace.cancel-batch-remove"].click()
        XCTAssertTrue(waitUntil { !confirmation.exists }, app.debugDescription)
        assertSelectionCount(3, in: workspace, app: app)
        for value in values { XCTAssertTrue(row(named: value, in: workspace).exists, app.debugDescription) }

        workspace.buttons["clipy.history.workspace.batch.remove"].click()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5), app.debugDescription)
        confirmation.buttons["clipy.history.workspace.confirm-batch-remove"].click()
        assertBatchCompleted(3, operation: "Remove", in: workspace, app: app)
        XCTAssertTrue(waitUntil {
            values.allSatisfy { !self.row(named: $0, in: workspace).exists }
                && workspace.staticTexts["History is empty"].exists
        }, app.debugDescription)
        assertSelectionCount(0, in: workspace, app: app)
        XCTAssertFalse(workspace.buttons["clipy.history.workspace.copy"].isEnabled)
        XCTAssertTrue(workspace.exists, "Batch removal must keep the Settings workspace open.")

        // Terminating releases the app's Authority before checking durable
        // public History facts. A filtered/hidden row is not deletion evidence.
        app.terminate()
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .persistent(storeURL: storeURL)))
        let after = try await history.browse(.init(kind: .recent, limit: 50))
        XCTAssertTrue(after.rows.isEmpty)
        XCTAssertNil(after.next)
    }

    @MainActor
    func testGlobalSortAndExplicitPagesKeepTheVisiblePageAndPreviewPosition() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("history.sqlite")
        let fixtures = try await seedPagingHistory(at: storeURL)
        NSPasteboard.general.clearContents()
        let app = launch(storeURL: storeURL, captureAccess: "denied")
        defer { app.terminate(); NSPasteboard.general.clearContents() }
        let workspace = openWorkspace(in: app)
        let next = workspace.buttons["clipy.history.workspace.next"]
        let previous = workspace.buttons["clipy.history.workspace.previous"]
        XCTAssertTrue(waitUntil {
            let newest = self.row(for: fixtures[54].id, in: workspace)
            return newest.exists && newest.isHittable && next.isEnabled
        }, app.debugDescription)
        XCTAssertFalse(previous.isEnabled)
        workspace.buttons["clipy.history.workspace.select-page"].click()
        assertSelectionCount(50, in: workspace, app: app)

        next.click()
        assertPage(2, range: "Items 51–55", in: workspace, app: app)
        XCTAssertTrue(row(for: fixtures[4].id, in: workspace).isHittable, app.debugDescription)
        XCTAssertTrue(row(for: fixtures[0].id, in: workspace).isHittable, app.debugDescription)
        XCTAssertFalse(next.isEnabled)
        XCTAssertTrue(previous.isEnabled)
        workspace.buttons["clipy.history.workspace.select-page"].click()
        assertSelectionCount(5, in: workspace, app: app)

        chooseSort("Oldest copied first", in: workspace, app: app)
        assertPage(1, range: "Items 1–50", in: workspace, app: app)
        XCTAssertTrue(waitUntil {
            let oldest = self.row(for: fixtures[0].id, in: workspace)
            return oldest.exists && oldest.isHittable && next.isEnabled
        }, app.debugDescription)
        next.click()
        assertPage(2, range: "Items 51–55", in: workspace, app: app)
        let firstVisible = row(for: fixtures[50].id, in: workspace)
        let lastVisible = row(for: fixtures[54].id, in: workspace)
        XCTAssertTrue(firstVisible.isHittable && lastVisible.isHittable, app.debugDescription)
        XCTAssertLessThan(firstVisible.frame.minY, lastVisible.frame.minY)
        let position = firstVisible.frame.minY
        lastVisible.click()
        assertPreview(fixtures[54].text, in: workspace, app: app)
        assertPage(2, range: "Items 51–55", in: workspace, app: app)
        XCTAssertEqual(firstVisible.frame.minY, position, accuracy: 1,
                       "Selecting a later row must not move the page's reading position.")
        XCTAssertFalse(next.isEnabled)
        previous.click()
        assertPage(1, range: "Items 1–50", in: workspace, app: app)
        XCTAssertTrue(row(for: fixtures[0].id, in: workspace).isHittable, app.debugDescription)

        next.click()
        assertPage(2, range: "Items 51–55", in: workspace, app: app)
        chooseSort("Most copied first", in: workspace, app: app)
        XCTAssertTrue(waitUntil {
            let frequent = self.row(for: fixtures[22].id, in: workspace)
            return frequent.exists && frequent.isHittable
        }, app.debugDescription)
        let frequent = row(for: fixtures[22].id, in: workspace)
        let newest = row(for: fixtures[54].id, in: workspace)
        XCTAssertTrue(newest.isHittable, app.debugDescription)
        XCTAssertLessThan(frequent.frame.minY, newest.frame.minY,
                          "Global copy-count sorting must bring the frequent item from outside the previous page.")
        frequent.click()
        assertPreview(fixtures[22].text, in: workspace, app: app)
        attachScreenshot(app, name: "History workspace global sort, explicit page and fixed preview")
    }

    private struct PagingItem: Sendable {
        let id: HistoryItemID
        let text: String
    }

    /// The local facade ends here before XCUIApplication launches. Fixtures
    /// carry only public IDs/text; SQLite metadata and blob layout stay opaque.
    @MainActor
    private func seedPagingHistory(at storeURL: URL) async throws -> [PagingItem] {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .persistent(storeURL: storeURL)))
        let base = Date().addingTimeInterval(-1_000)
        var fixtures: [PagingItem] = []
        for index in 1...55 {
            let value = String(format: "Workspace page item %03d", index)
            let capture = ClipboardCapture(
                representations: [.init(typeIdentifier: "public.utf8-plain-text", bytes: Data(value.utf8))],
                origin: .init(sourceApplication: nil, lineageHint: nil), observedAt: base.addingTimeInterval(Double(index))
            )
            let receipt = try await history.perform(.capture(capture))
            let inserted: HistoryItemReference?
            if case .committed(let commit) = receipt, case .inserted(let reference) = commit.outcome { inserted = reference }
            else { inserted = nil }
            let reference = try XCTUnwrap(inserted, "Each distinct fixture must create a real History item.")
            fixtures.append(PagingItem(id: reference.id, text: value))
            if index == 23 {
                for copy in 1...3 {
                    _ = try await history.perform(.capture(.init(
                        representations: capture.representations, origin: capture.origin,
                        observedAt: base.addingTimeInterval(Double(index) + Double(copy) / 10)
                    )))
                }
            }
        }
        return fixtures
    }

    @MainActor
    private func launch(storeURL: URL, captureAccess: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-clipy.language", "en",
            "-clipy.browsing.remembersWorkspaceLayout", "NO", "-clipy.browsing.workspaceOpeningPosition", "latest",
        ]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = captureAccess
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = storeURL.path
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["clipy.panel.root"].waitForExistence(timeout: 20), app.debugDescription)
        return app
    }

    @MainActor
    private func openWorkspace(in app: XCUIApplication) -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let category = app.buttons["clipy.settings.category.history"]
        XCTAssertTrue(category.waitForExistence(timeout: 10), app.debugDescription)
        category.click()
        let workspace = app.descendants(matching: .any)["clipy.history.workspace"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 10), app.debugDescription)
        return workspace
    }

    @MainActor
    private func row(named value: String, in workspace: XCUIElement) -> XCUIElement {
        workspace.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "clipy.history.workspace.row.", value
        )).firstMatch
    }

    @MainActor
    private func row(for id: HistoryItemID, in workspace: XCUIElement) -> XCUIElement {
        workspace.descendants(matching: .any)["clipy.history.workspace.row." + id.description]
    }

    @MainActor
    private func assertSelectionCount(_ count: Int, in workspace: XCUIElement, app: XCUIApplication) {
        let value = workspace.descendants(matching: .any)["clipy.history.workspace.selection-count"]
        XCTAssertTrue(waitUntil { value.exists && value.label == "\(count) selected" }, app.debugDescription)
    }

    @MainActor
    private func assertPinState(_ label: String, for values: [String], in workspace: XCUIElement, app: XCUIApplication) {
        for value in values {
            let selected = row(named: value, in: workspace)
            XCTAssertTrue(waitUntil { selected.exists && selected.isHittable }, app.debugDescription)
            selected.click()
            assertPreview(value, in: workspace, app: app)
            let pin = workspace.buttons["clipy.history.workspace.pin"]
            XCTAssertTrue(waitUntil { pin.isEnabled && pin.label == label }, app.debugDescription)
        }
    }

    @MainActor
    private func assertBatchCompleted(_ count: Int, operation: String, in workspace: XCUIElement, app: XCUIApplication) {
        let summary = workspace.descendants(matching: .any)["clipy.history.workspace.batch.summary"]
        let expected = "Completed: \(count) · Failed: 0 · Not processed: 0"
        XCTAssertTrue(waitUntil {
            summary.exists && summary.label.contains(expected) && summary.value as? String == operation
                && workspace.buttons["clipy.history.workspace.select-page"].isEnabled
        }, app.debugDescription)
    }

    @MainActor
    private func assertPage(_ number: Int, range: String, in workspace: XCUIElement, app: XCUIApplication) {
        let page = workspace.descendants(matching: .any)["clipy.history.workspace.page-number"]
        let items = workspace.descendants(matching: .any)["clipy.history.workspace.page-range"]
        XCTAssertTrue(waitUntil { page.exists && items.exists && page.label == "Page \(number)" && items.label == range }, app.debugDescription)
    }

    @MainActor
    private func assertPreview(_ expected: String, in workspace: XCUIElement, app: XCUIApplication) {
        let preview = workspace.descendants(matching: .any)["clipy.history.workspace.preview"]
            .descendants(matching: .any)["clipy.preview.text"]
        XCTAssertTrue(waitUntil { preview.exists && ((preview.value as? String) ?? preview.label) == expected }, app.debugDescription)
    }

    @MainActor
    private func chooseSort(_ title: String, in workspace: XCUIElement, app: XCUIApplication) {
        let sort = workspace.popUpButtons["clipy.history.workspace.sort"]
        XCTAssertTrue(sort.exists && sort.isHittable, app.debugDescription)
        sort.click()
        app.menuItems[title].click()
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipy-history-management-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        if condition() { return true }
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }
}
