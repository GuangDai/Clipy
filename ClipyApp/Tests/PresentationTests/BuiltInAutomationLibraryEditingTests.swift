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

    @Test func batchSaveRetainsOtherWindowsEditsAndAdditions() throws {
        let suite = "WorkflowMergedSave.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstWindow = BuiltInAutomationLibrary(defaults: defaults)
        var alpha = workflow("Alpha")
        var beta = workflow("Beta")
        try firstWindow.saveAll([alpha, beta])
        let secondWindow = BuiltInAutomationLibrary(defaults: defaults)
        let unrelated = workflow("Other window")
        beta.name = "Beta edited elsewhere"
        try secondWindow.saveAll([beta, unrelated])

        let added = workflow("New draft")
        alpha.steps.append(.init(operation: .uppercase))
        try firstWindow.saveAll([alpha, added], orderedIDs: [beta.id, alpha.id, added.id])

        #expect(BuiltInAutomationLibrary(defaults: defaults).workflows == [beta, alpha, unrelated, added])
        #expect(firstWindow.workflows == [beta, alpha, unrelated, added])
    }

    @Test func invalidBatchDoesNotSaveEarlierDraftsOrOrder() throws {
        let suite = "WorkflowInvalidBatch.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = BuiltInAutomationLibrary(defaults: defaults)
        let original = workflow("Original")
        try library.save(original)
        let savedBytes = try #require(defaults.data(forKey: BuiltInAutomationLibrary.defaultsKey))
        var edited = original
        edited.name = "Changed"
        let invalid = BuiltInAutomationWorkflow(name: "Incomplete", steps: [.init(operation: .replace)])

        #expect(throws: BuiltInAutomationFailure.emptyFind) {
            try library.saveAll([edited, invalid], orderedIDs: [invalid.id, edited.id])
        }
        #expect(defaults.data(forKey: BuiltInAutomationLibrary.defaultsKey) == savedBytes)
        #expect(library.workflows == [original])
        #expect(BuiltInAutomationLibrary(defaults: defaults).workflows == [original])
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

    @Test func duplicateHasIndependentIdentitiesAndStartsManual() throws {
        let original = BuiltInAutomationWorkflow(name: "Automatic original", steps: [
            .init(operation: .conditional, find: "TODO", thenSteps: [
                .init(operation: .replace, find: "TODO", replacement: "Done"),
                .init(operation: .conditional, condition: .isImage, thenSteps: [.init(operation: .recognizeText)])
            ], otherwiseSteps: [.init(operation: .uppercase, enabled: false)])
        ], trigger: .both, scope: .init(source: .clipboard, applications: "com.example.editor"))
        let duplicate = original.duplicated(named: "My copy")

        func allIDs(_ steps: [BuiltInAutomationStep]) -> [UUID] {
            steps.flatMap { [$0.id] + allIDs($0.thenSteps) + allIDs($0.otherwiseSteps) }
        }
        let originalIDs = Set([original.id] + allIDs(original.steps))
        let duplicateIDs = [duplicate.id] + allIDs(duplicate.steps)
        #expect(duplicate.name == "My copy")
        #expect(duplicate.trigger == .manual)
        #expect(duplicate.scope == original.scope)
        #expect(originalIDs.isDisjoint(with: duplicateIDs))
        #expect(Set(duplicateIDs).count == duplicateIDs.count)
        #expect(duplicateIDs.count == originalIDs.count)
        #expect(duplicate.steps.first?.thenSteps.first?.find == "TODO")
        #expect(duplicate.steps.first?.thenSteps.first?.replacement == "Done")
        #expect(duplicate.steps.first?.otherwiseSteps.first?.enabled == false)
        #expect(original.trigger == .both)
        #expect(BuiltInAutomationLibrary.validationFailure(for: duplicate) == nil)
    }

    private func workflow(_ name: String) -> BuiltInAutomationWorkflow {
        .init(name: name, steps: [.init(operation: .trim)])
    }
}
