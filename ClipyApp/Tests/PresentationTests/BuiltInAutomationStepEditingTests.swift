import Foundation
import Testing
@testable import ClipyApp

@Suite("Workflow branch editing")
struct BuiltInAutomationStepEditingTests {
    @Test func movingActionBetweenBranchesPreservesExactDefinitionAndExecutionOrder() {
        let trim = BuiltInAutomationStep(operation: .trim)
        let replace = BuiltInAutomationStep(operation: .replace, find: "e\u{301}", replacement: "é")
        let condition = BuiltInAutomationStep(operation: .conditional, condition: .isText,
                                              thenSteps: [trim], otherwiseSteps: [replace])
        var steps = [condition]
        #expect(BuiltInAutomationStepEditing.move(replace.id, in: &steps, parent: condition.id,
                                                 otherwise: false, before: trim.id))
        #expect(steps[0].thenSteps == [replace, trim])
        #expect(steps[0].otherwiseSteps.isEmpty)
        #expect(BuiltInAutomationStepEditing.count(steps) == 3)
        #expect(BuiltInAutomationStepEditing.move(trim.id, in: &steps, parent: nil, otherwise: false, before: nil))
        #expect(steps.map(\.id) == [condition.id, trim.id])
        #expect(steps[0].thenSteps == [replace])
    }

    @Test func movingConditionIntoItselfOrDescendantLeavesDefinitionUnchanged() {
        let nested = BuiltInAutomationStep(operation: .conditional, condition: .isText,
                                           thenSteps: [.init(operation: .trim)])
        let outer = BuiltInAutomationStep(operation: .conditional, condition: .isImage,
                                          thenSteps: [nested])
        var steps = [outer]
        #expect(!BuiltInAutomationStepEditing.move(outer.id, in: &steps, parent: nested.id,
                                                  otherwise: true, before: nil))
        #expect(steps == [outer])
        #expect(!BuiltInAutomationStepEditing.move(outer.id, in: &steps, parent: outer.id,
                                                  otherwise: false, before: nil))
        #expect(steps == [outer])
        #expect(!BuiltInAutomationStepEditing.move(nested.id, in: &steps, parent: UUID(),
                                                  otherwise: false, before: nil))
        #expect(steps == [outer])
    }

    @Test func duplicatingConditionCopiesEveryBranchWithFreshIDsAndExactParameterBytes() throws {
        let nested = BuiltInAutomationStep(operation: .conditional, enabled: false,
                                           find: "e\u{301}", condition: .containsText,
                                           thenSteps: [.init(operation: .replace, find: "é", replacement: "e\u{301}")],
                                           otherwiseSteps: [.init(operation: .trim)])
        let original = BuiltInAutomationStep(operation: .conditional, find: #"(TODO)"#, condition: .matchesRegex,
                                             thenSteps: [nested], otherwiseSteps: [.init(operation: .notify)])
        let following = BuiltInAutomationStep(operation: .uppercase)
        var steps = [original, following]
        #expect(BuiltInAutomationStepEditing.duplicate(original.id, in: &steps))
        #expect(steps.count == 3)
        #expect(steps[0] == original)
        #expect(steps[2] == following)
        expectCopy(steps[1], preserves: original)
        try BuiltInAutomation.validateStepTree(steps)
    }

    @Test func duplicatingNestedStepStaysInItsBranchImmediatelyAfterTheOriginal() {
        let guardStep = BuiltInAutomationStep(operation: .containsText, find: "TODO")
        let following = BuiltInAutomationStep(operation: .notify)
        let condition = BuiltInAutomationStep(operation: .conditional, condition: .isText,
                                              thenSteps: [.init(operation: .trim)],
                                              otherwiseSteps: [guardStep, following])
        var steps = [condition]
        #expect(BuiltInAutomationStepEditing.duplicate(guardStep.id, in: &steps))
        #expect(steps[0].thenSteps == condition.thenSteps)
        #expect(steps[0].otherwiseSteps.count == 3)
        #expect(steps[0].otherwiseSteps[0] == guardStep)
        #expect(steps[0].otherwiseSteps[2] == following)
        expectCopy(steps[0].otherwiseSteps[1], preserves: guardStep)
    }

    @Test func duplicateAdmitsExactly32StepsIncludingDisabledBranchesAndRejectsOverflow() throws {
        let condition = BuiltInAutomationStep(operation: .conditional, enabled: false, condition: .isText,
                                              otherwiseSteps: [.init(operation: .trim, enabled: false)])
        var steps = [condition] + (0..<28).map { _ in BuiltInAutomationStep(operation: .trim) }
        #expect(BuiltInAutomationStepEditing.canDuplicate(condition.id, in: steps))
        #expect(BuiltInAutomationStepEditing.duplicate(condition.id, in: &steps))
        #expect(BuiltInAutomationStepEditing.count(steps) == 32)
        try BuiltInAutomation.validateStepTree(steps)
        let full = steps
        #expect(!BuiltInAutomationStepEditing.canDuplicate(condition.id, in: steps))
        #expect(!BuiltInAutomationStepEditing.duplicate(condition.id, in: &steps))
        #expect(steps == full)

        var belowLimit = [condition] + (0..<29).map { _ in BuiltInAutomationStep(operation: .trim) }
        let unchanged = belowLimit
        #expect(!BuiltInAutomationStepEditing.duplicate(condition.id, in: &belowLimit))
        #expect(belowLimit == unchanged)
    }

    @Test func duplicatingUnknownIDDoesNotChangeTheDefinition() {
        let original = [BuiltInAutomationStep(operation: .trim)]
        var steps = original
        #expect(!BuiltInAutomationStepEditing.canDuplicate(UUID(), in: steps))
        #expect(!BuiltInAutomationStepEditing.duplicate(UUID(), in: &steps))
        #expect(steps == original)
    }

    @Test func addingNestedStepsUsesWholeWorkflowLimitWhileReorderingAtTheLimitStillWorks() {
        let condition = BuiltInAutomationStep(operation: .conditional, condition: .isText)
        var steps = [condition] + (0..<30).map { _ in BuiltInAutomationStep(operation: .trim) }
        let original = steps
        let subtree = BuiltInAutomationStep(operation: .conditional, condition: .isText,
                                           thenSteps: [.init(operation: .trim)])
        #expect(!BuiltInAutomationStepEditing.insert(subtree, into: &steps, parent: condition.id,
                                                    otherwise: true, before: nil))
        #expect(steps == original)
        let last = BuiltInAutomationStep(operation: .uppercase)
        #expect(BuiltInAutomationStepEditing.insert(last, into: &steps, parent: condition.id,
                                                   otherwise: true, before: nil))
        #expect(BuiltInAutomationStepEditing.count(steps) == 32)
        #expect(BuiltInAutomationStepEditing.move(last.id, in: &steps, parent: nil,
                                                 otherwise: false, before: condition.id))
        #expect(steps.first == last)
        #expect(steps[1].otherwiseSteps.isEmpty)
    }

    private func expectCopy(_ copied: BuiltInAutomationStep, preserves original: BuiltInAutomationStep) {
        #expect(copied.id != original.id)
        #expect(copied.operation == original.operation)
        #expect(copied.enabled == original.enabled)
        #expect(copied.condition == original.condition)
        #expect(copied.find.utf8.elementsEqual(original.find.utf8))
        #expect(copied.replacement.utf8.elementsEqual(original.replacement.utf8))
        #expect(copied.thenSteps.count == original.thenSteps.count)
        #expect(copied.otherwiseSteps.count == original.otherwiseSteps.count)
        for (child, originalChild) in zip(copied.thenSteps, original.thenSteps) {
            expectCopy(child, preserves: originalChild)
        }
        for (child, originalChild) in zip(copied.otherwiseSteps, original.otherwiseSteps) {
            expectCopy(child, preserves: originalChild)
        }
    }
}
