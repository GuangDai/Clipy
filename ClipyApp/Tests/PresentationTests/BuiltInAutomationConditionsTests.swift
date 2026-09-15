import AppKit
import Foundation
import Testing
@testable import HistoryCore
@testable import HistoryStorage
@testable import ClipyApp

struct BuiltInAutomationConditionsTests {
    @Test func regexHandlesUnicodeGroupsZeroWidthMatchesAndBoundedExpansion() throws {
        #expect(try BuiltInAutomation.run("é😀", steps: [.init(operation: .regexReplace,
            find: "(é)(😀)", replacement: "$2/$1")]) == "😀/é")
        #expect(try BuiltInAutomation.run("a", steps: [.init(operation: .regexReplace,
            find: "^|$", replacement: "_")]) == "_a_")
        #expect(try BuiltInAutomation.run("one=12 two=34", steps: [.init(operation: .regexExtract,
            find: "[0-9]+")]) == "12\n34")
        #expect(try BuiltInAutomation.matchesRegularExpression("", pattern: "^$"))
        #expect(throws: BuiltInAutomationFailure.invalidRegex) {
            try BuiltInAutomation.run("text", steps: [.init(operation: .regexReplace, find: "(")])
        }
        #expect(throws: BuiltInAutomationFailure.textTooLarge) {
            try BuiltInAutomation.run(String(repeating: "a", count: 1024), steps: [
                .init(operation: .regexReplace, find: "(a{1024})", replacement: String(repeating: "$1", count: 1025))
            ])
        }
    }

    @Test func engineFailureDoesNotMisreportAValidPatternAsInvalidSyntax() throws {
        #expect(throws: BuiltInAutomationFailure.regexEngineFailed) {
            try BuiltInAutomation.run(String(repeating: "a", count: 600_000), steps: [
                .init(operation: .regexReplace, find: "(a+)", replacement: "$1$1")
            ])
        }
    }

    @Test func nonmatchingConditionSkipsNotificationEvenWhenNotificationStepComesFirst() async throws {
        let result = try await BuiltInAutomation.run(.text("ordinary text"), steps: [
            .init(operation: .notify), .init(operation: .containsText, find: "TODO")
        ])
        #expect(!result.matchedConditions)
        #expect(!result.requestsNotification)
        let typeMismatch = try await BuiltInAutomation.run(.text("TODO"), steps: [
            .init(operation: .requireImage), .init(operation: .notify)
        ])
        #expect(!typeMismatch.matchedConditions)
        #expect(!typeMismatch.requestsNotification)
        await #expect(throws: BuiltInAutomationFailure.notificationNeedsCondition) {
            try await BuiltInAutomation.run(.text("text"), steps: [.init(operation: .notify)])
        }
    }

    @MainActor @Test func previewIsInertAndManualRunNotifiesOnlyOnMatch() async throws {
        let notifications = NotificationCounter()
        let model = BuiltInAutomationModel(notify: { await notifications.record($0) })
        let steps: [BuiltInAutomationStep] = [.init(operation: .matchesRegex, find: "TODO: [0-9]+"), .init(operation: .notify)]
        model.preview(input: .text("TODO: 42"), steps: steps)
        await wait(model)
        #expect(model.result == "TODO: 42")
        #expect(await notifications.count == 0)
        model.preview(input: .text("ordinary text"), steps: steps, runEffects: true)
        await wait(model)
        #expect(model.result == nil)
        #expect(await notifications.count == 0)
        model.preview(input: .text("TODO: 42"), steps: steps, runEffects: true)
        await wait(model)
        #expect(await notifications.count == 1)
    }

    @MainActor @Test func automaticWorkflowsRequireNewSubmissionAndRespectSource() async throws {
        let suite = "WorkflowConditions.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var workflow = BuiltInAutomationWorkflow(name: "TODO", steps: [
            .init(operation: .containsText, find: "TODO"), .init(operation: .notify)
        ], trigger: .both)
        workflow.scope.applications = "com.example.Editor"
        try BuiltInAutomationLibrary(defaults: defaults).save(workflow)
        let notifications = NotificationCounter()
        let runner = BuiltInAutomationAutomaticRunner(defaults: defaults, notify: { await notifications.record($0) })
        defer { runner.stop() }
        #expect(await notifications.count == 0, "Saving/enabling definitions must not scan old clipboard history")
        runner.submit(capture("TODO: one", app: "com.example.Other"))
        await runner.waitForPendingWorkForTesting()
        #expect(await notifications.count == 0)
        runner.submit(capture("ordinary", app: "com.example.Editor"))
        await runner.waitForPendingWorkForTesting()
        #expect(await notifications.count == 0)
        runner.submit(capture("TODO: one", app: "com.example.Editor"))
        await runner.waitForPendingWorkForTesting()
        #expect(await notifications.count == 1)
        #expect(await notifications.names == ["TODO"])
        workflow.trigger = .manual
        try BuiltInAutomationLibrary(defaults: defaults).save(workflow)
        runner.submit(capture("TODO: two", app: "com.example.Editor"))
        await runner.waitForPendingWorkForTesting()
        #expect(await notifications.count == 1)
    }

    @Test func manualHistoryScopeUsesSourceAndTimeWithoutChangingHistory() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let now = Date()
        for item in [capture("TODO recent", app: "com.example.Editor", at: now),
                     capture("TODO old", app: "com.example.Editor", at: now.addingTimeInterval(-7200)),
                     capture("TODO other", app: "com.example.Other", at: now)] {
            _ = try await history.perform(.capture(item))
        }
        let before = try await history.browse(.init(kind: .recent, limit: 10))
        var workflow = BuiltInAutomationWorkflow(name: "TODO", steps: [
            .init(operation: .containsText, find: "TODO"), .init(operation: .notify)
        ])
        workflow.scope.source = .history
        workflow.scope.applications = "com.example.Editor"
        workflow.scope.timeRange = .lastHour
        let result = try await BuiltInAutomation.evaluateManual(input: .text("unused"), workflow: workflow, history: history)
        #expect(result.matchedItemCount == 1)
        #expect(result.value.text == "TODO recent")
        #expect(result.requestsNotification)
        #expect(try await history.browse(.init(kind: .recent, limit: 10)) == before)
    }

    @Test func historyRangeSpansPagesWithoutChangingCursorQuery() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        for index in 0..<52 {
            _ = try await history.perform(.capture(capture("matching-\(index)", app: "com.example.Editor")))
        }
        var workflow = BuiltInAutomationWorkflow(name: "Matching rows", steps: [
            .init(operation: .containsText, find: "matching-")
        ])
        workflow.scope.source = .history
        workflow.scope.historyLimit = 51
        let result = try await BuiltInAutomation.evaluateManual(input: .text(""), workflow: workflow, history: history)
        #expect(result.matchedItemCount == 51)
        #expect(result.value.text == "matching-51")
    }

    @MainActor @Test func systemOCRFeedsTextConditionsAndPreservesOriginalImage() async throws {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 180,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 800, height: 180)).fill()
        ("CLIPY 2048" as NSString).draw(at: NSPoint(x: 35, y: 55), withAttributes: [
            .font: NSFont.systemFont(ofSize: 80), .foregroundColor: NSColor.black
        ])
        NSGraphicsContext.restoreGraphicsState()
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let input = BuiltInAutomationInput.image(data)
        let result = try await BuiltInAutomation.run(input, steps: [
            .init(operation: .requireImage), .init(operation: .recognizeText),
            .init(operation: .containsText, find: "2048"), .init(operation: .notify)
        ])
        #expect(result.matchedConditions)
        #expect(result.value.text?.contains("2048") == true)
        #expect(result.requestsNotification)
        #expect(input == .image(data))
    }

    private func capture(_ text: String, app: String, at date: Date = Date()) -> ClipboardCapture {
        .init(representations: [.init(typeIdentifier: "public.utf8-plain-text", bytes: Data(text.utf8))],
              origin: .init(sourceApplication: app, lineageHint: nil), observedAt: date)
    }

    @MainActor private func wait(_ model: BuiltInAutomationModel) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.isRunning && ContinuousClock.now < deadline { await Task.yield() }
        #expect(!model.isRunning)
    }
}

private actor NotificationCounter {
    private(set) var names: [String] = []
    var count: Int { names.count }
    func record(_ name: String) { names.append(name) }
}
