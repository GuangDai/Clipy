/// ClipboardJourneyUITests.swift — the first Card 15 running-app vertical
/// tracer. The DEBUG launch seam changes only the store path and privacy
/// posture; capture, search, keyboard selection, paste payload resolution,
/// General pasteboard write, and panel close remain production paths.
import AppKit
import XCTest

final class ClipboardJourneyUITests: XCTestCase {
    private var temporaryDirectory: URL?

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testSummonSearchArrowReturnWritesGeneralPasteboardAndCloses() throws {
        let alpha = "clipy-ui-journey-alpha"
        let beta = "clipy-ui-journey-beta"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(alpha, forType: .string))

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
        XCTAssertTrue(panel.waitForExistence(timeout: 20))

        let search = app.textFields["clipy.search.field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(search.hasKeyboardFocus)

        let rows = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "clipy.history.row."
            )
        )
        XCTAssertTrue(waitUntil(timeout: 10) { rows.count == 1 })

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(beta, forType: .string))
        XCTAssertTrue(waitUntil(timeout: 10) { rows.count == 2 })

        search.typeText("clipy-ui-journey-")
        XCTAssertTrue(waitUntil(timeout: 10) { rows.count == 2 })

        // Open selected alpha. Beta arrived later and is now one row above it
        // in authoritative recent order, so Up chooses beta.
        search.typeKey(.upArrow, modifierFlags: [])
        pasteboard.clearContents()
        XCTAssertTrue(
            pasteboard.setString(
                "before-product-paste",
                forType: .string
            )
        )
        search.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(waitUntil(timeout: 10) { !panel.exists })
        XCTAssertTrue(waitUntil(timeout: 10) {
            pasteboard.string(forType: .string) == beta
        })
    }

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
