/// Real Space-triggered Quick Look, scoped separately from the automatic
/// side preview. Only the existing store/access launch seams are used.
import AppKit
import XCTest

final class QuickLookJourneyUITests: XCTestCase {
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

    @MainActor
    func testSpaceRespectsSearchFocusAndQuickLookDismissalSurvivesRemovalAndReopen() throws {
        let alpha = "clipy-quicklook-alpha"
        let beta = "clipy-quicklook-beta"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(alpha, forType: .string))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectory = directory
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory
            .appendingPathComponent("history.store").path
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launch()
        defer { app.terminate() }

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        XCTAssertTrue(panel.waitForExistence(timeout: 20), app.debugDescription)
        let search = app.textFields["clipy.search.field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        let rows = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "clipy.history.row."
        ))
        XCTAssertTrue(waitUntil { rows.count == 1 }, app.debugDescription)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(beta, forType: .string))
        XCTAssertTrue(waitUntil { rows.count == 2 }, app.debugDescription)
        let alphaRow = rows.matching(NSPredicate(format: "label CONTAINS %@", alpha)).firstMatch
        let betaRow = rows.matching(NSPredicate(format: "label CONTAINS %@", beta)).firstMatch
        XCTAssertTrue(alphaRow.exists && betaRow.exists, app.debugDescription)
        let quickLook = app.descendants(matching: .any)["clipy.panel.quicklook"]

        // No field click: initial panel focus must consume a bare Space as
        // text even though the list already has a selected retained item.
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(waitUntil { search.value as? String == " " }, app.debugDescription)
        XCTAssertFalse(quickLook.exists, app.debugDescription)
        let clear = app.buttons["clipy.search.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5) && clear.isHittable, app.debugDescription)
        clear.click()
        XCTAssertTrue(waitUntil {
            search.value as? String == "" && rows.count == 2
        }, app.debugDescription)

        // A real List-row mouse click transfers focus and selects older
        // alpha. Newest beta is deliberately different from this target.
        XCTAssertTrue(alphaRow.isHittable, app.debugDescription)
        alphaRow.click()
        app.typeKey(.space, modifierFlags: [])
        assertQuickLook(alpha, in: quickLook, app: app)
        XCTAssertEqual(search.value as? String, "")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { !quickLook.exists }, app.debugDescription)
        XCTAssertTrue(panel.exists, "Escape must dismiss Quick Look before closing the panel.\n\(app.debugDescription)")

        XCTAssertTrue(betaRow.isHittable, app.debugDescription)
        betaRow.click()
        XCTAssertFalse(quickLook.exists, app.debugDescription)
        app.typeKey(.space, modifierFlags: [])
        assertQuickLook(beta, in: quickLook, app: app)
        let close = quickLook.buttons["clipy.panel.quicklook.dismiss"]
        XCTAssertTrue(close.isHittable, app.debugDescription)
        close.click()
        XCTAssertTrue(waitUntil { !quickLook.exists }, app.debugDescription)

        // Removing the formerly previewed item through its real context menu
        // must not revive the dismissed overlay or retarget it to alpha.
        betaRow.rightClick()
        let remove = app.menuItems["Remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5) && remove.isHittable, app.debugDescription)
        remove.click()
        XCTAssertTrue(waitUntil {
            rows.count == 1 && alphaRow.exists && !betaRow.exists
        }, app.debugDescription)
        XCTAssertFalse(quickLook.exists, app.debugDescription)

        // A fresh panel session likewise starts without the retired overlay.
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil { !panel.exists }, app.debugDescription)
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(panel.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(waitUntil { rows.count == 1 && alphaRow.exists }, app.debugDescription)
        XCTAssertFalse(quickLook.exists, app.debugDescription)
    }

    @MainActor
    private func assertQuickLook(_ expected: String, in overlay: XCUIElement, app: XCUIApplication) {
        XCTAssertTrue(overlay.waitForExistence(timeout: 5), app.debugDescription)
        // Scope beneath Quick Look: the side pane uses the same preview IDs
        // and may be open because of the normal selection dwell.
        let text = overlay.descendants(matching: .any)["clipy.preview.text"]
        XCTAssertTrue(waitUntil {
            guard text.exists else { return false }
            let value = (text.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? text.label
            return value == expected
        }, app.debugDescription)
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() }, object: nil
        )
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }
}
