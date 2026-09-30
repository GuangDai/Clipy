import Foundation
import Testing
@testable import ClipyApp

struct BuiltInAutomationSyntaxArgumentTests {
    @Test(arguments: [BuiltInAutomationStep.Condition.isText, .isImage])
    func unusedKindTestArgumentsDoNotPreventConvertingVisualStepsToRules(
        condition: BuiltInAutomationStep.Condition
    ) throws {
        // V2-13 omits unused legacy fields. A user can change a condition's
        // kind while its previous find text is still in the visual draft.
        let unused = String(repeating: "é", count: 8_193)
        let steps: [BuiltInAutomationStep] = [
            .init(operation: .conditional, find: unused, condition: condition,
                  thenSteps: [.init(operation: .trim)]),
            .init(operation: .conditional, predicate: .not(.match(condition, unused)),
                  thenSteps: [.init(operation: .uppercase)]),
        ]

        let source = try BuiltInAutomationSyntax.render(steps)
        let name = condition == .isText ? "is_text" : "is_image"
        #expect(source == "if \(name)():\n    trim()\nif not (\(name)()):\n    uppercase()\n")
        let restored = try BuiltInAutomationSyntax.parse(source)
        try #require(restored.count == 2)
        #expect(restored[0].effectivePredicate == .match(condition, ""))
        #expect(restored[1].effectivePredicate == .not(.match(condition, "")))
        for input in [BuiltInAutomationInput.text(" text "), .image(Data())] {
            for index in steps.indices {
                #expect(try restored[index].effectivePredicate.matches(input)
                        == steps[index].effectivePredicate.matches(input))
            }
        }
    }

    @Test(arguments: [BuiltInAutomationStep.Condition.containsText, .matchesRegex])
    func executablePredicateArgumentsStillHaveTheUTF8ByteLimit(
        condition: BuiltInAutomationStep.Condition
    ) {
        let steps = [BuiltInAutomationStep(
            operation: .conditional,
            predicate: .match(condition, String(repeating: "é", count: 8_193))
        )]

        #expect(throws: BuiltInAutomationSyntaxError(reason: .parameterTooLarge, line: 1, column: 1)) {
            try BuiltInAutomationSyntax.render(steps)
        }
    }
}
