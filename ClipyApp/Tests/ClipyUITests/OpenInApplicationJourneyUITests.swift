import AppKit
import UniformTypeIdentifiers
import XCTest

/// Exercises the real SwiftUI → AppKit context menu and asynchronous option
/// preparation. Merely testing the descriptor does not prove native menu labels.
final class OpenInApplicationJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testLocalFileContextMenuShowsItsDefaultApplication() throws {
        try verifyMenu(image: false)
    }

    @MainActor
    func testRawImageContextMenuShowsItsDefaultApplication() throws {
        try verifyMenu(image: true)
    }

    @MainActor
    private func verifyMenu(image: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Open this file.txt")
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
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(row.exists)
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}
