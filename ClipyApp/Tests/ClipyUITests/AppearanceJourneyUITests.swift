/// AppearanceJourneyUITests.swift — running-app proofs for the wave-2
/// Appearance surface: the row-density switch applying live and persisting
/// across summons, the preview auto-open preference gating the selection
/// dwell, the search filter menu narrowing the loaded rows, and the preview
/// divider's free drag and double-click reset. The DEBUG launch seam changes
/// only the store path and capture-access posture; the `clipy.appearance.*`
/// preferences live in the app's real UserDefaults domain, and the divider
/// journey resets the persisted width in-test to keep the suite
/// order-independent.
///
/// Row-density points (`PanelTheme` metrics) and the preview column's width
/// are not published through the public accessibility tree. These journeys
/// therefore prove the end-to-end wiring (Settings control → persisted
/// preference → next panel open; divider gesture → live column) and assert
/// only AX-visible evidence: the panel root, the stable row identifiers, the
/// preview root, and the empty-state copy.
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
    /// Column points are not AX-assertable, so the journey proves the
    /// gesture wiring only: the divider exists while the preview is open,
    /// and the preview root plus the panel root survive both the drag and
    /// the reset. The reset runs in-test, so the persisted width leaves no
    /// residue for later journeys.
    @MainActor
    func testPreviewDividerDragAndReset() throws {
        let app = try launchApp(capturing: "clipy-preview-divider-check")
        defer { app.terminate() }

        let panel = app.descendants(matching: .any)["clipy.panel.root"]

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

        // A conservative rightward drag: the trailing placement narrows the
        // preview, and the 240…480 clamp keeps either direction safe.
        let dividerCenter = divider.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        dividerCenter.press(
            forDuration: 0.3,
            thenDragTo: dividerCenter.withOffset(CGVector(dx: 80, dy: 0))
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
        let menuItem = app.menuItems[title]
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
