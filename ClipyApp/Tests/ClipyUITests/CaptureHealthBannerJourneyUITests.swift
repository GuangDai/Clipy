/// CaptureHealthBannerJourneyUITests.swift — running-app materialization
/// evidence for REVIEW Card 6's content-free capture-health banner. A real
/// two-item General pasteboard generation enters the production observer's
/// unsupported-shape outcome; XCUI then reads and presses the rendered
/// SwiftUI control in Clipy's actual floating panel.
import AppKit
import XCTest

final class CaptureHealthBannerJourneyUITests: XCTestCase {
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

    /// Dismissal is scoped to one cumulative health episode. Re-rendering and
    /// repeated polling of the same pasteboard generation must leave it
    /// hidden; a later independently observed unsupported generation must
    /// materialize the banner again even though its typed failure is equal.
    @MainActor
    func testDismissedEpisodeStaysHiddenUntilANewerEpisode() throws {
        let app = try launchApp(capturing: "clipy-ui-health-valid-seed")
        defer { app.terminate() }

        let expectedMessage =
            "Clipy can't save multiple clipboard items yet. Copy one item at a time."
        let banner = app.descendants(matching: .any)[
            "clipy.capture.notice.banner"
        ]
        let message = app.descendants(matching: .any)[
            "clipy.capture.notice.message"
        ]
        let dismiss = app.buttons["clipy.capture.notice.dismiss"]

        stageUnsupportedGeneration(suffix: "first")
        XCTAssertTrue(
            banner.waitForExistence(timeout: 10),
            "The first unsupported generation did not materialize its banner."
        )
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertEqual(accessibilityText(of: message), expectedMessage)
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        XCTAssertTrue(dismiss.isHittable)
        XCTAssertEqual(dismiss.label, "Dismiss capture warning")
        dismiss.click()

        XCTAssertTrue(
            waitUntil(timeout: 5) { !banner.exists },
            "Dismiss did not remove the materialized capture warning."
        )
        assertRemains(
            { !banner.exists },
            duration: 1,
            message: "The dismissed warning reappeared in the same episode."
        )

        stageUnsupportedGeneration(suffix: "second")
        XCTAssertTrue(
            banner.waitForExistence(timeout: 10),
            "A later equal failure episode did not republish the banner."
        )
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertEqual(accessibilityText(of: message), expectedMessage)
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        XCTAssertTrue(dismiss.isHittable)
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
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory
            .appendingPathComponent("history.store")
            .path
        app.launch()

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        XCTAssertTrue(panel.waitForExistence(timeout: 20))
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "clipy.history.row."
            )
        )
        XCTAssertTrue(
            waitUntil(timeout: 10) { rows.count == 1 },
            "The running composition did not capture its valid seed."
        )
        return app
    }

    @MainActor
    private func stageUnsupportedGeneration(suffix: String) {
        let first = NSPasteboardItem()
        let second = NSPasteboardItem()
        XCTAssertTrue(
            first.setString(
                "clipy-ui-health-\(suffix)-alpha",
                forType: .string
            )
        )
        XCTAssertTrue(
            second.setString(
                "clipy-ui-health-\(suffix)-beta",
                forType: .string
            )
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([first, second]))
    }

    @MainActor
    private func accessibilityText(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty {
            return value
        }
        return element.label
    }

    @MainActor
    private func assertRemains(
        _ condition: @escaping () -> Bool,
        duration: TimeInterval,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            waitUntil(timeout: duration) { !condition() },
            message,
            file: file,
            line: line
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
}
