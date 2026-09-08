/// Physical Left/Right preview placement under Apple's RTL pseudolanguage.
/// The search controls must actually mirror, while the preview column and
/// its drag handle keep the same screen-space geometry as the AppKit window.
import AppKit
import XCTest

final class RTLPreviewGeometryJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testPhysicalPreviewSidesAndDividerRemainUsableWithRTLContent() throws {
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

        let preview = panel.descendants(matching: .any)["clipy.preview.root"]
        let divider = panel.descendants(matching: .any)["clipy.panel.previewDivider"]
        for side in ["Right", "Left"] {
            let isRight = side == "Right"
            openAppearance(in: app)
            let sideControl = app.descendants(matching: .any)["clipy.settings.appearance.preview-side"]
            let positionControl = app.descendants(matching: .any)["clipy.settings.appearance.panel-position"]
            choose(side, in: sideControl, app: app)
            choose("At Mouse Cursor", in: positionControl, app: app)
            let autoOpen = app.switches["clipy.settings.appearance.preview-auto-open"]
            XCTAssertTrue(autoOpen.waitForExistence(timeout: 5), app.debugDescription)
            if (autoOpen.value as? Int) == 0 { autoOpen.click() }
            XCTAssertTrue(waitUntil(timeout: 5) {
                (autoOpen.value as? Int) == 1
            }, app.debugDescription)
            let reset = app.buttons["clipy.settings.appearance.reset-panel-size"]
            XCTAssertTrue(reset.waitForExistence(timeout: 5), app.debugDescription)
            reset.click()
            // A 400-point main column at x=40 has space to expand right;
            // at x=400 it has space to expand left on the 1024-point runner.
            // Keep the real pointer in place through Cmd-W and keyboard summon.
            sideControl.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .withOffset(CGVector(dx: (isRight ? 40 : 400) - sideControl.frame.midX, dy: 0))
                .hover()
            app.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(waitUntil(timeout: 5) { !sideControl.exists }, app.debugDescription)
            app.typeKey("c", modifierFlags: [.command, .shift])
            XCTAssertTrue(panel.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(preview.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(divider.waitForExistence(timeout: 5), app.debugDescription)
            divider.doubleClick()
            XCTAssertTrue(waitUntil(timeout: 5) {
                preview.exists && abs(preview.frame.width - 320) <= 3
            }, app.debugDescription)

            // Reset Panel Size does not reset the independently persisted
            // preview width, and divider reset deliberately leaves the window
            // frame fixed. Reopen after both resets so this side's measured
            // baseline uses 400 + 1 + 320 even if a prior run left width 260.
            openAppearance(in: app)
            XCTAssertTrue(reset.waitForExistence(timeout: 5), app.debugDescription)
            reset.click()
            XCTAssertTrue(sideControl.waitForExistence(timeout: 5), app.debugDescription)
            sideControl.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .withOffset(CGVector(dx: (isRight ? 40 : 400) - sideControl.frame.midX, dy: 0))
                .hover()
            app.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(waitUntil(timeout: 5) { !sideControl.exists }, app.debugDescription)
            app.typeKey("c", modifierFlags: [.command, .shift])
            XCTAssertTrue(panel.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(preview.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(divider.waitForExistence(timeout: 5), app.debugDescription)

            let expectedOffset: CGFloat = isRight ? 400.5 : 320.5
            XCTAssertTrue(waitUntil(timeout: 5) {
                abs(panel.frame.width - 721) <= 3
                    && abs(divider.frame.midX - panel.frame.minX - expectedOffset) <= 3
                    && abs(preview.frame.width - 320) <= 3
                    && (isRight
                        ? preview.frame.minX > divider.frame.midX
                        : preview.frame.maxX < divider.frame.midX)
            }, "\(side) preview must stay on its physical side.\n\(app.debugDescription)")
            XCTAssertLessThan(filter.frame.maxX, search.frame.minX, app.debugDescription)
            let baseline = panel.frame
            let translation: CGFloat = isRight ? 60 : -60
            let start = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.click(
                forDuration: 0.3,
                thenDragTo: start.withOffset(CGVector(dx: translation, dy: 0)),
                withVelocity: XCUIGestureVelocity(rawValue: 40),
                thenHoldForDuration: 0.5
            )
            XCTAssertTrue(waitUntil(timeout: 5) {
                preview.exists && divider.exists
                    && abs(divider.frame.midX - panel.frame.minX - expectedOffset - translation) <= 3
                    && abs(preview.frame.width - 260) <= 3
            }, "\(side) divider must follow the complete drag.\n\(app.debugDescription)")
            assertFrame(panel.frame, equals: baseline)

            divider.doubleClick()
            XCTAssertTrue(waitUntil(timeout: 5) {
                preview.exists && divider.exists
                    && abs(divider.frame.midX - panel.frame.minX - expectedOffset) <= 3
                    && abs(preview.frame.width - 320) <= 3
            }, "\(side) divider must reset.\n\(app.debugDescription)")
            assertFrame(panel.frame, equals: baseline)

            // Closing preserves the physical edge the user just resized.
            // Pull that real edge inward to reopen, without a second launch
            // or a programmatic preview-state transition.
            app.typeKey(.space, modifierFlags: .control)
            let edge = panel.descendants(matching: .any)["clipy.panel.previewEdgeOpener"]
            // The opener's 6 pt band sits inset 6 pt from the window edge so
            // its press clears the AppKit live-resize track a `.resizable`
            // window owns at its border; the strip's center is 9 pt in.
            XCTAssertTrue(waitUntil(timeout: 5) {
                !preview.exists && edge.exists && edge.isHittable
                    && abs(panel.frame.width - 400) <= 3
                    && abs(edge.frame.midX - (isRight
                        ? panel.frame.maxX - 9
                        : panel.frame.minX + 9)) <= 1
            }, "\(side) closed preview must keep its physical pull edge.\n\(app.debugDescription)")
            assertFrame(panel.frame, equals: CGRect(
                x: isRight ? baseline.minX : baseline.maxX - 400,
                y: baseline.minY, width: 400, height: baseline.height
            ))
            let edgeStart = edge.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            edgeStart.click(
                forDuration: 0.3,
                thenDragTo: edgeStart.withOffset(CGVector(dx: -translation, dy: 0)),
                withVelocity: XCUIGestureVelocity(rawValue: 40),
                thenHoldForDuration: 0.5
            )
            XCTAssertTrue(waitUntil(timeout: 5) {
                preview.exists && divider.exists
                    && abs(panel.frame.width - baseline.width) <= 3
                    && abs(divider.frame.midX - panel.frame.minX - expectedOffset) <= 3
                    && abs(preview.frame.width - 320) <= 3
            }, "\(side) inward edge pull must restore the preview.\n\(app.debugDescription)")
            assertFrame(panel.frame, equals: baseline)
        }

        // Each side has already restored preview width 320 without changing
        // the 400-point main column. Leave the shared settings at their
        // normal side/position and tab for the next running-app journey.
        openAppearance(in: app)
        choose("Automatic", in: app.descendants(matching: .any)[
            "clipy.settings.appearance.preview-side"
        ], app: app)
        let general = app.buttons["General"]
        XCTAssertTrue(general.waitForExistence(timeout: 5), app.debugDescription)
        general.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil(timeout: 5) { !general.exists }, app.debugDescription)
    }

    @MainActor
    private func openAppearance(in app: XCUIApplication) {
        app.typeKey(",", modifierFlags: .command)
        let tab = app.buttons["Appearance"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), app.debugDescription)
        tab.click()
    }

    @MainActor
    private func choose(_ title: String, in control: XCUIElement, app: XCUIApplication) {
        XCTAssertTrue(control.waitForExistence(timeout: 5), app.debugDescription)
        control.click()
        // Scope to this real picker; the Window menu also has Left/Right.
        let option = control.menuItems[title]
        XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
        option.click()
    }

    private func assertFrame(_ frame: CGRect, equals baseline: CGRect) {
        XCTAssertEqual(frame.minX, baseline.minX, accuracy: 3)
        XCTAssertEqual(frame.minY, baseline.minY, accuracy: 3)
        XCTAssertEqual(frame.width, baseline.width, accuracy: 3)
        XCTAssertEqual(frame.height, baseline.height, accuracy: 3)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() }, object: nil
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
