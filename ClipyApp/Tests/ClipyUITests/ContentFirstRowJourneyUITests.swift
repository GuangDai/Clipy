import AppKit
import XCTest

/// The redesigned content/metadata layout keeps one accessible row, exact
/// identity through pinning, and the existing keyboard Copy action.
final class ContentFirstRowJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testLongContentKeepsAccessibleMetadataPinningAndKeyboardCopy() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        let captured = "clipy-content-row: " + String(repeating: "A comfortably readable line of copied text. ", count: 5)
        XCTAssertTrue(pasteboard.setString(captured, forType: .string))

        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("history.store").path
        app.launch()
        defer { app.terminate() }
        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        XCTAssertTrue(panel.waitForExistence(timeout: 20), app.debugDescription)
        let rows = panel.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "clipy.history.row."
        ))
        XCTAssertTrue(waitUntil { rows.count == 1 }, app.debugDescription)
        let row = rows.element(boundBy: 0)
        let identifier = row.identifier
        XCTAssertEqual(row.elementType, .button)
        XCTAssertTrue(row.label.contains("clipy-content-row:"))
        XCTAssertEqual(row.value as? String, "Copied 1 time")
        XCTAssertTrue(panel.frame.insetBy(dx: -2, dy: -2).contains(row.frame))

        row.click()
        app.typeKey("p", modifierFlags: .command)
        XCTAssertTrue(waitUntil {
            rows.count == 1 && rows.element(boundBy: 0).identifier == identifier
                && rows.element(boundBy: 0).label.contains("Pinned at position 1")
        }, app.debugDescription)
        let attachment = XCTAttachment(screenshot: panel.screenshot())
        attachment.name = "Content-first history row"
        attachment.lifetime = .keepAlways
        add(attachment)

        let sentinel = NSPasteboardItem()
        XCTAssertTrue(sentinel.setString("before-product-copy", forType: .string))
        XCTAssertTrue(sentinel.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([sentinel]))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil { pasteboard.string(forType: .string) == captured }, app.debugDescription)
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() }, object: nil
        )
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }
}
