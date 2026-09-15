import AppKit
import XCTest

/// Selecting text must not replace the display font or paragraph spacing.
/// Uses the actual floating pane and the macOS standard Copy command.
final class PreviewTextSelectionJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testSelectingPreviewTextKeepsWrappingAndCopiesTheSelectedSpelling() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let selectedWord = "Cafe\u{301}"
        let source = selectedWord + " keeps its exact spelling when selected. "
            + "This sentence wraps across the preview width without changing its font.\n"
            + "第二行用于对照：点击文字前后，字号和行距保持一致。\n"
            + "A final line makes any change in paragraph spacing visible."
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        XCTAssertTrue(pasteboard.setString(source, forType: .string))
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-clipy.appearance.previewAutoOpen", "YES",
            "-clipy.preview.isTextLengthLimited", "YES",
            "-clipy.preview.maximumTextCharacters", "50000",
            "-clipy.panelContentWidth", "360", "-clipy.panelHeight", "420",
        ]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("history.sqlite").path
        app.launch()
        defer { app.terminate() }
        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        XCTAssertTrue(panel.waitForExistence(timeout: 20), app.debugDescription)
        HistoryJourneyControls.selectFirst(in: app)
        let preview = app.descendants(matching: .any)["clipy.preview.root"]
        let text = preview.descendants(matching: .any)["clipy.preview.text"]
        XCTAssertTrue(waitUntil {
            text.exists && self.value(text) == source && text.frame.height > 40
        }, app.debugDescription)
        let originalTextSize = text.frame.size
        let originalPreviewSize = preview.frame.size
        attach(preview, named: "Preview text before selection")

        let firstWord = text.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: 15, dy: 8))
        firstWord.doubleClick()
        XCTAssertTrue(waitUntil { text.exists && self.value(text) == source }, app.debugDescription)
        attach(preview, named: "Preview text after selecting a word")
        XCTAssertEqual(text.frame.width, originalTextSize.width, accuracy: 1)
        XCTAssertEqual(text.frame.height, originalTextSize.height, accuracy: 1,
                       "Text selection must keep the same wrapping and line spacing")
        XCTAssertEqual(preview.frame.width, originalPreviewSize.width, accuracy: 1)
        XCTAssertEqual(preview.frame.height, originalPreviewSize.height, accuracy: 1)

        // SwiftUI documents Edit > Copy / Command-C for selected macOS
        // Text. It does not promise a contextual Copy menu; a global menu
        // query can instead match the hidden Edit-menu command.
        app.typeKey("c", modifierFlags: .command)
        XCTAssertTrue(waitUntil {
            pasteboard.string(forType: .string).map { Data($0.utf8) } == Data(selectedWord.utf8)
        }, "Copy must preserve the selected decomposed spelling, not copy the complete history item")
        XCTAssertTrue(preview.exists, app.debugDescription)
        XCTAssertEqual(text.frame.height, originalTextSize.height, accuracy: 1)

        // Escape is still the panel command when the preview owns Copy.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { !panel.exists && !preview.exists }, app.debugDescription)
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(panel.waitForExistence(timeout: 10), app.debugDescription)
        let search = panel.textFields["clipy.search.field"]
        app.typeText("spelling")
        XCTAssertTrue(waitUntil { search.value as? String == "spelling" }, app.debugDescription)
        let originalRow = panel.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "clipy.history.row.", "spelling"
        )).firstMatch
        XCTAssertTrue(originalRow.waitForExistence(timeout: 10), app.debugDescription)
        search.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(waitUntil { text.exists && self.value(text) == source }, app.debugDescription)
        // Dwell only orders the preview front: continued typing must still
        // reach Search without another click or explicit focus request.
        app.typeText(" when")
        XCTAssertTrue(waitUntil { search.value as? String == "spelling when" }, app.debugDescription)
        XCTAssertTrue(waitUntil {
            originalRow.exists && originalRow.isSelected && text.exists && self.value(text) == source
        }, "Refining a matching query must preserve its selected row and preview without another arrow key.\n" + app.debugDescription)

        firstWord.doubleClick()
        let information = preview.buttons["clipy.preview.information"]
        information.click()
        let informationContent = app.descendants(matching: .any)["clipy.preview.information.content"]
        XCTAssertTrue(informationContent.waitForExistence(timeout: 5), app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { !informationContent.exists && preview.exists && panel.exists },
                      "Escape dismisses information before the browsing session")

        // A pointer-exit hide returns key status to the retained parent;
        // the child's resign callback must not close the whole session.
        panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: 40)).hover()
        XCTAssertTrue(waitUntil { !preview.exists && panel.exists }, app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { !panel.exists }, app.debugDescription)
    }

    @MainActor
    private func attach(_ preview: XCUIElement, named name: String) {
        let attachment = XCTAttachment(screenshot: preview.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func value(_ element: XCUIElement) -> String {
        (element.value as? String) ?? element.label
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() }, object: nil
        )
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }
}
