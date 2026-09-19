import AppKit
import UniformTypeIdentifiers
import XCTest

/// Exercises the real SwiftUI → AppKit context menu and asynchronous option
/// preparation, then clicks through to the actual default app document window.
final class OpenInApplicationJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testLocalFileContextMenuOpensDocumentInItsDefaultApplication() throws {
        try verifyOpen(image: false)
    }

    @MainActor
    func testRawImageContextMenuOpensTemporaryCopyInItsDefaultApplication() throws {
        try verifyOpen(image: true)
    }

    @MainActor
    private func verifyOpen(image: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Clipy open fixture " + UUID().uuidString + ".txt")
        try Data("open-in fixture".utf8).write(to: file)
        let item = NSPasteboardItem()
        let handler: URL?
        if image {
            let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
            XCTAssertTrue(item.setData(png, forType: .png))
            handler = NSWorkspace.shared.urlForApplication(toOpen: UTType.png)
        } else {
            XCTAssertTrue(item.setData(Data(file.absoluteString.utf8), forType: .fileURL))
            handler = NSWorkspace.shared.urlForApplication(toOpen: file)
        }
        let application = try XCTUnwrap(handler)
        let expectedLabel = "Open in " + application.deletingPathExtension().lastPathComponent
        let handlerIdentifier = try XCTUnwrap(Bundle(url: application)?.bundleIdentifier)
        let handlerWasRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: handlerIdentifier
        ).isEmpty
        let externalApp = XCUIApplication(bundleIdentifier: handlerIdentifier)
        let documentName = image ? "Clipboard" : file.deletingPathExtension().lastPathComponent
        let documentWindows = externalApp.windows.matching(NSPredicate(
            format: "title == %@ OR title == %@ OR label == %@ OR label == %@",
            documentName, documentName + (image ? ".png" : ".txt"),
            documentName, documentName + (image ? ".png" : ".txt")
        ))
        // A clean filename baseline prevents an already-open document from
        // satisfying this positive launch proof or being closed by cleanup.
        if handlerWasRunning {
            XCTAssertEqual(documentWindows.count, 0,
                           "A pre-existing same-name document would make the open proof ambiguous.")
        }
        var requestedOpen = false
        defer {
            if requestedOpen {
                if !handlerWasRunning, externalApp.state != .notRunning {
                    externalApp.terminate()
                } else if let window = documentWindows.allElementsBoundByIndex.first {
                    let close = window.buttons[XCUIIdentifierCloseWindow]
                    if close.exists && close.isHittable { close.click() }
                }
            }
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                "-clipy.appearance.previewAutoOpen", "NO"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = root.appendingPathComponent("history.store").path
        app.launch()
        defer { app.terminate() }
        let row = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "clipy.history.row."
        )).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), app.debugDescription)
        row.rightClick()
        let command = app.menuItems[expectedLabel]
        XCTAssertTrue(command.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(command.isEnabled, app.debugDescription)
        requestedOpen = true
        command.click()
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            externalApp.state == .runningForeground && documentWindows.count == 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 20), .completed,
                       "The explicit Open action must reach the default application's document window.\n"
                           + externalApp.debugDescription + "\n" + app.debugDescription)
        XCTAssertTrue(documentWindows.firstMatch.exists, externalApp.debugDescription)
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        XCTAssertEqual(pasteboard.pasteboardItems?.first?.data(forType: image ? .png : .fileURL),
                       item.data(forType: image ? .png : .fileURL),
                       "Opening externally must not replace the system clipboard.")
        XCTAssertEqual(try Data(contentsOf: file), Data("open-in fixture".utf8),
                       "Opening a reference must preserve the original file.")
    }
}
