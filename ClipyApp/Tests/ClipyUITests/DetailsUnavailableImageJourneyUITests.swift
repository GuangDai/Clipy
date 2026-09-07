/// Details opens with metadata only. Explicit image previews read the selected
/// representation rather than reusing an item-level thumbnail. The existing
/// launch fixture changes only store location and capture-access posture.
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
    func testCapturedMalformedPNGKeepsItsRepresentationMetadataInDetails() throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        // The existing decoder fixtures use this short, invalid PNG header;
        // no native decoder failure or ThumbnailStore result is injected.
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(bytes, forType: .png))
        XCTAssertTrue(pasteboard.writeObjects([item]))
        XCTAssertEqual(pasteboard.data(forType: .png), bytes)

        let app = XCUIApplication()
        defer { app.terminate() }
        let details = try launchAndOpenCapturedDetails(in: app)
        // Header evidence precedes scrolling to the lower Content section.
        assertVisibleText("Content type icon", in: details, app: app)
        assertVisibleText("public.png", in: details, app: app)
        assertVisibleText("4 bytes", in: details, app: app)
        assertNoRepresentationImage("public.png", in: details, app: app)
        XCTAssertFalse(details.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Preview unavailable for public.png")
        ).firstMatch.exists, diagnostic(app, context: "metadata must not classify unread image bytes"))
        clickPreview("public.png", in: details, app: app)
        assertVisibleText("Preview unavailable for public.png", in: details, app: app)
        assertNoRepresentationImage("public.png", in: details, app: app)
        // The renderer result can be dismissed and explicitly requested again;
        // no retry changes the captured bytes or hides their metadata.
        clickPreview("public.png", in: details, app: app)
        XCTAssertFalse(details.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Preview unavailable for public.png")
        ).firstMatch.exists)
        clickPreview("public.png", in: details, app: app)
        assertVisibleText("Preview unavailable for public.png", in: details, app: app)
        assertVisibleText("4 bytes", in: details, app: app)
        XCTAssertEqual(pasteboard.data(forType: .png), bytes)
    }

    @MainActor
    func testItemThumbnailIsNotReusedAsEachImageRepresentationPreview() throws {
        // Same fixed 1×1 RGBA PNG literal as the storage/presentation owner
        // fixtures. The XCUI target does not import their test-only module.
        let png = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
            0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99,
            0x3D, 0x1D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
            0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
        ])
        let tiff = Data("opaque TIFF!!".utf8)
        XCTAssertEqual(png.count, 70)
        XCTAssertEqual(tiff.count, 13)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(png, forType: .png))
        XCTAssertTrue(item.setData(tiff, forType: .tiff))
        XCTAssertEqual(item.data(forType: .png), png)
        XCTAssertEqual(item.data(forType: .tiff), tiff)
        XCTAssertTrue(pasteboard.writeObjects([item]))
        // Verify the actual declared payloads after system publication.
        // AppKit may expose additional synthesized types; no total type-count
        // assumption is needed for these two explicit representations.
        XCTAssertEqual(pasteboard.data(forType: .png), png)
        XCTAssertEqual(pasteboard.data(forType: .tiff), tiff)

        let app = XCUIApplication()
        defer { app.terminate() }
        let details = try launchAndOpenCapturedDetails(in: app)
        assertVisibleText("Content type icon", in: details, app: app)
        assertVisibleText("public.png", in: details, app: app)
        assertVisibleText("70 bytes", in: details, app: app)
        assertVisibleText("public.tiff", in: details, app: app)
        assertVisibleText("13 bytes", in: details, app: app)
        assertNoRepresentationImage("public.png", in: details, app: app)
        assertNoRepresentationImage("public.tiff", in: details, app: app)
        clickPreview("public.png", in: details, app: app)
        assertVisibleElement(matching: NSPredicate(
            format: "identifier == %@", "clipy.details.image-preview.public.png"
        ), in: details, app: app, context: "explicit PNG preview")
        // A completed PNG decode cannot stand in for the still-unread TIFF.
        assertNoRepresentationImage("public.tiff", in: details, app: app)
        clickPreview("public.tiff", in: details, app: app)
        assertVisibleText("Preview unavailable for public.tiff", in: details, app: app)
        assertNoRepresentationImage("public.tiff", in: details, app: app)
        XCTAssertEqual(pasteboard.data(forType: .png), png)
        XCTAssertEqual(pasteboard.data(forType: .tiff), tiff)
    }

    @MainActor
    private func launchAndOpenCapturedDetails(in app: XCUIApplication) throws -> XCUIElement {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        temporaryDirectory = directory

        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory
            .appendingPathComponent("history.store")
            .path
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
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
            diagnostic(app, context: "real image capture")
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
        return details
    }

    @MainActor
    private func assertVisibleText(_ value: String, in details: XCUIElement, app: XCUIApplication) {
        let predicate = NSPredicate(format: "label == %@ OR value == %@", value, value)
        assertVisibleElement(matching: predicate, in: details, app: app, context: value)
    }

    @MainActor
    private func clickPreview(_ type: String, in details: XCUIElement, app: XCUIApplication) {
        let identifier = "clipy.details.show-preview." + type
        assertVisibleElement(matching: NSPredicate(format: "identifier == %@", identifier),
                             in: details, app: app, context: identifier)
        let button = details.buttons[identifier]
        XCTAssertTrue(button.isEnabled, diagnostic(app, context: "enabled explicit preview: \(type)"))
        button.click()
    }

    @MainActor
    private func assertVisibleElement(
        matching predicate: NSPredicate, in details: XCUIElement,
        app: XCUIApplication, context: String
    ) {
        let element = details.descendants(matching: .any).matching(predicate).firstMatch
        guard waitUntil(timeout: 10, condition: { element.exists }) else {
            XCTFail(diagnostic(app, context: "missing Details element: \(context)"))
            return
        }
        // Grouped Form exposes offscreen children as existing. The observed
        // narrow Details viewport ended at y629 while Content began at y653.
        // Find the owning Form rather than scrolling a sibling preview or
        // the other column of the wide Details layout.
        guard let scrollView = details.scrollViews.allElementsBoundByIndex.first(where: {
            $0.descendants(matching: .any).matching(predicate).firstMatch.exists
        }) else {
            XCTFail(diagnostic(app, context: "owning Details scroll view: \(context)"))
            return
        }
        let scrollCoordinate = scrollView.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        func isFullyVisible() -> Bool {
            element.exists && scrollView.frame.contains(element.frame) && element.isHittable
        }
        // Same bounded native wheel steps used by the Settings Form journeys.
        for _ in 0..<8 {
            if isFullyVisible() { return }
            let deltaY: CGFloat = element.frame.midY < scrollView.frame.midY ? 50 : -50
            scrollCoordinate.scroll(byDeltaX: 0, deltaY: deltaY)
        }
        XCTAssertTrue(
            isFullyVisible(),
            diagnostic(app, context: "visible Details element: \(context)")
        )
    }

    @MainActor
    private func assertNoRepresentationImage(
        _ type: String, in details: XCUIElement, app: XCUIApplication
    ) {
        XCTAssertFalse(
            details.descendants(matching: .any).matching(
                NSPredicate(format: "identifier == %@", "clipy.details.image-preview." + type)
            ).firstMatch.exists,
            diagnostic(app, context: "item thumbnail must not stand in for \(type)")
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
