import Foundation
import Testing
@testable import ClipyApp

@MainActor
struct WorkflowStepsEditorStateTests {
    @Test
    func workflowsStartVisuallyAndKeepSeparateSourceDraftsAcrossModeChanges() async throws {
        let state = WorkflowStepsEditorState()
        let firstID = UUID()
        let secondID = UUID()
        let firstSteps: [BuiltInAutomationStep] = [.init(operation: .trim)]
        let secondSteps: [BuiltInAutomationStep] = [.init(operation: .lowercase)]
        state.prepare(firstID, steps: firstSteps)
        state.prepare(secondID, steps: secondSteps)
        let first = try #require(state.draft(for: firstID))
        let second = try #require(state.draft(for: secondID))
        #expect(first.mode == .visual)
        #expect(second.mode == .visual)
        #expect(!state.hasUnappliedChanges)

        first.setMode(.syntax)
        await first.prepareSourceIfNeeded()
        #expect(first.source == "trim()\n")
        let firstSource = "# keep this draft\nuppercase()\n"
        first.updateSource(firstSource)
        first.setMode(.visual)
        second.setMode(.syntax)
        await second.prepareSourceIfNeeded()
        #expect(second.source == "lowercase()\n")
        let secondSource = "replace(\"e\u{301}\", \"é\")\n"
        second.updateSource(secondSource)

        state.prepare(firstID, steps: firstSteps)
        first.setMode(.syntax)
        await first.prepareSourceIfNeeded()
        state.prepare(secondID, steps: secondSteps)
        await second.prepareSourceIfNeeded()

        #expect(state.draft(for: firstID) === first)
        #expect(state.draft(for: secondID) === second)
        #expect(Data(first.source.utf8) == Data(firstSource.utf8))
        #expect(Data(second.source.utf8) == Data(secondSource.utf8))
        #expect(state.hasUnappliedChanges(for: firstID))
        #expect(state.hasUnappliedChanges(for: secondID))
        #expect(state.hasUnappliedChanges)
        #expect(state.unappliedWorkflowIDs == [firstID, secondID])
        state.forget(firstID)
        #expect(state.draft(for: firstID) == nil)
        #expect(state.unappliedWorkflowIDs == [secondID])
    }

    @Test
    func failedParsePreservesSourceAndVisualStepsWithExactDiagnostic() async {
        let draft = WorkflowStepsEditorDraft(steps: [.init(operation: .lowercase)])
        draft.setMode(.syntax)
        await draft.prepareSourceIfNeeded()
        let invalidSource = "trim()\r\n  uppercase()"
        draft.updateSource(invalidSource)

        let candidate = await draft.parseSource()

        #expect(candidate == nil)
        #expect(Data(draft.source.utf8) == Data(invalidSource.utf8))
        #expect(draft.hasUnappliedChanges)
        #expect(!draft.hasVisualConflict)
        #expect(draft.diagnostic == BuiltInAutomationSyntaxError(
            reason: .unexpectedIndentation, line: 2, column: 3
        ))
        #expect(draft.failureMessage == nil)
        #expect(draft.diagnosticIsInSource)
        #expect(!draft.isProcessing)
        #expect(!draft.didApplySource)

        // A reload reads the still-current visual tree, proving the failed
        // parse did not replace it with the valid prefix of the source.
        draft.requestReload()
        await draft.prepareSourceIfNeeded()
        #expect(draft.source == "lowercase()\n")
        #expect(!draft.hasUnappliedChanges)
        #expect(draft.diagnostic == nil)
    }

    @Test
    func successfulParseReturnsCandidateUntilTheViewAcceptsIt() async throws {
        let draft = WorkflowStepsEditorDraft(steps: [.init(operation: .trim)])
        draft.setMode(.syntax)
        await draft.prepareSourceIfNeeded()
        let editedSource = "# preserve the user's comment\nuppercase()\n"
        draft.updateSource(editedSource)

        let candidate = try #require(await draft.parseSource())

        #expect(candidate.map(\.operation) == [.uppercase])
        #expect(try BuiltInAutomation.run(" Mixed ", steps: candidate) == " MIXED ")
        #expect(draft.source == editedSource)
        #expect(draft.hasUnappliedChanges)
        #expect(!draft.didApplySource)
        #expect(draft.diagnostic == nil)
        #expect(!draft.isProcessing)

        // Parsing alone must leave the visual tree at Trim.
        draft.requestReload()
        await draft.prepareSourceIfNeeded()
        #expect(draft.source == "trim()\n")
        draft.updateSource(editedSource)
        let accepted = try #require(await draft.parseSource())
        draft.acceptApplied(accepted)

        #expect(draft.source == editedSource)
        #expect(!draft.hasUnappliedChanges)
        #expect(!draft.hasVisualConflict)
        #expect(draft.didApplySource)
        draft.requestReload()
        await draft.prepareSourceIfNeeded()
        #expect(draft.source == "uppercase()\n")
    }

    @Test
    func visualEditsReportConflictWithoutReplacingPendingSource() async throws {
        let state = WorkflowStepsEditorState()
        let workflowID = UUID()
        state.prepare(workflowID, steps: [.init(operation: .trim)])
        let draft = try #require(state.draft(for: workflowID))
        draft.setMode(.syntax)
        await draft.prepareSourceIfNeeded()
        let pendingSource = "# unapplied rule\nuppercase()\n"
        draft.updateSource(pendingSource)
        draft.setMode(.visual)

        state.prepare(workflowID, steps: [.init(operation: .lowercase)])
        draft.setMode(.syntax)
        await draft.prepareSourceIfNeeded()

        #expect(draft.hasVisualConflict)
        #expect(state.hasUnappliedChanges(for: workflowID))
        #expect(draft.source == pendingSource)

        draft.requestReload()
        await draft.prepareSourceIfNeeded()
        #expect(draft.source == "lowercase()\n")
        #expect(!draft.hasVisualConflict)
        #expect(!state.hasUnappliedChanges)
    }

    @Test
    func discardingOneWorkflowKeepsOtherDraftsAndDiscardAllClearsPendingWork() async throws {
        let state = WorkflowStepsEditorState()
        let firstID = UUID()
        let secondID = UUID()
        state.prepare(firstID, steps: [.init(operation: .trim)])
        state.prepare(secondID, steps: [.init(operation: .lowercase)])
        let first = try #require(state.draft(for: firstID))
        let second = try #require(state.draft(for: secondID))
        first.setMode(.syntax)
        second.setMode(.syntax)
        await first.prepareSourceIfNeeded()
        await second.prepareSourceIfNeeded()
        first.updateSource("unknown()")
        _ = await first.parseSource()
        try #require(first.diagnostic != nil)
        second.updateSource("uppercase()\n")

        state.discard(firstID)

        #expect(first.mode == .visual)
        #expect(first.source.isEmpty)
        #expect(!first.hasPreparedSource)
        #expect(first.diagnostic == nil)
        #expect(!state.hasUnappliedChanges(for: firstID))
        #expect(second.source == "uppercase()\n")
        #expect(state.hasUnappliedChanges(for: secondID))
        #expect(state.hasUnappliedChanges)
        first.setMode(.syntax)
        await first.prepareSourceIfNeeded()
        #expect(first.source == "trim()\n")

        state.discardAll()

        #expect(!state.hasUnappliedChanges)
        #expect(!state.hasUnappliedChanges(for: secondID))
        #expect(first.mode == .visual)
        #expect(second.mode == .visual)
        #expect(first.source.isEmpty)
        #expect(second.source.isEmpty)
        #expect(!first.hasPreparedSource)
        #expect(!second.hasPreparedSource)
    }

    @Test
    func failedReloadKeepsSourceUntilVisualStepsCanBeRepresented() async {
        let draft = WorkflowStepsEditorDraft(steps: [.init(operation: .trim)])
        draft.setMode(.syntax)
        await draft.prepareSourceIfNeeded()
        let pendingSource = "# keep e\u{301} exactly\nuppercase()\n"
        draft.updateSource(pendingSource)
        draft.synchronize(with: [
            .init(operation: .trim, thenSteps: [.init(operation: .lowercase)])
        ])

        draft.requestReload()
        await draft.prepareSourceIfNeeded()

        #expect(Data(draft.source.utf8) == Data(pendingSource.utf8))
        #expect(draft.hasUnappliedChanges)
        #expect(draft.hasVisualConflict)
        #expect(draft.hasPreparedSource)
        #expect(draft.diagnostic == BuiltInAutomationSyntaxError(
            reason: .unrepresentableStep, line: 1, column: 1
        ))
        #expect(!draft.diagnosticIsInSource)
        #expect(draft.failureMessage == nil)
        #expect(!draft.isProcessing)

        draft.synchronize(with: [.init(operation: .lowercase)])
        draft.requestReload()
        await draft.prepareSourceIfNeeded()
        #expect(draft.source == "lowercase()\n")
        #expect(draft.diagnostic == nil)
        #expect(!draft.hasUnappliedChanges)
        #expect(!draft.hasVisualConflict)
    }

    @Test
    func diagnosticSelectionHandlesCRLFAndWholeGraphemesAndClampsLocations() {
        let source = "first\r\n😀e\u{301}👩🏽‍💻\r\nlast"
        let cases: [(Int, Int, NSRange, String)] = [
            (2, 1, NSRange(location: 7, length: 2), "😀"),
            (2, 2, NSRange(location: 9, length: 2), "e\u{301}"),
            (2, 3, NSRange(location: 11, length: 7), "👩🏽‍💻"),
            (2, 4, NSRange(location: 18, length: 0), ""),
            (2, 100, NSRange(location: 18, length: 0), ""),
            (3, 1, NSRange(location: 20, length: 1), "l"),
            (-10, -10, NSRange(location: 0, length: 1), "f"),
            (100, 2, NSRange(location: 21, length: 1), "a"),
            (100, 100, NSRange(location: 24, length: 0), ""),
        ]
        for (line, column, expectedRange, expectedText) in cases {
            let selection = WorkflowSyntaxLocation.selection(in: source, line: line, column: column)
            #expect(selection == expectedRange)
            let selected = (source as NSString).substring(with: selection)
            #expect(Data(selected.utf8) == Data(expectedText.utf8))
        }
        #expect(WorkflowSyntaxLocation.selection(in: "one\r\n\r\n😀", line: 2, column: 1)
            == NSRange(location: 5, length: 0))
        #expect(WorkflowSyntaxLocation.selection(in: "one\r\n\r\n😀", line: 3, column: 1)
            == NSRange(location: 7, length: 2))
        #expect(WorkflowSyntaxLocation.selection(in: "", line: 1, column: 1)
            == NSRange(location: 0, length: 0))
    }
}
