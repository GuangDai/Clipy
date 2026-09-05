/// RetentionCountJourneyUITests.swift — running-app proof that the unified
/// Retention surface sends the real v1 count action only after destructive
/// confirmation, clears accepted success on a newer edit, and reads the
/// committed value back after a same-store process restart. The DEBUG launch
/// seam changes only the store path and privacy posture; captures, retention
/// mutation, persistence, observation, and panel purge remain production paths.
import AppKit
import XCTest

final class RetentionCountJourneyUITests: XCTestCase {
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

    @MainActor
    func testCountTighteningCancelCommitDirtyResetAndRestartReadback() throws {
        let oldest = "clipy-retention-count-oldest"
        let newest = "clipy-retention-count-newest"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(oldest, forType: .string))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        temporaryDirectory = directory

        let storeURL = directory.appendingPathComponent("history.store")
        let app = launchApp(storeURL: storeURL)
        defer { app.terminate() }

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        assertExists(panel, timeout: 20, in: app, context: "initial panel")

        let rows = historyRows(in: app)
        assertRowCount(1, in: rows, app: app, context: "first capture")
        XCTAssertTrue(
            rows.firstMatch.label.contains(oldest),
            diagnostic(app, context: "oldest row label")
        )

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(newest, forType: .string))
        assertRowCount(2, in: rows, app: app, context: "second capture")
        let capturedLabels = rows.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(
            capturedLabels.contains(where: { $0.contains(oldest) })
                && capturedLabels.contains(where: { $0.contains(newest) }),
            diagnostic(app, context: "distinguishable captured rows")
        )

        app.typeKey(",", modifierFlags: .command)
        let retentionTab = app.buttons["Retention"]
        assertExists(
            retentionTab,
            timeout: 10,
            in: app,
            context: "Settings Retention tab"
        )
        retentionTab.click()

        let maximumUnpinned = app.textFields[
            "clipy.settings.retention.maximum-unpinned"
        ]
        assertExists(
            maximumUnpinned,
            timeout: 5,
            in: app,
            context: "maximum unpinned field"
        )
        maximumUnpinned.click()
        maximumUnpinned.typeKey("a", modifierFlags: .command)
        maximumUnpinned.typeText("1")

        let applyItemLimit = app.buttons[
            "clipy.settings.retention.apply-item-limit"
        ]
        assertExists(
            applyItemLimit,
            timeout: 5,
            in: app,
            context: "Apply Item Limit"
        )
        XCTAssertTrue(
            waitUntil(timeout: 5) { applyItemLimit.isEnabled },
            diagnostic(app, context: "loaded count configuration")
        )
        applyItemLimit.click()

        // Anchor to the Settings window that owns the edited field, then its
        // attached confirmation sheet. A global title query also sees the
        // Touch Bar mirror on CI and is therefore ambiguous.
        let settingsWindow = app.windows.containing(
            .textField,
            identifier: "clipy.settings.retention.maximum-unpinned"
        ).firstMatch
        assertExists(
            settingsWindow,
            timeout: 5,
            in: app,
            context: "Settings window owning count confirmation"
        )
        let confirmationSheet = settingsWindow.sheets.firstMatch
        assertExists(
            confirmationSheet,
            timeout: 5,
            in: app,
            context: "attached count confirmation sheet"
        )
        let confirm = confirmationSheet.buttons["action-button-1"]
        assertExists(
            confirm,
            timeout: 5,
            in: app,
            context: "destructive count confirmation"
        )
        XCTAssertEqual(
            confirm.label,
            "Apply Stricter Limit",
            diagnostic(app, context: "destructive count confirmation copy")
        )
        XCTAssertTrue(
            confirmationSheet.staticTexts[
                "A stricter limit can immediately remove unpinned items, and they can't be recovered."
            ].exists,
            diagnostic(app, context: "count confirmation disclosure")
        )

        let itemLimitStatus = app.descendants(matching: .any)[
            "clipy.settings.retention.item-limit-status"
        ]

        // Card 10D: dismissing the destructive confirmation must send no
        // History action. The real panel therefore still exposes both rows,
        // and no receipt-derived success can appear.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            waitUntil(timeout: 5) { !confirmationSheet.exists },
            diagnostic(app, context: "cancel count confirmation")
        )
        XCTAssertFalse(
            itemLimitStatus.exists,
            diagnostic(app, context: "cancel must not publish a receipt")
        )
        XCTAssertTrue(
            applyItemLimit.isEnabled,
            diagnostic(app, context: "canceled count draft remains applicable")
        )

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(
            waitUntil(timeout: 5) { !maximumUnpinned.exists },
            diagnostic(app, context: "Settings close after canceled count")
        )
        app.typeKey("c", modifierFlags: [.command, .shift])
        assertExists(
            panel,
            timeout: 10,
            in: app,
            context: "panel after canceled count confirmation"
        )
        assertRowCount(
            2,
            in: rows,
            app: app,
            context: "cancel before count mutation"
        )

        // Re-enter through the real Settings scene and submit the same draft.
        // A newly materialized view may show either its neutral prefill or the
        // prior unsaved text until the authoritative read lands, so write the
        // intended literal again instead of relying on scene retention.
        app.typeKey(",", modifierFlags: .command)
        assertExists(
            retentionTab,
            timeout: 10,
            in: app,
            context: "reopened Settings Retention tab"
        )
        retentionTab.click()
        assertExists(
            maximumUnpinned,
            timeout: 5,
            in: app,
            context: "reopened maximum unpinned field"
        )
        replaceText(in: maximumUnpinned, with: "1")
        XCTAssertTrue(
            waitUntil(timeout: 5) { applyItemLimit.isEnabled },
            diagnostic(app, context: "reopened count configuration")
        )
        applyItemLimit.click()
        assertExists(
            confirmationSheet,
            timeout: 5,
            in: app,
            context: "reopened count confirmation sheet"
        )
        let reopenedConfirm = confirmationSheet.buttons["action-button-1"]
        assertExists(
            reopenedConfirm,
            timeout: 5,
            in: app,
            context: "reopened destructive count confirmation"
        )
        XCTAssertEqual(
            reopenedConfirm.label,
            "Apply Stricter Limit",
            diagnostic(app, context: "reopened count confirmation copy")
        )
        reopenedConfirm.click()

        assertExists(
            itemLimitStatus,
            timeout: 10,
            in: app,
            context: "receipt-derived item-limit status"
        )
        XCTAssertTrue(
            app.staticTexts["Done. 1 item removed."].exists,
            diagnostic(app, context: "exact count receipt feedback")
        )

        // Card 10E: an accepted success belongs to exactly one edit
        // generation. A newer edit clears it immediately; restoring the exact
        // configured baseline disables Apply without resurrecting old success.
        replaceText(in: maximumUnpinned, with: "2")
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                !itemLimitStatus.exists && applyItemLimit.isEnabled
            },
            diagnostic(app, context: "new count edit clears accepted success")
        )
        replaceText(in: maximumUnpinned, with: "1")
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                !itemLimitStatus.exists && !applyItemLimit.isEnabled
            },
            diagnostic(app, context: "restored count baseline has no pending save")
        )

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(
            waitUntil(timeout: 5) { !maximumUnpinned.exists },
            diagnostic(app, context: "Settings window close")
        )
        app.typeKey("c", modifierFlags: [.command, .shift])
        assertExists(
            panel,
            timeout: 10,
            in: app,
            context: "panel after retention commit"
        )

        assertRowCount(1, in: rows, app: app, context: "post-retention panel")
        let remainingLabel = rows.firstMatch.label
        XCTAssertTrue(
            remainingLabel.contains(newest),
            diagnostic(app, context: "newest row retained")
        )
        XCTAssertFalse(
            remainingLabel.contains(oldest),
            diagnostic(app, context: "oldest row retired")
        )

        // Card 10A: discard every process-local Settings value and reopen the
        // same physical store. The new process must render the persisted count
        // through the public configured-policy read, with no dirty Apply, and
        // must observe the same retained survivor.
        app.terminate()
        let reopenedApp = launchApp(storeURL: storeURL)
        defer { reopenedApp.terminate() }

        let reopenedPanel = reopenedApp.descendants(matching: .any)[
            "clipy.panel.root"
        ]
        assertExists(
            reopenedPanel,
            timeout: 20,
            in: reopenedApp,
            context: "same-store restarted panel"
        )
        let reopenedRows = historyRows(in: reopenedApp)
        assertRowCount(
            1,
            in: reopenedRows,
            app: reopenedApp,
            context: "same-store restarted survivor"
        )
        let restartedLabel = reopenedRows.firstMatch.label
        XCTAssertTrue(
            restartedLabel.contains(newest),
            diagnostic(reopenedApp, context: "same-store newest survivor")
        )
        XCTAssertFalse(
            restartedLabel.contains(oldest),
            diagnostic(reopenedApp, context: "same-store retired row absent")
        )

        reopenedApp.typeKey(",", modifierFlags: .command)
        let reopenedRetentionTab = reopenedApp.buttons["Retention"]
        assertExists(
            reopenedRetentionTab,
            timeout: 10,
            in: reopenedApp,
            context: "same-store Settings Retention tab"
        )
        reopenedRetentionTab.click()
        let readbackField = reopenedApp.textFields[
            "clipy.settings.retention.maximum-unpinned"
        ]
        assertExists(
            readbackField,
            timeout: 5,
            in: reopenedApp,
            context: "same-store maximum unpinned readback field"
        )
        let readbackApply = reopenedApp.buttons[
            "clipy.settings.retention.apply-item-limit"
        ]
        assertExists(
            readbackApply,
            timeout: 5,
            in: reopenedApp,
            context: "same-store Apply Item Limit"
        )
        XCTAssertTrue(
            waitUntil(timeout: 10) {
                readbackField.value as? String == "1"
                    && !readbackApply.isEnabled
            },
            diagnostic(
                reopenedApp,
                context: "same-store authoritative count readback"
            )
        )
        XCTAssertFalse(
            reopenedApp.descendants(matching: .any)[
                "clipy.settings.retention.item-limit-status"
            ].exists,
            diagnostic(reopenedApp, context: "restart carries no stale success")
        )
    }

    @MainActor
    private func launchApp(storeURL: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = storeURL.path
        app.launch()
        return app
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with value: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(value)
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
            waitUntil(timeout: 10) { rows.count == expected },
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
