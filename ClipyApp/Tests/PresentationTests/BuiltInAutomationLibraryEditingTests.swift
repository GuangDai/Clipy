import Foundation
@testable import ClipyApp
import Testing

@MainActor
struct BuiltInAutomationLibraryEditingTests {
    @Test func savingOneDraftAlsoPersistsItsVisiblePriority() throws {
        let suite = "WorkflowAtomicSave.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = BuiltInAutomationLibrary(defaults: defaults)
        let first = workflow("First")
        let last = workflow("Last")
        let middle = workflow(" Middle ")
        let unsaved = workflow("Unsaved")
        try library.saveAll([first, last])
        try library.save(middle, orderedIDs: [first.id, middle.id, unsaved.id, last.id])

        let saved = BuiltInAutomationLibrary(defaults: defaults).workflows
        #expect(saved.map(\.id) == [first.id, middle.id, last.id])
        #expect(saved.map(\.name) == ["First", "Middle", "Last"])
        #expect(!saved.contains { $0.id == unsaved.id })
    }

    @Test func exceedingWorkflowLimitDoesNotPartiallySaveBatch() throws {
        let suite = "WorkflowBatchLimit.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = BuiltInAutomationLibrary(defaults: defaults)
        let original = (0..<49).map { workflow("Workflow \($0)") }
        try library.saveAll(original)
        let savedBytes = try #require(defaults.data(forKey: BuiltInAutomationLibrary.defaultsKey))
        var edited = original[0]
        edited.name = "Changed"

        #expect(throws: BuiltInAutomationFailure.workflowLimit) {
            try library.saveAll([edited, workflow("Fiftieth"), workflow("Fifty-first")])
        }
        #expect(defaults.data(forKey: BuiltInAutomationLibrary.defaultsKey) == savedBytes)
        #expect(library.workflows == original)
    }

    @Test func validationUsesTheSameNormalizedDefinitionAsSave() throws {
        let suite = "WorkflowLiveValidation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = BuiltInAutomationLibrary(defaults: defaults)
        let valid = workflow(" \(String(repeating: "x", count: 200)) ")
        #expect(BuiltInAutomationLibrary.validationFailure(for: valid) == nil)
        try library.save(valid)
        #expect(library.workflows.first?.name.utf8.count == 200)

        let invalid = BuiltInAutomationWorkflow(name: "Nested", steps: [
            .init(operation: .conditional, condition: .isText, otherwiseSteps: [
                .init(operation: .regexExtract, find: "[")
            ])
        ])
        #expect(BuiltInAutomationLibrary.validationFailure(for: invalid) == .invalidRegex)
        #expect(throws: BuiltInAutomationFailure.invalidRegex) { try library.save(invalid) }
        #expect(BuiltInAutomationLibrary.validationFailure(for: workflow("  ")) == .invalidWorkflow)
    }

    private func workflow(_ name: String) -> BuiltInAutomationWorkflow {
        .init(name: name, steps: [.init(operation: .trim)])
    }
}
