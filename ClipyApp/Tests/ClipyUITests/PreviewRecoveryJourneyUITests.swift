/// PreviewRecoveryJourneyUITests.swift — Card 9D/Card 15 running-app
/// acceptance for the real preview column. The DEBUG launch switch replaces
/// only one loader-local details result; Retry, authoritative History read,
/// ContentPreview rendering, SwiftUI publication, and keyboard routing remain
/// production paths.
import AppKit
import XCTest

final class PreviewRecoveryJourneyUITests: XCTestCase {
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

    /// A supported representation's one transient details failure exposes the
    /// real control. Pressing it retries the same selected reference through
    /// History and the renderer, then removes the failed episode.
    @MainActor
    func testTransientPreviewFailureExposesClickableRetryAndRecovers() throws {
        let expected = "clipy-preview-click-recovered"
        let app = try launchApp(
            representation: Data(expected.utf8),
            typeIdentifier: "public.utf8-plain-text",
            transientFirstDetailsFailure: true
        )
        defer { app.terminate() }

        let retry = app.buttons["clipy.preview.retry"]
        XCTAssertTrue(
            retry.waitForExistence(timeout: 10),
            diagnostic(app, context: "transient preview Retry")
        )
        XCTAssertEqual(retry.label, "Retry")
        XCTAssertTrue(retry.isHittable)
        retry.click()

        assertRecoveredPreview(expected, in: app)
    }

    /// Card 15 keyboard recovery: the Retry control's app shortcut invokes
    /// the same action without pointer input and leaves a successful text
    /// artifact as public evidence.
    @MainActor
    func testTransientPreviewFailureRecoversFromCommandR() throws {
        let expected = "clipy-preview-keyboard-recovered"
        let app = try launchApp(
            representation: Data(expected.utf8),
            typeIdentifier: "public.utf8-plain-text",
            transientFirstDetailsFailure: true
        )
        defer { app.terminate() }

        let retry = app.buttons["clipy.preview.retry"]
        XCTAssertTrue(
            retry.waitForExistence(timeout: 10),
            diagnostic(app, context: "keyboard preview Retry")
        )
        app.typeKey("r", modifierFlags: .command)

        assertRecoveredPreview(expected, in: app)
    }

    /// A valid opaque RTF is stable unsupported, while malformed bytes for a
    /// supported UTF-8 type are terminal failed. Neither exact request admits
    /// replay, so neither running surface may manufacture Retry.
    @MainActor
    func testUnsupportedAndMalformedPreviewNeverExposeRetry() throws {
        do {
            let unsupportedApp = try launchApp(
                representation: Data(#"{\rtf1\ansi opaque}"#.utf8),
                typeIdentifier: "public.rtf"
            )
            defer { unsupportedApp.terminate() }
            let unsupported = unsupportedApp.descendants(matching: .any)[
                "clipy.preview.unsupported"
            ]
            XCTAssertTrue(
                unsupported.waitForExistence(timeout: 10),
                diagnostic(unsupportedApp, context: "unsupported RTF preview")
            )
            XCTAssertFalse(unsupportedApp.buttons["clipy.preview.retry"].exists)
            XCTAssertFalse(
                unsupportedApp.descendants(matching: .any)[
                    "clipy.preview.failed"
                ].exists
            )
        }

        let malformedApp = try launchApp(
            representation: Data([0xFF, 0xFE, 0xFF]),
            typeIdentifier: "public.utf8-plain-text"
        )
        defer { malformedApp.terminate() }
        let failed = malformedApp.descendants(matching: .any)[
            "clipy.preview.failed"
        ]
        XCTAssertTrue(
            failed.waitForExistence(timeout: 10),
            diagnostic(malformedApp, context: "malformed UTF-8 preview")
        )
        XCTAssertFalse(malformedApp.buttons["clipy.preview.retry"].exists)
        XCTAssertFalse(
            malformedApp.descendants(matching: .any)[
                "clipy.preview.unsupported"
            ].exists
        )
    }

    @MainActor
    private func launchApp(
        representation: Data,
        typeIdentifier: String,
        transientFirstDetailsFailure: Bool = false
    ) throws -> XCUIApplication {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        XCTAssertTrue(
            item.setData(
                representation,
                forType: NSPasteboard.PasteboardType(typeIdentifier)
            )
        )
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        temporaryDirectories.append(directory)

        let app = XCUIApplication()
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory
            .appendingPathComponent("history.store")
            .path
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        if transientFirstDetailsFailure {
            app.launchEnvironment["CLIPY_UI_TEST_PREVIEW_FAILURE"] =
                "transient-details-once"
        }
        app.launch()

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        XCTAssertTrue(
            panel.waitForExistence(timeout: 20),
            diagnostic(app, context: "production panel")
        )
        let rows = historyRows(in: app)
        XCTAssertTrue(
            waitUntil(timeout: 10) { rows.count == 1 },
            diagnostic(app, context: "captured preview row")
        )

        // The selected row normally opens Preview through the production
        // 200 ms dwell. If it has not yet fired, use the product's documented
        // Control-Space toggle rather than a DEBUG summon method.
        let preview = app.descendants(matching: .any)["clipy.preview.root"]
        if !preview.waitForExistence(timeout: 3) {
            app.typeKey(.space, modifierFlags: .control)
        }
        XCTAssertTrue(
            preview.waitForExistence(timeout: 5),
            diagnostic(app, context: "preview column")
        )
        return app
    }

    @MainActor
    private func assertRecoveredPreview(
        _ expected: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let text = app.descendants(matching: .any)["clipy.preview.text"]
        let recovered = waitUntil(timeout: 10) {
            text.exists && self.accessibilityText(of: text) == expected
        }
        XCTAssertTrue(
            recovered,
            diagnostic(app, context: "recovered text preview"),
            file: file,
            line: line
        )
        XCTAssertFalse(app.buttons["clipy.preview.retry"].exists)
        XCTAssertFalse(
            app.descendants(matching: .any)["clipy.preview.failed"].exists
        )
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

    /// macOS SwiftUI Text commonly publishes its body through AXValue; an
    /// explicit label remains the fallback for bridge variations.
    @MainActor
    private func accessibilityText(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty {
            return value
        }
        return element.label
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
    private func diagnostic(_ app: XCUIApplication, context: String) -> String {
        "\(context)\n\(app.debugDescription)"
    }
}
