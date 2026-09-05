/// SearchAndAccessibilityJourneyUITests.swift — running-app leaves for the
/// panel search-clear focus contract and the row's public accessibility
/// default action. Both journeys cross the real Clipy process boundary; no
/// SwiftUI/private accessibility-tree inspection or callback test seam is
/// involved.
import AppKit
import ApplicationServices
import XCTest

final class SearchAndAccessibilityJourneyUITests: XCTestCase {
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

    /// UI-7 / Card 14A: panel-open focus accepts typing without a click; the
    /// visible Clear control restores the recent page and explicitly returns
    /// focus to the search field, so a second bare typing operation edits the
    /// query rather than disappearing into the panel shortcut surface.
    @MainActor
    func testSearchClearRestoresRecentPageAndKeepsSearchFocused() throws {
        let captured = "clipy-ui-clear-alpha"
        let app = try launchApp(capturing: captured)
        defer { app.terminate() }

        let search = app.textFields["clipy.search.field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        let rows = historyRows(in: app)
        XCTAssertTrue(waitUntil(timeout: 10) { rows.count == 1 })

        // Deliberately do not click the field. This is the panel-open focus
        // half of the contract.
        search.typeText("no-such-clipy-value")
        let clear = app.buttons["clipy.search.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "no-such-clipy-value")

        XCTAssertTrue(
            clear.isHittable,
            "The visible Clear control must expose a hittable frame.\n\(clear.debugDescription)"
        )
        clear.click()
        XCTAssertTrue(
            waitUntil(timeout: 10) { !clear.exists },
            "Clear did not mutate the bound query.\n\(app.debugDescription)"
        )
        XCTAssertTrue(waitUntil(timeout: 10) { rows.count == 1 })
        XCTAssertEqual(search.value as? String, "")
        XCTAssertTrue(rows.element(boundBy: 0).label.contains(captured))

        // Again do not click the field: Clear's production callback must
        // have restored focus. A suffix unique to the retained row yields a
        // real filtered page and makes misrouted keystrokes observable.
        search.typeText("alpha")
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "alpha")
        XCTAssertTrue(waitUntil(timeout: 10) { rows.count == 1 })
        XCTAssertTrue(rows.element(boundBy: 0).label.contains(captured))
    }

    /// Exercise language selection in the real generated application, not
    /// just an explicitly opened .lproj bundle. Clipboard text stays literal
    /// while the surrounding search actions use the requested app language.
    @MainActor
    func testChineseSearchCopyAndClearUsePackagedTranslations() throws {
        let captured = "clipy-ui-localized-alpha"
        let app = try launchApp(
            capturing: captured, language: "zh-Hans", locale: "zh_CN"
        )
        defer { app.terminate() }

        let search = app.textFields["clipy.search.field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertEqual(search.label, "搜索剪贴板历史记录")
        let rows = historyRows(in: app)
        XCTAssertTrue(waitUntil(timeout: 10) { rows.count == 1 })
        XCTAssertTrue(rows.element(boundBy: 0).label.contains(captured))

        search.typeText("no-such-clipy-value")
        let clear = app.buttons["clipy.search.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        XCTAssertEqual(clear.label, "清除搜索")
        XCTAssertTrue(waitUntil(timeout: 10) { rows.count == 0 })
        XCTAssertTrue(app.staticTexts["无结果"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[
            "没有与“no-such-clipy-value”匹配的项目。"
        ].exists)

        clear.click()
        XCTAssertTrue(waitUntil(timeout: 10) { !clear.exists && rows.count == 1 })
        XCTAssertEqual(search.value as? String, "")
        XCTAssertTrue(rows.element(boundBy: 0).label.contains(captured))
        // Localized controls must preserve the same focus restoration.
        search.typeText("alpha")
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "alpha")
        XCTAssertTrue(waitUntil(timeout: 10) { rows.count == 1 })
    }

    /// Card 15 / UI-16: resolve the running row by its exact stable
    /// AXIdentifier, invoke the public AXPress default action, and observe the
    /// production Copy pipeline's General-pasteboard bytes and panel close.
    ///
    /// Accessibility authorization belongs to the signed runner environment,
    /// not the product. An unauthorized runner is therefore reported as an
    /// explicit skipped physical-evidence cell rather than a product pass.
    @MainActor
    func testExactRowAXPressCopiesToGeneralPasteboardAndClosesPanel() throws {
        guard AXIsProcessTrusted() else {
            throw XCTSkip(
                "The UI-test runner lacks macOS Accessibility authorization; "
                    + "grant it to execute the running-app AXPress cell."
            )
        }

        let captured = "clipy-ui-ax-default-copy"
        let pasteboard = NSPasteboard.general
        let app = try launchApp(capturing: captured)
        defer { app.terminate() }

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        let rows = historyRows(in: app)
        XCTAssertTrue(waitUntil(timeout: 10) { rows.count == 1 })
        let row = rows.element(boundBy: 0)
        XCTAssertTrue(row.label.contains(captured))
        let exactIdentifier = row.identifier
        XCTAssertTrue(exactIdentifier.hasPrefix("clipy.history.row."))

        let runningApplications = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.clipy.ClipyApp"
        )
        XCTAssertEqual(runningApplications.count, 1)
        let processIdentifier = try XCTUnwrap(
            runningApplications.first?.processIdentifier
        )
        let applicationElement = AXUIElementCreateApplication(
            processIdentifier
        )
        let accessibilityRow = try XCTUnwrap(
            findAccessibilityElement(
                beneath: applicationElement,
                exactIdentifier: exactIdentifier
            ),
            "The running app must publish the stable row AXIdentifier."
        )
        XCTAssertEqual(
            accessibilityString(
                accessibilityRow,
                attribute: kAXRoleAttribute
            ),
            kAXButtonRole
        )
        XCTAssertTrue(
            accessibilityActionNames(of: accessibilityRow).contains(
                kAXPressAction
            )
        )

        pasteboard.clearContents()
        XCTAssertTrue(
            pasteboard.setString("before-ax-default-copy", forType: .string)
        )
        XCTAssertEqual(
            AXUIElementPerformAction(
                accessibilityRow,
                kAXPressAction as CFString
            ),
            .success
        )

        XCTAssertTrue(waitUntil(timeout: 10) { !panel.exists })
        XCTAssertTrue(waitUntil(timeout: 10) {
            pasteboard.string(forType: .string) == captured
        })
    }

    @MainActor
    private func launchApp(
        capturing value: String,
        language: String = "en",
        locale: String = "en_US"
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
        app.launchArguments += [
            "-AppleLanguages", "(\(language))", "-AppleLocale", locale
        ]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory
            .appendingPathComponent("history.store")
            .path
        app.launch()

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        XCTAssertTrue(panel.waitForExistence(timeout: 20))
        return app
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

    /// Breadth-first traversal of the target process's public AX children.
    /// The stable identifier is the sole match key; row labels and screen
    /// positions are intentionally not treated as identity.
    private func findAccessibilityElement(
        beneath root: AXUIElement,
        exactIdentifier: String
    ) -> AXUIElement? {
        var pending = [root]
        var index = 0

        while index < pending.count && index < 4_096 {
            let element = pending[index]
            index += 1

            if accessibilityString(
                element,
                attribute: kAXIdentifierAttribute
            ) == exactIdentifier {
                return element
            }
            pending.append(
                contentsOf: accessibilityChildren(of: element)
            )
        }
        return nil
    }

    private func accessibilityActionNames(
        of element: AXUIElement
    ) -> [String] {
        var value: CFArray?
        guard AXUIElementCopyActionNames(element, &value) == .success else {
            return []
        }
        return value as? [String] ?? []
    }

    private func accessibilityString(
        _ element: AXUIElement,
        attribute: String
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private func accessibilityChildren(
        of element: AXUIElement
    ) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
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
