import SwiftUI

/// A branch owns an ordered array. Dragging moves the entire step, including
/// its children, and cannot insert a condition into one of its own branches.
struct BuiltInAutomationStepsEditor: View {
    @Binding var steps: [BuiltInAutomationStep]
    let bundle: Bundle

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(BuiltInAutomationCopy.text("Steps run from top to bottom.", bundle: bundle))
                Spacer()
                Text(String(format: BuiltInAutomationCopy.text("Steps: %lld", bundle: bundle),
                            Int64(BuiltInAutomationStepEditing.count(steps))))
                    .monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
            BuiltInAutomationBranchEditor(root: $steps, parent: nil, otherwise: false,
                                          ancestorsEnabled: true, bundle: bundle)
        }
    }
}

private struct BuiltInAutomationBranchEditor: View {
    @Binding var root: [BuiltInAutomationStep]
    let parent: UUID?
    let otherwise: Bool
    let ancestorsEnabled: Bool
    let bundle: Bundle

    private var steps: [BuiltInAutomationStep] {
        BuiltInAutomationStepEditing.branch(in: root, parent: parent, otherwise: otherwise) ?? []
    }
    private func text(_ key: String) -> String { BuiltInAutomationCopy.text(key, bundle: bundle) }

    var body: some View {
        // The enclosing definition ScrollView requests cards as they approach
        // its viewport, including the children of an explicitly opened branch.
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                BuiltInAutomationStepCard(root: $root, snapshot: step, parent: parent,
                                          otherwise: otherwise, index: index, siblingCount: steps.count,
                                          ancestorsEnabled: ancestorsEnabled, bundle: bundle)
                    .dropDestination(for: String.self, isEnabled: ancestorsEnabled) { payloads, _ in _ = drop(payloads.first, before: step.id) }
            }
            if steps.isEmpty {
                Text(text(parent == nil ? "Add an action or condition to build this workflow." : "No actions. The current value passes to the following steps."))
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            Menu {
                Button { add(.conditional) } label: {
                    Label(text("Add condition"), systemImage: "arrow.triangle.branch")
                }
                Divider()
                ForEach(BuiltInAutomationActionCategory.allCases.filter {
                    $0 != .notifications || parent != nil
                }, id: \.self) { category in
                    Menu {
                        ForEach(category.operations, id: \.self) { operation in
                            Button(text(operation.title)) { add(operation) }
                        }
                    } label: {
                        Label(text(category.title), systemImage: category.symbol)
                    }
                }
            } label: {
                Label(text("Add step"), systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
            .menuStyle(.borderlessButton)
            .disabled(!ancestorsEnabled)
            .accessibilityIdentifier("clipy.workflow.add-step." + (parent?.uuidString ?? "root") + (otherwise ? ".otherwise" : ".then"))
            .dropDestination(for: String.self, isEnabled: ancestorsEnabled) { payloads, _ in _ = drop(payloads.first, before: nil) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func add(_ operation: BuiltInAutomationStep.Operation) {
        _ = BuiltInAutomationStepEditing.insert(.init(operation: operation, condition: .isText), into: &root,
                                                parent: parent, otherwise: otherwise, before: nil)
    }

    private func drop(_ payload: String?, before: UUID?) -> Bool {
        guard let payload, payload.hasPrefix("step:"),
              let id = UUID(uuidString: String(payload.dropFirst(5))) else { return false }
        return BuiltInAutomationStepEditing.move(id, in: &root, parent: parent, otherwise: otherwise, before: before)
    }
}

private struct BuiltInAutomationStepCard: View {
    @Binding var root: [BuiltInAutomationStep]
    let snapshot: BuiltInAutomationStep
    let parent: UUID?
    let otherwise: Bool
    let index: Int
    let siblingCount: Int
    let ancestorsEnabled: Bool
    let bundle: Bundle
    @State private var thenExpanded: Bool
    @State private var otherwiseExpanded = false

    init(root: Binding<[BuiltInAutomationStep]>, snapshot: BuiltInAutomationStep,
         parent: UUID?, otherwise: Bool, index: Int, siblingCount: Int,
         ancestorsEnabled: Bool, bundle: Bundle) {
        _root = root
        self.snapshot = snapshot
        self.parent = parent
        self.otherwise = otherwise
        self.index = index
        self.siblingCount = siblingCount
        self.ancestorsEnabled = ancestorsEnabled
        self.bundle = bundle
        _thenExpanded = State(initialValue: parent == nil)
    }

    private func text(_ key: String) -> String { BuiltInAutomationCopy.text(key, bundle: bundle) }
    private var step: BuiltInAutomationStep { BuiltInAutomationStepEditing.find(snapshot.id, in: root) ?? snapshot }
    private var binding: Binding<BuiltInAutomationStep> {
        Binding(get: { step }, set: { value in BuiltInAutomationStepEditing.update(value, in: &root) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                    .help(text("Drag to reorder"))
                    .draggable(ancestorsEnabled ? "step:" + step.id.uuidString : "")
                Text("\(index + 1)").monospacedDigit().font(.caption).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Toggle(text("Enable step"), isOn: binding.enabled).labelsHidden().toggleStyle(.checkbox)
                    .accessibilityLabel(text("Enable step") + ": " + text(step.operation.title))
                    .disabled(!ancestorsEnabled)
                if step.operation == .conditional {
                    Text(text("If")).fontWeight(.semibold)
                } else if step.operation.isCondition {
                    Text(text("If")).fontWeight(.semibold)
                    Text(text(legacyConditionTitle)).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Picker(text("Operation"), selection: binding.operation) {
                        ForEach(BuiltInAutomationActionCategory.allCases.filter {
                            $0 != .notifications || parent != nil || step.operation == .notify
                        }, id: \.self) { category in
                            Section(text(category.title)) {
                                ForEach(category.operations, id: \.self) { operation in
                                    Text(text(operation.title)).tag(operation)
                                }
                            }
                        }
                    }
                    .labelsHidden()
                    .disabled(!ancestorsEnabled)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("clipy.workflow.operation." + step.id.uuidString)
                }
                Spacer(minLength: 0)
                Menu {
                    Button(text("Duplicate step")) {
                        _ = BuiltInAutomationStepEditing.duplicate(step.id, in: &root)
                    }
                    .disabled(!BuiltInAutomationStepEditing.canDuplicate(step.id, in: root))
                    .help(text("Duplicates this step and all nested steps."))
                    Divider()
                    Button(text("Move step up")) { move(by: -1) }.disabled(index == 0)
                    Button(text("Move step down")) { move(by: 1) }.disabled(index == siblingCount - 1)
                    Divider()
                    Button(text("Remove step"), role: .destructive) {
                        _ = BuiltInAutomationStepEditing.remove(step.id, from: &root)
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuIndicator(.hidden)
                .disabled(!ancestorsEnabled)
                .accessibilityLabel(text("Step actions"))
                .accessibilityIdentifier("clipy.workflow.step-actions." + step.id.uuidString)
            }
            HStack(alignment: .top, spacing: 6) {
                if !step.enabled {
                    Text(text("Disabled")).fontWeight(.medium)
                }
                Text(text(step.operation.explanation))
            }
            .font(.caption).foregroundStyle(.secondary)
            if step.operation == .conditional {
                BuiltInAutomationConditionEditor(predicate: Binding(
                    get: { step.effectivePredicate },
                    set: { predicate in
                        var updated = step
                        updated.predicate = predicate
                        BuiltInAutomationStepEditing.update(updated, in: &root)
                    }
                ), bundle: bundle, identifier: step.id.uuidString,
                    isEnabled: ancestorsEnabled && step.enabled)
            } else if step.needsFind {
                parameterFields
            }
            if step.operation == .conditional {
                branchSection("Then", otherwise: false)
                branchSection("Otherwise", otherwise: true)
                Text(text("End If")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            } else if step.operation == .notify {
                Text(text("Clipboard content is never included in notifications."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipy.workflow.step." + step.id.uuidString)
    }

    private var parameterFields: some View {
        let issues = step.parameterIssues(ancestorsEnabled: ancestorsEnabled)
        return VStack(alignment: .leading, spacing: 6) {
            TextField(text(step.isLiteralFind ? "Find (literal text)" : "Regular expression"), text: binding.find, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...4)
                .disabled(!step.enabled || !ancestorsEnabled)
                .accessibilityIdentifier("clipy.workflow.find." + step.id.uuidString)
            parameterFeedback(for: .find, issues: issues)
            if step.needsReplacement {
                TextField(text("Replace with"), text: binding.replacement, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...4)
                    .disabled(!step.enabled || !ancestorsEnabled)
                    .accessibilityIdentifier("clipy.workflow.replacement." + step.id.uuidString)
                parameterFeedback(for: .replacement, issues: issues)
                Text(text(step.operation == .regexReplace
                          ? "Use $0 for the full match and $1, $2 for capture groups. Leave empty to remove matches."
                          : "Leave the replacement empty to remove matching text."))
                    .font(.caption).foregroundStyle(.secondary)
            } else if step.isLiteralFind {
                Text(text("Matches exact text, including letter case and spacing."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func parameterFeedback(for field: BuiltInAutomationParameterIssue.Field,
                                   issues: [BuiltInAutomationParameterIssue]) -> some View {
        ForEach(Array(issues.filter { $0.field == field }.enumerated()), id: \.offset) { _, issue in
            Label(text(issue.message), systemImage: issue.isError ? "exclamationmark.circle" : "info.circle")
                .font(.caption).foregroundStyle(issue.isError ? Color.orange : Color.secondary)
        }
    }

    private var legacyConditionTitle: String {
        switch step.operation {
        case .requireText: "Input is text"
        case .requireImage: "Input is an image"
        default: step.operation.title
        }
    }
    private func branchSection(_ title: String, otherwise: Bool) -> some View {
        let branch = otherwise ? step.otherwiseSteps : step.thenSteps
        return DisclosureGroup(isExpanded: otherwise ? $otherwiseExpanded : $thenExpanded) {
            if otherwise ? otherwiseExpanded : thenExpanded {
                // Build only expanded branches; type erasure stays local to
                // this recursive UI edge, not the persisted definition.
                AnyView(BuiltInAutomationBranchEditor(root: $root, parent: step.id, otherwise: otherwise,
                                                     ancestorsEnabled: ancestorsEnabled && step.enabled, bundle: bundle))
                    .padding(.top, 6)
            }
        } label: {
            HStack {
                Text(text(title)).fontWeight(.semibold)
                Spacer()
                Text(String(format: text("Steps: %lld"), Int64(BuiltInAutomationStepEditing.count(branch))))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor.opacity(0.35)).frame(width: 2) }
        .accessibilityIdentifier("clipy.workflow.branch." + step.id.uuidString + (otherwise ? ".otherwise" : ".then"))
    }

    private func move(by offset: Int) {
        guard let siblings = BuiltInAutomationStepEditing.branch(in: root, parent: parent, otherwise: otherwise),
              siblings.indices.contains(index + offset) else { return }
        let target = offset < 0 ? siblings[index - 1].id : (index + 2 < siblings.count ? siblings[index + 2].id : nil)
        _ = BuiltInAutomationStepEditing.move(step.id, in: &root, parent: parent, otherwise: otherwise, before: target)
    }
}

/// Editing the same tree that execution consumes avoids a second graph model.
/// A rejected drop leaves the entire definition, including its IDs, unchanged.
enum BuiltInAutomationStepEditing {
    static func count(_ steps: [BuiltInAutomationStep]) -> Int {
        var total = 0
        var pending = steps
        while let step = pending.popLast() {
            total += 1
            pending.append(contentsOf: step.thenSteps)
            pending.append(contentsOf: step.otherwiseSteps)
        }
        return total
    }

    static func find(_ id: UUID, in steps: [BuiltInAutomationStep]) -> BuiltInAutomationStep? {
        var pending = Array(steps.reversed())
        while let step = pending.popLast() {
            if step.id == id { return step }
            pending.append(contentsOf: step.otherwiseSteps.reversed())
            pending.append(contentsOf: step.thenSteps.reversed())
        }
        return nil
    }

    static func branch(in steps: [BuiltInAutomationStep], parent: UUID?, otherwise: Bool) -> [BuiltInAutomationStep]? {
        guard let parent else { return steps }
        guard let step = find(parent, in: steps), step.operation == .conditional else { return nil }
        return otherwise ? step.otherwiseSteps : step.thenSteps
    }

    static func update(_ value: BuiltInAutomationStep, in steps: inout [BuiltInAutomationStep]) {
        guard let location = location(of: value.id, in: steps) else { return }
        editBranch(location.path, in: &steps) { branch in
            branch[location.index] = value
        }
    }

    @discardableResult
    static func remove(_ id: UUID, from steps: inout [BuiltInAutomationStep]) -> BuiltInAutomationStep? {
        guard let location = location(of: id, in: steps) else { return nil }
        return editBranch(location.path, in: &steps) { branch in
            branch.remove(at: location.index)
        }
    }

    @discardableResult
    static func insert(_ step: BuiltInAutomationStep, into steps: inout [BuiltInAutomationStep],
                       parent: UUID?, otherwise: Bool, before: UUID?) -> Bool {
        guard let parent else {
            return insertSibling(step, into: &steps, before: before)
        }
        guard let location = location(of: parent, in: steps) else { return false }
        return editBranch(location.path, in: &steps) { branch in
            guard branch[location.index].operation == .conditional else { return false }
            if otherwise {
                return insertSibling(step, into: &branch[location.index].otherwiseSteps, before: before)
            }
            return insertSibling(step, into: &branch[location.index].thenSteps, before: before)
        }
    }

    static func canDuplicate(_ id: UUID, in steps: [BuiltInAutomationStep]) -> Bool {
        find(id, in: steps) != nil
    }

    /// V2-13 copies both branches, including disabled children. Parameters and
    /// predicate values stay exact; only copied step identities are replaced.
    @discardableResult
    static func duplicate(_ id: UUID, in steps: inout [BuiltInAutomationStep]) -> Bool {
        guard let location = location(of: id, in: steps) else { return false }
        editBranch(location.path, in: &steps) { branch in
            branch.insert(copyWithNewIDs(branch[location.index]), at: location.index + 1)
        }
        return true
    }

    @discardableResult
    static func move(_ id: UUID, in steps: inout [BuiltInAutomationStep],
                     parent: UUID?, otherwise: Bool, before: UUID?) -> Bool {
        guard id != before, let moving = find(id, in: steps),
              parent.map({ find($0, in: [moving]) == nil }) ?? true else { return false }
        var updated = steps
        guard remove(id, from: &updated) != nil,
              insert(moving, into: &updated, parent: parent, otherwise: otherwise, before: before) else { return false }
        steps = updated
        return true
    }

    /// A path records only ancestor branch choices. Iterative traversal and
    /// reconstruction keep deeply nested editing off the native call stack.
    private struct Descent {
        let index: Int
        let otherwise: Bool
    }

    private static func location(
        of id: UUID, in steps: [BuiltInAutomationStep]
    ) -> (path: [Descent], index: Int)? {
        var stack: [(steps: [BuiltInAutomationStep], index: Int, nextBranch: Int)] = [(steps, 0, 0)]
        var path: [Descent] = []
        while let frame = stack.last {
            guard frame.index < frame.steps.count else {
                stack.removeLast()
                if !stack.isEmpty { path.removeLast() }
                continue
            }
            let depth = stack.count - 1
            let step = frame.steps[frame.index]
            switch frame.nextBranch {
            case 0:
                if step.id == id { return (path, frame.index) }
                stack[depth].nextBranch = 1
                if !step.thenSteps.isEmpty {
                    path.append(Descent(index: frame.index, otherwise: false))
                    stack.append((step.thenSteps, 0, 0))
                }
            case 1:
                stack[depth].nextBranch = 2
                if !step.otherwiseSteps.isEmpty {
                    path.append(Descent(index: frame.index, otherwise: true))
                    stack.append((step.otherwiseSteps, 0, 0))
                }
            default:
                stack[depth].index += 1
                stack[depth].nextBranch = 0
            }
        }
        return nil
    }

    private static func editBranch<Result>(
        _ path: [Descent], in steps: inout [BuiltInAutomationStep],
        _ edit: (inout [BuiltInAutomationStep]) -> Result
    ) -> Result {
        var branch = steps
        var parents: [[BuiltInAutomationStep]] = []
        parents.reserveCapacity(path.count)
        for descent in path {
            parents.append(branch)
            branch = descent.otherwise ? branch[descent.index].otherwiseSteps : branch[descent.index].thenSteps
        }
        let result = edit(&branch)
        for descent in path.reversed() {
            var parent = parents.removeLast()
            if descent.otherwise { parent[descent.index].otherwiseSteps = branch }
            else { parent[descent.index].thenSteps = branch }
            branch = parent
        }
        steps = branch
        return result
    }

    private static func insertSibling(
        _ step: BuiltInAutomationStep, into siblings: inout [BuiltInAutomationStep], before: UUID?
    ) -> Bool {
        if let before {
            guard let index = siblings.firstIndex(where: { $0.id == before }) else { return false }
            siblings.insert(step, at: index)
        } else { siblings.append(step) }
        return true
    }

    private enum CopyWork {
        case visit(BuiltInAutomationStep)
        case assemble(BuiltInAutomationStep)
    }

    static func copyWithNewIDs(_ original: BuiltInAutomationStep) -> BuiltInAutomationStep {
        var pending: [CopyWork] = [.visit(original)]
        var completed: [BuiltInAutomationStep] = []
        while let work = pending.popLast() {
            switch work {
            case .visit(let step):
                pending.append(.assemble(step))
                for child in step.otherwiseSteps.reversed() { pending.append(.visit(child)) }
                for child in step.thenSteps.reversed() { pending.append(.visit(child)) }
            case .assemble(var step):
                let thenCount = step.thenSteps.count
                let childCount = thenCount + step.otherwiseSteps.count
                let firstChild = completed.count - childCount
                step.id = UUID()
                step.thenSteps = Array(completed[firstChild..<(firstChild + thenCount)])
                step.otherwiseSteps = Array(completed[(firstChild + thenCount)..<completed.count])
                completed.removeLast(childCount)
                completed.append(step)
            }
        }
        return completed[0]
    }
}
