import XCTest

/// Select for inspection through the real search/list keyboard path. An
/// ordinary row click now copies and closes; preview tests must not copy.
@MainActor
enum HistoryJourneyControls {
    static func select(_ target: XCUIElement, in app: XCUIApplication) {
        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        let rows = panel.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "clipy.history.row."
        )).allElementsBoundByIndex.sorted { $0.frame.minY < $1.frame.minY }
        guard let index = rows.firstIndex(where: { $0.identifier == target.identifier }) else {
            XCTFail("The row to inspect is not displayed.\n\(app.debugDescription)")
            return
        }
        let search = app.textFields["clipy.search.field"]
        search.click()
        for _ in rows { app.typeKey(.upArrow, modifierFlags: []) }
        for _ in 0..<index { app.typeKey(.downArrow, modifierFlags: []) }
        // Leave native text editing so Space invokes Quick Look.
        app.typeKey(.tab, modifierFlags: [])
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            target.isSelected
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed, app.debugDescription)
    }
}
