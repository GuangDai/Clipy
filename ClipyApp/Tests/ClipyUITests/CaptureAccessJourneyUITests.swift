/// CLIP-1's running-app accessibility journeys. They distinguish capture
/// access from retained History through public AX output and drive the one
/// production pause/retry/resume ingress; no private SwiftUI inspection or
/// callback-only UI seam is involved.
import AppKit
import XCTest

final class CaptureAccessJourneyUITests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    /// CLIP-1: an access denial is not presented as ordinary empty History.
    /// Retrying re-reads the fixed denied posture and must not manufacture an
    /// approval that the system did not report.
    @MainActor
    func testDeniedEmptyStateIsDistinctAndRetryStaysDenied() throws {
        let app = try launchApp(
            storeURL: try makeStoreURL(),
            captureAccess: "denied",
            pasteboardValue: "clipy-ui-denied-must-not-capture"
        )
        defer { app.terminate() }

        let deniedState = app.descendants(matching: .any)[
            "clipy.capture.access.empty"
        ]
        guard assertEventually(
            { deniedState.exists },
            in: app,
            message: "Denied access did not replace the ordinary empty state."
        ) else { return }
        assertCondition(
            !app.staticTexts["No Clipboard History"].exists,
            in: app,
            message: "Denied access and ordinary empty History were both exposed."
        )

        let retry = app.buttons["clipy.capture.access.recovery"]
        guard assertCondition(
            retry.exists && retry.isHittable,
            in: app,
            message: "Denied access did not expose a usable Try Again action."
        ) else { return }
        retry.click()

        let deniedRows = historyRows(in: app)
        assertRemains(
            {
                deniedState.exists
                    && retry.exists
                    && deniedRows.count == 0
            },
            in: app,
            duration: 1.5,
            message: "Try Again promoted the fixed denied posture without approval."
        )
        assertCondition(
            !app.descendants(matching: .any)["clipy.capture.pause"].exists,
            in: app,
            message: "Denied access incorrectly exposed the allowed Pause action."
        )
    }

    /// The recovery action is not a disconnected control: it re-reads the
    /// configured system boundary, leaves the denied surface only after that
    /// boundary reports allowed, and then starts the production capture lane.
    @MainActor
    func testTryAgainRechecksAccessBeforeStartingCapture() throws {
        let recovered = "clipy-ui-retry-recovered"
        let app = try launchApp(
            storeURL: try makeStoreURL(),
            captureAccess: "denied-then-allowed",
            pasteboardValue: recovered
        )
        defer { app.terminate() }

        let deniedState = app.descendants(matching: .any)[
            "clipy.capture.access.empty"
        ]
        guard assertEventually(
            { deniedState.exists },
            in: app,
            message: "Recovery scenario did not begin in denied state."
        ) else { return }

        let retry = app.buttons["clipy.capture.access.recovery"]
        guard assertCondition(
            retry.exists && retry.isHittable,
            in: app,
            message: "Recovery scenario did not expose Try Again."
        ) else { return }
        retry.click()

        let rows = historyRows(in: app)
        guard assertEventually(
            { !deniedState.exists && rows.count == 1 },
            in: app,
            timeout: 10,
            message: "Try Again did not adopt allowed access and start capture."
        ) else { return }
        assertCondition(
            rows.element(boundBy: 0).label.contains(recovered),
            in: app,
            message: "Recovered capture did not retain the staged value."
        )

        let moreActions = app.descendants(matching: .any)[
            "clipy.panel.more-actions"
        ]
        guard assertCondition(
            moreActions.exists && moreActions.isHittable,
            in: app,
            message: "Allowed recovery did not restore More Actions."
        ) else { return }
        moreActions.click()
        assertEventually(
            {
                let pause = app.descendants(matching: .any)[
                    "clipy.capture.pause"
                ]
                return pause.exists && pause.isHittable
            },
            in: app,
            message: "Allowed recovery did not expose Pause."
        )
    }

    /// A denial stops new monitoring; it does not revoke browsing access to
    /// values already retained by the user's History store.
    @MainActor
    func testDeniedAccessKeepsRetainedRowsBrowsable() throws {
        let retained = "clipy-ui-denied-retained-row"
        let storeURL = try makeStoreURL()
        let seedingApp = try launchApp(
            storeURL: storeURL,
            captureAccess: "allowed",
            pasteboardValue: retained
        )
        let seedingRows = historyRows(in: seedingApp)
        guard assertEventually(
            { seedingRows.count == 1 },
            in: seedingApp,
            timeout: 10,
            message: "Allowed setup launch did not retain its clipboard value."
        ) else {
            seedingApp.terminate()
            return
        }
        seedingApp.terminate()

        let deniedApp = try launchApp(
            storeURL: storeURL,
            captureAccess: "denied",
            pasteboardValue: "clipy-ui-denied-must-not-capture"
        )
        defer { deniedApp.terminate() }
        let rows = historyRows(in: deniedApp)
        guard assertEventually(
            { rows.count == 1 },
            in: deniedApp,
            timeout: 10,
            message: "Denied launch did not preserve the retained browsing row."
        ) else { return }
        assertCondition(
            rows.element(boundBy: 0).label.contains(retained),
            in: deniedApp,
            message: "Denied launch replaced or concealed the retained row."
        )
        assertCondition(
            deniedApp.descendants(matching: .any)[
                "clipy.capture.access.banner"
            ].exists,
            in: deniedApp,
            message: "Browsable denied History did not expose its access banner."
        )
        assertRemains(
            {
                rows.count == 1
                    && rows.element(boundBy: 0).label.contains(retained)
                    && !rows.allElementsBoundByIndex.contains(where: {
                        $0.label.contains("clipy-ui-denied-must-not-capture")
                    })
            },
            in: deniedApp,
            duration: 1.5,
            message: "Denied monitoring later captured or replaced a retained row."
        )
    }

    /// The visible Pause and Resume controls drive the same composition-owned
    /// capture-access reducer as lifecycle recovery. While paused a new
    /// pasteboard generation is not retained; Resume rechecks allowed access
    /// and observes it through the production polling lane.
    @MainActor
    func testPauseThenResumeRestartsCapture() throws {
        let original = "clipy-ui-pause-original"
        let whilePaused = "clipy-ui-copied-while-paused"
        let afterResume = "clipy-ui-copied-after-resume"
        let app = try launchApp(
            storeURL: try makeStoreURL(),
            captureAccess: "allowed",
            pasteboardValue: original
        )
        defer { app.terminate() }
        let rows = historyRows(in: app)
        guard assertEventually(
            { rows.count == 1 },
            in: app,
            timeout: 10,
            message: "Allowed launch did not capture its initial value."
        ) else { return }

        let moreActions = app.descendants(matching: .any)[
            "clipy.panel.more-actions"
        ]
        guard assertCondition(
            moreActions.exists && moreActions.isHittable,
            in: app,
            message: "The panel did not expose its More Actions menu."
        ) else { return }
        moreActions.click()

        let pause = app.descendants(matching: .any)["clipy.capture.pause"]
        guard assertEventually(
            { pause.exists && pause.isHittable },
            in: app,
            message: "Allowed capture did not expose a usable Pause action."
        ) else { return }
        pause.click()

        let resume = app.buttons["clipy.capture.access.recovery"]
        guard assertEventually(
            { resume.exists && resume.label == "Resume clipboard capture" },
            in: app,
            message: "Pause did not publish the recoverable paused state."
        ) else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        assertCondition(
            pasteboard.setString(whilePaused, forType: .string),
            in: app,
            message: "The test runner could not stage the paused value."
        )
        assertCondition(
            !waitUntil(timeout: 1.5) { rows.count == 2 },
            in: app,
            message: "Clipboard monitoring continued while user-paused."
        )

        resume.click()
        assertRemains(
            {
                rows.count == 1
                    && !rows.allElementsBoundByIndex.contains(where: {
                        $0.label.contains(whilePaused)
                    })
            },
            in: app,
            duration: 1.5,
            message: "Resume imported a generation copied while paused."
        )

        pasteboard.clearContents()
        assertCondition(
            pasteboard.setString(afterResume, forType: .string),
            in: app,
            message: "The test runner could not stage the post-resume value."
        )
        assertEventually(
            { rows.count == 2 },
            in: app,
            timeout: 10,
            message: "Resume did not restart monitoring for a later copy."
        )
        assertCondition(
            rows.allElementsBoundByIndex.contains(where: {
                $0.label.contains(afterResume)
            }),
            in: app,
            message: "Resume added a row, but not the later clipboard value."
        )
    }

    /// The production Pause deadline owns automatic recovery. The DEBUG
    /// launch envelope shortens only elapsed time to eight seconds; this still
    /// drives the real access reducer, observer baseline, and capture lane.
    @MainActor
    func testTimedPauseAutomaticallyResumesWithoutImportingPausedValue() throws {
        let original = "clipy-ui-timed-pause-original"
        let whilePaused = "clipy-ui-timed-pause-excluded"
        let afterResume = "clipy-ui-timed-pause-after-resume"
        let app = try launchApp(
            storeURL: try makeStoreURL(),
            captureAccess: "allowed",
            pasteboardValue: original,
            shortPause: true
        )
        defer { app.terminate() }
        let rows = historyRows(in: app)
        guard assertEventually(
            { rows.count == 1 },
            in: app,
            timeout: 10,
            message: "Allowed launch did not capture the timed-Pause fixture."
        ) else { return }

        let moreActions = app.descendants(matching: .any)[
            "clipy.panel.more-actions"
        ]
        guard assertCondition(
            moreActions.exists && moreActions.isHittable,
            in: app,
            message: "The panel did not expose More Actions for timed Pause."
        ) else { return }
        moreActions.click()

        let pause = app.descendants(matching: .any)["clipy.capture.pause"]
        guard assertEventually(
            {
                pause.exists
                    && pause.isHittable
                    && pause.label.contains("5 Minutes")
            },
            in: app,
            message: "Pause did not disclose its five-minute product window."
        ) else { return }
        pause.click()

        let recovery = app.buttons["clipy.capture.access.recovery"]
        guard assertEventually(
            {
                recovery.exists
                    && recovery.label == "Resume clipboard capture"
            },
            in: app,
            message: "Timed Pause did not publish its recoverable state."
        ) else { return }
        let message = app.descendants(matching: .any)[
            "clipy.capture.access.message"
        ]
        assertCondition(
            message.label.contains("up to 5 minutes"),
            in: app,
            message: "Paused presentation did not disclose its time bound."
        )

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        assertCondition(
            pasteboard.setString(whilePaused, forType: .string),
            in: app,
            message: "The runner could not stage the timed paused value."
        )
        assertRemains(
            { rows.count == 1 && recovery.exists },
            in: app,
            duration: 0.5,
            message: "Timed Pause ended early or captured while paused."
        )

        guard assertEventually(
            { !recovery.exists },
            in: app,
            timeout: 20,
            message: "The Pause deadline did not automatically resume capture."
        ) else { return }
        assertRemains(
            {
                rows.count == 1
                    && !rows.allElementsBoundByIndex.contains(where: {
                        $0.label.contains(whilePaused)
                    })
            },
            in: app,
            duration: 1.0,
            message: "Timed Resume imported the pause-period generation."
        )

        pasteboard.clearContents()
        assertCondition(
            pasteboard.setString(afterResume, forType: .string),
            in: app,
            message: "The runner could not stage the post-deadline value."
        )
        assertEventually(
            { rows.count == 2 },
            in: app,
            timeout: 10,
            message: "Automatic Resume did not restart production monitoring."
        )
        assertCondition(
            rows.allElementsBoundByIndex.contains(where: {
                $0.label.contains(afterResume)
            }),
            in: app,
            message: "Automatic Resume captured a row without the new value."
        )
    }

    @MainActor
    private func launchApp(
        storeURL: URL,
        captureAccess: String,
        pasteboardValue: String?,
        shortPause: Bool = false
    ) throws -> XCUIApplication {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let pasteboardValue {
            XCTAssertTrue(
                pasteboard.setString(pasteboardValue, forType: .string)
            )
        }

        let app = XCUIApplication()
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = storeURL.path
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = captureAccess
        if shortPause {
            app.launchEnvironment["CLIPY_UI_TEST_SHORT_PAUSE"] = "1"
        }
        app.launch()

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        guard assertEventually(
            { panel.exists },
            in: app,
            timeout: 20,
            message: "The running app did not summon its panel."
        ) else {
            throw CaptureAccessJourneyError.panelUnavailable
        }
        return app
    }

    private func makeStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        temporaryDirectories.append(directory)
        return directory.appendingPathComponent("history.store")
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
    private func assertRemains(
        _ condition: @escaping () -> Bool,
        in app: XCUIApplication,
        duration: TimeInterval,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let violated = waitUntil(timeout: duration) { !condition() }
        return assertCondition(
            !violated,
            in: app,
            message: message,
            file: file,
            line: line
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
        let succeeded = waitUntil(timeout: timeout, condition: condition)
        return assertCondition(
            succeeded,
            in: app,
            message: message,
            file: file,
            line: line
        )
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
        guard condition() else {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Capture access journey failure"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTFail(
                "\(message)\n\(app.debugDescription)",
                file: file,
                line: line
            )
            return false
        }
        return true
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

private enum CaptureAccessJourneyError: Error {
    case panelUnavailable
}
