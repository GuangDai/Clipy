import Foundation
import Testing
@testable import ClipyApp

@MainActor
struct BuiltInAutomationPredicateTests {
    @Test func nestedAllAnyAndNotChooseExactlyOneBranchUsingTheCurrentValue() async throws {
        let predicate = BuiltInAutomationPredicate.all([
            .match(.isText, ""),
            .any([.match(.containsText, "TODO"), .match(.containsText, "FIXME")]),
            .not(.match(.matchesRegex, "^SKIP"))
        ])
        let step = BuiltInAutomationStep(
            operation: .conditional, predicate: predicate,
            thenSteps: [.init(operation: .uppercase)],
            otherwiseSteps: [.init(operation: .trim)]
        )
        let accepted = try await BuiltInAutomation.run(.text("  TODO: next  "), steps: [step])
        #expect(accepted.value == .text("  TODO: NEXT  "))
        let alternate = try await BuiltInAutomation.run(.text("SKIP TODO: next  "), steps: [step])
        #expect(alternate.value == .text("SKIP TODO: next"))
        let ordinary = try await BuiltInAutomation.run(.text(" ordinary "), steps: [step])
        #expect(ordinary.value == .text("ordinary"))
        #expect(!accepted.requestsNotification && !alternate.requestsNotification)
    }

    @Test func allAndAnyShortCircuitButSavingChecksEveryCondition() throws {
        let invalid = BuiltInAutomationPredicate.match(.matchesRegex, "[")
        let all = BuiltInAutomationPredicate.all([.match(.isImage, ""), invalid])
        let any = BuiltInAutomationPredicate.any([.match(.isText, ""), invalid])
        #expect(try !all.matches(.text("text")))
        #expect(try any.matches(.text("text")))
        #expect(throws: BuiltInAutomationFailure.invalidRegex) { try all.validate() }
        #expect(throws: BuiltInAutomationFailure.invalidRegex) { try any.validate() }
        #expect(throws: BuiltInAutomationFailure.invalidRegex) {
            try BuiltInAutomationPredicate.all([.match(.isText, ""), invalid]).matches(.text("text"))
        }
    }

    @Test func emptyGroupsAreIncompleteInsteadOfUnconditionalMatches() {
        for predicate in [BuiltInAutomationPredicate.all([]), .any([])] {
            #expect(throws: BuiltInAutomationFailure.emptyConditionGroup) { try predicate.validate() }
            #expect(throws: BuiltInAutomationFailure.emptyConditionGroup) { try predicate.matches(.text("text")) }
        }
    }

    @Test(arguments: [BuiltInAutomationPredicate.all([]), .any([])])
    func nestedEmptyGroupsReportTheSameActionableFailureForSavingAndExecution(
        emptyGroup: BuiltInAutomationPredicate
    ) async {
        let predicate = BuiltInAutomationPredicate.all([
            .match(.isText, ""),
            .not(.any([.match(.isImage, ""), emptyGroup]))
        ])
        let step = BuiltInAutomationStep(
            operation: .conditional, predicate: predicate,
            thenSteps: [.init(operation: .uppercase)], otherwiseSteps: [.init(operation: .trim)]
        )
        let workflow = BuiltInAutomationWorkflow(name: "Incomplete nested condition", steps: [step])

        #expect(BuiltInAutomationLibrary.validationFailure(for: workflow) == .emptyConditionGroup)
        await #expect(throws: BuiltInAutomationFailure.emptyConditionGroup) {
            try await BuiltInAutomation.run(.text("unchanged input"), steps: workflow.steps)
        }
    }

    @Test func legacyConditionAndNewCompoundDefinitionsRoundTripWithoutChangingMatching() throws {
        let legacy = BuiltInAutomationStep(operation: .conditional, find: "TODO", condition: .containsText)
        let legacyBytes = try JSONEncoder().encode(legacy)
        let legacyObject = try #require(JSONSerialization.jsonObject(with: legacyBytes) as? [String: Any])
        #expect(legacyObject["predicate"] == nil)
        let restored = try JSONDecoder().decode(BuiltInAutomationStep.self, from: legacyBytes)
        #expect(restored.predicate == nil)
        #expect(restored.effectivePredicate == .match(.containsText, "TODO"))
        #expect(try restored.effectivePredicate.matches(.text("TODO: retained")))

        var compound = legacy
        compound.predicate = .all([legacy.effectivePredicate, .not(.match(.containsText, "done"))])
        let encoded = try JSONEncoder().encode(compound)
        let decoded = try JSONDecoder().decode(BuiltInAutomationStep.self, from: encoded)
        #expect(decoded == compound)
        #expect(try !decoded.effectivePredicate.matches(.text("TODO done")))
        #expect(try decoded.effectivePredicate.matches(.text("TODO new")))
    }

    @Test func unicodeSpellingChangesInvalidateThePredicateAndTheWholeStep() {
        let composed = BuiltInAutomationPredicate.not(.all([.match(.containsText, "é")]))
        let decomposed = BuiltInAutomationPredicate.not(.all([.match(.containsText, "e\u{301}")]))
        #expect(composed != decomposed)
        let first = BuiltInAutomationStep(operation: .conditional, predicate: composed)
        var second = first
        second.predicate = decomposed
        #expect(first != second)
    }

    @Test func deepConditionsUseTheirExplicitStacksWithoutAnArtificialStepLimit() throws {
        var predicate = BuiltInAutomationPredicate.match(.isText, "")
        for _ in 0..<1_024 { predicate = .not(predicate) }
        try predicate.validate()
        #expect(try predicate.matches(.text("input")))
        #expect(!predicate.containsImageTest)
        #expect(predicate == predicate)
        #expect(BuiltInAutomationPredicate.any([predicate, .match(.isImage, "")]).containsImageTest)
    }

    @Test func cancelledConditionEvaluationDoesNotContinueIntoMatching() async {
        let predicate = BuiltInAutomationPredicate.all([.match(.isText, ""), .match(.containsText, "input")])
        let task = Task { try predicate.matches(.text("input")) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
