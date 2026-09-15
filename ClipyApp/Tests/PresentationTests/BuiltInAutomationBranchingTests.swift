import Foundation
@testable import ClipyApp
import Testing

struct BuiltInAutomationBranchingTests {
    @Test func nestedConditionsExecuteOnlyTheirSelectedBranch() async throws {
        let steps: [BuiltInAutomationStep] = [
            .init(operation: .conditional, condition: .isText, thenSteps: [
                .init(operation: .conditional, find: "TODO", thenSteps: [
                    .init(operation: .uppercase), .init(operation: .notify)
                ], otherwiseSteps: [.init(operation: .lowercase)])
            ], otherwiseSteps: [.init(operation: .recognizeText)])
        ]
        let matched = try await BuiltInAutomation.run(.text("TODO: Mixed"), steps: steps)
        #expect(matched.value.text == "TODO: MIXED")
        #expect(matched.originalInput == .text("TODO: Mixed"))
        #expect(matched.requestsNotification)
        let otherwise = try await BuiltInAutomation.run(.text("OTHER"), steps: steps)
        #expect(otherwise.value.text == "other")
        #expect(otherwise.matchedConditions)
        #expect(!otherwise.requestsNotification)
    }

    @Test func unmatchedIfDoesNotPreventFollowingActions() async throws {
        let conditional = BuiltInAutomationStep(operation: .conditional, find: "TODO",
                                                thenSteps: [.init(operation: .uppercase)])
        let onlyCondition = try await BuiltInAutomation.run(.text(" ordinary "), steps: [conditional])
        #expect(!onlyCondition.matchedConditions)
        let followingAction = try await BuiltInAutomation.run(.text(" ordinary "), steps: [conditional, .init(operation: .trim)])
        #expect(followingAction.matchedConditions)
        #expect(followingAction.value.text == "ordinary")
        #expect(!followingAction.requestsNotification)
    }

    @Test func rootNotificationCannotBorrowConditionFromAnotherBranch() async {
        await #expect(throws: BuiltInAutomationFailure.notificationNeedsCondition) {
            try await BuiltInAutomation.run(.text("TODO"), steps: [
                .init(operation: .conditional, find: "TODO", thenSteps: [.init(operation: .trim)]),
                .init(operation: .notify)
            ])
        }
    }

    @Test func branchFailureDiscardsDeferredNotification() async {
        await #expect(throws: BuiltInAutomationFailure.invalidJSON) {
            try await BuiltInAutomation.run(.text("TODO"), steps: [
                .init(operation: .conditional, find: "TODO", thenSteps: [
                    .init(operation: .notify), .init(operation: .prettyJSON)
                ])
            ])
        }
    }

    @Test func batchRetainsFirstResultAndNotificationsFromLaterMatchingBranches() async throws {
        let workflow = BuiltInAutomationWorkflow(name: "Batch", steps: [
            .init(operation: .conditional, find: "TODO", thenSteps: [.init(operation: .notify)],
                  otherwiseSteps: [.init(operation: .lowercase)])
        ])
        let output = try await BuiltInAutomation.evaluate([.text("FIRST"), .text("TODO")], workflow: workflow)
        #expect(output.value.text == "first")
        #expect(output.originalInput == .text("FIRST"))
        #expect(output.matchedItemCount == 2)
        #expect(output.requestsNotification)
    }

    @Test func oldFlatDefinitionsDecodeAndNestedStepsShareTheLimit() async throws {
        let id = UUID()
        let data = Data("""
        {"id":"\(id.uuidString)","operation":"trim","enabled":true,"find":"","replacement":""}
        """.utf8)
        let old = try JSONDecoder().decode(BuiltInAutomationStep.self, from: data)
        #expect(old.id == id)
        #expect(old.thenSteps.isEmpty && old.otherwiseSteps.isEmpty)
        let tree = BuiltInAutomationStep(operation: .conditional, condition: .isText,
                                        thenSteps: (0..<32).map { _ in .init(operation: .trim) })
        await #expect(throws: BuiltInAutomationFailure.tooManySteps) {
            try await BuiltInAutomation.run(.text("text"), steps: [tree])
        }
    }
}
