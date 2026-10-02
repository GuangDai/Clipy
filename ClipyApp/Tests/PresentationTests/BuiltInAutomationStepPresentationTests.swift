import Foundation
import Testing
@testable import ClipyApp

@Suite("Workflow step configuration feedback")
struct BuiltInAutomationStepPresentationTests {
    @Test func emptyLiteralReplacementIsValidAndAnEmptyFindNeedsCorrection() {
        let removal = BuiltInAutomationStep(operation: .replace, find: "remove", replacement: "")
        #expect(removal.parameterIssues().isEmpty)
        let missingFind = BuiltInAutomationStep(operation: .replace)
        #expect(missingFind.parameterIssues().contains { $0.field == .find && $0.isError })
    }

    @Test func emptyContainsConditionRemainsNonmatchingInsteadOfBecomingAValidationError() throws {
        let condition = BuiltInAutomationStep(operation: .conditional, condition: .containsText,
                                              thenSteps: [.init(operation: .uppercase)],
                                              otherwiseSteps: [.init(operation: .lowercase)])
        #expect(condition.parameterIssues().count == 1)
        #expect(condition.parameterIssues().allSatisfy { !$0.isError })
        #expect(try BuiltInAutomation.run("MiXeD", steps: [condition]) == "mixed")
        let oldGuard = BuiltInAutomationStep(operation: .containsText)
        #expect(oldGuard.parameterIssues().allSatisfy { !$0.isError })
        #expect(throws: BuiltInAutomationFailure.conditionNotMet) {
            try BuiltInAutomation.run("MiXeD", steps: [oldGuard, .init(operation: .uppercase)])
        }
    }

    @Test func invalidRegexIsReportedOnlyWhenTheStepCanParticipate() {
        let step = BuiltInAutomationStep(operation: .regexReplace, find: "(", replacement: "$1")
        #expect(step.parameterIssues().contains { $0.field == .find && $0.isError })
        var disabled = step
        disabled.enabled = false
        #expect(disabled.parameterIssues().isEmpty)
        #expect(step.parameterIssues(ancestorsEnabled: false).isEmpty)
        let valid = BuiltInAutomationStep(operation: .conditional, find: #"^TODO\b"#, condition: .matchesRegex)
        #expect(valid.parameterIssues().isEmpty)
    }

    @Test func fieldLimitsUseUTF8BytesAndPreserveDisabledStepSaveRequirements() {
        var step = BuiltInAutomationStep(operation: .replace, enabled: false,
                                         find: String(repeating: "é", count: 8192),
                                         replacement: String(repeating: "a", count: 16_384))
        #expect(step.parameterIssues().isEmpty)
        step.find += "a"
        step.replacement += "a"
        #expect(step.parameterIssues().filter(\.isError).count == 2)
        #expect(step.parameterIssues(ancestorsEnabled: false).isEmpty)
    }

    @Test func captureTemplateFeedbackUsesTheSameParsingRulesAsExecution() throws {
        for template in ["$0", "$1", "$12", #"\$1"#, "$", #"tail\"#] {
            let step = BuiltInAutomationStep(operation: .regexReplace, find: "(a)", replacement: template)
            #expect(step.parameterIssues().isEmpty)
            _ = try BuiltInAutomation.run("a", steps: [step])
        }
        let missingGroup = BuiltInAutomationStep(operation: .regexReplace, find: "(a)", replacement: "$2")
        #expect(missingGroup.parameterIssues().contains { $0.field == .replacement && $0.isError })
        #expect(throws: BuiltInAutomationFailure.invalidRegex) {
            try BuiltInAutomation.run("a", steps: [missingGroup])
        }
    }
}
