import AppKit
import XCTest

final class KeyboardShortcutsJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testDedicatedPageRecordsRecoversFromConflictClearsAndRestoresShortcuts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipy-keyboard-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        NSPasteboard.general.clearContents()
        defer { NSPasteboard.general.clearContents() }
        XCTAssertTrue(NSPasteboard.general.setString("keyboard settings journey", forType: .string))
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("history.sqlite").path
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any)["clipy.panel.root"].waitForExistence(timeout: 20))
        app.typeKey(",", modifierFlags: .command)
        let category = app.buttons["clipy.settings.category.keyboard"]
        XCTAssertTrue(category.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(category.label, "Keyboard Shortcuts")
        category.click()

        let record = app.buttons["clipy.settings.keyboard.focusSearch.record"]
        let clear = app.buttons["clipy.settings.keyboard.focusSearch.clear"]
        let reset = app.buttons["clipy.settings.keyboard.focusSearch.reset"]
        XCTAssertTrue(record.waitForExistence(timeout: 10), app.debugDescription)
        reset.click()
        XCTAssertTrue(waitUntil { record.value as? String == "⌘F" }, app.debugDescription)
        record.click()
        let recorder = app.descendants(matching: .any)["clipy.settings.keyboard.recorder"]
        XCTAssertTrue(recorder.waitForExistence(timeout: 5), app.debugDescription)

        app.typeKey("p", modifierFlags: .command)
        let error = app.descendants(matching: .any)["clipy.settings.keyboard.recordingError"]
        XCTAssertTrue(error.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(recorder.exists, "A conflict must keep recording open for correction")
        app.typeKey("f", modifierFlags: [.command, .option])
        XCTAssertTrue(waitUntil { !recorder.exists && record.value as? String == "⌥⌘F" }, app.debugDescription)
        clear.click()
        XCTAssertTrue(waitUntil { record.value as? String == "Not set" && !clear.isEnabled }, app.debugDescription)

        // Category changes reconstruct the page from the persisted explicit
        // unassigned value; clearing must not silently restore the default.
        app.buttons["clipy.settings.category.general"].click()
        category.click()
        XCTAssertTrue(waitUntil { record.value as? String == "Not set" }, app.debugDescription)
        reset.click()
        XCTAssertTrue(waitUntil { record.value as? String == "⌘F" && clear.isEnabled }, app.debugDescription)

        let summon = app.buttons["clipy.settings.shortcut.change"]
        let clearSummon = app.buttons["clipy.settings.shortcut.clear"]
        let resetSummon = app.buttons["clipy.settings.shortcut.reset"]
        XCTAssertTrue(clearSummon.waitForExistence(timeout: 5))
        clearSummon.click()
        XCTAssertTrue(waitUntil {
            summon.value as? String == "Not set" && summon.isEnabled && !clearSummon.isEnabled
        }, app.debugDescription)
        resetSummon.click()
        XCTAssertTrue(waitUntil { summon.value as? String == "⇧⌘C" }, app.debugDescription)

        // Drive a visible History mutation with a custom chord, then clear
        // that chord. Merely showing an empty Settings value cannot prove the
        // old SwiftUI key equivalent stopped dispatching its action.
        let pinRecord = app.buttons["clipy.settings.keyboard.togglePin.record"]
        let pinClear = app.buttons["clipy.settings.keyboard.togglePin.clear"]
        let pinReset = app.buttons["clipy.settings.keyboard.togglePin.reset"]
        reveal(pinRecord, in: app)
        pinRecord.click()
        XCTAssertTrue(recorder.waitForExistence(timeout: 5))
        app.typeKey("k", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil { !recorder.exists && pinRecord.value as? String == "⇧⌘K" })
        showPanel(fromSettingsIn: app)
        let row = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "clipy.history.row."
        )).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        HistoryJourneyControls.select(row, in: app)
        app.typeKey("k", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil { row.label.contains("Pinned at position 1") }, app.debugDescription)
        app.typeKey("p", modifierFlags: .command)
        XCTAssertFalse(waitUntil(timeout: 1) { !row.label.contains("Pinned at position 1") },
                       "The old default must not remain registered after a custom shortcut is saved")

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        category.click()
        reveal(pinClear, in: app)
        pinClear.click()
        XCTAssertTrue(waitUntil { pinRecord.value as? String == "Not set" })
        showPanel(fromSettingsIn: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        HistoryJourneyControls.select(row, in: app)
        app.typeKey("k", modifierFlags: [.command, .shift])
        XCTAssertFalse(waitUntil(timeout: 1) { !row.label.contains("Pinned at position 1") },
                       "An explicitly cleared shortcut must not dispatch its former action")
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        category.click()
        reveal(pinReset, in: app)
        pinReset.click()
        XCTAssertTrue(waitUntil { pinRecord.value as? String == "⌘P" })
        app.buttons["clipy.settings.category.general"].click()
    }

    @MainActor
    private func showPanel(fromSettingsIn app: XCUIApplication) {
        app.typeKey("w", modifierFlags: .command)
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.descendants(matching: .any)["clipy.panel.root"].waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), app.debugDescription)
        let scroll = app.scrollViews.containing(.button, identifier: element.identifier).firstMatch
        XCTAssertTrue(scroll.exists, app.debugDescription)
        for _ in 0..<8 {
            if element.isHittable && scroll.frame.contains(element.frame) { return }
            let distance = element.frame.midY - scroll.frame.midY
            let magnitude = min(abs(distance), scroll.frame.height * 0.75)
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .scroll(byDeltaX: 0, deltaY: distance < 0 ? magnitude : -magnitude)
        }
        XCTAssertTrue(element.isHittable && scroll.frame.contains(element.frame), app.debugDescription)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
