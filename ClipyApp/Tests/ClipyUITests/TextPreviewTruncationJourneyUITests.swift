/// The real text preview discloses its display limit while Return copies
/// the complete retained UTF-8 value through the General pasteboard.
import AppKit
import XCTest

final class TextPreviewTruncationJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testTruncationNoticeDoesNotTruncateCopyAndRetiresForShortText() throws {
        let tail = "CLIPY-COMPLETE-TAIL!"
        let original = String(repeating: "A", count: 50_001 - tail.utf8.count) + tail
        let originalBytes = Data(original.utf8)
        XCTAssertEqual(originalBytes.count, 50_001)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        XCTAssertTrue(pasteboard.setData(originalBytes, forType: .string))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory
            .appendingPathComponent("history.store").path
        defer { app.terminate() }
        app.launch()

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        XCTAssertTrue(panel.waitForExistence(timeout: 20), "History panel did not open")
        let rows = panel.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "clipy.history.row."
        ))
        XCTAssertTrue(waitUntil(timeout: 10) { rows.count == 1 }, "Long text was not captured")
        let longRowIdentifier = rows.firstMatch.identifier

        // Use the real preference control: a prior journey may have disabled
        // automatic preview. Reopening the panel starts ordinary dwell.
        app.typeKey(",", modifierFlags: .command)
        let appearance = app.buttons["Appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 10))
        appearance.click()
        let autoOpen = app.switches["clipy.settings.appearance.preview-auto-open"]
        XCTAssertTrue(autoOpen.waitForExistence(timeout: 5))
        if (autoOpen.value as? Int) == 0 { autoOpen.click() }
        XCTAssertTrue(waitUntil(timeout: 5) { (autoOpen.value as? Int) == 1 })
        let general = app.buttons["General"]
        XCTAssertTrue(general.exists)
        general.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil(timeout: 5) { !general.exists })
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(panel.waitForExistence(timeout: 10))

        let preview = panel.descendants(matching: .any)["clipy.preview.root"]
        let notice = preview.descendants(matching: .any)["clipy.preview.truncation-notice"]
        XCTAssertTrue(waitUntil(timeout: 10) {
            notice.exists && notice.isHittable
                && self.text(of: notice) == "Preview truncated. Copying the item keeps its complete content."
        }, "Long-text preview must show its separate truncation notice")

        let longRow = rows.matching(NSPredicate(
            format: "identifier == %@", longRowIdentifier
        )).firstMatch
        XCTAssertTrue(longRow.exists && longRow.isHittable)
        longRow.click()
        // Replace General with an ignored transient sentinel so an unchanged
        // seed cannot masquerade as a successful product copy.
        let sentinel = NSPasteboardItem()
        XCTAssertTrue(sentinel.setString("before-complete-copy", forType: .string))
        XCTAssertTrue(sentinel.setData(Data(), forType: NSPasteboard.PasteboardType(
            "org.nspasteboard.TransientType"
        )))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([sentinel]))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil(timeout: 10) { !panel.exists }, "Return did not dismiss the panel")
        XCTAssertTrue(waitUntil(timeout: 10) {
            pasteboard.data(forType: .string) == originalBytes
        }, "Return must copy all 50,001 original UTF-8 bytes")
        let copied = try XCTUnwrap(pasteboard.data(forType: .string))
        XCTAssertEqual(copied.count, 50_001)
        XCTAssertTrue(copied.suffix(tail.utf8.count).elementsEqual(tail.utf8),
                      "The copied value must include its complete tail")

        // A different real capture reuses the same panel/preview surface.
        // Wait for its text, not merely the notice disappearing during load.
        let shortText = "clipy-short-preview-after-truncation"
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(shortText, forType: .string))
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        let shortRow = rows.matching(NSPredicate(
            format: "label CONTAINS %@", shortText
        )).firstMatch
        XCTAssertTrue(waitUntil(timeout: 10) { rows.count == 2 && shortRow.exists })
        XCTAssertTrue(shortRow.isHittable)
        shortRow.click()
        let body = preview.descendants(matching: .any)["clipy.preview.text"]
        XCTAssertTrue(waitUntil(timeout: 10) {
            body.exists && self.text(of: body) == shortText && !notice.exists
        }, "Short-text preview must retire the preceding truncation notice")
    }

    @MainActor
    private func text(of element: XCUIElement) -> String {
        (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() }, object: nil
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
