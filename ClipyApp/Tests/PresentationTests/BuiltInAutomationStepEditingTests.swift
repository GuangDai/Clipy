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
}
