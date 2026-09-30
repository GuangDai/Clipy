import Foundation
import Testing
@testable import ClipyApp

@MainActor
struct BuiltInAutomationDefinitionAdmissionTests {
    @Test func byteDistinctNameAndScopeEditsRemainDirtyAndCanBeSaved() throws {
        let suite = "WorkflowExactDraft.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = BuiltInAutomationWorkflow(name: "é", steps: [.init(operation: .trim)])
        try BuiltInAutomationLibrary(defaults: defaults).save(original)
        let workspace = BuiltInAutomationWorkspace(defaults: defaults)
        workspace.workflow.name = "e\u{301}"
        #expect(workspace.hasUnsavedChanges)
        #expect(workspace.isDirty(workspace.workflow))
        try workspace.saveSelection()
        let saved = try #require(BuiltInAutomationLibrary(defaults: defaults).workflows.first)
        #expect(Data(saved.name.utf8) == Data("e\u{301}".utf8))
        #expect(!workspace.hasUnsavedChanges)

        workspace.workflow.scope.applications = "app.é"
        try workspace.saveSelection()
        workspace.workflow.scope.applications = "app.e\u{301}"
        #expect(workspace.hasUnsavedChanges)
        try workspace.saveSelection()
        let updated = try #require(BuiltInAutomationLibrary(defaults: defaults).workflows.first)
        #expect(Data(updated.scope.applications.utf8) == Data("app.e\u{301}".utf8))
    }

    @Test func batchAdmissionKeepsPerItemLimitsAndCompleteTreeIdentityChecks() async throws {
        let workflow = BuiltInAutomationWorkflow(name: "Batch", steps: [
            .init(operation: .containsText, find: "TOKEN"), .init(operation: .trim),
        ])
        let output = try await BuiltInAutomation.evaluate([
            .text("other"), .text(" TOKEN first "), .text("TOKEN second"),
        ], workflow: workflow)
        #expect(output.value == .text("TOKEN first"))
        #expect(output.originalInput == .text(" TOKEN first "))
        #expect(output.matchedItemCount == 2)

        await #expect(throws: BuiltInAutomationFailure.textTooLarge) {
            try await BuiltInAutomation.evaluate([
                .text("TOKEN first"), .text(String(repeating: "x", count: BuiltInAutomation.maximumBytes + 1)),
            ], workflow: workflow)
        }
        var duplicate = workflow
        duplicate.steps.append(.init(operation: .conditional, enabled: false, thenSteps: [workflow.steps[0]]))
        await #expect(throws: BuiltInAutomationFailure.invalidWorkflow) {
            try await BuiltInAutomation.evaluate([.text("TOKEN")], workflow: duplicate)
        }
    }

    @Test func invalidCaptureTemplateCannotReplaceASavedWorkflowOrBeExported() throws {
        let suite = "WorkflowAdmission.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = BuiltInAutomationLibrary(defaults: defaults)
        var workflow = BuiltInAutomationWorkflow(name: "Saved", steps: [.init(operation: .trim)])
        try library.save(workflow)
        let saved = try #require(defaults.data(forKey: BuiltInAutomationLibrary.defaultsKey))
        workflow.steps = [.init(operation: .regexReplace, find: "(a)", replacement: "$2")]

        #expect(throws: BuiltInAutomationFailure.invalidRegex) { try library.save(workflow) }
        #expect(throws: BuiltInAutomationTransfer.Failure.invalidDefinition(.invalidRegex)) {
            try BuiltInAutomationTransfer.export(workflow)
        }
        #expect(defaults.data(forKey: BuiltInAutomationLibrary.defaultsKey) == saved)
        #expect(library.failure == nil)

        // Capture 1 followed by a literal 2 is the executor's valid $12 form.
        workflow.steps[0].replacement = "$12"
        try library.save(workflow)
        #expect(try BuiltInAutomation.run("a", steps: workflow.steps) == "a2")
    }

    @Test func disabledBranchFieldsKeepTheirSaveBudgetWithoutEnablingTheirActions() throws {
        let oversized = String(repeating: "é", count: 8_193)
        let leaf = BuiltInAutomationStep(operation: .replace, find: oversized)
        let predicate = BuiltInAutomationPredicate.not(.all([.match(.containsText, oversized)]))
        let definitions: [[BuiltInAutomationStep]] = [
            [.init(operation: .conditional, enabled: false, condition: .isText, thenSteps: [leaf])],
            [.init(operation: .conditional, enabled: false, condition: .isText, otherwiseSteps: [leaf])],
            [.init(operation: .conditional, enabled: false, predicate: predicate)],
            [.init(operation: .trim, thenSteps: [leaf])],
        ]
        for steps in definitions {
            let workflow = BuiltInAutomationWorkflow(name: "Oversized inactive field", steps: steps)
            #expect(BuiltInAutomationLibrary.validationFailure(for: workflow) == .definitionTooLarge)
            #expect(throws: BuiltInAutomationTransfer.Failure.invalidDefinition(.definitionTooLarge)) {
                try BuiltInAutomationTransfer.export(workflow)
            }
        }

        // Invalid syntax in an inactive edit is retained within its byte budget.
        let inactive = BuiltInAutomationWorkflow(name: "Unfinished disabled branch", steps: [
            .init(operation: .conditional, enabled: false, predicate: .all([]), thenSteps: [
                .init(operation: .regexReplace, find: "[", replacement: "$9"), .init(operation: .notify),
            ]), .init(operation: .trim),
        ])
        let restored = try BuiltInAutomationTransfer.decode(BuiltInAutomationTransfer.export(inactive))
        #expect(restored == inactive)
        #expect(try BuiltInAutomation.run(" text ", steps: restored.steps) == "text")
    }
}
