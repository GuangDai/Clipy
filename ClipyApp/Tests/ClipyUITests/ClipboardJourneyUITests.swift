/// ClipboardJourneyUITests.swift — the first Card 15 running-app vertical
/// tracer. The DEBUG launch seam changes only the store path and privacy
/// posture; capture, search, keyboard selection, paste payload resolution,
/// General pasteboard write, and panel close remain production paths.
import AppKit
import XCTest

final class ClipboardJourneyUITests: XCTestCase {
    private let revisionDisclosure =
        "Save appends an immutable revision. Previous and original content "
        + "may remain in this item's revision history."

    private var temporaryDirectory: URL?

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
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
        XCTAssertTrue(
            pasteboard.setString(
                "before-product-paste",
                forType: .string
            )
        )
        search.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(waitUntil(timeout: 10) { !panel.exists })
        XCTAssertTrue(waitUntil(timeout: 10) {
            pasteboard.string(forType: .string) == alpha
        })
    }

    @MainActor
    func testEditorDisclosesImmutableHistoryAndDirtyEscapeKeepsDraft() throws {
        let app = try launchApp(capturing: "clipy-ui-editor-original")
        defer { app.terminate() }

        let row = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "clipy.history.row."
            )
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))

        app.typeKey("i", modifierFlags: .command)
        let edit = app.buttons["Edit Content"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.click()

        let disclosure = app.descendants(matching: .any)[
            "clipy.editor.revision-disclosure"
        ]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        XCTAssertEqual(disclosure.label, revisionDisclosure)

        let decision = app.descendants(matching: .any)[
            "clipy.editor.decision.public.utf8-plain-text"
        ]
        XCTAssertTrue(decision.waitForExistence(timeout: 5))
        decision.click()
        let replace = app.menuItems["Replace"]
        XCTAssertTrue(replace.waitForExistence(timeout: 5))
        replace.click()

        let replacement = app.descendants(matching: .any)[
            "clipy.editor.replacement.public.utf8-plain-text"
        ]
        XCTAssertTrue(replacement.waitForExistence(timeout: 5))
        replacement.click()
        replacement.typeKey("a", modifierFlags: .command)
        replacement.typeText("clipy-ui-editor-draft")
        replacement.typeKey(.escape, modifierFlags: [])

        let discardAlert = app.alerts["Discard Changes?"]
        XCTAssertTrue(discardAlert.waitForExistence(timeout: 5))
        XCTAssertEqual(replacement.value as? String, "clipy-ui-editor-draft")
        discardAlert.buttons["Keep Editing"].click()
        XCTAssertTrue(replacement.waitForExistence(timeout: 5))
        XCTAssertEqual(replacement.value as? String, "clipy-ui-editor-draft")

        app.buttons["Cancel"].click()
        XCTAssertTrue(discardAlert.waitForExistence(timeout: 5))
        discardAlert.buttons["Discard Changes"].click()
        XCTAssertTrue(waitUntil(timeout: 5) { !disclosure.exists })
    }

    @MainActor
    func testSettingsExposePlatformStateAndConfirmStrictRetention() throws {
        let app = try launchApp(capturing: "clipy-ui-settings-original")
        defer { app.terminate() }

        app.typeKey(",", modifierFlags: .command)
        let launchAtLogin = app.descendants(matching: .any)[
            "clipy.settings.launch-at-login"
        ]
        XCTAssertTrue(launchAtLogin.waitForExistence(timeout: 10))

        let retentionTab = app.buttons["Retention"]
        XCTAssertTrue(retentionTab.waitForExistence(timeout: 5))
        retentionTab.click()

        let ageLimit = app.descendants(matching: .any)[
            "clipy.settings.retention.age-enabled"
        ]
        XCTAssertTrue(ageLimit.waitForExistence(timeout: 5))
        ageLimit.click()

        let apply = app.descendants(matching: .any)[
            "clipy.settings.retention.apply"
        ]
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        XCTAssertTrue(apply.isEnabled)
        apply.click()

        let confirmation = app.dialogs["Apply stricter retention limits?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(
            confirmation.staticTexts[
                "Stricter limits can permanently remove items or revisions."
            ].exists
        )
        confirmation.buttons["Cancel"].click()
        XCTAssertTrue(ageLimit.exists)
        XCTAssertEqual(ageLimit.value as? String, "1")
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
