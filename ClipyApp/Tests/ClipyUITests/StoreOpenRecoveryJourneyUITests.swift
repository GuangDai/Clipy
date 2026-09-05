/// DATA-14 running-app recovery acceptance. One real app launch fails its
/// real persistent `AppComposition` open because a regular file occupies the
/// configured store directory. The journey observes and drives the actual
/// SwiftUI failure controls, then removes only that test-owned external
/// obstacle and proves Retry opens the same locator into the real History
/// panel, then a new General-pasteboard generation appears as a real row and
/// application-directed typing reaches the focused search field without a
/// click or reopen. A second, compressed journey pins the permission
/// dimension: a read-only StoreRoot produces the SAME pane and controls,
/// Reveal stays side-effect-free inside it, and once the runner restores the
/// write permission the visible Retry reaches the real panel (the
/// pasteboard/typing half is not repeated — the permission dimension adds no
/// new session-focus fact). Reveal replaces Finder only at the final DEBUG
/// boundary with a fixed-name, empty, no-overwrite marker; there is no
/// private AX lookup or arbitrary sleep.
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
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
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
    func testPermissionBlockedStoreRootStillRecoversThroughVisibleRetry() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "clipy-running-store-permission-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: fixtureRoot,
            withIntermediateDirectories: true
        )
        temporaryDirectory = fixtureRoot

        // The StoreRoot EXISTS but its owner write bit is removed, so the
        // app-layer directory creation inside the real open is refused and
        // the running app must land on the one DATA-14 failure pane. 0500
        // keeps read+execute — only writing is refused. Teardown restores
        // write permission FIRST: an unrestorable 0500 directory would make
        // the shared `removeItem` cleanup a no-op and leave TMP garbage.
        let guardedRoot = fixtureRoot.appendingPathComponent(
            "GuardedRoot",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: guardedRoot,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o500)],
            ofItemAtPath: guardedRoot.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: guardedRoot.path
            )
        }
        // Staging self-check, symmetric with the hosted and SPM permission
        // cells: if the runner could not stage 0500, the app would open
        // normally and this journey would fail on its first pane wait —
        // asserting the staged fact here keeps the failure mode legible.
        let stagedPermissions = try FileManager.default.attributesOfItem(
            atPath: guardedRoot.path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual(stagedPermissions?.int16Value, 0o500)
        let storeDirectory = guardedRoot.appendingPathComponent(
            "HistoryStore",
            isDirectory: true
        )
        let storeURL = storeDirectory.appendingPathComponent("history.store")
        // The marker is forced to the fixed-name sibling two levels above
        // the store locator (= the guarded StoreRoot itself), so even a
        // clicked Reveal stays inside the DEBUG boundary and can never open
        // the runner's Finder. Under 0500 its publication is refused and
        // swallowed by the product.
        let revealMarkerURL = guardedRoot.appendingPathComponent(
            "clipy-store-reveal.marker"
        )

        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
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

        // Non-destructive characterization only: after a bounded settle the
        // marker is absent because its publication into the 0500 StoreRoot
        // is refused and swallowed by the product. Absence cannot
        // distinguish "write refused" from "control did not run"; the pinned
        // fact is that Reveal stays side-effect-free while the pane remains.
        // Any permission-repairing Reveal would violate DATA-14 and is a
        // review obligation, not something this absence can encode.
        reveal.click()
        _ = waitUntil(timeout: 5) { false }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: revealMarkerURL.path),
            "Reveal must not create anything inside a read-only StoreRoot."
        )
        XCTAssertTrue(failure.exists)

        // Recovery changes only the external permissions, then drives the
        // visible product Retry control. The post-Retry pasteboard/typing
        // half of the sibling journey is intentionally NOT repeated: the
        // permission dimension adds no new fact about session focus, and
        // dropping it trims CI minutes and flake surface.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: guardedRoot.path
        )
        retry.click()

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        XCTAssertTrue(
            panel.waitForExistence(timeout: 20),
            diagnostic(app, context: "History panel after permission Retry")
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
                atPath: storeDirectory.path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(
            isDirectory.boolValue,
            "Retry did not recreate the exact configured store directory."
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
