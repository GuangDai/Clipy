/// Search excerpt and truncation use bounded display data. Return still copies
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
        let original = String(repeating: "A", count: 50_000) + "\n" + tail
        let originalBytes = Data(original.utf8)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        XCTAssertTrue(pasteboard.setData(originalBytes, forType: .string))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = XCUIApplication()
        // Arm production dwell without inheriting another journey's preference.
        app.launchArguments += [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-clipy.language", "system",
            "-clipy.appearance.previewAutoOpen", "YES",
            "-clipy.preview.isTextLengthLimited", "YES",
            "-clipy.preview.maximumTextCharacters", "50000",
        ]
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

        // The preview is the floating child pane now — a separate window, so
        // its queries scope to the app, never to the main panel.
        let preview = app.descendants(matching: .any)["clipy.preview.root"]
        HistoryJourneyControls.selectFirst(in: app)
        let notice = preview.descendants(matching: .any)["clipy.preview.truncation-notice"]
        XCTAssertTrue(waitUntil(timeout: 10) {
            notice.exists && notice.isHittable
                && self.text(of: notice) == "Preview truncated. Copying the item keeps its complete content."
        }, "Long-text preview must show its separate truncation notice")

        let longRow = rows.matching(NSPredicate(
            format: "identifier == %@", longRowIdentifier
        )).firstMatch
        XCTAssertTrue(longRow.exists && longRow.isHittable)
        let search = app.textFields["clipy.search.field"]
        search.click()
        app.typeText(tail)
        XCTAssertTrue(waitUntil(timeout: 10) {
            longRow.exists && longRow.label.contains(tail)
        }, "The result should expose the hit beyond the preview limit")
        HistoryJourneyControls.select(longRow, in: app)
        let searchMatch = preview.descendants(matching: .any)["clipy.preview.search-match"]
        XCTAssertTrue(waitUntil(timeout: 10) {
            searchMatch.exists && searchMatch.isHittable && self.text(of: searchMatch) == "…" + tail
                && notice.exists
        }, "The preview should show the search hit separately from its truncated body")

        let clearSearch = panel.buttons["clipy.search.clear"]
        clearSearch.click()
        XCTAssertTrue(waitUntil(timeout: 10) { !searchMatch.exists && longRow.exists && !longRow.label.contains(tail) },
                      "Clearing the query must retire its excerpt even when the item survives")
        HistoryJourneyControls.select(longRow, in: app)
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
        }, "Return must copy all original UTF-8 bytes")
        let copied = try XCTUnwrap(pasteboard.data(forType: .string))
        XCTAssertEqual(copied.count, originalBytes.count)
        XCTAssertTrue(copied.suffix(tail.utf8.count).elementsEqual(tail.utf8),
                      "The copied value must include its complete tail")

        // A different real capture reuses the same panel/preview surface.
        // Wait for its text, not merely the notice disappearing during load.
        let shortTitle = "clipy-short-preview marker FIRST"
        let shortText = shortTitle + "\n" + String(repeating: "ordinary line\n", count: 15) + "marker SECOND"
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(shortText, forType: .string))
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        let shortRow = rows.matching(NSPredicate(
            format: "label CONTAINS %@", shortTitle
        )).firstMatch
        XCTAssertTrue(waitUntil(timeout: 10) { rows.count == 2 && shortRow.exists })
        XCTAssertTrue(shortRow.isHittable)
        HistoryJourneyControls.select(shortRow, in: app)
        let body = preview.descendants(matching: .any)["clipy.preview.text"]
        XCTAssertTrue(waitUntil(timeout: 10) {
            body.exists && self.text(of: body) == shortText && !notice.exists
        }, "Short-text preview must retire the preceding truncation notice")

        search.click()
        app.typeText("marker")
        XCTAssertTrue(waitUntil(timeout: 10) { rows.count == 1 && shortRow.exists })
        HistoryJourneyControls.select(shortRow, in: app)
        let position = preview.descendants(matching: .any)["clipy.preview.matches.position"]
        let context = preview.staticTexts["clipy.preview.matches.context"]
        let previous = preview.buttons["clipy.preview.matches.previous"]
        let next = preview.buttons["clipy.preview.matches.next"]
        XCTAssertTrue(waitUntil(timeout: 10) {
            position.exists && self.text(of: position) == "1 of 2 matches shown" && next.isHittable
                && context.isHittable && self.text(of: context).contains("marker FIRST")
        }, preview.debugDescription)
        XCTAssertFalse(previous.isEnabled)
        next.click()
        XCTAssertTrue(waitUntil(timeout: 5) {
            self.text(of: position) == "2 of 2 matches shown" && previous.isHittable && !next.isEnabled
                && context.isHittable && self.text(of: context).contains("marker SECOND")
        }, preview.debugDescription)
        let attachment = XCTAttachment(screenshot: preview.screenshot())
        attachment.name = "Two highlighted occurrences in one expanded search preview"
        attachment.lifetime = .keepAlways
        add(attachment)
        previous.click()
        XCTAssertTrue(waitUntil(timeout: 5) { self.text(of: position) == "1 of 2 matches shown" })

        shortRow.rightClick()
        let showDetails = app.menuItems["Show Details"]
        XCTAssertTrue(showDetails.waitForExistence(timeout: 5))
        showDetails.click()
        let details = app.descendants(matching: .any)["clipy.details.root"]
        let evidence = details.descendants(matching: .any)["clipy.details.search-match"]
        XCTAssertTrue(waitUntil(timeout: 5) { evidence.exists && self.text(of: evidence).contains("marker") })
        details.buttons["clipy.details.show-preview.public.utf8-plain-text"].click()
        let detailsPosition = details.descendants(matching: .any)["clipy.details.text-preview.public.utf8-plain-text.matches.position"]
        let detailsNext = details.buttons["clipy.details.text-preview.public.utf8-plain-text.matches.next"]
        XCTAssertTrue(waitUntil(timeout: 5) {
            detailsPosition.exists && self.text(of: detailsPosition) == "1 of 2 matches shown" && detailsNext.isHittable
        }, details.debugDescription)
        detailsNext.click()
        XCTAssertTrue(waitUntil(timeout: 5) { self.text(of: detailsPosition) == "2 of 2 matches shown" })
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
