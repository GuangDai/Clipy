/// RetentionUsageJourneyUITests.swift — running-app proof that a Danger
/// Zone clear on the General tab cannot leave the Retention tab's
/// retained-usage row stale: re-entering the tab must re-read the now-empty
/// store (zero items, zero content bytes) instead of keeping the values
/// recorded before the clear. This pins 037178f's tab-lifecycle refresh
/// trigger, previously exercised only for the two Apply paths.
import AppKit
import XCTest

final class RetentionUsageJourneyUITests: XCTestCase {
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
    func testDangerZoneClearLeavesNoStaleRetainedUsage() throws {
        // The exact strings the count journey uses, so the populated usage
        // read ("2 items, 56 bytes") matches the storage accounting that
        // journey already proved on CI.
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
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(newest, forType: .string))
        assertRowCount(2, in: rows, app: app, context: "second capture")

        // Record the populated usage row on the Retention tab, then leave
        // the tab — its onDisappear clears the row and the next appearance
        // owns a fresh read.
        app.typeKey(",", modifierFlags: .command)
        let retentionTab = app.buttons["Retention"]
        assertExists(
            retentionTab,
            timeout: 10,
            in: app,
            context: "Settings Retention tab"
        )
        retentionTab.click()
        assertUsage(itemCount: "2", contentSize: "56 bytes", in: app)

        app.buttons["General"].click()
        // The Settings window on the General tab is anchored by the
        // Keyboard Shortcut section's Change button — the retention fields
        // are off-tab, and the runtime AX tree flattens the privacy
        // section's children under the section identifier, so only the
        // shortcut control survives as a stable interactive anchor here.
        let settingsWindow = app.windows.containing(
            .any,
            identifier: "clipy.settings.shortcut.change"
        ).firstMatch
        assertExists(
            settingsWindow,
            timeout: 10,
            in: app,
            context: "Settings window owning the Danger Zone"
        )

        // Danger Zone clear through its real destructive confirmation.
        let clearAll = app.buttons["Clear All History…"]
        assertExists(
            clearAll,
            timeout: 10,
            in: app,
            context: "Danger Zone Clear All History"
        )
        // The General tab's Form scrolls; bring the Danger Zone into view
        // the way ClipboardJourneyUITests scrolls the Retention Apply.
        let generalScrollView = settingsWindow.scrollViews.firstMatch
        assertExists(
            generalScrollView,
            timeout: 5,
            in: app,
            context: "General tab scroll view"
        )
        guard scrollUntilFullyVisible(
            clearAll,
            in: generalScrollView,
            app: app,
            context: "Danger Zone Clear All History"
        ) else { return }
        clearAll.click()
        // A global button-label query also sees the Touch Bar mirror on CI.
        let confirmationSheet = settingsWindow.sheets.firstMatch
        assertExists(
            confirmationSheet,
            timeout: 5,
            in: app,
            context: "attached clear-all confirmation sheet"
        )
        let confirm = confirmationSheet.buttons["action-button-1"]
        assertExists(
            confirm,
            timeout: 5,
            in: app,
            context: "destructive clear-all confirmation"
        )
        XCTAssertEqual(
            confirm.label,
            "Clear All History",
            diagnostic(app, context: "destructive clear-all confirmation copy")
        )
        confirm.click()
        XCTAssertTrue(
            waitUntil(timeout: 5) { !confirmationSheet.exists },
            diagnostic(app, context: "clear-all sheet dismisses after receipt")
        )
        // The sheet dismisses before the clear's Task completes; join the
        // receipt itself before re-entering the tab, so the tab's single
        // usage read cannot race the commit.
        XCTAssertTrue(
            app.staticTexts["Removed 2 items."].waitForExistence(timeout: 10),
            diagnostic(app, context: "exact clear-all receipt feedback")
        )

        // Re-entering the Retention tab must show the emptied store, not
        // the values recorded before the clear.
        retentionTab.click()
        assertUsage(itemCount: "0", contentSize: "0 bytes", in: app)
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
    private func assertUsage(itemCount: String, contentSize: String, in app: XCUIApplication) {
        let items = app.staticTexts["clipy.settings.usage.item-count"]
        let pinned = app.staticTexts["clipy.settings.usage.pinned-count"]
        let bytes = app.staticTexts["clipy.settings.usage.content-bytes"]
        // Foundation can use a nonbreaking space between quantity and unit;
        // compare the user-visible words without pinning that typography.
        func text(of element: XCUIElement) -> String {
            (element.value as? String ?? element.label)
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
        }
        XCTAssertTrue(
            waitUntil(timeout: 10) {
                items.exists && pinned.exists && bytes.exists
                    && text(of: items) == itemCount
                    && text(of: pinned) == "0"
                    && text(of: bytes) == contentSize
            },
            diagnostic(app, context: "retained usage: \(itemCount) items, 0 pinned, \(contentSize)")
        )
    }

    @MainActor
    private func scrollUntilFullyVisible(
        _ element: XCUIElement,
        in scrollView: XCUIElement,
        app: XCUIApplication,
        context: String
    ) -> Bool {
        let scrollCoordinate = scrollView.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        func isFullyVisible() -> Bool {
            element.exists
                && scrollView.frame.contains(element.frame)
                && element.isHittable
        }
        for _ in 0..<8 {
            if isFullyVisible() {
                return true
            }
            let deltaY: CGFloat = element.frame.midY < scrollView.frame.midY
                ? 50
                : -50
            scrollCoordinate.scroll(byDeltaX: 0, deltaY: deltaY)
        }
        let result = isFullyVisible()
        XCTAssertTrue(
            result,
            "\(context) did not scroll into view\n\(app.debugDescription)"
        )
        return result
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
