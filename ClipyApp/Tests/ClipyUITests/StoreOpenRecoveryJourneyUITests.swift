/// DATA-14 running-app recovery acceptance. One real app launch fails its
/// real persistent `AppComposition` open because a regular file occupies the
/// configured store directory. The journey observes and drives the actual
/// SwiftUI failure controls, then removes only that test-owned external
/// obstacle and proves Retry opens the same locator into the real History
/// panel, then a new General-pasteboard generation appears as a real row and
/// application-directed typing reaches the focused search field without a
/// click or reopen. Reveal replaces Finder only at the final DEBUG boundary
/// with a fixed-name, empty, no-overwrite marker; there is no private AX lookup
/// or arbitrary sleep.
import AppKit
import XCTest

final class StoreOpenRecoveryJourneyUITests: XCTestCase {
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
    func testFailureControlsRevealThenRetryTheSameStoreLocator() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "clipy-running-store-recovery-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: fixtureRoot,
            withIntermediateDirectories: true
        )
        temporaryDirectory = fixtureRoot

        let blockedDirectory = fixtureRoot.appendingPathComponent(
            "HistoryStore",
            isDirectory: true
        )
        try Data("not a directory".utf8).write(to: blockedDirectory)
        let storeURL = blockedDirectory.appendingPathComponent("history.store")
        let revealMarkerURL = fixtureRoot.appendingPathComponent(
            "clipy-store-reveal.marker"
        )

        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = storeURL.path
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launchEnvironment[
            "CLIPY_UI_TEST_STORE_REVEAL_MARKER_PATH"
        ] = revealMarkerURL.path
        app.launch()

        let failure = app.descendants(matching: .any)[
            "clipy.store.open.failure"
        ]
        XCTAssertTrue(
            failure.waitForExistence(timeout: 20),
            diagnostic(app, context: "store-open failure pane")
        )
        let category = app.descendants(matching: .any)[
            "clipy.store.open.failure.category"
        ]
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        XCTAssertEqual(accessibilityText(of: category), "History Store Open Failed")

        let retry = app.buttons["clipy.store.open.failure.retry"]
        let reveal = app.buttons["clipy.store.open.failure.reveal"]
        let quit = app.buttons["clipy.store.open.failure.quit"]
        for (button, label) in [
            (retry, "Retry"),
            (reveal, "Reveal Store Location"),
            (quit, "Quit"),
        ] {
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            XCTAssertTrue(button.isHittable)
            XCTAssertEqual(button.label, label)
        }

        reveal.click()
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                FileManager.default.fileExists(atPath: revealMarkerURL.path)
            },
            "Reveal control did not cross the content-free DEBUG boundary."
        )
        XCTAssertEqual(try Data(contentsOf: revealMarkerURL), Data())
        XCTAssertTrue(failure.exists)

        // The app's second publication attempt must not replace an existing
        // marker. This sentinel is test-authored; production writes no bytes.
        let noOverwriteSentinel = Data("test-owned-sentinel".utf8)
        try noOverwriteSentinel.write(to: revealMarkerURL)
        reveal.click()
        XCTAssertEqual(
            try Data(contentsOf: revealMarkerURL),
            noOverwriteSentinel
        )

        // The failed open has no live ModelContainer. Remove only the
        // test-owned obstacle, then drive the visible product Retry control.
        try FileManager.default.removeItem(at: blockedDirectory)
        retry.click()

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        XCTAssertTrue(
            panel.waitForExistence(timeout: 20),
            diagnostic(app, context: "History panel after store Retry")
        )
        let search = app.textFields["clipy.search.field"]
        XCTAssertTrue(
            search.waitForExistence(timeout: 10),
            diagnostic(app, context: "authoritative History surface after Retry")
        )
        XCTAssertFalse(failure.exists)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: blockedDirectory.path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(
            isDirectory.boolValue,
            "Retry did not recreate the exact configured store directory."
        )

        // A view shell alone is insufficient: publish a new, unique General
        // pasteboard generation after Retry and require its real History row.
        // This proves the recovered view state activated its observation.
        let query = "clipy-retry-query-\(UUID().uuidString)"
        let captured = "\(query)-captured"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(captured, forType: .string))
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "clipy.history.row."
            )
        )
        XCTAssertTrue(
            waitUntil(timeout: 10) {
                rows.allElementsBoundByIndex.contains {
                    $0.label.contains(captured)
                }
            },
            diagnostic(app, context: "post-Retry observed History row")
        )

        // Do not click or focus any element. `beginSession` advances the
        // surface generation that makes HistoryPanelView's session task focus
        // Search. Typing through XCUIApplication therefore pins the missing
        // panel-session half separately from the observed-row proof above.
        app.typeText(query)
        XCTAssertTrue(
            waitUntil(timeout: 10) {
                (search.value as? String) == query
                    && rows.count == 1
                    && rows.element(boundBy: 0).label.contains(captured)
            },
            diagnostic(
                app,
                context: "post-Retry session focus and filtered History row"
            )
        )
    }

    @MainActor
    private func accessibilityText(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty {
            return value
        }
        return element.label
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
    private func diagnostic(_ app: XCUIApplication, context: String) -> String {
        "\(context)\n\(app.debugDescription)"
    }
}
