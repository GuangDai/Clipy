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
                Text(String(format: BuiltInAutomationCopy.text("%lld of %lld steps", bundle: bundle),
                            Int64(BuiltInAutomationStepEditing.count(steps)), Int64(BuiltInAutomation.maximumSteps)))
                    .monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
            BuiltInAutomationBranchEditor(root: $steps, parent: nil, otherwise: false,
                                          ancestorsEnabled: true, bundle: bundle)
            if BuiltInAutomationStepEditing.count(steps) >= BuiltInAutomation.maximumSteps {
                Label(BuiltInAutomationCopy.text("The 32-step limit includes both branches and disabled steps.", bundle: bundle),
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
        VStack(alignment: .leading, spacing: 8) {
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
            .disabled(!ancestorsEnabled || BuiltInAutomationStepEditing.count(root) >= BuiltInAutomation.maximumSteps)
            .accessibilityIdentifier("clipy.workflow.add-step." + (parent?.uuidString ?? "root") + (otherwise ? ".otherwise" : ".then"))
            .dropDestination(for: String.self, isEnabled: ancestorsEnabled) { payloads, _ in _ = drop(payloads.first, before: nil) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func add(_ operation: BuiltInAutomationStep.Operation) {
        guard BuiltInAutomationStepEditing.count(root) < BuiltInAutomation.maximumSteps else { return }
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
    @State private var thenExpanded = true
    @State private var otherwiseExpanded = false

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
                    Picker(text("Condition"), selection: binding.condition) {
                        ForEach(BuiltInAutomationStep.Condition.allCases, id: \.self) { condition in
                            Text(text(condition.title)).tag(condition)
                        }
                    }
                    .labelsHidden()
                    .disabled(!ancestorsEnabled)
                    .accessibilityIdentifier("clipy.workflow.condition." + step.id.uuidString)
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
                    .help(text("Duplicates this step and all nested steps, within the 32-step limit."))
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
            if step.needsFind {
                parameterFields
            }
            if step.operation == .conditional {
                branchSection("Then", otherwise: false)
                branchSection("Otherwise", otherwise: true)
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
            // Type erasure is local to the recursive UI edge. The persisted
            // definition remains a concrete tree of value types.
            AnyView(BuiltInAutomationBranchEditor(root: $root, parent: step.id, otherwise: otherwise,
                                                 ancestorsEnabled: ancestorsEnabled && step.enabled, bundle: bundle))
                .padding(.top, 6)
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
        steps.reduce(0) { $0 + 1 + count($1.thenSteps) + count($1.otherwiseSteps) }
    }

    static func find(_ id: UUID, in steps: [BuiltInAutomationStep]) -> BuiltInAutomationStep? {
        for step in steps {
            if step.id == id { return step }
            if let match = find(id, in: step.thenSteps) ?? find(id, in: step.otherwiseSteps) { return match }
        }
        return nil
    }

    static func branch(in steps: [BuiltInAutomationStep], parent: UUID?, otherwise: Bool) -> [BuiltInAutomationStep]? {
        guard let parent else { return steps }
        guard let step = find(parent, in: steps), step.operation == .conditional else { return nil }
        return otherwise ? step.otherwiseSteps : step.thenSteps
    }

    static func update(_ value: BuiltInAutomationStep, in steps: inout [BuiltInAutomationStep]) {
        for index in steps.indices {
            if steps[index].id == value.id { steps[index] = value; return }
            update(value, in: &steps[index].thenSteps)
            update(value, in: &steps[index].otherwiseSteps)
        }
    }

    @discardableResult
    static func remove(_ id: UUID, from steps: inout [BuiltInAutomationStep]) -> BuiltInAutomationStep? {
        if let index = steps.firstIndex(where: { $0.id == id }) { return steps.remove(at: index) }
        for index in steps.indices {
            if let removed = remove(id, from: &steps[index].thenSteps) { return removed }
            if let removed = remove(id, from: &steps[index].otherwiseSteps) { return removed }
        }
        return nil
    }

    @discardableResult
    static func insert(_ step: BuiltInAutomationStep, into steps: inout [BuiltInAutomationStep],
                       parent: UUID?, otherwise: Bool, before: UUID?) -> Bool {
        guard count(steps) + count([step]) <= BuiltInAutomation.maximumSteps else { return false }
        return insertIntoBranch(step, into: &steps, parent: parent, otherwise: otherwise, before: before)
    }

    private static func insertIntoBranch(_ step: BuiltInAutomationStep, into steps: inout [BuiltInAutomationStep],
                                         parent: UUID?, otherwise: Bool, before: UUID?) -> Bool {
        guard let parent else {
            if let before {
                guard let index = steps.firstIndex(where: { $0.id == before }) else { return false }
                steps.insert(step, at: index)
            } else { steps.append(step) }
            return true
        }
        for index in steps.indices {
            if steps[index].id == parent {
                guard steps[index].operation == .conditional else { return false }
                if otherwise { return insertIntoBranch(step, into: &steps[index].otherwiseSteps, parent: nil, otherwise: false, before: before) }
                return insertIntoBranch(step, into: &steps[index].thenSteps, parent: nil, otherwise: false, before: before)
            }
            if insertIntoBranch(step, into: &steps[index].thenSteps, parent: parent, otherwise: otherwise, before: before) { return true }
            if insertIntoBranch(step, into: &steps[index].otherwiseSteps, parent: parent, otherwise: otherwise, before: before) { return true }
        }
        return false
    }

    static func canDuplicate(_ id: UUID, in steps: [BuiltInAutomationStep]) -> Bool {
        guard let original = find(id, in: steps) else { return false }
        return count(steps) + count([original]) <= BuiltInAutomation.maximumSteps
    }

    /// V2-13 counts the complete tree, including disabled children. Duplicating
    /// preserves every parameter byte while giving each copied node a new ID.
    @discardableResult
    static func duplicate(_ id: UUID, in steps: inout [BuiltInAutomationStep]) -> Bool {
        guard canDuplicate(id, in: steps) else { return false }
        return duplicateInBranch(id, in: &steps)
    }

    private static func duplicateInBranch(_ id: UUID, in steps: inout [BuiltInAutomationStep]) -> Bool {
        for index in steps.indices {
            if steps[index].id == id {
                steps.insert(copyWithNewIDs(steps[index]), at: index + 1)
                return true
            }
            if duplicateInBranch(id, in: &steps[index].thenSteps) { return true }
            if duplicateInBranch(id, in: &steps[index].otherwiseSteps) { return true }
        }
        return false
    }

    private static func copyWithNewIDs(_ original: BuiltInAutomationStep) -> BuiltInAutomationStep {
        var copied = original
        copied.id = UUID()
        copied.thenSteps = original.thenSteps.map(copyWithNewIDs)
        copied.otherwiseSteps = original.otherwiseSteps.map(copyWithNewIDs)
        return copied
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
}
