import AppKit
import XCTest

/// Real Settings interactions shared by the running-app journeys. The Form
/// that contains the control owns scrolling; the sidebar is a separate view.
@MainActor
enum SettingsJourneyControls {
    static func reveal(
        _ target: XCUIElement,
        byExpanding identifier: String,
        in app: XCUIApplication
    ) {
        if target.exists { return }
        let disclosure = app.disclosureTriangles[identifier]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5), app.debugDescription)
        let scrollView = app.scrollViews.containing(.any, identifier: identifier).firstMatch
        XCTAssertTrue(scrollView.exists, app.debugDescription)
        scroll(disclosure, into: scrollView, app: app)
        // macOS exposes the arrow and its label in one wide AX rectangle.
        // The label's midpoint did not toggle either Settings disclosure in
        // the running-app failure; click the native leading arrow instead.
        // These journeys launch LTR Settings (English or Simplified Chinese).
        disclosure.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: disclosure.frame.height / 2, dy: 0))
            .click()
        let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            String(describing: disclosure.value ?? "") == "1" && target.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 5), .completed, app.debugDescription)
    }

    static func scroll(_ control: XCUIElement, into scrollView: XCUIElement, app: XCUIApplication) {
        for _ in 0..<10 {
            if control.isHittable && scrollView.frame.contains(control.frame) { break }
            scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .scroll(byDeltaX: 0, deltaY: control.frame.midY < scrollView.frame.midY ? 60 : -60)
        }
        XCTAssertTrue(control.isHittable, app.debugDescription)
        XCTAssertTrue(scrollView.frame.contains(control.frame), app.debugDescription)
    }
}
