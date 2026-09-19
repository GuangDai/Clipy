import Foundation
@testable import HistoryCore
@testable import HistoryStorage
@testable import ClipyApp
import Testing

struct BuiltInAutomationTests {
    @Test func runsOrderedStepsAndPreservesByteDistinctLines() throws {
        let steps: [BuiltInAutomationStep] = [
            .init(operation: .trimLines), .init(operation: .removeEmptyLines),
            .init(operation: .uniqueLines), .init(operation: .sortLines)
        ]
        let result = try BuiltInAutomation.run(" b \r\na\r\n b\r\n\r\ne\u{301}\r\né ", steps: steps)
        #expect(Array(result.utf8) == Array("a\nb\ne\u{301}\né".utf8))
        let trimThenReplace: [BuiltInAutomationStep] = [
            .init(operation: .trim), .init(operation: .replace, find: "a", replacement: " a ")
        ]
        #expect(try BuiltInAutomation.run(" a ", steps: trimThenReplace) == " a ")
        #expect(try BuiltInAutomation.run(" a ", steps: Array(trimThenReplace.reversed())) == "a")
    }

    @Test func replacementIsLiteralAndDoesNotNormalizeUnicode() throws {
        let step = BuiltInAutomationStep(operation: .replace, find: "é", replacement: "$1\\n")
        let result = try BuiltInAutomation.run("é e\u{301} .+", steps: [step])
        #expect(Array(result.utf8) == Array("$1\\n e\u{301} .+".utf8))
        let duplicate = BuiltInAutomationStep(operation: .replace, find: "a", replacement: "aa")
        #expect(try BuiltInAutomation.run("aaa", steps: [duplicate]) == "aaaaaa")
    }

    @Test func jsonFormattingPreservesNumbersDuplicateKeysAndStringEscapes() throws {
        let compact = #"{"n":9007199254740993,"n":1.2300e+02,"s":" x, : [ \\\" ","empty":[],"child":{"a":true}}"#
        let pretty = try BuiltInAutomation.run(compact, steps: [.init(operation: .prettyJSON)])
        #expect(pretty.contains("\n  \"n\": 9007199254740993,"))
        #expect(pretty.contains("\"empty\": []"))
        #expect(try BuiltInAutomation.run(pretty, steps: [.init(operation: .compactJSON)]) == compact)
        #expect(try BuiltInAutomation.run(" 123.00e+2 \n", steps: [.init(operation: .prettyJSON)]) == "123.00e+2")
    }

    @Test func invalidInputAndExpansionFailWithoutAResult() throws {
        #expect(throws: BuiltInAutomationFailure.invalidJSON) {
            try BuiltInAutomation.run("{broken}", steps: [.init(operation: .prettyJSON)])
        }
        #expect(throws: BuiltInAutomationFailure.emptyFind) {
            try BuiltInAutomation.run("text", steps: [.init(operation: .replace)])
        }
        #expect(throws: BuiltInAutomationFailure.textTooLarge) {
            try BuiltInAutomation.run(String(repeating: "a", count: 1024), steps: [
                .init(operation: .replace, find: "a", replacement: String(repeating: "b", count: 2048))
            ])
        }
        #expect(throws: BuiltInAutomationFailure.tooManyLines) {
            try BuiltInAutomation.run(String(repeating: "\n", count: 50_000), steps: [.init(operation: .sortLines)])
        }
        #expect(try BuiltInAutomation.run("bad json", steps: [.init(operation: .prettyJSON, enabled: false)]) == "bad json")
    }

    @Test func lineLimitCountsEmptyLinesAndNormalizesLineEndings() throws {
        let trimLines = [BuiltInAutomationStep(operation: .trimLines)]
        #expect(try BuiltInAutomation.run("", steps: trimLines) == "")
        #expect(try BuiltInAutomation.run("\r\n x \r\r\n", steps: trimLines) == "\nx\n\n")
        let atLimit = String(repeating: "\n", count: 49_999)
        #expect(try BuiltInAutomation.run(atLimit, steps: trimLines) == atLimit)
        // Even remove-empty-lines must enforce the input line bound before
        // discarding lines; a full-size newline input must not expand into
        // a million individually owned strings before it can be rejected.
        let operations: [BuiltInAutomationStep.Operation] = [.trimLines, .removeEmptyLines, .uniqueLines, .sortLines]
        for operation in operations {
            #expect(throws: BuiltInAutomationFailure.tooManyLines) {
                try BuiltInAutomation.run(
                    String(repeating: "\n", count: BuiltInAutomation.maximumBytes),
                    steps: [.init(operation: operation)]
                )
            }
        }
    }

    @MainActor @Test func cancellationAndSupersedingPreviewNeverPublishAnOldResult() async {
        let cancelled = Task { @MainActor in
            try BuiltInAutomation.run("text", steps: [.init(operation: .uppercase)])
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            Issue.record("Cancelled work returned a result")
        } catch { #expect(error is CancellationError) }

        let model = BuiltInAutomationModel()
        model.preview(source: String(repeating: "a", count: 500_000), steps: [.init(operation: .uppercase)])
        let latestSteps = [BuiltInAutomationStep(operation: .lowercase)]
        model.preview(source: "LATEST", steps: latestSteps)
        await waitForPreview(model)
        #expect(model.result == "latest")
        #expect(model.isCurrent(source: "LATEST", steps: latestSteps))
        #expect(!model.isCurrent(source: "CHANGED", steps: latestSteps))
        model.invalidate()
        #expect(model.result == nil)
        #expect(!model.isCurrent(source: "LATEST", steps: latestSteps))

        model.preview(source: "bad json", steps: [.init(operation: .prettyJSON)])
        await waitForPreview(model)
        #expect(model.result == nil)
        #expect(model.failure == .invalidJSON)
        model.preview(source: "fixed", steps: latestSteps)
        await waitForPreview(model)
        #expect(model.failure == nil)
        #expect(model.result == "fixed")
    }

    @MainActor @Test func workflowLibraryPersistsEditsAndKeepsMalformedDataUntilExplicitReset() throws {
        let suite = "BuiltInAutomationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = BuiltInAutomationLibrary(defaults: defaults)
        var workflow = BuiltInAutomationWorkflow(name: " Clean ", steps: [.init(operation: .trim)])
        try library.save(workflow)
        workflow.name = "Updated"
        workflow.steps.append(.init(operation: .uppercase))
        try library.save(workflow)
        let reopened = BuiltInAutomationLibrary(defaults: defaults)
        #expect(reopened.workflows.count == 1)
        #expect(reopened.workflows.first == workflow)
        try reopened.remove(workflow.id)
        #expect(BuiltInAutomationLibrary(defaults: defaults).workflows.isEmpty)

        let malformed = Data("invalid workflow data".utf8)
        defaults.set(malformed, forKey: BuiltInAutomationLibrary.defaultsKey)
        let damaged = BuiltInAutomationLibrary(defaults: defaults)
        #expect(damaged.failure == .unreadableWorkflows)
        #expect(throws: BuiltInAutomationFailure.unreadableWorkflows) { try damaged.save(workflow) }
        #expect(defaults.data(forKey: BuiltInAutomationLibrary.defaultsKey) == malformed)
        damaged.reset()
        try damaged.save(workflow)
        #expect(BuiltInAutomationLibrary(defaults: defaults).workflows == [workflow])
    }

    @MainActor @Test func libraryRejectsIncompleteReplacementWithoutLosingSavedWorkflow() throws {
        let suite = "BuiltInAutomationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = BuiltInAutomationLibrary(defaults: defaults)
        var workflow = BuiltInAutomationWorkflow(name: "Clean", steps: [.init(operation: .trim)])
        try library.save(workflow)
        workflow.steps.append(.init(operation: .replace))
        #expect(throws: BuiltInAutomationFailure.emptyFind) { try library.save(workflow) }
        #expect(BuiltInAutomationLibrary(defaults: defaults).workflows.first?.steps.count == 1)
    }

    @MainActor @Test func simultaneousLibrariesPreserveOtherWindowsSavedWorkflows() throws {
        let suite = "BuiltInAutomationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = BuiltInAutomationLibrary(defaults: defaults)
        let second = BuiltInAutomationLibrary(defaults: defaults)
        let alpha = BuiltInAutomationWorkflow(name: "Alpha", steps: [.init(operation: .trim)])
        let beta = BuiltInAutomationWorkflow(name: "Beta", steps: [.init(operation: .uppercase)])
        let gamma = BuiltInAutomationWorkflow(name: "Gamma", steps: [.init(operation: .lowercase)])
        try first.save(alpha)
        try second.save(beta)
        try first.save(gamma)
        try second.remove(alpha.id)
        #expect(BuiltInAutomationLibrary(defaults: defaults).workflows == [beta, gamma])
    }

    @MainActor @Test func previewRequiresByteExactSourceAndReplacementConfiguration() async {
        let model = BuiltInAutomationModel()
        let step = BuiltInAutomationStep(operation: .replace, find: "é", replacement: "x")
        model.preview(source: "é", steps: [step])
        await waitForPreview(model)
        #expect(model.result == "x")
        #expect(!model.isCurrent(source: "e\u{301}", steps: [step]))
        var edited = step
        edited.find = "e\u{301}"
        #expect(edited != step)
        #expect(!model.isCurrent(source: "é", steps: [edited]))
        edited = step
        edited.replacement = "é"
        var decomposed = edited
        decomposed.replacement = "e\u{301}"
        #expect(edited != decomposed)
    }

    @MainActor private func waitForPreview(_ model: BuiltInAutomationModel) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while (model.isQueued || model.isRunning) && ContinuousClock.now < deadline { await Task.yield() }
        if model.isQueued || model.isRunning {
            Issue.record("Text workflow did not finish within five seconds")
            model.invalidate()
        }
    }

    @Test func applyingToEditorPreservesUTF16AndOnlySaveAppendsAnImmutableRevision() async throws {
        let history = try await SQLiteHistory.open(
            configuration: HistoryConfiguration(persistence: .temporary)
        )
        let textType = "public.utf16-external-plain-text"
        let siblingType = "com.example.opaque"
        let originalBytes = Data([0xFE, 0xFF, 0x00, 0x20, 0x00, 0x61, 0x00, 0x20])
        let captured = try await history.perform(.capture(ClipboardCapture(
            representations: [
                CapturedRepresentation(typeIdentifier: textType, bytes: originalBytes),
                CapturedRepresentation(typeIdentifier: siblingType, bytes: Data([0x00, 0xFF]))
            ],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_100_000)
        )))
        guard case let .committed(capture) = captured, case let .inserted(initial) = capture.outcome else {
            Issue.record("Expected the workflow editor fixture to be captured")
            return
        }
        let before = try await history.details(for: initial.id)
        var draft = ReviseEditorDraft(details: before)
        let request = try #require(draft.replacementRequest(for: textType))
        let source = try await history.representation(request)
        let installed = draft.installReplacementSource(source)
        #expect(installed)
        draft.setChoice(.replace, for: textType)
        let result = try BuiltInAutomation.run(draft.replacementText(for: textType), steps: [
            .init(operation: .trim), .init(operation: .uppercase)
        ])
        draft.setReplacementText(result, for: textType)
        #expect(try await history.details(for: initial.id) == before)
        #expect(draft.revisionRequest().expected == initial.contentVersion)
        let saved = try await history.perform(.revise(draft.revisionRequest()))
        guard case let .committed(commit) = saved, case let .revised(current) = commit.outcome else {
            Issue.record("Expected workflow Save to append a revision")
            return
        }
        let after = try await history.details(for: initial.id)
        #expect(after.revisions.count == 1)
        let canonical = try await history.representation(HistoryRepresentationRequest(
            item: current, basis: .canonical, typeIdentifier: textType
        ))
        #expect(canonical.bytes == originalBytes)
        let payload = try await history.pastePayload(for: initial.id)
        #expect(payload.representations.first { $0.typeIdentifier == textType }?.bytes == Data([0xFE, 0xFF, 0x00, 0x41]))
        #expect(payload.representations.first { $0.typeIdentifier == siblingType }?.bytes == Data([0x00, 0xFF]))
        let staleRequest = draft.revisionRequest()
        await #expect(throws: HistoryFailure.staleContent(expected: initial.contentVersion, current: current.contentVersion)) {
            try await history.perform(.revise(staleRequest))
        }
        #expect(try await history.details(for: initial.id) == after)
    }
}
