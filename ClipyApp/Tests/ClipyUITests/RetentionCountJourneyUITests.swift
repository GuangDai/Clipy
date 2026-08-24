/// RetentionCountJourneyUITests.swift — running-app proof that the unified
/// Retention surface sends the real v1 count action, renders its exact
/// receipt-derived removal count, and returns to an authoritative panel with
/// the retired row gone. The DEBUG launch seam changes only the store path and
/// privacy posture; both captures, retention mutation, observation, and panel
/// purge remain production paths.
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
    func testCountTighteningReportsOneRemovalAndKeepsOnlyNewestRow() throws {
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

        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory
            .appendingPathComponent("history.store")
            .path
        app.launch()

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

        // The destructive copy is itself part of the confirmation contract;
        // query it by that exact user-visible label as the existing Settings
        // running-app journey does for the sibling policy confirmation.
        let confirm = app.buttons["Apply Stricter Limit"]
        assertExists(
            confirm,
            timeout: 5,
            in: app,
            context: "destructive count confirmation"
        )
        XCTAssertTrue(
            app.staticTexts[
                "A stricter limit can immediately remove unpinned items, and they can't be recovered."
            ].exists,
            diagnostic(app, context: "count confirmation disclosure")
        )
        confirm.click()

        let itemLimitStatus = app.descendants(matching: .any)[
            "clipy.settings.retention.item-limit-status"
        ]
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
