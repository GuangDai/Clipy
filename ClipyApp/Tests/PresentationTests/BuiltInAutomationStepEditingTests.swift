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
                                           predicate: .all([.match(.isText, ""), .not(.match(.containsText, "e\u{301}"))]),
                                           thenSteps: [.init(operation: .replace, find: "é", replacement: "e\u{301}")],
                                           otherwiseSteps: [.init(operation: .trim)])
        let original = BuiltInAutomationStep(operation: .conditional, find: #"(TODO)"#, condition: .matchesRegex,
                                             thenSteps: [nested, .init(operation: .trimLines)],
                                             otherwiseSteps: [.init(operation: .notify), .init(operation: .lowercase)])
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

    @Test func duplicatingDisabledBranchesWorksBeyond32Steps() throws {
        let condition = BuiltInAutomationStep(operation: .conditional, enabled: false, condition: .isText,
                                              otherwiseSteps: [.init(operation: .trim, enabled: false)])
        let following = (0..<40).map { _ in BuiltInAutomationStep(operation: .trim) }
        var steps = [condition] + following
        #expect(BuiltInAutomationStepEditing.canDuplicate(condition.id, in: steps))
        #expect(BuiltInAutomationStepEditing.duplicate(condition.id, in: &steps))
        #expect(BuiltInAutomationStepEditing.count(steps) == 44)
        expectCopy(steps[1], preserves: condition)
        #expect(BuiltInAutomationStepEditing.canDuplicate(condition.id, in: steps))
        #expect(BuiltInAutomationStepEditing.duplicate(condition.id, in: &steps))
        #expect(BuiltInAutomationStepEditing.count(steps) == 46)
        #expect(steps[0] == condition)
        expectCopy(steps[1], preserves: condition)
        #expect(Array(steps.dropFirst(3)) == following)
        try BuiltInAutomation.validateStepTree(steps)
    }

    @Test func duplicatingUnknownIDDoesNotChangeTheDefinition() {
        let original = [BuiltInAutomationStep(operation: .trim)]
        var steps = original
        #expect(!BuiltInAutomationStepEditing.canDuplicate(UUID(), in: steps))
        #expect(!BuiltInAutomationStepEditing.duplicate(UUID(), in: &steps))
        #expect(steps == original)
    }

    @Test func insertingAndMovingSubtreesWorksBeyond32Steps() throws {
        let condition = BuiltInAutomationStep(operation: .conditional, condition: .isText)
        let following = (0..<40).map { _ in BuiltInAutomationStep(operation: .trim) }
        var steps = [condition] + following
        let subtree = BuiltInAutomationStep(operation: .conditional, condition: .isText,
                                           thenSteps: [.init(operation: .trim)])
        #expect(BuiltInAutomationStepEditing.insert(subtree, into: &steps, parent: condition.id,
                                                   otherwise: true, before: nil))
        let last = BuiltInAutomationStep(operation: .uppercase)
        #expect(BuiltInAutomationStepEditing.insert(last, into: &steps, parent: condition.id,
                                                   otherwise: true, before: nil))
        #expect(BuiltInAutomationStepEditing.count(steps) == 44)
        #expect(steps[0].otherwiseSteps == [subtree, last])
        #expect(BuiltInAutomationStepEditing.move(subtree.id, in: &steps, parent: nil,
                                                 otherwise: false, before: condition.id))
        #expect(steps.first == subtree)
        #expect(steps[1].otherwiseSteps == [last])
        #expect(Array(steps.dropFirst(2)) == following)
        #expect(BuiltInAutomationStepEditing.count(steps) == 44)
        try BuiltInAutomation.validateStepTree(steps)
    }

    @Test func editingDeepAlternatingBranchesPreservesOtherStepsAndCanRestoreRemovedValues() throws {
        let tree = makeDeepTree()
        let following = BuiltInAutomationStep(operation: .uppercase)
        var steps = [tree.root, following]
        let original = definitionSnapshot(steps)
        #expect(BuiltInAutomationStepEditing.count(steps) == 514)
        let found = try #require(BuiltInAutomationStepEditing.find(tree.leaf.id, in: steps))
        #expect(found == tree.leaf)
        let leafBranch = try #require(BuiltInAutomationStepEditing.branch(
            in: steps, parent: tree.parent, otherwise: tree.otherwise))
        let oppositeBranch = try #require(BuiltInAutomationStepEditing.branch(
            in: steps, parent: tree.parent, otherwise: !tree.otherwise))
        #expect(leafBranch == [tree.leaf])
        #expect(oppositeBranch.count == 1)

        var edited = found
        edited.enabled = true
        edited.find = "é"
        edited.replacement = "e\u{301}\nchanged"
        BuiltInAutomationStepEditing.update(edited, in: &steps)
        var expected = original
        let leafIndex = try #require(expected.firstIndex { $0.step.id == tree.leaf.id })
        expected[leafIndex] = .init(step: edited, thenIDs: [], otherwiseIDs: [])
        #expect(definitionSnapshot(steps) == expected)

        let inserted = BuiltInAutomationStep(operation: .trim)
        #expect(BuiltInAutomationStepEditing.insert(inserted, into: &steps, parent: tree.parent,
                                                   otherwise: tree.otherwise, before: edited.id))
        #expect(BuiltInAutomationStepEditing.branch(in: steps, parent: tree.parent,
                                                   otherwise: tree.otherwise) == [inserted, edited])
        #expect(BuiltInAutomationStepEditing.remove(edited.id, from: &steps) == edited)
        #expect(BuiltInAutomationStepEditing.find(edited.id, in: steps) == nil)
        #expect(BuiltInAutomationStepEditing.branch(in: steps, parent: tree.parent,
                                                   otherwise: tree.otherwise) == [inserted])
        #expect(BuiltInAutomationStepEditing.insert(tree.leaf, into: &steps, parent: tree.parent,
                                                   otherwise: tree.otherwise, before: nil))
        #expect(BuiltInAutomationStepEditing.remove(inserted.id, from: &steps) == inserted)
        #expect(definitionSnapshot(steps) == original)
    }

    @Test func duplicatingDeepTreePreservesBothBranchesAndRefreshesEveryStepID() throws {
        let tree = makeDeepTree()
        let following = BuiltInAutomationStep(operation: .uppercase)
        var steps = [tree.root, following]
        let original = definitionSnapshot(steps)
        #expect(BuiltInAutomationStepEditing.canDuplicate(tree.root.id, in: steps))
        #expect(BuiltInAutomationStepEditing.duplicate(tree.root.id, in: &steps))
        try #require(steps.count == 3)
        #expect(BuiltInAutomationStepEditing.count(steps) == 1_027)
        #expect(definitionSnapshot([steps[0], steps[2]]) == original)
        expectCopy(steps[1], preserves: tree.root)
        try BuiltInAutomation.validateStepTree(steps)

        #expect(BuiltInAutomationStepEditing.duplicate(tree.leaf.id, in: &steps))
        let leafBranch = try #require(BuiltInAutomationStepEditing.branch(
            in: steps, parent: tree.parent, otherwise: tree.otherwise))
        try #require(leafBranch.count == 2)
        #expect(leafBranch[0] == tree.leaf)
        expectCopy(leafBranch[1], preserves: tree.leaf)
    }

    @Test func duplicatingAWorkflowWith512NestedConditionsKeepsItsDefinitionAndBecomesManual() throws {
        let tree = makeDeepTree(depth: 512)
        var root = tree.root
        root.predicate = .all([
            .match(.containsText, "e\u{301}"),
            .not(.match(.containsText, "é"))
        ])
        let following = BuiltInAutomationStep(operation: .uppercase)
        let original = BuiltInAutomationWorkflow(
            name: "Deep automatic workflow", steps: [root, following], trigger: .newCopies,
            scope: .init(source: .clipboard, applications: "com.example.editor")
        )
        let before = definitionSnapshot(original.steps)

        let copied = original.duplicated(named: "Deep manual copy")

        #expect(copied.id != original.id)
        #expect(copied.name == "Deep manual copy")
        #expect(copied.trigger == .manual)
        #expect(copied.scope == original.scope)
        try #require(copied.steps.count == 2)
        #expect(BuiltInAutomationStepEditing.count(copied.steps) == 1_026)
        expectCopy(copied.steps[0], preserves: root)
        expectCopy(copied.steps[1], preserves: following)
        let copiedIDs = Set(definitionSnapshot(copied.steps).map { $0.step.id })
        #expect(copiedIDs.count == 1_026)
        #expect(copiedIDs.isDisjoint(with: Set(before.map { $0.step.id })))
        // Both canonically equivalent spellings remain distinct in the copied
        // predicate; duplicating the workflow must not normalize either one.
        let predicate = try #require(copied.steps[0].predicate)
        if case .all(let children) = predicate {
            try #require(children.count == 2)
            if case .match(.containsText, let decomposed) = children[0],
               case .not(.match(.containsText, let composed)) = children[1] {
                #expect(decomposed.utf8.elementsEqual("e\u{301}".utf8))
                #expect(composed.utf8.elementsEqual("é".utf8))
            } else { Issue.record("The copied predicate changed its conditions") }
        } else { Issue.record("The copied predicate changed its group") }
        #expect(original.trigger == .newCopies)
        #expect(definitionSnapshot(original.steps) == before)
        try BuiltInAutomation.validateStepTree(copied.steps)
    }

    @Test func deepMovesRejectCyclesAndInvalidDestinationsWithoutChangingTheTree() throws {
        let tree = makeDeepTree()
        let following = BuiltInAutomationStep(operation: .uppercase)
        var steps = [tree.root, following]
        let original = definitionSnapshot(steps)
        for parent in [tree.root.id, tree.parent, tree.leaf.id, UUID()] {
            #expect(!BuiltInAutomationStepEditing.move(tree.root.id, in: &steps, parent: parent,
                                                      otherwise: true, before: nil))
            #expect(definitionSnapshot(steps) == original)
        }
        #expect(!BuiltInAutomationStepEditing.move(following.id, in: &steps, parent: tree.leaf.id,
                                                  otherwise: false, before: nil))
        #expect(definitionSnapshot(steps) == original)
        #expect(!BuiltInAutomationStepEditing.move(following.id, in: &steps, parent: tree.parent,
                                                  otherwise: !tree.otherwise, before: tree.leaf.id))
        #expect(definitionSnapshot(steps) == original)
        #expect(BuiltInAutomationStepEditing.move(following.id, in: &steps, parent: tree.parent,
                                                 otherwise: tree.otherwise, before: tree.leaf.id))
        let leafBranch = try #require(BuiltInAutomationStepEditing.branch(
            in: steps, parent: tree.parent, otherwise: tree.otherwise))
        #expect(leafBranch == [following, tree.leaf])
        #expect(steps.count == 1)
        #expect(BuiltInAutomationStepEditing.count(steps) == 514)
        #expect(BuiltInAutomationStepEditing.move(following.id, in: &steps, parent: nil,
                                                 otherwise: false, before: nil))
        #expect(definitionSnapshot(steps) == original)
    }

    private func expectCopy(_ copied: BuiltInAutomationStep, preserves original: BuiltInAutomationStep) {
        var pending = [(copied, original)]
        var copiedIDs = Set<UUID>()
        var originalIDs = Set<UUID>()
        while let (copy, source) = pending.popLast() {
            let insertion = copiedIDs.insert(copy.id)
            #expect(insertion.inserted)
            originalIDs.insert(source.id)
            #expect(copy.operation == source.operation)
            #expect(copy.enabled == source.enabled)
            #expect(copy.condition == source.condition)
            #expect(copy.predicate == source.predicate)
            #expect(copy.find.utf8.elementsEqual(source.find.utf8))
            #expect(copy.replacement.utf8.elementsEqual(source.replacement.utf8))
            #expect(copy.thenSteps.count == source.thenSteps.count)
            #expect(copy.otherwiseSteps.count == source.otherwiseSteps.count)
            pending.append(contentsOf: zip(copy.thenSteps, source.thenSteps))
            pending.append(contentsOf: zip(copy.otherwiseSteps, source.otherwiseSteps))
        }
        #expect(copiedIDs.isDisjoint(with: originalIDs))
    }

    private func makeDeepTree(depth: Int = 256) -> (root: BuiltInAutomationStep, leaf: BuiltInAutomationStep,
                                                   parent: UUID, otherwise: Bool) {
        let leaf = BuiltInAutomationStep(operation: .replace, enabled: false,
                                         find: "e\u{301}", replacement: "é\n")
        var root = leaf
        var leafParent = UUID()
        let leafOtherwise = !(depth - 1).isMultiple(of: 2)
        for level in (0..<depth).reversed() {
            let sibling = BuiltInAutomationStep(operation: .notify, find: "sibling \(level)")
            let useOtherwise = !level.isMultiple(of: 2)
            root = BuiltInAutomationStep(
                operation: .conditional, enabled: !level.isMultiple(of: 5),
                find: "condition \(level)", condition: .isText,
                predicate: .not(.match(.containsText, "skip \(level)")),
                thenSteps: useOtherwise ? [sibling] : [root],
                otherwiseSteps: useOtherwise ? [root] : [sibling])
            if level == depth - 1 { leafParent = root.id }
        }
        return (root, leaf, leafParent, leafOtherwise)
    }

    private struct StepSnapshot: Equatable {
        var step: BuiltInAutomationStep
        let thenIDs: [UUID]
        let otherwiseIDs: [UUID]
    }

    /// Each comparison contains a shallow step and its explicit branch order,
    /// so the test never recursively compares or prints a deeply nested tree.
    private func definitionSnapshot(_ steps: [BuiltInAutomationStep]) -> [StepSnapshot] {
        var pending = Array(steps.reversed())
        var result: [StepSnapshot] = []
        while var step = pending.popLast() {
            let thenIDs = step.thenSteps.map(\.id)
            let otherwiseIDs = step.otherwiseSteps.map(\.id)
            pending.append(contentsOf: step.otherwiseSteps.reversed())
            pending.append(contentsOf: step.thenSteps.reversed())
            step.thenSteps = []
            step.otherwiseSteps = []
            result.append(.init(step: step, thenIDs: thenIDs, otherwiseIDs: otherwiseIDs))
        }
        return result
    }
}
