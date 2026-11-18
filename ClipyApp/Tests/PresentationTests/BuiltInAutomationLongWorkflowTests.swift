import Foundation
@testable import ClipyApp
import Testing

struct BuiltInAutomationLongWorkflowTests {
    @Test func longRulesExecuteEveryStepInOrderAfterParsingAndFormatting() async throws {
        let numbers = (0..<513).map { String($0) }
        let source = numbers.map { "replace(\">\", \"\($0),>\")" }.joined(separator: "\n")
        let expected = numbers.joined(separator: ",") + ",>"
        let steps = try BuiltInAutomationSyntax.parse(source)
        #expect(try BuiltInAutomation.run(">", steps: steps) == expected)

        let restored = try BuiltInAutomationSyntax.parse(BuiltInAutomationSyntax.render(steps))
        let output = try await BuiltInAutomation.run(.text(">"), steps: restored)
        #expect(output.value == .text(expected))
        #expect(output.originalInput == .text(">"))
        #expect(output.matchedConditions)
        #expect(!output.requestsNotification)
    }

    @Test func deeplyNestedBranchesExecuteOnlySelectedActionsAndResumeTheirParents() async throws {
        var steps = [BuiltInAutomationStep(operation: .uppercase)]
        for _ in 0..<512 {
            steps = [.init(operation: .conditional, condition: .isText,
                           thenSteps: steps, otherwiseSteps: [.init(operation: .prettyJSON)])]
        }
        steps.append(.init(operation: .replace, find: "TEXT", replacement: "done"))
        try BuiltInAutomation.validateStepTree(steps)
        #expect(try BuiltInAutomation.run("text", steps: steps) == "done")
        let output = try await BuiltInAutomation.run(.text("text"), steps: steps)
        #expect(output.value == .text("done"))
        #expect(output.matchedConditions)
        #expect(!BuiltInAutomation.prefersImage(steps))
    }

    @Test func failedDeepBranchDiscardsItsTransformsAndDeferredNotification() async throws {
        var branch: [BuiltInAutomationStep] = [
            .init(operation: .notify), .init(operation: .trim),
            .init(operation: .containsText, find: "absent"),
        ]
        for _ in 0..<128 {
            branch = [.init(operation: .conditional, condition: .isText, thenSteps: branch)]
        }
        branch.append(.init(operation: .uppercase))
        let output = try await BuiltInAutomation.run(.text(" text "), steps: branch)
        #expect(output.value == .text(" TEXT "))
        #expect(output.originalInput == .text(" text "))
        #expect(output.matchedConditions)
        #expect(!output.requestsNotification)
    }

    @Test func duplicateIDsInDisabledDeepBranchesRemainInvalid() throws {
        let duplicate = BuiltInAutomationStep(operation: .trim)
        var branch = [duplicate]
        for _ in 0..<128 {
            branch = [.init(operation: .conditional, enabled: false, condition: .isText,
                            thenSteps: branch)]
        }
        #expect(throws: BuiltInAutomationFailure.invalidWorkflow) {
            try BuiltInAutomation.validateStepTree([duplicate] + branch)
        }
    }

    @MainActor @Test func longDefinitionsSaveAndReloadWithoutAReplacementCountLimit() async throws {
        let suite = "LongWorkflow.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let steps = (0..<1_024).map { _ in BuiltInAutomationStep(operation: .trim) }
        let workflow = BuiltInAutomationWorkflow(name: "Long definition", steps: steps)
        let library = BuiltInAutomationLibrary(defaults: defaults)
        try library.save(workflow)
        let reopened = BuiltInAutomationLibrary(defaults: defaults)
        #expect(reopened.failure == nil)
        #expect(reopened.workflows == [workflow])
        let readable = try #require(reopened.workflows.first)
        let result = try await BuiltInAutomation.run(.text(" text "), steps: readable.steps)
        #expect(result.value == .text("text"))
        #expect(result.matchedConditions)

        var invalid = workflow
        invalid.steps.append(.init(operation: .replace, find: String(repeating: "a", count: 16_385), replacement: "x"))
        #expect(throws: BuiltInAutomationFailure.definitionTooLarge) { try library.save(invalid) }
        #expect(BuiltInAutomationLibrary(defaults: defaults).workflows == [workflow])
    }

    @MainActor @Test func nestedBranchesAndCompoundConditionsSaveReopenAndExecute() async throws {
        let suite = "NestedWorkflow.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var predicate = BuiltInAutomationPredicate.all([
            .match(.isText, ""), .not(.match(.containsText, "absent")),
        ])
        for _ in 0..<48 { predicate = .not(predicate) }
        var steps: [BuiltInAutomationStep] = [
            .init(operation: .conditional, predicate: predicate,
                  thenSteps: [.init(operation: .trim), .init(operation: .uppercase)],
                  otherwiseSteps: [.init(operation: .prettyJSON)]),
        ]
        for _ in 0..<48 {
            steps = [.init(operation: .conditional, condition: .isText, thenSteps: steps)]
        }
        let workflow = BuiltInAutomationWorkflow(name: "Nested but readable", steps: steps)
        try BuiltInAutomationLibrary(defaults: defaults).save(workflow)
        let reopened = BuiltInAutomationLibrary(defaults: defaults)
        #expect(reopened.failure == nil)
        #expect(reopened.workflows == [workflow])
        let saved = try #require(reopened.workflows.first)
        let result = try await BuiltInAutomation.run(.text(" text "), steps: saved.steps)
        #expect(result.value == .text("TEXT"))
        #expect(result.matchedConditions)
    }

    @MainActor @Test func unsupportedJSONNestingCannotReplaceReadableSavedDefinitions() throws {
        let suite = "UnrepresentableWorkflow.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = BuiltInAutomationWorkflow(name: "Keep this", steps: [.init(operation: .trim)])
        let library = BuiltInAutomationLibrary(defaults: defaults)
        try library.save(original)
        let savedBytes = try #require(defaults.data(forKey: BuiltInAutomationLibrary.defaultsKey))

        var deep = original
        for _ in 0..<600 {
            deep.steps = [.init(operation: .conditional, condition: .isText, thenSteps: deep.steps)]
        }
        // No artificial step/depth validator rejects this executable tree.
        // The actual Foundation JSON codec decides whether it is representable.
        #expect(BuiltInAutomationLibrary.validationFailure(for: deep) == nil)
        #expect(throws: BuiltInAutomationFailure.unsupportedDefinitionNesting) { try library.save(deep) }
        #expect(defaults.data(forKey: BuiltInAutomationLibrary.defaultsKey) == savedBytes)
        #expect(library.failure == nil)
        #expect(library.workflows == [original])
        let reopened = BuiltInAutomationLibrary(defaults: defaults)
        #expect(reopened.failure == nil)
        #expect(reopened.workflows == [original])
    }

    @Test func invalidJSONAndInvalidFieldsAreNotMisreportedAsNestingFailures() throws {
        do {
            _ = try JSONDecoder().decode([BuiltInAutomationWorkflow].self, from: Data("{broken".utf8))
            Issue.record("Malformed JSON was accepted")
        } catch { #expect(BuiltInAutomation.definitionNestingFailure(for: error) == nil) }

        var invalid = BuiltInAutomationWorkflow(name: "Invalid date", steps: [.init(operation: .trim)])
        invalid.scope.endDate = Date(timeIntervalSinceReferenceDate: .infinity)
        do {
            _ = try JSONEncoder().encode([invalid])
            Issue.record("An infinite date was encoded")
        } catch { #expect(BuiltInAutomation.definitionNestingFailure(for: error) == nil) }
    }

    @MainActor @Test func cancellingDefinitionReadDoesNotMarkValidSavedDataAsCorrupt() async throws {
        let suite = "CancelledWorkflowRead.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workflow = BuiltInAutomationWorkflow(name: "Keep this", steps: [.init(operation: .trim)])
        let library = BuiltInAutomationLibrary(defaults: defaults)
        try library.save(workflow)
        let original = defaults.data(forKey: BuiltInAutomationLibrary.defaultsKey)
        let task = Task { @MainActor in try library.refresh() }
        task.cancel()
        do {
            try await task.value
            Issue.record("Cancelled definition read succeeded")
        } catch { #expect(error is CancellationError) }
        #expect(library.failure == nil)
        #expect(library.workflows == [workflow])
        #expect(defaults.data(forKey: BuiltInAutomationLibrary.defaultsKey) == original)
        try library.refresh()
        #expect(library.workflows == [workflow])
    }
}
