import AppKit
import XCTest

final class MaintenanceJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testMaintenanceSeparatesContentFromFolderSizeAndRevealsCurrentFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipy-maintenance-ui-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Store", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("clipy-store-reveal.marker")
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString("maintenance-test", forType: .string))

        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = folder.appendingPathComponent("history.store").path
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_REVEAL_MARKER_PATH"] = marker.path
        app.launch()
        defer { app.terminate() }
        let rows = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "clipy.history.row."
        ))
        XCTAssertTrue(waitUntil { rows.count == 1 }, app.debugDescription)
        app.typeKey(",", modifierFlags: .command)
        let maintenance = app.buttons["Maintenance"]
        XCTAssertTrue(maintenance.waitForExistence(timeout: 10), app.debugDescription)
        maintenance.click()

        let logical = app.staticTexts["clipy.settings.maintenance.logical-bytes"]
        let physical = app.staticTexts["clipy.settings.maintenance.folder-bytes"]
        XCTAssertTrue(waitUntil {
            logical.exists && self.text(logical) == "16 bytes"
                && physical.exists && !self.text(physical).isEmpty
                && self.text(physical) != "Unavailable" && self.text(physical) != "0 bytes"
        }, app.debugDescription)
        let path = app.staticTexts["clipy.settings.maintenance.folder-path"]
        XCTAssertTrue(path.exists, app.debugDescription)
        XCTAssertEqual(text(path), folder.path)
        let initialPhysical = text(physical)
        let derivedCache = app.staticTexts["clipy.settings.maintenance.derived-cache"]
        XCTAssertTrue(derivedCache.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(text(derivedCache), "Not Used")
        for identifier in [
            "clipy.settings.maintenance.resident-bytes",
            "clipy.settings.maintenance.peak-resident-bytes",
            "clipy.settings.maintenance.footprint-bytes",
        ] {
            let reading = app.staticTexts[identifier]
            XCTAssertTrue(waitUntil {
                reading.exists && !self.text(reading).isEmpty
                    && self.text(reading) != "Unavailable"
                    && self.text(reading) != "0 bytes" && self.text(reading) != "16 bytes"
            }, "kernel memory reading: \(identifier)\n\(app.debugDescription)")
        }

        // An unrelated file belongs to the displayed folder total, while the
        // logical content and History remain unchanged.
        try Data(repeating: 7, count: 2_097_152).write(to: folder.appendingPathComponent("other-data"))
        let refresh = app.buttons["clipy.settings.maintenance.refresh"]
        XCTAssertTrue(refresh.exists, app.debugDescription)
        scrollToVisible(refresh, in: app)
        refresh.click()
        XCTAssertTrue(waitUntil {
            logical.exists && self.text(logical) == "16 bytes"
                && physical.exists && !self.text(physical).isEmpty
                && self.text(physical) != initialPhysical && self.text(physical) != "Unavailable"
        }, app.debugDescription)

        let reveal = app.buttons["clipy.settings.maintenance.reveal"]
        XCTAssertTrue(reveal.exists, app.debugDescription)
        scrollToVisible(reveal, in: app)
        reveal.click()
        XCTAssertTrue(waitUntil { FileManager.default.fileExists(atPath: marker.path) }, app.debugDescription)
        XCTAssertEqual(try Data(contentsOf: marker), Data())
    }

    @MainActor
    private func scrollToVisible(_ element: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.containing(
            .any, identifier: "clipy.settings.maintenance.refresh"
        ).firstMatch
        let scrollView = window.scrollViews.firstMatch
        for _ in 0..<10 {
            if element.isHittable && scrollView.frame.contains(element.frame) { return }
            scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .scroll(byDeltaX: 0, deltaY: element.frame.midY < scrollView.frame.midY ? 60 : -60)
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    @MainActor
    private func text(_ element: XCUIElement) -> String {
        (element.value as? String ?? element.label)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() }, object: nil
        )
        return XCTWaiter.wait(for: [expectation], timeout: 20) == .completed
    }
}
