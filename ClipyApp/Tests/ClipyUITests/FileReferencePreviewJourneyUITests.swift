/// A file URL travels through the real pasteboard observer and History into
/// the dwell preview. The destination never exists; the journey inspects the
/// reference as text and never opens it or invokes a file-reading operation.
import AppKit
import XCTest

final class FileReferencePreviewJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testFileURLCaptureShowsItsDecodedPathAndOriginalAddress() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let expectedPath = directory.path + "/未创建的文件 计划.txt"
        let originalAddress = URL(fileURLWithPath: expectedPath).absoluteString
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedPath))
        XCTAssertTrue(originalAddress.contains("%20"))
        let fileType = NSPasteboard.PasteboardType("public.file-url")
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(Data(originalAddress.utf8), forType: fileType))
        XCTAssertEqual(item.types, [fileType])
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory
            .appendingPathComponent("history.store").path
        defer { app.terminate() }
        app.launch()

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        XCTAssertTrue(panel.waitForExistence(timeout: 20), app.debugDescription)
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "clipy.history.row.")
        )
        XCTAssertTrue(waitUntil(timeout: 10) { rows.count == 1 }, app.debugDescription)

        // Configure the real auto-open control so this journey exercises
        // dwell even if a previous run left the preference disabled. No
        // manual preview toggle substitutes for the dwell transition.
        app.typeKey(",", modifierFlags: .command)
        let appearance = app.buttons["Appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 10), app.debugDescription)
        appearance.click()
        let autoOpen = app.switches["clipy.settings.appearance.preview-auto-open"]
        XCTAssertTrue(autoOpen.waitForExistence(timeout: 5), app.debugDescription)
        if (autoOpen.value as? Int) == 0 { autoOpen.click() }
        XCTAssertTrue(waitUntil(timeout: 5) { (autoOpen.value as? Int) == 1 },
                      app.debugDescription)
        let general = app.buttons["General"]
        XCTAssertTrue(general.exists, app.debugDescription)
        general.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil(timeout: 5) { !general.exists }, app.debugDescription)
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(panel.waitForExistence(timeout: 10), app.debugDescription)

        let preview = panel.descendants(matching: .any)["clipy.preview.root"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10), app.debugDescription)
        let reference = preview.descendants(matching: .any)["clipy.preview.reference"]
        XCTAssertTrue(reference.waitForExistence(timeout: 10), app.debugDescription)
        let title = reference.descendants(matching: .any)["clipy.preview.reference.title"]
        let path = reference.descendants(matching: .any)["clipy.preview.reference.path"]
        let address = reference.descendants(matching: .any)["clipy.preview.reference.address"]
        let disclosure = reference.descendants(matching: .any)["clipy.preview.reference.disclosure"]
        XCTAssertTrue(waitUntil(timeout: 10) {
            title.exists && path.exists && address.exists && disclosure.exists
                && self.text(of: title) == "File Reference"
                && self.text(of: path) == expectedPath
                && self.text(of: address) == originalAddress
                && self.text(of: disclosure)
                    == "Only the reference is shown. Its destination has not been opened."
        }, app.debugDescription)
        XCTAssertEqual(rows.count, 1, app.debugDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedPath))
    }

    @MainActor
    private func text(of element: XCUIElement) -> String {
        (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval, condition: @escaping () -> Bool
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() }, object: nil
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
