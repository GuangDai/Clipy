/// AppearanceJourneyUITests.swift — running-app proofs for the wave-2
/// Appearance surface: the row-density switch applying live and persisting
/// across summons, the preview auto-open preference gating the selection
/// dwell, the search filter menu narrowing the loaded rows, and the preview
/// divider's free drag and double-click reset. The DEBUG launch seam changes
/// only the store path and capture-access posture; the `clipy.appearance.*`
/// preferences live in the app's real UserDefaults domain, and every journey
/// that edits one (density, auto-open, divider width) resets it in-test to
/// keep the suite order-independent.
///
/// Row-density points (`PanelTheme` metrics) are not published through the
/// public accessibility tree. Divider geometry is observable through the
/// real panel and divider frames: its relative position proves resizing and
/// reset without reading a private preference or adding a measurement view.
import AppKit
import XCTest

final class AppearanceJourneyUITests: XCTestCase {
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

    /// The density switch persists through `@AppStorage` and applies live;
    /// this journey proves the wiring end-to-end across a resummon: after
    /// switching to Compact, the resummoned panel still renders the captured
    /// row. Density pixels are not AX-assertable.
    @MainActor
    func testRowDensitySwitchPersistsAcrossSummons() throws {
        let captured = "clipy-density-row-check"
        let app = try launchApp(capturing: captured)
        defer { app.terminate() }

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        let rows = historyRows(in: app)
        assertRowCount(1, in: rows, app: app, context: "density initial capture")

        openAppearanceTab(in: app)
        let density = app.descendants(matching: .any)[
            "clipy.settings.appearance.row-density"
        ]
        assertExists(density, timeout: 5, in: app, context: "row density control")
        chooseOption("Compact", in: density, app: app, context: "row density")

        closeSettingsAndSummonPanel(control: density, panel: panel, app: app)
        assertRowCount(
            1,
            in: rows,
            app: app,
            context: "row survives the density switch"
        )
        XCTAssertTrue(
            rows.firstMatch.label.contains(captured),
            diagnostic(app, context: "density journey row title")
        )

        // Restore Comfortable so later journeys sharing the runner's real
        // defaults domain are not left on compact metrics.
        openAppearanceTab(in: app)
        let restoreDensity = app.descendants(matching: .any)[
            "clipy.settings.appearance.row-density"
        ]
        assertExists(
            restoreDensity,
            timeout: 5,
            in: app,
            context: "row density restore control"
        )
        chooseOption(
            "Comfortable",
            in: restoreDensity,
            app: app,
            context: "row density restore"
        )
        // Leave the Settings window on the default tab: the window restores
        // its selected tab across launches, and later journeys must not
        // inherit the Appearance tab.
        let generalTab = app.buttons["General"]
        assertExists(generalTab, timeout: 5, in: app, context: "General tab")
        generalTab.click()
        app.typeKey("w", modifierFlags: .command)
    }

    /// With the auto-open preference off, selecting a row and outwaiting the
    /// production 200 ms dwell must not open the preview column; the
    /// product's documented manual toggle (⌃Space) still opens it.
    @MainActor
    func testPreviewAutoOpenDisabledStopsTheDwell() throws {
        let app = try launchApp(capturing: "clipy-auto-open-dwell-check")
        defer { app.terminate() }

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        let rows = historyRows(in: app)
        assertRowCount(
            1,
            in: rows,
            app: app,
            context: "auto-open initial capture"
        )

        openAppearanceTab(in: app)
        let autoOpen = app.switches[
            "clipy.settings.appearance.preview-auto-open"
        ]
        assertExists(
            autoOpen,
            timeout: 5,
            in: app,
            context: "preview auto-open toggle"
        )
        // The preference persists across launches in the app's real
        // UserDefaults domain, so a previous run may have left it off; only
        // an on toggle needs the click to reach the disabled state.
        if (autoOpen.value as? Int) == 1 {
            autoOpen.click()
        }
        XCTAssertTrue(
            waitUntil(timeout: 5) { (autoOpen.value as? Int) == 0 },
            diagnostic(app, context: "auto-open preference off")
        )

        closeSettingsAndSummonPanel(control: autoOpen, panel: panel, app: app)
        let search = app.textFields["clipy.search.field"]
        assertExists(
            search,
            timeout: 5,
            in: app,
            context: "resummoned search field"
        )
        search.typeKey(.downArrow, modifierFlags: [])

        // The production dwell is 200 ms; 500 ms gives the disabled
        // preference more than the dwell interval, so a still-absent preview
        // is a stable negative rather than a race with the timer.
        Thread.sleep(forTimeInterval: 0.5)
        let preview = app.descendants(matching: .any)["clipy.preview.root"]
        XCTAssertFalse(
            preview.exists,
            diagnostic(app, context: "disabled auto-open must stop the dwell")
        )

        app.typeKey(.space, modifierFlags: .control)
        assertExists(preview, timeout: 5, in: app, context: "manual preview toggle")

        // Restore the default-on preference so later journeys relying on the
        // production dwell are not left with auto-open disabled.
        openAppearanceTab(in: app)
        let restoreToggle = app.switches[
            "clipy.settings.appearance.preview-auto-open"
        ]
        assertExists(
            restoreToggle,
            timeout: 5,
            in: app,
            context: "auto-open restore toggle"
        )
        if (restoreToggle.value as? Int) == 0 {
            restoreToggle.click()
        }
        XCTAssertTrue(
            waitUntil(timeout: 5) { (restoreToggle.value as? Int) == 1 },
            diagnostic(app, context: "auto-open preference restored")
        )
        // Same tab-neutral finish as the density restore above.
        let generalTab = app.buttons["General"]
        assertExists(generalTab, timeout: 5, in: app, context: "General tab")
        generalTab.click()
        app.typeKey("w", modifierFlags: .command)
    }

    /// The type filter is client-side over the loaded rows: with one
    /// plain-text item, Links narrows to zero rows and the search empty
    /// state, and All restores the captured row.
    @MainActor
    func testFilterMenuNarrowsRows() throws {
        let captured = "alpha-filter-check"
        let app = try launchApp(capturing: captured)
        defer { app.terminate() }

        let rows = historyRows(in: app)
        assertRowCount(1, in: rows, app: app, context: "filter initial capture")

        let filter = app.descendants(matching: .any)["clipy.search.filter"]
        assertExists(filter, timeout: 5, in: app, context: "search filter menu")
        filter.click()
        let links = app.menuItems["Links"]
        assertExists(links, timeout: 5, in: app, context: "Links filter item")
        links.click()

        XCTAssertTrue(
            waitUntil(timeout: 10) { rows.count == 0 },
            diagnostic(app, context: "Links narrows out the text row")
        )
        XCTAssertTrue(
            app.staticTexts["No Results"].waitForExistence(timeout: 5),
            diagnostic(app, context: "filtered empty state")
        )

        filter.click()
        let all = app.menuItems["All"]
        assertExists(all, timeout: 5, in: app, context: "All filter item")
        all.click()
        assertRowCount(
            1,
            in: rows,
            app: app,
            context: "All restores the text row"
        )
        XCTAssertTrue(
            rows.firstMatch.label.contains(captured),
            diagnostic(app, context: "filter journey row title")
        )
    }

    /// The preview divider drags the column live inside the FIXED window
    /// (the browsing column absorbs the trade; the AppKit frame never
    /// moves), and a double click resets the width to the 320 default.
    /// A trailing preview makes a rightward drag shrink its measured span.
    /// The real AX frames prove movement relative to the fixed panel, then
    /// a return to the reset baseline. Edited preferences are restored using
    /// the same Settings controls before the journey finishes.
    @MainActor
    func testPreviewDividerDragAndReset() throws {
        let app = try launchApp(capturing: "clipy-preview-divider-check")
        defer { app.terminate() }

        let panel = app.descendants(matching: .any)["clipy.panel.root"]

        // Even an explicit Right preference can flip near a screen edge.
        // A 400-point main panel centered on the 1024-point CI screen leaves
        // only 312 points to its right, less than the 321-point preview.
        // Use the real cursor-placement setting with space for that expansion.
        openAppearanceTab(in: app)
        let previewSide = app.descendants(matching: .any)[
            "clipy.settings.appearance.preview-side"
        ]
        let panelPosition = app.descendants(matching: .any)[
            "clipy.settings.appearance.panel-position"
        ]
        let resetPanelSize = app.buttons["clipy.settings.appearance.reset-panel-size"]
        assertExists(previewSide, timeout: 5, in: app, context: "preview side control")
        assertExists(panelPosition, timeout: 5, in: app, context: "panel position control")
        assertExists(resetPanelSize, timeout: 5, in: app, context: "panel size reset control")
        chooseOption("Right", in: previewSide, app: app, context: "trailing preview")
        chooseOption("At Mouse Cursor", in: panelPosition, app: app, context: "cursor-placed panel")
        resetPanelSize.click()
        // Move only the pointer while the coordinate's real Settings
        // control still exists. Cmd-W and the summon shortcut below keep
        // this x=40 position, leaving room for the trailing preview.
        previewSide.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 40 - previewSide.frame.midX, dy: 0))
            .hover()
        closeSettingsAndSummonPanel(control: previewSide, panel: panel, app: app)

        // The selected row normally opens Preview through the production
        // 200 ms dwell. If the preference left by an earlier journey has not
        // fired it, use the product's documented Control-Space toggle.
        let preview = app.descendants(matching: .any)["clipy.preview.root"]
        if !preview.waitForExistence(timeout: 3) {
            app.typeKey(.space, modifierFlags: .control)
        }
        assertExists(
            preview,
            timeout: 5,
            in: app,
            context: "preview open for the divider drag"
        )

        let divider = app.descendants(matching: .any)[
            "clipy.panel.previewDivider"
        ]
        assertExists(divider, timeout: 5, in: app, context: "preview divider")

        // Start from the real 320-point reset width, independent of an
        // earlier run's persisted adjustment. The 1-point divider's center
        // adds half a point to the right-side span measured from AX frames.
        divider.doubleClick()
        assertExists(preview, timeout: 5, in: app, context: "preview reset before resizing")
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                preview.frame.midX > divider.frame.midX
                    && abs(panel.frame.maxX - divider.frame.midX - 320.5) <= 3
            },
            diagnostic(app, context: "trailing preview at its 320-point reset width")
        )
        let baselinePanelFrame = panel.frame
        let baselineDividerOffset = divider.frame.midX - baselinePanelFrame.minX
        let baselinePreviewSpan = baselinePanelFrame.maxX - divider.frame.midX

        // This journey exercises settled resizing. The default 500px/s drag
        // with immediate release can legitimately trigger fling-to-collapse
        // even when its final width is above the threshold. Use XCTest's
        // explicit pointer velocity and hold at the endpoint before release.
        let dividerCenter = divider.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        dividerCenter.click(
            forDuration: 0.3,
            // 320 → 260 avoids both the 240-point settled minimum and the
            // 280 ± 8-point magnetic stop (PanelGeometry).
            thenDragTo: dividerCenter.withOffset(CGVector(dx: 60, dy: 0)),
            withVelocity: XCUIGestureVelocity(rawValue: 40),
            thenHoldForDuration: 0.5
        )
        assertExists(
            preview,
            timeout: 5,
            in: app,
            context: "preview survives the divider drag"
        )
        XCTAssertTrue(
            panel.exists,
            diagnostic(app, context: "panel intact after the divider drag")
        )
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                abs(divider.frame.midX - panel.frame.minX - baselineDividerOffset - 60) <= 3
            },
            diagnostic(app, context: "slow drag moves divider right from offset \(baselineDividerOffset)")
        )
        let draggedPanelFrame = panel.frame
        let draggedPreviewSpan = draggedPanelFrame.maxX - divider.frame.midX
        XCTAssertEqual(draggedPreviewSpan, baselinePreviewSpan - 60, accuracy: 3,
                       diagnostic(app, context: "preview follows the complete pointer displacement"))
        // The drag must settle above the 240-point floor; its observed AX
        // displacement, not the requested pointer distance, is the proof.
        XCTAssertGreaterThanOrEqual(draggedPreviewSpan, 237.5,
                                    diagnostic(app, context: "preview respects settled minimum"))
        XCTAssertEqual(draggedPanelFrame.minX, baselinePanelFrame.minX, accuracy: 3)
        XCTAssertEqual(draggedPanelFrame.minY, baselinePanelFrame.minY, accuracy: 3)
        XCTAssertEqual(draggedPanelFrame.width, baselinePanelFrame.width, accuracy: 3)
        XCTAssertEqual(draggedPanelFrame.height, baselinePanelFrame.height, accuracy: 3)

        divider.doubleClick()
        assertExists(
            preview,
            timeout: 5,
            in: app,
            context: "preview survives the divider reset"
        )
        XCTAssertTrue(
            panel.exists,
            diagnostic(app, context: "panel intact after the divider reset")
        )
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                abs((divider.frame.midX - panel.frame.minX) - baselineDividerOffset) <= 3
                    && abs((panel.frame.maxX - divider.frame.midX) - baselinePreviewSpan) <= 3
            },
            diagnostic(app, context: "double-click restores the measured divider baseline")
        )
        XCTAssertEqual(panel.frame.minX, baselinePanelFrame.minX, accuracy: 3)
        XCTAssertEqual(panel.frame.minY, baselinePanelFrame.minY, accuracy: 3)
        XCTAssertEqual(panel.frame.width, baselinePanelFrame.width, accuracy: 3)
        XCTAssertEqual(panel.frame.height, baselinePanelFrame.height, accuracy: 3)

        // The advertised 9-point strip must admit drags on both sides of
        // the visual separator, not only at its center. Each attempt starts
        // after a real reset and obtains fresh frames and pointer coordinates.
        for hitOffset in [CGFloat(-3), CGFloat(3)] {
            let sidePanelFrame = panel.frame
            let sideDividerOffset = divider.frame.midX - sidePanelFrame.minX
            let sidePreviewSpan = sidePanelFrame.maxX - divider.frame.midX
            let sideStart = divider.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            ).withOffset(CGVector(dx: hitOffset, dy: 0))
            sideStart.click(
                forDuration: 0.3,
                thenDragTo: sideStart.withOffset(CGVector(dx: 60, dy: 0)),
                withVelocity: XCUIGestureVelocity(rawValue: 40),
                thenHoldForDuration: 0.5
            )
            assertExists(
                preview, timeout: 5, in: app,
                context: "preview survives divider hit offset \(hitOffset)"
            )
            XCTAssertTrue(
                waitUntil(timeout: 5) {
                    panel.exists && divider.exists
                        && abs(divider.frame.midX - panel.frame.minX - sideDividerOffset - 60) <= 3
                },
                diagnostic(app, context: "divider moves from hit offset \(hitOffset)")
            )
            let sideDraggedFrame = panel.frame
            let sideDraggedSpan = sideDraggedFrame.maxX - divider.frame.midX
            XCTAssertEqual(
                sideDraggedSpan, sidePreviewSpan - 60, accuracy: 3,
                diagnostic(app, context: "side hit \(hitOffset) follows the complete pointer displacement")
            )
            XCTAssertGreaterThanOrEqual(sideDraggedSpan, 237.5)
            XCTAssertEqual(sideDraggedFrame.minX, sidePanelFrame.minX, accuracy: 3)
            XCTAssertEqual(sideDraggedFrame.minY, sidePanelFrame.minY, accuracy: 3)
            XCTAssertEqual(sideDraggedFrame.width, sidePanelFrame.width, accuracy: 3)
            XCTAssertEqual(sideDraggedFrame.height, sidePanelFrame.height, accuracy: 3)

            divider.doubleClick()
            assertExists(
                preview, timeout: 5, in: app,
                context: "preview survives reset after hit offset \(hitOffset)"
            )
            XCTAssertTrue(
                waitUntil(timeout: 5) {
                    panel.exists && divider.exists
                        && abs((divider.frame.midX - panel.frame.minX) - sideDividerOffset) <= 3
                        && abs((panel.frame.maxX - divider.frame.midX) - sidePreviewSpan) <= 3
                },
                diagnostic(app, context: "double-click resets side hit \(hitOffset)")
            )
            XCTAssertEqual(panel.frame.minX, sidePanelFrame.minX, accuracy: 3)
            XCTAssertEqual(panel.frame.minY, sidePanelFrame.minY, accuracy: 3)
            XCTAssertEqual(panel.frame.width, sidePanelFrame.width, accuracy: 3)
            XCTAssertEqual(panel.frame.height, sidePanelFrame.height, accuracy: 3)
        }

        // Header background drag moves the whole window, not either column.
        // Stay horizontal: x=40 plus the 721-point panel and a 60-point move
        // fits the 1024-point runner without invoking screen-edge clamping.
        let searchField = app.textFields["clipy.search.field"]
        let firstRow = historyRows(in: app).firstMatch
        assertExists(searchField, timeout: 5, in: app, context: "search field before header drag")
        assertExists(firstRow, timeout: 5, in: app, context: "first row below header drag")
        let beforeHeaderDragFrame = panel.frame
        for windowTranslation in [CGFloat(60), CGFloat(-60)] {
            let windowFrame = panel.frame
            let searchFrame = searchField.frame
            let windowDividerOffset = divider.frame.midX - windowFrame.minX
            let windowPreviewSpan = windowFrame.maxX - divider.frame.midX
            // Search has 6 points of inner bottom padding; another 3 points
            // reaches the middle of the header's 6-point outer padding.
            // Check the live AX geometry before dispatching either drag.
            let headerPoint = CGPoint(x: searchFrame.midX, y: searchFrame.maxY + 9)
            XCTAssertTrue(windowFrame.contains(headerPoint))
            XCTAssertFalse(searchFrame.contains(headerPoint))
            XCTAssertLessThan(headerPoint.y, firstRow.frame.minY)
            let headerStart = panel.coordinate(
                withNormalizedOffset: CGVector(dx: 0, dy: 0)
            ).withOffset(CGVector(
                dx: headerPoint.x - windowFrame.minX,
                dy: headerPoint.y - windowFrame.minY
            ))
            headerStart.click(
                forDuration: 0.3,
                thenDragTo: headerStart.withOffset(CGVector(dx: windowTranslation, dy: 0)),
                withVelocity: XCUIGestureVelocity(rawValue: 40),
                thenHoldForDuration: 0.5
            )
            XCTAssertTrue(
                waitUntil(timeout: 5) {
                    panel.exists
                        && abs(panel.frame.minX - windowFrame.minX - windowTranslation) <= 3
                },
                diagnostic(app, context: "header moves window by \(windowTranslation) points")
            )
            assertExists(preview, timeout: 5, in: app, context: "preview survives header drag")
            let movedWindowFrame = panel.frame
            XCTAssertEqual(movedWindowFrame.minY, windowFrame.minY, accuracy: 3)
            XCTAssertEqual(movedWindowFrame.width, windowFrame.width, accuracy: 3)
            XCTAssertEqual(movedWindowFrame.height, windowFrame.height, accuracy: 3)
            XCTAssertEqual(
                divider.frame.midX - movedWindowFrame.minX, windowDividerOffset, accuracy: 3
            )
            XCTAssertEqual(
                movedWindowFrame.maxX - divider.frame.midX, windowPreviewSpan, accuracy: 3
            )
        }
        XCTAssertEqual(panel.frame.minX, beforeHeaderDragFrame.minX, accuracy: 3)
        XCTAssertEqual(panel.frame.minY, beforeHeaderDragFrame.minY, accuracy: 3)
        XCTAssertEqual(panel.frame.width, beforeHeaderDragFrame.width, accuracy: 3)
        XCTAssertEqual(panel.frame.height, beforeHeaderDragFrame.height, accuracy: 3)

        openAppearanceTab(in: app)
        assertExists(previewSide, timeout: 5, in: app, context: "preview side restore control")
        assertExists(panelPosition, timeout: 5, in: app, context: "panel position restore control")
        chooseOption("Automatic", in: previewSide, app: app, context: "preview side restore")
        chooseOption("At Mouse Cursor", in: panelPosition, app: app, context: "panel position restore")
        let generalTab = app.buttons["General"]
        assertExists(generalTab, timeout: 5, in: app, context: "General tab")
        generalTab.click()
        app.typeKey("w", modifierFlags: .command)
    }

    @MainActor
    private func launchApp(capturing value: String) throws -> XCUIApplication {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(value, forType: .string))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        temporaryDirectory = directory

        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory
            .appendingPathComponent("history.store")
            .path
        app.launch()

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        assertExists(panel, timeout: 20, in: app, context: "initial panel")
        return app
    }

    @MainActor
    private func openAppearanceTab(in app: XCUIApplication) {
        app.typeKey(",", modifierFlags: .command)
        let appearanceTab = app.buttons["Appearance"]
        assertExists(
            appearanceTab,
            timeout: 10,
            in: app,
            context: "Settings Appearance tab"
        )
        appearanceTab.click()
    }

    @MainActor
    private func closeSettingsAndSummonPanel(
        control: XCUIElement,
        panel: XCUIElement,
        app: XCUIApplication
    ) {
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(
            waitUntil(timeout: 5) { !control.exists },
            diagnostic(app, context: "Settings window close")
        )
        app.typeKey("c", modifierFlags: [.command, .shift])
        assertExists(panel, timeout: 10, in: app, context: "resummoned panel")
    }

    /// Segmented/radio bridges expose one labeled child per option, while
    /// menu-style pickers expose their items only after the control opens.
    /// Try the labeled descendant first, then the pop-up route.
    @MainActor
    private func chooseOption(
        _ title: String,
        in control: XCUIElement,
        app: XCUIApplication,
        context: String
    ) {
        let labeledChoice = control.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", title)
        ).firstMatch
        if labeledChoice.waitForExistence(timeout: 2) {
            labeledChoice.click()
            return
        }
        control.click()
        // The system Window menu also has a "Right" move/resize command.
        // The opened picker owns its own native menu in the AX tree.
        let menuItem = control.menuItems[title]
        assertExists(menuItem, timeout: 5, in: app, context: "\(context) option")
        menuItem.click()
    }

    @MainActor
    private func historyRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "clipy.history.row."
            )
        )
    }

    @MainActor
    private func assertRowCount(
        _ expected: Int,
        in rows: XCUIElementQuery,
        app: XCUIApplication,
        context: String
    ) {
        XCTAssertTrue(
            waitUntil(timeout: 30) { rows.count == expected },
            diagnostic(
                app,
                context: "\(context); expected \(expected) rows, observed \(rows.count)"
            )
        )
    }

    @MainActor
    private func assertExists(
        _ element: XCUIElement,
        timeout: TimeInterval,
        in app: XCUIApplication,
        context: String
    ) {
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            diagnostic(app, context: context)
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
        return XCTWaiter.wait(
            for: [expectation],
            timeout: timeout
        ) == .completed
    }

    @MainActor
    private func diagnostic(
        _ app: XCUIApplication,
        context: String
    ) -> String {
        "\(context)\n\(app.debugDescription)"
    }
}
