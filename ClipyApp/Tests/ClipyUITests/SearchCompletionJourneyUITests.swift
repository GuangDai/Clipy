import AppKit
import HistoryCore
import HistoryStorage
import XCTest

/// Native input, candidate clicks and panel key routing share one running-app
/// journey. The source beyond both first pages belongs to an older occurrence
/// of the target, so neither visible rows nor lastSource can supply it.
final class SearchCompletionJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testCompletionInsertsWithoutPastingAndFindsAnOlderRemoteSource() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("history.sqlite")
        let fixture = try await seedHistory(at: storeURL)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        try require(pasteboard.setString("completion must not copy", forType: .string))
        addTeardownBlock { @MainActor () async in pasteboard.clearContents() }

        let app = XCUIApplication()
        addTeardownBlock { @MainActor () async in app.terminate() }
        app.launchArguments += [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-clipy.language", "en",
            "-clipy.appearance.previewAutoOpen", "NO", "-panelPosition", "center",
        ]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "denied"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = storeURL.path
        app.launch()

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        let search = app.textFields["clipy.search.field"]
        let popup = app.descendants(matching: .any)["clipy.search.completions"]
        let rows = panel.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "clipy.history.row."
        ))
        try require(panel.waitForExistence(timeout: 20), app.debugDescription)
        try require(search.waitForExistence(timeout: 5), app.debugDescription)
        let accessNotice = app.descendants(matching: .any)["clipy.capture.access.banner"]
        try require(accessNotice.waitForExistence(timeout: 5), app.debugDescription)
        try require(waitUntil {
            search.isHittable && accessNotice.frame.maxY <= search.frame.minY
                && app.buttons["clipy.capture.access.recovery"].isHittable
        }, "The denied-access notice must occupy space above the editable search field.\n" + app.debugDescription)
        try require(!popup.exists, "An empty focused search must leave list navigation available.")

        // Start with the tall history window: the asynchronous search then
        // replaces it with an empty result and fits the window to that result.
        search.click()
        app.typeText("$type:")
        try require(app.staticTexts["No Results"].waitForExistence(timeout: 10), app.debugDescription)
        try require(waitUntil {
            popup.exists && popup.frame.height > 40
                && panel.frame.insetBy(dx: -1, dy: -1).contains(popup.frame)
        }, "The idle completion popup must remain visible inside the resized panel.\n" + app.debugDescription)
        let initialTextCandidate = app.buttons["clipy.search.completion.type:text"]
        try require(initialTextCandidate.isHittable, app.debugDescription)
        initialTextCandidate.click()
        try require(waitUntil {
            search.value as? String == "$type:text$" && !popup.exists && rows.count > 0
        }, app.debugDescription)
        try replaceSearch(with: "", search: search, in: app)

        // A bare field-like spelling remains ordinary Exact text.
        search.click()
        app.typeKey("1", modifierFlags: .command)
        app.typeText("source:literal")
        try require(waitUntil {
            search.value as? String == "source:literal" && rows.count == 1
                && rows.firstMatch.label.contains("source:literal") && !popup.exists
        }, app.debugDescription)

        try replaceSearch(with: "$type:missing$", search: search, in: app)
        let issue = app.buttons["clipy.search.expression.error"]
        try require(waitUntil {
            issue.exists && issue.isHittable && !issue.label.isEmpty
                && search.value as? String == "$type:missing$" && panel.exists
        }, "A malformed closed condition must show its diagnostic.\n" + app.debugDescription)
        // Delete through the current responder, without restoring focus, to
        // keep the rejected query editable and return to unfinished input.
        app.typeKey(.delete, modifierFlags: [])
        try require(waitUntil {
            search.value as? String == "$type:missing" && !issue.exists && panel.exists
        }, "The diagnostic must clear when the native editor repairs the query.\n" + app.debugDescription)

        try replaceSearch(with: "$ty", search: search, in: app)
        let typeCandidate = app.buttons["clipy.search.completion.type:"]
        try require(typeCandidate.waitForExistence(timeout: 5), app.debugDescription)
        app.typeKey(.return, modifierFlags: [])
        try require(waitUntil {
            search.value as? String == "$type:$" && !popup.exists && panel.exists
        }, "Return must insert a completion and retain the panel.\n" + app.debugDescription)
        try require(pasteboard.string(forType: .string) == "completion must not copy",
                    "Return inserted a condition but also changed the General pasteboard.")

        // The template puts the native caret before its closing dollar. Bare
        // typing and Tab complete the value without clicking the field again.
        app.typeText("te")
        let textCandidate = app.buttons["clipy.search.completion.type:text"]
        try require(textCandidate.waitForExistence(timeout: 5), app.debugDescription)
        app.typeKey(.tab, modifierFlags: [])
        try require(waitUntil {
            search.value as? String == "$type:text$" && !popup.exists && panel.exists
                && rows.count > 0
        }, app.debugDescription)
        try require(pasteboard.string(forType: .string) == "completion must not copy",
                    "Tab must insert the candidate without copying a history item.")

        try replaceSearch(with: "$ty", search: search, in: app)
        try require(typeCandidate.waitForExistence(timeout: 5), app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
        try require(waitUntil {
            !popup.exists && panel.exists && search.value as? String == "$ty"
        }, "The first Escape must dismiss candidates before closing the panel.\n" + app.debugDescription)

        // Let the unfinished query replace the history list and shrink the
        // panel before clicking. Immediate keyboard acceptance misses a
        // candidate list covered by the refreshed results surface.
        try replaceSearch(with: "$ty", search: search, in: app)
        try require(app.staticTexts["No Results"].waitForExistence(timeout: 10), app.debugDescription)
        try require(typeCandidate.waitForExistence(timeout: 5), app.debugDescription)
        try require(typeCandidate.isHittable, "Search refresh must leave the candidate clickable.\n" + app.debugDescription)
        typeCandidate.click()
        try require(waitUntil {
            search.value as? String == "$type:$" && !popup.exists && panel.exists
        }, "Clicking after search refresh must insert the condition.\n" + app.debugDescription)
        app.typeText("te")
        try require(textCandidate.waitForExistence(timeout: 5), app.debugDescription)
        app.typeKey(.tab, modifierFlags: [])
        try require(waitUntil { search.value as? String == "$type:text$" && !popup.exists }, app.debugDescription)

        // The subsequence is deliberately not a literal source-ID prefix.
        // That source appears after 55 other IDs in the metadata catalogue,
        // and its item is absent from the initial 50-row history page.
        try replaceSearch(with: "$source:zzrmtarg", search: search, in: app)
        let candidateID = "clipy.search.completion.source."
            + Data(fixture.oldSource.utf8).base64EncodedString()
        let sourceCandidate = app.buttons[candidateID]
        try require(sourceCandidate.waitForExistence(timeout: 10), app.debugDescription)
        try require(sourceCandidate.isHittable, app.debugDescription)
        sourceCandidate.click()
        let expression = "$source-id:" + HistorySearchExpression.quoted(fixture.oldSource) + "$"
        try require(waitUntil {
            search.value as? String == expression && !popup.exists && panel.exists
                && rows.count == 1 && rows.firstMatch.identifier == fixture.rowIdentifier
        }, app.debugDescription)

        // app.typeText targets the current responder; search.typeText would
        // repair focus and hide a candidate-click regression.
        app.typeText(" retained")
        try require(waitUntil {
            search.value as? String == expression + " retained"
                && rows.count == 1 && rows.firstMatch.identifier == fixture.rowIdentifier
                && rows.firstMatch.label.contains(fixture.text) && panel.exists
        }, "Clicking a candidate must preserve the native field editor.\n" + app.debugDescription)
        XCTAssertEqual(pasteboard.string(forType: .string), "completion must not copy")
    }

    private struct SourceFixture: Sendable {
        let oldSource: String
        let text: String
        let rowIdentifier: String
    }

    @MainActor
    private func seedHistory(at storeURL: URL) async throws -> SourceFixture {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .persistent(storeURL: storeURL)))
        let base = Date().addingTimeInterval(-1_000)
        let oldSource = "org.zzz.remote.Target"
        let targetText = "remote retained target"
        let first = try await history.perform(.capture(capture(
            targetText, source: oldSource, at: base
        )))
        let inserted: HistoryItemReference?
        if case .committed(let commit) = first, case .inserted(let reference) = commit.outcome { inserted = reference }
        else { inserted = nil }
        let target = try XCTUnwrap(inserted)
        let second = try await history.perform(.capture(capture(
            targetText, source: "org.example.replacement", at: base.addingTimeInterval(1)
        )))
        let coalesced: HistoryItemReference?
        if case .committed(let commit) = second, case .coalesced(let reference) = commit.outcome { coalesced = reference }
        else { coalesced = nil }
        let copiedTarget = try XCTUnwrap(coalesced)
        try require(copiedTarget.id == target.id)
        for index in 0..<55 {
            _ = try await history.perform(.capture(capture(
                String(format: "Remote fixture %03d", index),
                source: String(format: "org.example.remote.%03d", index),
                at: base.addingTimeInterval(Double(index + 10))
            )))
        }
        _ = try await history.perform(.capture(capture(
            "source:literal", source: nil, at: base.addingTimeInterval(100)
        )))
        let details = try await history.details(for: target.id)
        try require(details.occurrence.firstSource == oldSource)
        try require(details.occurrence.lastSource == "org.example.replacement")
        let recent = try await history.browse(.init(kind: .recent, limit: 50))
        try require(!recent.rows.contains { $0.item.id == target.id } && recent.next != nil)
        let sources = try await history.sourceApplications(.init(limit: 32))
        try require(!sources.applications.contains(oldSource) && sources.next != nil)
        return SourceFixture(oldSource: oldSource, text: targetText,
                             rowIdentifier: "clipy.history.row." + target.id.description)
    }

    private func capture(_ text: String, source: String?, at date: Date) -> ClipboardCapture {
        .init(representations: [.init(typeIdentifier: "public.utf8-plain-text", bytes: Data(text.utf8))],
              origin: .init(sourceApplication: source, lineageHint: nil), observedAt: date)
    }

    @MainActor
    private func replaceSearch(with text: String, search: XCUIElement, in app: XCUIApplication) throws {
        try require(search.exists && search.isHittable, app.debugDescription)
        search.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
        app.typeText(text)
        try require(waitUntil { search.value as? String == text }, app.debugDescription)
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }

    private func require(_ condition: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) throws {
        guard condition else {
            XCTFail(message, file: file, line: line)
            throw JourneyFailure.precondition
        }
    }

    private enum JourneyFailure: Error { case precondition }
}
