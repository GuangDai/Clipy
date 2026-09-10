/// AppearanceJourneyUITests.swift — running-app proofs for the wave-2
/// Appearance surface: the row-density switch applying live and persisting
/// across summons, the preview auto-open preference gating the floating
/// pane's selection dwell, and the search filter menu narrowing the loaded
/// rows. The DEBUG launch seam changes only the store path and
/// capture-access posture; the `clipy.appearance.*` preferences live in the
/// app's real UserDefaults domain, and every journey that edits one
/// (density, auto-open) resets it in-test to keep the suite
/// order-independent.
///
/// Row-density points (`PanelTheme` metrics) are not published through the
/// public accessibility tree. The preview is the transient floating pane
/// (a separate child window, AX id clipy.panel.floatingPreview), so preview
/// queries scope to the app, never to the main panel's descendants.
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
    /// switching to Comfortable, the resummoned panel still renders the captured
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
        chooseOption("Comfortable", in: density, app: app, context: "row density")

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

        // Restore the compact product default for later journeys.
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
            "Compact",
            in: restoreDensity,
            app: app,
            context: "row density restore"
        )
        // Leave the Settings window on the default tab: the window restores
        // its selected tab across launches, and later journeys must not
        // inherit the Appearance tab.
        let generalTab = app.buttons["clipy.settings.category.general"]
        assertExists(generalTab, timeout: 5, in: app, context: "General tab")
        generalTab.click()
        app.typeKey("w", modifierFlags: .command)
    }

    /// With the auto-open preference off, selecting a row and outwaiting the
    /// production 200 ms dwell must not present the floating preview pane;
    /// re-enabling the preference restores the dwell on the next session's
    /// selection (PreviewPaneState's preference gate takes effect on the
    /// next selection change, and a summon supplies one).
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
        // preference more than the dwell interval, so a still-absent floating
        // pane is a stable negative rather than a race with the timer. The
        // pane is a separate child window now, so the query scopes to the
        // app, never to the panel's descendants.
        Thread.sleep(forTimeInterval: 0.5)
        let preview = app.descendants(matching: .any)["clipy.preview.root"]
        XCTAssertFalse(
            preview.exists,
            diagnostic(app, context: "disabled auto-open must stop the dwell")
        )

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
        // Same tab-neutral finish as the density restore above, then prove
        // the gate reopened: the resummoned panel's own selection dwell
        // presents the floating pane without any further input.
        let generalTab = app.buttons["clipy.settings.category.general"]
        assertExists(generalTab, timeout: 5, in: app, context: "General tab")
        generalTab.click()
        closeSettingsAndSummonPanel(control: generalTab, panel: panel, app: app)
        assertExists(
            preview,
            timeout: 10,
            in: app,
            context: "re-enabled auto-open restores the selection dwell"
        )
    }

    /// The menu changes the History query: with one plain-text item,
    /// Links narrows to zero rows and the search empty state, then All
    /// restores the captured row without dismissing the floating panel.
    @MainActor
    func testFilterMenuNarrowsRows() throws {
        let captured = "alpha-filter-check"
        let app = try launchApp(capturing: captured)
        defer { app.terminate() }

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        let rows = historyRows(in: app)
        assertRowCount(1, in: rows, app: app, context: "filter initial capture")

        let filter = app.descendants(matching: .any)["clipy.search.filter"]
        assertExists(filter, timeout: 5, in: app, context: "search filter menu")
        filter.click()
        let links = app.menuItems["Links"]
        assertExists(links, timeout: 5, in: app, context: "Links filter item")
        XCTAssertTrue(links.isHittable, diagnostic(app, context: "inline Links choice"))
        links.click()
        XCTAssertTrue(panel.exists, diagnostic(app, context: "panel remains open after Links"))
        XCTAssertEqual(filter.value as? String, "Links", diagnostic(app, context: "Links was selected"))

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
        XCTAssertTrue(all.isHittable, diagnostic(app, context: "inline All choice"))
        all.click()
        // A closed panel also reports zero AX rows. Verify the interaction
        // before judging the asynchronous History observation's row result.
        XCTAssertTrue(panel.exists, diagnostic(app, context: "panel remains open after All"))
        XCTAssertEqual(filter.value as? String, "All", diagnostic(app, context: "All was selected"))
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
        let appearanceTab = app.buttons["clipy.settings.category.appearance"]
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
