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
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        addTeardownBlock { @MainActor () async in pasteboard.clearContents() }
        XCTAssertTrue(pasteboard.setString("clipy-rtl-preview-geometry", forType: .string))

        let app = XCUIApplication()
        // Apple's documented Mac RTL test arguments work without adding an
        // Arabic localization or a product-only layout-direction switch.
        app.launchArguments += [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-clipy.language", "system",
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
        addTeardownBlock { @MainActor () async in app.terminate() }
        app.launch()

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        let window = app.dialogs.containing(.textField, identifier: "clipy.search.field").firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(window.exists, app.debugDescription)
        let rows = panel.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "clipy.history.row.")
        )
        XCTAssertTrue(waitUntil(timeout: 10) {
            rows.count == 1 && rows.firstMatch.label.contains("clipy-rtl-preview-geometry")
        }, app.debugDescription)

        let search = panel.textFields["clipy.search.field"]
        let mode = panel.descendants(matching: .any)["clipy.search.mode"]
        let sort = panel.descendants(matching: .any)["clipy.search.sort"]
        let filter = panel.descendants(matching: .any)["clipy.search.filter"]
        // Match and Sort share a controls row beneath Search and Filter.
        // Sort follows Match in source order, so its physical position is
        // on the left only when the header actually mirrors for RTL.
        XCTAssertTrue(waitUntil(timeout: 5) {
            search.exists && mode.exists && sort.exists && filter.exists
                && search.isHittable && mode.isHittable && sort.isHittable && filter.isHittable
                && sort.frame.maxX < mode.frame.minX
                && sort.frame.minY < mode.frame.maxY
                && mode.frame.minY < sort.frame.maxY
        }, app.debugDescription)

        // This journey covers panel RTL and physical preview placement.
        // Settings' RTL detail AX viewport mismatch remains a separate,
        // unresolved issue; launch preferences provide only this setup.
        // Move the real pointer using the visible panel, then start a fresh
        // dwell at x=40 with room for the 360-point panel and trailing pane.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: 40 - window.frame.minX, dy: 0))
            .hover()
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil(timeout: 5) { !panel.exists }, app.debugDescription)
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(panel.waitForExistence(timeout: 10), app.debugDescription)
        HistoryJourneyControls.selectFirst(in: app)

        let pane = app.dialogs["clipy.panel.floatingPreview"]
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
            abs(window.frame.width - compactWidth) <= 3
                && abs(pane.frame.width - paneWidth) <= 3
                && abs(pane.frame.minX - window.frame.maxX - gap) <= 3
                && abs(pane.frame.minY - window.frame.minY) <= 3
                && pane.frame.height > 0
                && abs(pane.frame.height - window.frame.height) <= 3
        }, "trailing floating pane under RTL.\n\(app.debugDescription)")
        let resizedWidth = resizePreview(pane, beside: window, isOnLeft: false, in: app)

        // One Escape retires both windows even when the preview has focus.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil(timeout: 5) { !pane.exists && !panel.exists },
                      "Esc must dismiss the panel and its floating preview together.\n\(app.debugDescription)")

        // Reopen near the screen's right edge: no trailing room, so the pane
        // flips to the PHYSICAL leading (left) side without resizing or
        // moving the main panel. Move the real pointer first, then close and
        // re-summon at the cursor.
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(panel.waitForExistence(timeout: 10), app.debugDescription)
        HistoryJourneyControls.selectFirst(in: app)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: 900 - window.frame.minX, dy: 0))
            .hover()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil(timeout: 5) { !panel.exists }, app.debugDescription)
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(panel.waitForExistence(timeout: 10), app.debugDescription)
        HistoryJourneyControls.selectFirst(in: app)
        XCTAssertTrue(
            pane.waitForExistence(timeout: 10),
            "the reopened session's dwell must present the floating pane.\n\(app.debugDescription)"
        )
        XCTAssertTrue(waitUntil(timeout: 5) {
            abs(window.frame.width - compactWidth) <= 3
                && abs(pane.frame.width - resizedWidth) <= 3
                && abs(pane.frame.maxX + gap - window.frame.minX) <= 3
                && abs(pane.frame.minY - window.frame.minY) <= 3
                && pane.frame.height > 0
                && abs(pane.frame.height - window.frame.height) <= 3
        }, "leading floating pane at the screen's right edge under RTL.\n\(app.debugDescription)")
        _ = resizePreview(pane, beside: window, isOnLeft: true, in: app)
    }

    @MainActor
    private func resizePreview(
        _ pane: XCUIElement, beside window: XCUIElement, isOnLeft: Bool, in app: XCUIApplication
    ) -> CGFloat {
        let handle = pane.descendants(matching: .any)["clipy.preview.resize-width"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5), app.debugDescription)
        let initial = pane.frame
        let mainFrame = window.frame
        let outerEdge = isOnLeft ? initial.minX : initial.maxX
        let handleEdge = isOnLeft ? handle.frame.minX : handle.frame.maxX
        let contentEdge = isOnLeft ? initial.maxX : initial.minX
        XCTAssertEqual(handleEdge, outerEdge, accuracy: 2, app.debugDescription)

        let distance: CGFloat = 48
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.4, thenDragTo: start.withOffset(CGVector(
            dx: isOnLeft ? distance : -distance, dy: 0
        )), withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(waitUntil(timeout: 5) {
            pane.exists && abs(pane.frame.width - (initial.width - distance)) <= 6
        }, app.debugDescription)

        let draggedWidth = pane.frame.width
        let outwardKey: XCUIKeyboardKey = isOnLeft ? .leftArrow : .rightArrow
        app.typeKey(outwardKey, modifierFlags: [])
        XCTAssertTrue(waitUntil(timeout: 5) {
            pane.exists && pane.frame.width > draggedWidth
        }, "The focused handle must grow outwards by keyboard.\n\(app.debugDescription)")
        XCTAssertEqual(isOnLeft ? pane.frame.maxX : pane.frame.minX, contentEdge, accuracy: 2)
        XCTAssertEqual(window.frame, mainFrame)
        return pane.frame.width
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() }, object: nil
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
