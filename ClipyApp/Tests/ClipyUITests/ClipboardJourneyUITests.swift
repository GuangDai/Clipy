/// ClipboardJourneyUITests.swift — the first Card 15 running-app vertical
/// tracer. The DEBUG launch seam changes only the store path and privacy
/// posture; capture, search, keyboard selection, paste payload resolution,
/// General pasteboard write, and panel close remain production paths.
import AppKit
import XCTest

final class ClipboardJourneyUITests: XCTestCase {
    private var temporaryDirectory: URL?
    private var loginItemsSettingsMarkerURL: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        loginItemsSettingsMarkerURL = nil
        try super.tearDownWithError()
    }

    @MainActor
    func testSummonSearchArrowReturnWritesGeneralPasteboardAndCloses() throws {
        let alpha = "clipy-ui-journey-alpha"
        let beta = "clipy-ui-journey-beta"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(alpha, forType: .string))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        temporaryDirectory = directory

        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory
            .appendingPathComponent("history.store")
            .path
        app.launch()

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        XCTAssertTrue(panel.waitForExistence(timeout: 20))

        let search = app.textFields["clipy.search.field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))

        let rows = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "clipy.history.row."
            )
        )
        XCTAssertTrue(waitUntil(timeout: 10) { rows.count == 1 })

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(beta, forType: .string))
        XCTAssertTrue(waitUntil(timeout: 10) { rows.count == 2 })

        // Do not click: successful typing and the filtered rows below prove
        // that panel-open focus reached the search field.
        search.typeText("clipy-ui-journey-")
        XCTAssertTrue(waitUntil(timeout: 10) { rows.count == 2 })
        let renderedRows = rows.allElementsBoundByIndex
        XCTAssertEqual(renderedRows.count, 2)
        XCTAssertTrue(renderedRows.allSatisfy {
            $0.elementType == .button
        })
        let labels = renderedRows.map(\.label)
        XCTAssertTrue(labels.contains(where: { $0.contains(alpha) }))
        XCTAssertTrue(labels.contains(where: { $0.contains(beta) }))

        // The replacement search page selects newest beta. Down must move to
        // alpha, making the final byte-exact paste distinguish arrow routing
        // from merely leaving the initial selection untouched.
        search.typeKey(.downArrow, modifierFlags: [])
        pasteboard.clearContents()
        let sentinel = NSPasteboardItem()
        XCTAssertTrue(
            sentinel.setString(
                "before-product-paste",
                forType: .string
            )
        )
        // Keep the assertion sentinel out of History so this proof observes
        // only selection/paste routing, not a competing third capture commit.
        XCTAssertTrue(sentinel.setData(
            Data(),
            forType: NSPasteboard.PasteboardType(
                "org.nspasteboard.TransientType"
            )
        ))
        XCTAssertTrue(pasteboard.writeObjects([sentinel]))
        search.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(waitUntil(timeout: 10) { !panel.exists })
        XCTAssertTrue(
            waitUntil(timeout: 10) {
                pasteboard.string(forType: .string) == alpha
            },
            "Expected selected alpha, observed \(pasteboard.string(forType: .string) ?? "nil")"
        )
    }

    @MainActor
    func testSettingsExposeLaunchStatesAndConfirmStrictAgeRetention() throws {
        let app = try launchApp(
            capturing: "clipy-ui-settings-original",
            launchAtLoginRequiresApproval: true
        )
        defer { app.terminate() }
        let loginItemsSettingsMarker = try XCTUnwrap(
            loginItemsSettingsMarkerURL
        )

        app.typeKey(",", modifierFlags: .command)
        let launchAtLogin = app.switches[
            "clipy.settings.launch-at-login"
        ]
        XCTAssertTrue(launchAtLogin.waitForExistence(timeout: 10))
        XCTAssertTrue(launchAtLogin.isEnabled)
        XCTAssertTrue(launchAtLogin.isHittable)
        XCTAssertEqual(launchAtLogin.value as? Int, 1)

        let approvalRequired = app.descendants(matching: .any)[
            "clipy.settings.launch-at-login.approval-required"
        ]
        XCTAssertTrue(approvalRequired.waitForExistence(timeout: 5))
        XCTAssertEqual(
            accessibilityText(of: approvalRequired),
            "Approval is required in System Settings."
        )

        let openLoginItemsSettings = app.buttons[
            "clipy.settings.launch-at-login.open-system-settings"
        ]
        XCTAssertTrue(openLoginItemsSettings.waitForExistence(timeout: 5))
        XCTAssertTrue(openLoginItemsSettings.isHittable)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: loginItemsSettingsMarker.path
        ))
        openLoginItemsSettings.click()
        XCTAssertTrue(waitUntil(timeout: 5) {
            FileManager.default.fileExists(
                atPath: loginItemsSettingsMarker.path
            )
        })

        // Approval is registered-but-not-enabled. The on Toggle must still
        // let the user unregister through the production controller, after
        // which the approval copy and recovery action disappear together.
        launchAtLogin.click()
        XCTAssertTrue(waitUntil(timeout: 5) {
            launchAtLogin.exists
                && launchAtLogin.value as? Int == 0
                && !approvalRequired.exists
                && !openLoginItemsSettings.exists
        })

        // A successful register reaches authoritative enabled without
        // approval copy. This distinguishes ordinary on from the earlier
        // registered-but-awaiting-approval presentation in the same process.
        launchAtLogin.click()
        XCTAssertTrue(waitUntil(timeout: 5) {
            launchAtLogin.exists
                && launchAtLogin.isEnabled
                && launchAtLogin.value as? Int == 1
        })
        XCTAssertFalse(approvalRequired.exists)
        XCTAssertFalse(openLoginItemsSettings.exists)

        // The injected true-external boundary next reports a failed
        // unregister and a fresh notFound status. The real Toggle action must
        // keep unavailable distinct from ordinary off and retain the separate
        // operation-failure episode; neither may offer approval recovery.
        launchAtLogin.click()
        let unavailable = app.descendants(matching: .any)[
            "clipy.settings.launch-at-login.unavailable"
        ]
        let operationFailed = app.descendants(matching: .any)[
            "clipy.settings.launch-at-login.operation-failed"
        ]
        XCTAssertTrue(waitUntil(timeout: 5) {
            unavailable.exists
                && operationFailed.exists
                && !launchAtLogin.isEnabled
        })
        XCTAssertEqual(
            accessibilityText(of: unavailable),
            "Launch at Login is unavailable for this app."
        )
        XCTAssertEqual(
            accessibilityText(of: operationFailed),
            "The Launch at Login setting couldn't be changed."
        )
        XCTAssertFalse(approvalRequired.exists)
        XCTAssertFalse(openLoginItemsSettings.exists)

        // Card 14B: the real General scene receives the AppDelegate-owned
        // neutral shortcut state. The default's advisory remains visible; the
        // real recorder opens and Escape cancels without changing the binding.
        // This does not claim signed Carbon delivery or layout behavior.
        let shortcutStatus = app.descendants(matching: .any)[
            "clipy.settings.shortcut.status"
        ]
        let shortcutWarning = app.staticTexts[
            "clipy.settings.shortcut.warning"
        ]
        let shortcutReset = app.buttons["clipy.settings.shortcut.reset"]
        let shortcutChange = app.buttons["clipy.settings.shortcut.change"]
        XCTAssertTrue(shortcutStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(shortcutWarning.waitForExistence(timeout: 5))
        XCTAssertEqual(
            accessibilityText(of: shortcutWarning),
            "This shortcut is also the standard Show Colors shortcut."
        )
        XCTAssertTrue(shortcutReset.waitForExistence(timeout: 5))
        XCTAssertTrue(shortcutReset.isEnabled)
        XCTAssertTrue(shortcutChange.waitForExistence(timeout: 5))
        XCTAssertTrue(shortcutChange.isEnabled)
        shortcutChange.click()
        let recorderTitle = app.staticTexts["Change Summon Shortcut"]
        XCTAssertTrue(recorderTitle.waitForExistence(timeout: 5))
        app.typeKey("k", modifierFlags: [])
        let recordingError = app.staticTexts[
            "clipy.settings.shortcut.recording-error"
        ]
        XCTAssertTrue(recordingError.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil(timeout: 5) { !recorderTitle.exists })
        XCTAssertTrue(shortcutStatus.exists)
        XCTAssertTrue(shortcutWarning.exists)

        // Re-recording the already-active default traverses the accepted
        // candidate tail without asking the shared CI account for a second
        // Carbon registration or making an environmental conflict assertion.
        shortcutChange.click()
        XCTAssertTrue(recorderTitle.waitForExistence(timeout: 5))
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil(timeout: 5) { !recorderTitle.exists })
        XCTAssertTrue(shortcutStatus.exists)
        XCTAssertTrue(shortcutWarning.exists)
        shortcutReset.click()
        XCTAssertTrue(shortcutStatus.exists)
        XCTAssertTrue(shortcutWarning.exists)

        let retentionTab = app.buttons["Retention"]
        XCTAssertTrue(retentionTab.waitForExistence(timeout: 5))
        retentionTab.click()

        let ageLimit = app.switches[
            "clipy.settings.retention.age-enabled"
        ]
        XCTAssertTrue(ageLimit.waitForExistence(timeout: 5))
        let settingsWindow = app.windows.containing(
            .textField,
            identifier: "clipy.settings.retention.age-days"
        ).firstMatch
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
        let retentionScrollView = settingsWindow.scrollViews.firstMatch
        XCTAssertTrue(retentionScrollView.waitForExistence(timeout: 5))
        ageLimit.click()

        let apply = app.buttons[
            "clipy.settings.retention.apply"
        ]
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        XCTAssertTrue(apply.isEnabled)
        guard scrollUntilFullyVisible(
            apply,
            in: retentionScrollView,
            app: app,
            context: "strict age retention Apply"
        ) else { return }
        apply.click()

        let destructiveApply = app.buttons["Apply Stricter Limits"]
        XCTAssertTrue(destructiveApply.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts[
                "Stricter limits can permanently remove items or revisions."
            ].exists
        )
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil(timeout: 5) { !destructiveApply.exists })
        XCTAssertTrue(ageLimit.exists)
        XCTAssertEqual(ageLimit.value as? Int, 1)
    }

    /// SwiftUI's grouped Form exposes offscreen descendants as existing even
    /// though macOS cannot compute a hit point for them. Move the real owning
    /// scroll view in bounded wheel increments until the requested control is
    /// inside its visible viewport and hittable.
    @MainActor
    @discardableResult
    private func scrollUntilFullyVisible(
        _ element: XCUIElement,
        in scrollView: XCUIElement,
        app: XCUIApplication,
        context: String
    ) -> Bool {
        let scrollCoordinate = scrollView.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        func isFullyVisible() -> Bool {
            element.exists
                && scrollView.frame.contains(element.frame)
                && element.isHittable
        }
        for _ in 0..<8 {
            if isFullyVisible() {
                return true
            }
            let deltaY: CGFloat = element.frame.midY < scrollView.frame.midY
                ? 50
                : -50
            scrollCoordinate.scroll(byDeltaX: 0, deltaY: deltaY)
        }
        let result = isFullyVisible()
        XCTAssertTrue(
            result,
            "\(context) did not scroll into view\n\(app.debugDescription)"
        )
        return result
    }

    /// SwiftUI Text commonly exposes its literal through AXValue on macOS;
    /// explicit labels remain the bridge fallback.
    @MainActor
    private func accessibilityText(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty {
            return value
        }
        return element.label
    }

    @MainActor
    private func launchApp(
        capturing value: String,
        launchAtLoginRequiresApproval: Bool = false
    ) throws -> XCUIApplication {
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
        if launchAtLoginRequiresApproval {
            let markerURL = directory.appendingPathComponent(
                "login-items-settings-opened"
            )
            loginItemsSettingsMarkerURL = markerURL
            app.launchEnvironment[
                "CLIPY_UI_TEST_LAUNCH_AT_LOGIN_STATUS"
            ] = "requires-approval"
            app.launchEnvironment[
                "CLIPY_UI_TEST_LOGIN_ITEMS_SETTINGS_MARKER_PATH"
            ] = markerURL.path
        }
        app.launch()

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        XCTAssertTrue(panel.waitForExistence(timeout: 20))
        return app
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
}
