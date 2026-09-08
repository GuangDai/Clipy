/// A file URL travels through the real pasteboard observer and History into
/// the dwell and Space Quick Look previews. Its synthetic destination exists
/// while macOS brokers the pasteboard reference, then is removed after
/// capture. Preview and search must still show the reference, never the
/// file's marker contents.
import AppKit
import CoreGraphics
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

        let expectedFilename = "未创建的文件 draft 计划.txt"
        let expectedPath = directory.path + "/" + expectedFilename
        let destination = URL(fileURLWithPath: expectedPath)
        let originalAddress = destination.absoluteString
        let fileContentMarker = "clipy-reference-file-contents-must-not-be-previewed"
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedPath))
        // General-pasteboard file URLs require an existing target for the
        // system's sandbox-extension creation. This is a small fixture file,
        // not an injected preview or an application-side file read.
        try Data(fileContentMarker.utf8).write(to: destination, options: .withoutOverwriting)
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
        let capturedRowIdentifier = rows.firstMatch.identifier
        XCTAssertTrue(rows.firstMatch.label.contains(expectedFilename), app.debugDescription)
        // Capture is now authoritative. Remove only the synthetic target;
        // the subsequent Settings reopen and dwell use its retained URL.
        try FileManager.default.removeItem(at: destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedPath))

        // Configure the real auto-open control so this journey exercises
        // dwell even if a previous run left the preference disabled. No
        // manual preview toggle substitutes for the dwell transition.
        app.typeKey(",", modifierFlags: .command)
        let appearance = app.buttons["clipy.settings.category.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 10), app.debugDescription)
        appearance.click()
        let autoOpen = app.switches["clipy.settings.appearance.preview-auto-open"]
        XCTAssertTrue(autoOpen.waitForExistence(timeout: 5), app.debugDescription)
        if (autoOpen.value as? Int) == 0 { autoOpen.click() }
        XCTAssertTrue(waitUntil(timeout: 5) { (autoOpen.value as? Int) == 1 },
                      app.debugDescription)
        let general = app.buttons["clipy.settings.category.general"]
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
                    == "Only the reference is shown. Loading its contents requires confirmation."
        }, app.debugDescription)
        XCTAssertEqual(rows.count, 1, app.debugDescription)

        // Recipe 5 exposes the decoded basename and reference metadata to
        // the ordinary search surface. Only the ASCII filename component is
        // typed here; Chinese matching is covered by the storage owner tests.
        let search = panel.textFields["clipy.search.field"]
        XCTAssertTrue(search.exists && search.isHittable, app.debugDescription)
        search.click()
        search.typeKey("1", modifierFlags: [.command])
        let searchMode = panel.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Search Mode")
        ).firstMatch
        XCTAssertTrue(waitUntil(timeout: 5) {
            searchMode.exists && searchMode.value as? String == "Exact"
        }, app.debugDescription)

        // Observe a real empty result before the positive query, so an old
        // Recent row cannot satisfy the assertion during debounce/loading.
        search.typeText("clipy-reference-no-match")
        XCTAssertTrue(waitUntil(timeout: 10) {
            rows.count == 0 && panel.staticTexts["No Results"].exists
        }, app.debugDescription)
        search.typeKey("a", modifierFlags: [.command])
        search.typeText("draft")
        XCTAssertEqual(search.value as? String, "draft", app.debugDescription)
        XCTAssertTrue(waitUntil(timeout: 10) {
            rows.count == 1 && rows.firstMatch.identifier == capturedRowIdentifier
                && rows.firstMatch.label.contains(expectedFilename)
        }, app.debugDescription)

        // The empty result retired selection. Select the recovered row using
        // the real search-field arrow command and let preview dwell again.
        search.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(waitUntil(timeout: 10) {
            title.exists && path.exists && address.exists && disclosure.exists
                && self.text(of: title) == "File Reference"
                && self.text(of: path) == expectedPath
                && self.text(of: address) == originalAddress
                && self.text(of: disclosure)
                    == "Only the reference is shown. Loading its contents requires confirmation."
        }, app.debugDescription)
        XCTAssertFalse(preview.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ OR value == %@", fileContentMarker, fileContentMarker)
        ).firstMatch.exists, app.debugDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedPath))

        // Transfer focus out of Search with a real row click. Space opens
        // Clipy's overlay for the same retained reference, not system Quick
        // Look and not the target that was removed before preview began.
        let row = rows.matching(NSPredicate(
            format: "identifier == %@", capturedRowIdentifier
        )).firstMatch
        XCTAssertTrue(row.exists && row.isHittable, app.debugDescription)
        row.click()
        let quickLook = app.descendants(matching: .any)["clipy.panel.quicklook"]
        XCTAssertFalse(quickLook.exists, app.debugDescription)
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(quickLook.waitForExistence(timeout: 10), app.debugDescription)
        // Both surfaces expose the same field IDs. Scope every assertion
        // below the overlay so the already-open side pane cannot satisfy it.
        let quickReference = quickLook.descendants(matching: .any)["clipy.preview.reference"]
        let quickTitle = quickReference.descendants(matching: .any)["clipy.preview.reference.title"]
        let quickPath = quickReference.descendants(matching: .any)["clipy.preview.reference.path"]
        let quickAddress = quickReference.descendants(matching: .any)["clipy.preview.reference.address"]
        let quickDisclosure = quickReference.descendants(matching: .any)["clipy.preview.reference.disclosure"]
        XCTAssertTrue(waitUntil(timeout: 10) {
            quickTitle.exists && quickPath.exists && quickAddress.exists && quickDisclosure.exists
                && self.text(of: quickTitle) == "File Reference"
                && self.text(of: quickPath) == expectedPath
                && self.text(of: quickAddress) == originalAddress
                && self.text(of: quickDisclosure)
                    == "Only the reference is shown. Loading its contents requires confirmation."
        }, app.debugDescription)
        XCTAssertEqual(search.value as? String, "draft", app.debugDescription)
        XCTAssertFalse(quickLook.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ OR value == %@", fileContentMarker, fileContentMarker)
        ).firstMatch.exists, app.debugDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedPath))

        let dismiss = quickLook.buttons["clipy.panel.quicklook.dismiss"]
        XCTAssertTrue(dismiss.exists && dismiss.isHittable, app.debugDescription)
        dismiss.click()
        XCTAssertTrue(waitUntil(timeout: 10) { !quickLook.exists }, app.debugDescription)
        XCTAssertTrue(waitUntil(timeout: 10) {
            title.exists && path.exists && address.exists && disclosure.exists
                && self.text(of: title) == "File Reference"
                && self.text(of: path) == expectedPath
                && self.text(of: address) == originalAddress
                && self.text(of: disclosure)
                    == "Only the reference is shown. Loading its contents requires confirmation."
        }, app.debugDescription)
        XCTAssertFalse(preview.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ OR value == %@", fileContentMarker, fileContentMarker)
        ).firstMatch.exists, app.debugDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedPath))
    }

    @MainActor
    func testFileContentsRequireConfirmationAndBackRestoresTheOriginalReference() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("explicit file preview.txt")
        let originalAddress = file.absoluteString
        let originalContents = "clipy-file-not-shown-before-confirmation"
        let loadedContents = "clipy-file-current-contents-after-confirmation"
        try Data(originalContents.utf8).write(to: file)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        let item = NSPasteboardItem()
        let fileType = NSPasteboard.PasteboardType("public.file-url")
        XCTAssertTrue(item.setData(Data(originalAddress.utf8), forType: fileType))
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("history.store").path
        app.launch()
        defer { app.terminate() }
        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        XCTAssertTrue(panel.waitForExistence(timeout: 20), app.debugDescription)
        let rows = panel.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "clipy.history.row.")
        )
        XCTAssertTrue(waitUntil(timeout: 10) { rows.count == 1 }, app.debugDescription)
        let preview = panel.descendants(matching: .any)["clipy.preview.root"]
        if !preview.waitForExistence(timeout: 3) {
            app.typeKey(.space, modifierFlags: .control)
        }
        XCTAssertTrue(preview.waitForExistence(timeout: 5), app.debugDescription)
        let request = preview.buttons["clipy.preview.file.request"]
        let address = preview.descendants(matching: .any)["clipy.preview.reference.address"]
        let renderedText = preview.descendants(matching: .any)["clipy.preview.text"]
        XCTAssertTrue(request.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(text(of: address), originalAddress)
        XCTAssertFalse(renderedText.exists, app.debugDescription)

        request.click()
        // AppKit also exposes Cancel/Load File in the Touch Bar. Scope both
        // actions to the visible confirmation sheet rather than selecting
        // an offscreen duplicate from the application-wide button query.
        let confirmation = app.sheets.containing(
            .button, identifier: "clipy.preview.file.confirm"
        ).firstMatch
        let confirm = confirmation.buttons["clipy.preview.file.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(renderedText.exists, app.debugDescription)
        let cancel = confirmation.buttons["Cancel"]
        XCTAssertTrue(cancel.exists && cancel.isHittable, app.debugDescription)
        cancel.click()
        XCTAssertTrue(waitUntil(timeout: 5) { !confirm.exists && request.exists }, app.debugDescription)
        XCTAssertFalse(renderedText.exists, app.debugDescription)
        XCTAssertEqual(text(of: address), originalAddress)

        // The second confirmation reads the file's then-current bytes, not a
        // cached copy captured while it was merely a clipboard reference.
        try Data(loadedContents.utf8).write(to: file)
        request.click()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        confirm.click()
        XCTAssertTrue(waitUntil(timeout: 10) {
            renderedText.exists && self.text(of: renderedText) == loadedContents
        }, app.debugDescription)
        let back = preview.buttons["clipy.preview.file.back"]
        XCTAssertTrue(back.exists && back.isHittable, app.debugDescription)
        XCTAssertTrue(preview.staticTexts["clipy.preview.file.disclosure"].exists)
        XCTAssertEqual(rows.count, 1)
        back.click()
        XCTAssertTrue(waitUntil(timeout: 5) {
            address.exists && self.text(of: address) == originalAddress && !renderedText.exists
        }, app.debugDescription)

        // Copy remains the original History item even after an explicit file
        // preview. File contents are never a replacement paste payload.
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil(timeout: 10) {
            pasteboard.pasteboardItems?.first?.data(forType: fileType) == Data(originalAddress.utf8)
                && !panel.exists
        }, app.debugDescription)
    }

    @MainActor
    func testConfirmedFilePDFNavigatesItsLoadedPagesWithoutReadingAReplacement() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("explicit PDF preview.pdf")
        let output = try XCTUnwrap(CFDataCreateMutable(kCFAllocatorDefault, 0))
        let consumer = try XCTUnwrap(CGDataConsumer(data: output))
        var box = CGRect(x: 0, y: 0, width: 120, height: 80)
        let writer = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for gray in [CGFloat(0), CGFloat(1)] {
            writer.beginPDFPage(nil)
            writer.setFillColor(gray: gray, alpha: 1)
            writer.fill(box)
            writer.endPDFPage()
        }
        writer.closePDF()
        try (output as Data).write(to: file)
        let fileType = NSPasteboard.PasteboardType("public.file-url")
        let referenceBytes = Data(file.absoluteString.utf8)
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(referenceBytes, forType: fileType))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("history.store").path
        app.launch()
        defer { app.terminate() }
        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        XCTAssertTrue(panel.waitForExistence(timeout: 20), app.debugDescription)
        let rows = panel.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "clipy.history.row.")
        )
        XCTAssertTrue(waitUntil(timeout: 10) { rows.count == 1 }, app.debugDescription)
        let preview = panel.descendants(matching: .any)["clipy.preview.root"]
        if !preview.waitForExistence(timeout: 3) {
            app.typeKey(.space, modifierFlags: .control)
        }
        let request = preview.buttons["clipy.preview.file.request"]
        XCTAssertTrue(request.waitForExistence(timeout: 10), app.debugDescription)
        let image = preview.descendants(matching: .any)["clipy.preview.image"]
        let caption = preview.descendants(matching: .any)["clipy.preview.pdf.page"]
        XCTAssertFalse(image.exists)
        XCTAssertFalse(caption.exists)
        request.click()
        let confirmation = app.sheets.containing(
            .button, identifier: "clipy.preview.file.confirm"
        ).firstMatch
        let confirm = confirmation.buttons["clipy.preview.file.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        confirm.click()
        XCTAssertTrue(waitUntil(timeout: 10) {
            image.exists && image.label == "PDF preview, page 1 of 2"
                && caption.exists && self.text(of: caption) == "Page 1 of 2"
        }, app.debugDescription)

        // A later explicit page action must use the already loaded PDF.
        // Reopening this replaced file would fail decoding, exposing rereads.
        try Data("This replacement is not a PDF".utf8).write(to: file)
        let next = preview.buttons["clipy.preview.pdf.next"]
        XCTAssertTrue(next.exists && next.isEnabled && next.isHittable)
        next.click()
        XCTAssertTrue(waitUntil(timeout: 10) {
            image.exists && image.label == "PDF preview, page 2 of 2"
                && caption.exists && self.text(of: caption) == "Page 2 of 2"
        }, app.debugDescription)
        XCTAssertFalse(next.isEnabled)
        app.typeKey(.leftArrow, modifierFlags: [.option, .command])
        XCTAssertTrue(waitUntil(timeout: 10) {
            image.exists && image.label == "PDF preview, page 1 of 2"
        }, app.debugDescription)
        preview.buttons["clipy.preview.file.back"].click()
        XCTAssertTrue(request.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(image.exists)
        XCTAssertFalse(caption.exists)

        // Retiring the preview discarded its document. A new confirmation
        // now reads the changed file and reports its actual decoding failure.
        request.click()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        confirm.click()
        let failure = preview.descendants(matching: .any)["clipy.preview.failed"]
        XCTAssertTrue(failure.waitForExistence(timeout: 10), app.debugDescription)
        preview.buttons["clipy.preview.file.back"].click()
        XCTAssertTrue(request.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(rows.count, 1)

        let sentinel = NSPasteboardItem()
        XCTAssertTrue(sentinel.setString("before-original-file-reference-copy", forType: .string))
        XCTAssertTrue(sentinel.setData(Data(), forType: .init("org.nspasteboard.TransientType")))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([sentinel]))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil(timeout: 10) {
            !panel.exists && pasteboard.pasteboardItems?.first?.data(forType: fileType) == referenceBytes
        }, app.debugDescription)
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
