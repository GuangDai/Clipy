/// A malformed image travels through the real pasteboard observer, History,
/// thumbnail request, and Details representation row. The existing launch
/// fixture changes only store location and capture-access posture.
import AppKit
import XCTest

final class DetailsUnavailableImageJourneyUITests: XCTestCase {
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
    func testCapturedMalformedPNGShowsUnavailablePreviewInDetails() throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        let item = NSPasteboardItem()
        // The existing decoder fixtures use this short, invalid PNG header;
        // no native decoder failure or ThumbnailStore result is injected.
        XCTAssertTrue(item.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png))
        XCTAssertTrue(pasteboard.writeObjects([item]))

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
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        defer { app.terminate() }
        app.launch()

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        XCTAssertTrue(
            panel.waitForExistence(timeout: 20),
            diagnostic(app, context: "production panel")
        )
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "clipy.history.row.")
        )
        XCTAssertTrue(
            waitUntil(timeout: 10) { rows.count == 1 && rows.firstMatch.isHittable },
            diagnostic(app, context: "real malformed PNG capture")
        )
        rows.firstMatch.rightClick()

        let showDetails = app.menuItems["Show Details"]
        XCTAssertTrue(
            waitUntil(timeout: 5) { showDetails.exists && showDetails.isHittable },
            diagnostic(app, context: "Show Details context menu")
        )
        showDetails.click()

        let details = app.descendants(matching: .any)["clipy.details.root"]
        XCTAssertTrue(
            details.waitForExistence(timeout: 10),
            diagnostic(app, context: "loaded Details")
        )
        let unavailable = details.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Preview unavailable for public.png")
        ).firstMatch
        XCTAssertTrue(
            unavailable.waitForExistence(timeout: 10),
            diagnostic(app, context: "unavailable image representation preview")
        )
        XCTAssertFalse(
            details.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", "Image preview of public.png")
            ).firstMatch.exists,
            diagnostic(app, context: "malformed PNG must not produce an image preview")
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
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func diagnostic(_ app: XCUIApplication, context: String) -> String {
        "\(context)\n\(app.debugDescription)"
    }
}
