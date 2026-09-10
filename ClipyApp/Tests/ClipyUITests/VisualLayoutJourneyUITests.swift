/// Actual running-app screenshots over real clipboard captures. Attachments
/// show the native layout at two widths; they are visual review evidence,
/// while the assertions establish which product surfaces were captured.
import AppKit
import XCTest

final class VisualLayoutJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testCompactWidePreviewDetailsAndSettingsScreenshots() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipy-visual-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        XCTAssertTrue(pasteboard.setString(
            "Reading notes\nA short paragraph with a second line for the clipboard list.", forType: .string
        ))
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("history.sqlite").path
        app.launch()
        defer { app.terminate() }
        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        XCTAssertTrue(panel.waitForExistence(timeout: 20), app.debugDescription)
        let rows = panel.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "clipy.history.row."
        ))
        XCTAssertTrue(waitUntil { rows.count == 1 }, app.debugDescription)

        // The preview is now a transient FLOATING pane beside the panel: it
        // never changes the panel's width, so the compact/wide captures need
        // no preview preference at all. Only the panel position is set here.
        app.typeKey(",", modifierFlags: .command)
        let appearance = app.buttons["clipy.settings.category.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 10), app.debugDescription)
        appearance.click()
        let position = app.descendants(matching: .any)["clipy.settings.appearance.panel-position"]
        XCTAssertTrue(position.waitForExistence(timeout: 5), app.debugDescription)
        let appearanceForm = app.scrollViews.containing(
            .any, identifier: "clipy.settings.appearance.panel-position"
        ).firstMatch
        SettingsJourneyControls.scroll(position, into: appearanceForm, app: app)
        position.click()
        let center = position.menuItems["At Screen Center"]
        XCTAssertTrue(center.waitForExistence(timeout: 5), app.debugDescription)
        center.click()
        let settingsWindow = app.windows.containing(
            .button, identifier: "clipy.settings.category.appearance"
        ).firstMatch
        XCTAssertTrue(settingsWindow.exists, app.debugDescription)
        attach(settingsWindow, named: "Settings — Appearance and sidebar")
        app.buttons["clipy.settings.category.general"].click()
        let launchAtLogin = app.switches["clipy.settings.launch-at-login"]
        XCTAssertTrue(launchAtLogin.waitForExistence(timeout: 5), app.debugDescription)
        attach(settingsWindow, named: "Settings — General")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil { !settingsWindow.exists }, app.debugDescription)
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(panel.waitForExistence(timeout: 10), app.debugDescription)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("https://example.org/reading-notes", forType: .URL))
        XCTAssertTrue(waitUntil { rows.count == 2 }, app.debugDescription)
        let previousIDs = Set(rows.allElementsBoundByIndex.map(\.identifier))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(try samplePNG(), forType: .png))
        XCTAssertTrue(waitUntil { rows.count == 3 }, app.debugDescription)
        let imageRow = try XCTUnwrap(rows.allElementsBoundByIndex.first { !previousIDs.contains($0.identifier) })
        imageRow.click()
        // The preview is the floating child pane now — a separate window, so
        // scope its content queries to the app, not the panel. Auto-open
        // dwells from the selection; the pane never touches the panel's
        // width, so the compact/wide captures need no preview juggling.
        let preview = app.descendants(matching: .any)["clipy.preview.root"]

        resize(panel, toWidth: 400)
        XCTAssertTrue(waitUntil { abs(panel.frame.width - 400) <= 4 && rows.count == 3 }, app.debugDescription)
        attach(panel, named: "History — Compact text, link and image")
        let compactWidth = panel.frame.width
        resize(panel, toWidth: 760)
        XCTAssertTrue(waitUntil { panel.frame.width >= compactWidth + 200 }, app.debugDescription)
        attach(panel, named: "History — Wide")

        imageRow.click()
        let image = preview.descendants(matching: .any)["clipy.preview.image"]
        XCTAssertTrue(waitUntil { preview.exists && image.exists && image.isHittable }, app.debugDescription)
        // The floating pane sits beside the panel: capture the whole app so
        // the attachment shows both windows.
        attach(app, named: "History — Floating image preview")
        let information = preview.buttons["clipy.preview.information"]
        XCTAssertTrue(information.exists && information.isHittable, app.debugDescription)
        information.click()
        let informationContent = app.descendants(matching: .any)["clipy.preview.information.content"]
        XCTAssertTrue(informationContent.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(image.exists,
                      "Crossing another row to open Information must not replace the selected image.\n\(app.debugDescription)")
        attach(app, named: "Preview — Information popover")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { !informationContent.exists }, app.debugDescription)
        XCTAssertTrue(panel.exists && imageRow.exists, "Escape must dismiss information without closing History: \(app.debugDescription)")

        imageRow.rightClick()
        let showDetails = app.menuItems["Show Details"]
        XCTAssertTrue(showDetails.waitForExistence(timeout: 5), app.debugDescription)
        showDetails.click()
        let details = app.descendants(matching: .any)["clipy.details.root"]
        XCTAssertTrue(details.waitForExistence(timeout: 10), app.debugDescription)
        let pin = details.buttons["clipy.details.pin-toggle"]
        XCTAssertTrue(waitUntil { pin.exists && pin.isEnabled }, app.debugDescription)
        attach(panel, named: "Details — Image and actions")
    }

    @MainActor
    private func resize(_ panel: XCUIElement, toWidth width: CGFloat) {
        let edge = panel.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.7))
            .withOffset(CGVector(dx: -1, dy: 0))
        edge.press(forDuration: 0.1, thenDragTo: edge.withOffset(CGVector(dx: width - panel.frame.width, dy: 0)))
    }

    @MainActor
    private func attach(_ surface: XCUIElement, named name: String) {
        let attachment = XCTAttachment(screenshot: surface.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func samplePNG() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 360, pixelsHigh: 220,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        NSColor(calibratedRed: 0.14, green: 0.32, blue: 0.62, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 360, height: 220)).fill()
        NSColor(calibratedRed: 0.95, green: 0.73, blue: 0.35, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 205, y: 92, width: 76, height: 76)).fill()
        NSColor(calibratedRed: 0.35, green: 0.66, blue: 0.65, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 35, y: 28, width: 290, height: 48), xRadius: 12, yRadius: 12).fill()
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }
}
