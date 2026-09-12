/// Physical floating-preview placement under Apple's RTL pseudolanguage.
/// The search controls must actually mirror, while the floating preview
/// pane keeps PHYSICAL left/right screen geometry — `floatingPreviewFrame`
/// is deliberately not layout-direction aware — and the main panel keeps
/// its 360-point width (the pane is a separate child window now, never an
/// in-window expansion).
import AppKit
import XCTest

final class RTLPreviewGeometryJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testFloatingPreviewKeepsPhysicalSidesWithRTLContent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        XCTAssertTrue(pasteboard.setString("clipy-rtl-preview-geometry", forType: .string))

        let app = XCUIApplication()
        // Apple's documented Mac RTL test arguments work without adding an
        // Arabic localization or a product-only layout-direction switch.
        app.launchArguments += [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-NSForceRightToLeftWritingDirection", "YES", "-AppleTextDirection", "YES",
            "-panelPosition", "cursor",
            "-clipy.appearance.previewAutoOpen", "YES",
            "-clipy.panelContentWidth", "360", "-clipy.panelHeight", "420",
            "-clipy.preview.panelGap", "2",
        ]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory
            .appendingPathComponent("history.store").path
        app.launch()
        defer { app.terminate() }

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        XCTAssertTrue(panel.waitForExistence(timeout: 20), app.debugDescription)
        let rows = panel.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "clipy.history.row.")
        )
        XCTAssertTrue(waitUntil(timeout: 10) {
            rows.count == 1 && rows.firstMatch.label.contains("clipy-rtl-preview-geometry")
        }, app.debugDescription)

        let search = panel.textFields["clipy.search.field"]
        let mode = panel.descendants(matching: .any)["clipy.search.mode"]
        let filter = panel.descendants(matching: .any)["clipy.search.filter"]
        // The adaptive header can move the menus below Search, but these two
        // controls remain on the same row. Filter follows Mode in source
        // order, so its physical position is on the LEFT only under RTL.
        // A full-panel LTR override or ineffective launch args still fails.
        XCTAssertTrue(waitUntil(timeout: 5) {
            search.exists && mode.exists && filter.exists
                && search.isHittable && mode.isHittable && filter.isHittable
                && filter.frame.maxX < mode.frame.minX
                && filter.frame.minY < mode.frame.maxY
                && mode.frame.minY < filter.frame.maxY
        }, app.debugDescription)

        // This journey covers panel RTL and physical preview placement.
        // Settings' RTL detail AX viewport mismatch remains a separate,
        // unresolved issue; launch preferences provide only this setup.
        // Move the real pointer using the visible panel, then start a fresh
        // dwell at x=40 with room for the 360-point panel and trailing pane.
        panel.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: 40 - panel.frame.minX, dy: 0))
            .hover()
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil(timeout: 5) { !panel.exists }, app.debugDescription)
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(panel.waitForExistence(timeout: 10), app.debugDescription)

        let pane = app.descendants(matching: .any)["clipy.panel.floatingPreview"]
        XCTAssertTrue(
            pane.waitForExistence(timeout: 10),
            "auto-open dwell must present the floating pane.\n\(app.debugDescription)"
        )
        let content = pane.descendants(matching: .any)["clipy.preview.root"]
        XCTAssertTrue(content.waitForExistence(timeout: 5),
                      "The window identifier must not replace its preview content identifier")
        XCTAssertTrue(content.descendants(matching: .any)["clipy.preview.text"].waitForExistence(timeout: 5))
        let compactWidth: CGFloat = 360
        let paneWidth: CGFloat = 340
        let gap: CGFloat = 2
        // Under RTL the pane still goes to the PHYSICAL trailing (right)
        // side: top edges align, the panel keeps its compact width, and the
        // pane is a separate window rather than panel content.
        XCTAssertTrue(waitUntil(timeout: 5) {
            abs(panel.frame.width - compactWidth) <= 3
                && abs(pane.frame.width - paneWidth) <= 3
                && abs(pane.frame.minX - panel.frame.maxX - gap) <= 3
                && abs(pane.frame.minY - panel.frame.minY) <= 3
                && pane.frame.height > 0 && pane.frame.height < 140
        }, "trailing floating pane under RTL.\n\(app.debugDescription)")

        // Esc dismisses the floating pane first (a manual close); the panel
        // stays open.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil(timeout: 5) { !pane.exists && panel.exists },
                      "Esc must dismiss the floating pane before the panel.\n\(app.debugDescription)")

        // Reopen near the screen's right edge: no trailing room, so the pane
        // flips to the PHYSICAL leading (left) side without resizing or
        // moving the main panel. Move the real pointer first, then close and
        // re-summon at the cursor.
        panel.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: 900 - panel.frame.minX, dy: 0))
            .hover()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil(timeout: 5) { !panel.exists }, app.debugDescription)
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(panel.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(
            pane.waitForExistence(timeout: 10),
            "the reopened session's dwell must present the floating pane.\n\(app.debugDescription)"
        )
        XCTAssertTrue(waitUntil(timeout: 5) {
            abs(panel.frame.width - compactWidth) <= 3
                && abs(pane.frame.width - paneWidth) <= 3
                && abs(pane.frame.maxX + gap - panel.frame.minX) <= 3
                && abs(pane.frame.minY - panel.frame.minY) <= 3
        }, "leading floating pane at the screen's right edge under RTL.\n\(app.debugDescription)")
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() }, object: nil
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
