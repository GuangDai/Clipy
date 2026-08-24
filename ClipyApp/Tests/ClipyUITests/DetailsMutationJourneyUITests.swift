/// DetailsMutationJourneyUITests.swift — UI-2's running-app vertical proof.
/// The DEBUG launch seam changes only the store path and capture-access
/// posture. Both clipboard captures, Details navigation, Pin/Unpin writes,
/// receipt-ordered details readback, Remove confirmation, and exact surface
/// purge remain production paths.
import AppKit
import XCTest

final class DetailsMutationJourneyUITests: XCTestCase {
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

    /// UI-2: public mouse controls drive one real retained item through
    /// Unpinned -> Pinned -> Unpinned -> removed. The status badge is backed
    /// only by Details' explicit post-receipt read, while successful Remove
    /// has no local pop: disappearance of the Details root therefore joins
    /// the receipt-confirmed panel purge rather than merely observing a later
    /// list replacement.
    @MainActor
    func testDetailsPinUnpinAndConfirmedRemoveReadBackAuthoritativeState() throws {
        let survivor = "clipy-ui-details-survivor"
        let target = "clipy-ui-details-target"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(survivor, forType: .string))

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
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launch()

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        guard assertEventually(
            { panel.exists },
            in: app,
            timeout: 20,
            message: "The running app did not present its production panel."
        ) else { return }

        let rows = historyRows(in: app)
        guard assertEventually(
            { rows.count == 1 && rows.firstMatch.label.contains(survivor) },
            in: app,
            timeout: 10,
            message: "The first real clipboard capture did not retain survivor."
        ) else { return }

        pasteboard.clearContents()
        XCTAssertTrue(
            pasteboard.setString(target, forType: .string),
            diagnostic(app, context: "staging target capture")
        )
        guard assertEventually(
            {
                rows.count == 2
                    && rows.allElementsBoundByIndex.contains(where: {
                        $0.label.contains(survivor)
                    })
                    && rows.allElementsBoundByIndex.contains(where: {
                        $0.label.contains(target)
                    })
            },
            in: app,
            timeout: 10,
            message: "The second real clipboard capture did not retain two distinguishable rows."
        ) else { return }

        let targetRow = rows.matching(
            NSPredicate(format: "label CONTAINS %@", target)
        ).firstMatch
        guard assertCondition(
            targetRow.exists && targetRow.isHittable,
            in: app,
            message: "The exact target row was not publicly hittable."
        ) else { return }
        targetRow.rightClick()

        let showDetails = app.menuItems["Show Details"]
        guard assertEventually(
            { showDetails.exists && showDetails.isHittable },
            in: app,
            message: "The production row context menu did not expose Show Details."
        ) else { return }
        showDetails.click()

        let detailsRoot = app.descendants(matching: .any)[
            "clipy.details.root"
        ]
        let pinStatus = app.descendants(matching: .any)[
            "clipy.details.pin-status"
        ]
        let pinToggle = app.buttons["clipy.details.pin-toggle"]
        guard assertEventually(
            {
                detailsRoot.exists
                    && pinStatus.exists
                    && pinStatus.label == "Unpinned"
                    && pinToggle.exists
                    && pinToggle.label == "Pin"
                    && pinToggle.isHittable
            },
            in: app,
            timeout: 10,
            message: "Details did not load the target's initial unpinned state."
        ) else { return }

        pinToggle.click()
        guard assertEventually(
            {
                pinStatus.exists
                    && pinStatus.label == "Pinned at position 1"
                    && pinToggle.exists
                    && pinToggle.label == "Unpin"
                    && pinToggle.isHittable
            },
            in: app,
            timeout: 10,
            message: "Pin did not complete its receipt-ordered Details readback."
        ) else { return }

        pinToggle.click()
        guard assertEventually(
            {
                pinStatus.exists
                    && pinStatus.label == "Unpinned"
                    && pinToggle.exists
                    && pinToggle.label == "Pin"
                    && pinToggle.isHittable
            },
            in: app,
            timeout: 10,
            message: "Unpin did not complete its receipt-ordered Details readback."
        ) else { return }

        let remove = app.buttons["clipy.details.remove"]
        guard assertCondition(
            remove.exists && remove.isHittable,
            in: app,
            message: "The production Details Remove button was not usable."
        ) else { return }
        remove.click()

        // Anchor to the exact window containing Details before selecting its
        // native attached confirmation sheet. This avoids matching Touch Bar
        // mirrors or another app-owned window by a duplicated action label.
        let detailsWindow = app.windows.containing(
            .any,
            identifier: "clipy.details.root"
        ).firstMatch
        guard assertEventually(
            { detailsWindow.exists },
            in: app,
            message: "XCUI could not resolve the window owning Details."
        ) else { return }
        let confirmationSheet = detailsWindow.sheets.firstMatch
        guard assertEventually(
            { confirmationSheet.exists },
            in: app,
            message: "Remove did not present an attached confirmation sheet."
        ) else { return }
        guard assertEventually(
            {
                confirmationSheet.staticTexts[
                    "Remove this item from your clipboard history?"
                ].exists
            },
            in: app,
            message: "The destructive confirmation did not disclose its exact scope."
        ) else { return }

        let confirmRemove = confirmationSheet.buttons[
            "clipy.details.confirm-remove"
        ]
        guard assertEventually(
            {
                confirmRemove.exists
                    && confirmRemove.label == "Remove"
                    && confirmRemove.isHittable
            },
            in: app,
            message: "The attached sheet did not expose its destructive Remove action."
        ) else { return }
        confirmRemove.click()

        guard assertEventually(
            {
                !detailsRoot.exists
                    && panel.exists
                    && rows.count == 1
                    && rows.firstMatch.label.contains(survivor)
                    && !rows.allElementsBoundByIndex.contains(where: {
                        $0.label.contains(target)
                    })
            },
            in: app,
            timeout: 10,
            message: "Committed Remove did not pop Details and purge only the target row."
        ) else { return }
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
    @discardableResult
    private func assertEventually(
        _ condition: @escaping () -> Bool,
        in app: XCUIApplication,
        timeout: TimeInterval = 5,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let result = waitUntil(timeout: timeout, condition: condition)
        if !result {
            attachFailureScreenshot(app, context: message)
        }
        XCTAssertTrue(
            result,
            diagnostic(app, context: message),
            file: file,
            line: line
        )
        return result
    }

    @MainActor
    @discardableResult
    private func assertCondition(
        _ condition: @autoclosure () -> Bool,
        in app: XCUIApplication,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let result = condition()
        if !result {
            attachFailureScreenshot(app, context: message)
        }
        XCTAssertTrue(
            result,
            diagnostic(app, context: message),
            file: file,
            line: line
        )
        return result
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

    @MainActor
    private func attachFailureScreenshot(
        _ app: XCUIApplication,
        context: String
    ) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = context
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
