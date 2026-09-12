/// A PDF-only General pasteboard item supports explicit page navigation,
/// while Return copies the complete original two-page document.
import AppKit
import CoreGraphics
import XCTest

final class PDFPreviewJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testPDFPagesNavigateInDwellAndQuickLookWhileCopyKeepsBothPages() throws {
        let original = try twoPagePDF()
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(original, forType: .pdf))
        XCTAssertEqual(item.types, [.pdf])
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let publishedItems = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(publishedItems.count, 1)
        let published = try XCTUnwrap(publishedItems.first)
        // Raw publication does not ask NSImage/NSPDFImageRep for alternative
        // formats. System-added metadata remains allowed; the PDF notice
        // below proves which source the real preview actually selected.
        XCTAssertEqual(published.data(forType: .pdf), original)

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
        XCTAssertTrue(panel.waitForExistence(timeout: 20), app.debugDescription)
        let rows = panel.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "clipy.history.row."
        ))
        XCTAssertTrue(waitUntil(timeout: 10) { rows.count == 1 }, "PDF was not captured")
        let capturedRowIdentifier = rows.firstMatch.identifier

        // Exercise ordinary dwell with the real preference, including when
        // another journey left auto-open off. No manual preview toggle stands
        // in for the delayed-selection transition.
        app.typeKey(",", modifierFlags: .command)
        let appearance = app.buttons["clipy.settings.category.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 10), app.debugDescription)
        appearance.click()
        let autoOpen = app.switches["clipy.settings.appearance.preview-auto-open"]
        XCTAssertTrue(autoOpen.waitForExistence(timeout: 5), app.debugDescription)
        if (autoOpen.value as? Int) == 0 { autoOpen.click() }
        XCTAssertTrue(waitUntil(timeout: 5) { (autoOpen.value as? Int) == 1 })
        let general = app.buttons["clipy.settings.category.general"]
        XCTAssertTrue(general.exists)
        general.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil(timeout: 5) { !general.exists })
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(panel.waitForExistence(timeout: 10), app.debugDescription)

        // The dwell preview is the floating child pane now — a separate,
        // never-key window — so its queries scope to the app, not the panel.
        let preview = app.descendants(matching: .any)["clipy.preview.root"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10), app.debugDescription)
        expectPage(1, in: preview)
        XCTAssertFalse(preview.buttons["clipy.preview.pdf.previous"].isEnabled)
        preview.buttons["clipy.preview.pdf.next"].click()
        expectPage(2, in: preview)
        XCTAssertFalse(preview.buttons["clipy.preview.pdf.next"].isEnabled)
        // The pane is never key, so the pager's ⌥⌘← shortcut cannot fire
        // there; page back through the same button.
        preview.buttons["clipy.preview.pdf.previous"].click()
        expectPage(1, in: preview)

        let row = rows.matching(NSPredicate(
            format: "identifier == %@", capturedRowIdentifier
        )).firstMatch
        XCTAssertTrue(row.exists && row.isHittable, app.debugDescription)
        row.click()
        let quickLook = app.descendants(matching: .any)["clipy.panel.quicklook"]
        XCTAssertFalse(quickLook.exists)
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(quickLook.waitForExistence(timeout: 10), app.debugDescription)
        // Scope both identifiers below the overlay. The still-present dwell
        // pane cannot satisfy the Quick Look assertions.
        expectPage(1, in: quickLook)
        quickLook.buttons["clipy.preview.pdf.next"].click()
        expectPage(2, in: quickLook)
        let dismiss = quickLook.buttons["clipy.panel.quicklook.dismiss"]
        XCTAssertTrue(dismiss.exists && dismiss.isHittable)
        dismiss.click()
        XCTAssertTrue(waitUntil(timeout: 10) { !quickLook.exists })
        expectPage(1, in: preview)
        XCTAssertEqual(rows.count, 1)
        row.click()

        // An ignored sentinel makes unchanged seed bytes insufficient proof
        // of Return copying. It never becomes another History item.
        let sentinel = NSPasteboardItem()
        XCTAssertTrue(sentinel.setString("before-complete-pdf-copy", forType: .string))
        XCTAssertTrue(sentinel.setData(Data(), forType: NSPasteboard.PasteboardType(
            "org.nspasteboard.TransientType"
        )))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([sentinel]))
        XCTAssertNil(pasteboard.data(forType: .pdf))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil(timeout: 10) { !panel.exists }, "Return did not dismiss the panel")
        XCTAssertTrue(waitUntil(timeout: 10) {
            pasteboard.data(forType: .pdf) == original
        }, "Return must copy the complete original PDF, not a first-page bitmap")
        let copied = try XCTUnwrap(pasteboard.data(forType: .pdf))
        XCTAssertEqual(copied, original)
        let provider = try XCTUnwrap(CGDataProvider(data: copied as CFData))
        let document = try XCTUnwrap(CGPDFDocument(provider))
        XCTAssertEqual(document.numberOfPages, 2)
    }

    @MainActor
    private func expectPage(_ page: Int, in surface: XCUIElement) {
        let notice = surface.descendants(matching: .any)["clipy.preview.pdf-page-notice"]
        let image = surface.descendants(matching: .any)["clipy.preview.image"]
        let caption = surface.descendants(matching: .any)["clipy.preview.pdf.page"]
        XCTAssertTrue(waitUntil(timeout: 10) {
            notice.exists && notice.isHittable && image.exists && image.isHittable
                && self.text(of: notice)
                    == "Showing PDF page \(page) of 2. Copying the item keeps its complete content."
                && image.label == "PDF preview, page \(page) of 2"
                && caption.exists && self.text(of: caption) == "Page \(page) of 2"
        }, surface.debugDescription)
        // Navigation remains a full pointer target; the caption must not
        // compress either control when the preview is narrow.
        for identifier in ["clipy.preview.pdf.previous", "clipy.preview.pdf.next"] {
            let button = surface.buttons[identifier]
            XCTAssertGreaterThanOrEqual(button.frame.width, 24, identifier)
            XCTAssertGreaterThanOrEqual(button.frame.height, 24, identifier)
            XCTAssertGreaterThanOrEqual(button.frame.minX, surface.frame.minX - 1, identifier)
            XCTAssertLessThanOrEqual(button.frame.maxX, surface.frame.maxX + 1, identifier)
        }
    }

    @MainActor
    private func twoPagePDF() throws -> Data {
        let output = try XCTUnwrap(CFDataCreateMutable(kCFAllocatorDefault, 0))
        let consumer = try XCTUnwrap(CGDataConsumer(data: output))
        var mediaBox = CGRect(x: 0, y: 0, width: 120, height: 80)
        let writer = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        // Distinct solid pages contain no text that a producer could export
        // as a plain-text representation. The second page remains in Copy.
        for gray in [CGFloat(0), CGFloat(1)] {
            writer.beginPDFPage(nil)
            writer.setFillColor(gray: gray, alpha: 1)
            writer.fill(mediaBox)
            writer.endPDFPage()
        }
        writer.closePDF()
        let bytes = output as Data
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let document = try XCTUnwrap(CGPDFDocument(provider))
        XCTAssertEqual(document.numberOfPages, 2)
        return bytes
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
