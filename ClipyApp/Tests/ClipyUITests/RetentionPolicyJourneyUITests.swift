/// RetentionPolicyJourneyUITests.swift — running-app proofs for the V2-02
/// Settings action. The R2 journey crosses a real General-pasteboard capture,
/// configured-policy read, destructive confirmation, receipt-derived feedback,
/// synchronous surface purge, and authoritative empty replacement. The R1
/// journey distinguishes a strict enable from a direct looser edit, then
/// reopens Settings to prove configured readback and the exact-value UI no-op.
/// The DEBUG launch seam changes only the store path and capture-access posture.
import AppKit
import XCTest

final class RetentionPolicyJourneyUITests: XCTestCase {
    private var temporaryDirectory: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    /// One ASCII representation contributes its UTF-8 length to R2. The
    /// short first line keeps the durable/AX title bounded while the second
    /// line makes the canonical representation unambiguously exceed 1 MiB.
    @MainActor
    func testStorageTighteningReportsRetirementAndPurgesThePanel() throws {
        let title = "clipy-retention-storage-large"
        let captured = title + "\n" + String(repeating: "x", count: 1_100_000)
        let app = try launchApp(capturing: captured)
        defer { app.terminate() }

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        let rows = historyRows(in: app)
        assertRowCount(1, in: rows, app: app, context: "large initial capture")
        XCTAssertTrue(
            rows.firstMatch.label.contains(title),
            diagnostic(app, context: "bounded large-capture row title")
        )

        openRetentionSettings(in: app)

        let storageEnabled = app.switches[
            "clipy.settings.retention.storage-enabled"
        ]
        assertExists(
            storageEnabled,
            timeout: 5,
            in: app,
            context: "storage policy toggle"
        )
        storageEnabled.click()

        let storageMiB = app.textFields[
            "clipy.settings.retention.storage-mib"
        ]
        assertExists(
            storageMiB,
            timeout: 5,
            in: app,
            context: "storage budget field"
        )
        replaceText(in: storageMiB, with: "1")

        let apply = app.buttons["clipy.settings.retention.apply"]
        assertExists(apply, timeout: 5, in: app, context: "policy Apply")
        XCTAssertTrue(
            waitUntil(timeout: 5) { apply.isEnabled },
            diagnostic(app, context: "loaded changed storage policy")
        )
        apply.click()

        let owningWindow = settingsWindow(
            in: app,
            owningTextField: "clipy.settings.retention.storage-mib"
        )
        confirmStrictPolicy(
            in: owningWindow,
            app: app,
            context: "storage tightening"
        )

        let policyStatus = app.descendants(matching: .any)[
            "clipy.settings.retention.policy-status"
        ]
        assertExists(
            policyStatus,
            timeout: 15,
            in: app,
            context: "storage receipt status"
        )
        XCTAssertTrue(
            app.staticTexts[
                "Done. 1 item retired, 0 revisions pruned."
            ].exists,
            diagnostic(app, context: "exact storage retirement receipt")
        )

        closeSettingsAndSummonPanel(
            field: storageMiB,
            panel: panel,
            app: app
        )
        assertRowCount(0, in: rows, app: app, context: "post-R2 panel purge")
        XCTAssertTrue(
            app.staticTexts["No Clipboard History"].waitForExistence(timeout: 5),
            diagnostic(app, context: "authoritative empty panel after R2")
        )
    }

    /// Enabling an absent age threshold is strict and must confirm. Raising
    /// 30 days to 31 is looser and therefore commits without a sheet. A later
    /// Settings appearance reads 31 back and offers no write for the exact
    /// configured value (`hasPolicyChanges == false`).
    @MainActor
    func testAgeTighteningThenLooseningReopensAsAnExactNoOp() throws {
        let app = try launchApp(capturing: "clipy-retention-age-current")
        defer { app.terminate() }

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        let rows = historyRows(in: app)
        assertRowCount(
            1,
            in: rows,
            app: app,
            context: "age journey initial capture"
        )
        openRetentionSettings(in: app)

        let ageEnabled = app.switches[
            "clipy.settings.retention.age-enabled"
        ]
        let ageDays = app.textFields[
            "clipy.settings.retention.age-days"
        ]
        assertExists(ageEnabled, timeout: 5, in: app, context: "age toggle")
        assertExists(ageDays, timeout: 5, in: app, context: "age field")
        XCTAssertEqual(
            ageDays.value as? String,
            "30",
            diagnostic(app, context: "default age draft")
        )
        ageEnabled.click()

        let apply = app.buttons["clipy.settings.retention.apply"]
        assertExists(apply, timeout: 5, in: app, context: "policy Apply")
        XCTAssertTrue(
            waitUntil(timeout: 5) { apply.isEnabled },
            diagnostic(app, context: "enabled strict age policy")
        )
        apply.click()

        let owningWindow = settingsWindow(
            in: app,
            owningTextField: "clipy.settings.retention.age-days"
        )
        confirmStrictPolicy(
            in: owningWindow,
            app: app,
            context: "age enable tightening"
        )

        let policyStatus = app.descendants(matching: .any)[
            "clipy.settings.retention.policy-status"
        ]
        assertExists(
            policyStatus,
            timeout: 10,
            in: app,
            context: "strict age receipt status"
        )
        XCTAssertTrue(
            app.staticTexts["Done."].exists,
            diagnostic(app, context: "strict age zero-effect receipt")
        )

        replaceText(in: ageDays, with: "31")
        XCTAssertTrue(
            waitUntil(timeout: 5) { !policyStatus.exists && apply.isEnabled },
            diagnostic(app, context: "new age edit clears success")
        )
        apply.click()

        // A strict path would be waiting in the attached sheet and could not
        // publish this status. Its return therefore proves the looser edit
        // crossed the direct Apply branch without timing a negative wait.
        assertExists(
            policyStatus,
            timeout: 10,
            in: app,
            context: "direct looser-age receipt status"
        )
        XCTAssertEqual(
            owningWindow.sheets.count,
            0,
            diagnostic(app, context: "looser age must not open confirmation")
        )
        XCTAssertTrue(
            app.staticTexts["Done."].exists,
            diagnostic(app, context: "looser age zero-effect receipt")
        )

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(
            waitUntil(timeout: 5) { !ageDays.exists },
            diagnostic(app, context: "close age Settings")
        )
        app.typeKey("c", modifierFlags: [.command, .shift])
        assertExists(panel, timeout: 10, in: app, context: "panel before readback")
        assertRowCount(
            1,
            in: rows,
            app: app,
            context: "current item survives both age-policy changes"
        )
        app.typeKey(",", modifierFlags: .command)
        openRetentionTab(in: app)

        let reopenedAgeEnabled = app.switches[
            "clipy.settings.retention.age-enabled"
        ]
        let reopenedAgeDays = app.textFields[
            "clipy.settings.retention.age-days"
        ]
        let reopenedApply = app.buttons["clipy.settings.retention.apply"]
        assertExists(
            reopenedAgeEnabled,
            timeout: 5,
            in: app,
            context: "reopened age toggle"
        )
        assertExists(
            reopenedAgeDays,
            timeout: 5,
            in: app,
            context: "reopened age field"
        )
        assertExists(
            reopenedApply,
            timeout: 5,
            in: app,
            context: "reopened policy Apply"
        )
        XCTAssertTrue(
            waitUntil(timeout: 10) {
                (reopenedAgeDays.value as? String) == "31"
                    && (reopenedAgeEnabled.value as? Int) == 1
                    && !reopenedApply.isEnabled
            },
            diagnostic(
                app,
                context: "persisted 31-day readback and exact-value no-op"
            )
        )
    }

    @MainActor
    private func launchApp(capturing value: String) throws -> XCUIApplication {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(value, forType: .string))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        temporaryDirectory = directory

        let app = XCUIApplication()
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory
            .appendingPathComponent("history.store")
            .path
        app.launch()

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        assertExists(panel, timeout: 20, in: app, context: "initial panel")
        return app
    }

    @MainActor
    private func openRetentionSettings(in app: XCUIApplication) {
        app.typeKey(",", modifierFlags: .command)
        openRetentionTab(in: app)
    }

    @MainActor
    private func openRetentionTab(in app: XCUIApplication) {
        let retentionTab = app.buttons["Retention"]
        assertExists(
            retentionTab,
            timeout: 10,
            in: app,
            context: "Settings Retention tab"
        )
        retentionTab.click()
    }

    @MainActor
    private func settingsWindow(
        in app: XCUIApplication,
        owningTextField identifier: String
    ) -> XCUIElement {
        let window = app.windows.containing(
            .textField,
            identifier: identifier
        ).firstMatch
        assertExists(
            window,
            timeout: 5,
            in: app,
            context: "Settings window owning \(identifier)"
        )
        return window
    }

    @MainActor
    private func confirmStrictPolicy(
        in settingsWindow: XCUIElement,
        app: XCUIApplication,
        context: String
    ) {
        // A global button-label query also sees the Touch Bar mirror on CI.
        let sheet = settingsWindow.sheets.firstMatch
        assertExists(sheet, timeout: 5, in: app, context: "\(context) sheet")
        let confirm = sheet.buttons["action-button-1"]
        assertExists(
            confirm,
            timeout: 5,
            in: app,
            context: "\(context) destructive action"
        )
        XCTAssertEqual(
            confirm.label,
            "Apply Stricter Limits",
            diagnostic(app, context: "\(context) action copy")
        )
        XCTAssertTrue(
            sheet.staticTexts[
                "Stricter limits can permanently remove items or revisions."
            ].exists,
            diagnostic(app, context: "\(context) disclosure")
        )
        confirm.click()
    }

    @MainActor
    private func closeSettingsAndSummonPanel(
        field: XCUIElement,
        panel: XCUIElement,
        app: XCUIApplication
    ) {
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(
            waitUntil(timeout: 5) { !field.exists },
            diagnostic(app, context: "Settings window close")
        )
        app.typeKey("c", modifierFlags: [.command, .shift])
        assertExists(panel, timeout: 10, in: app, context: "resummoned panel")
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with text: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    @MainActor
    private func historyRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "clipy.history.row."
            )
        )
    }

    @MainActor
    private func assertRowCount(
        _ expected: Int,
        in rows: XCUIElementQuery,
        app: XCUIApplication,
        context: String
    ) {
        XCTAssertTrue(
            waitUntil(timeout: 30) { rows.count == expected },
            diagnostic(
                app,
                context: "\(context); expected \(expected) rows, observed \(rows.count)"
            )
        )
    }

    @MainActor
    private func assertExists(
        _ element: XCUIElement,
        timeout: TimeInterval,
        in app: XCUIApplication,
        context: String
    ) {
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            diagnostic(app, context: context)
        )
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping () -> Bool
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() },
            object: nil
        )
        return XCTWaiter.wait(
            for: [expectation],
            timeout: timeout
        ) == .completed
    }

    @MainActor
    private func diagnostic(
        _ app: XCUIApplication,
        context: String
    ) -> String {
        "\(context)\n\(app.debugDescription)"
    }
}
