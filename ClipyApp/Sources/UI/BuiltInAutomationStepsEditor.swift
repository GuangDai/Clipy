import SwiftUI

/// A branch owns an ordered array. Dragging moves the entire step, including
/// its children, and cannot insert a condition into one of its own branches.
struct BuiltInAutomationStepsEditor: View {
    @Binding var steps: [BuiltInAutomationStep]
    let bundle: Bundle

    var body: some View {
        BuiltInAutomationBranchEditor(root: $steps, parent: nil, otherwise: false, bundle: bundle)
    }
}

private struct BuiltInAutomationBranchEditor: View {
    @Binding var root: [BuiltInAutomationStep]
    let parent: UUID?
    let otherwise: Bool
    let bundle: Bundle

    private var steps: [BuiltInAutomationStep] {
        BuiltInAutomationStepEditing.branch(in: root, parent: parent, otherwise: otherwise) ?? []
    }
    private func text(_ key: String) -> String { BuiltInAutomationCopy.text(key, bundle: bundle) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                BuiltInAutomationStepCard(root: $root, snapshot: step, parent: parent,
                                          otherwise: otherwise, index: index, siblingCount: steps.count, bundle: bundle)
                    .dropDestination(for: String.self, isEnabled: true) { payloads, _ in _ = drop(payloads.first, before: step.id) }
            }
            Menu {
                Button(text("Add condition")) { add(.conditional) }
                Divider()
                ForEach(BuiltInAutomationStep.Operation.allCases.filter {
                    !$0.isCondition && ($0 != .notify || parent != nil)
                }, id: \.self) { operation in
                    Button(text(operation.title)) { add(operation) }
                }
            } label: {
                Label(text("Add step"), systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
            .menuStyle(.borderlessButton)
            .disabled(BuiltInAutomationStepEditing.count(root) >= BuiltInAutomation.maximumSteps)
            .accessibilityIdentifier("clipy.workflow.add-step." + (parent?.uuidString ?? "root") + (otherwise ? ".otherwise" : ".then"))
            .dropDestination(for: String.self, isEnabled: true) { payloads, _ in _ = drop(payloads.first, before: nil) }
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
    let bundle: Bundle

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
                    .draggable("step:" + step.id.uuidString)
                Toggle(text("Enable step"), isOn: binding.enabled).labelsHidden().toggleStyle(.checkbox)
                if step.operation == .conditional {
                    Text(text("If")).fontWeight(.semibold)
                    Picker(text("Condition"), selection: binding.condition) {
                        ForEach(BuiltInAutomationStep.Condition.allCases, id: \.self) { condition in
                            Text(text(condition.title)).tag(condition)
                        }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("clipy.workflow.condition." + step.id.uuidString)
                } else if step.operation.isCondition {
                    Text(text("If")).fontWeight(.semibold)
                    Text(text(legacyConditionTitle)).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Picker(text("Operation"), selection: binding.operation) {
                        ForEach(BuiltInAutomationStep.Operation.allCases.filter {
                            !$0.isCondition && ($0 != .notify || parent != nil || step.operation == .notify)
                        }, id: \.self) { operation in
                            Text(text(operation.title)).tag(operation)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
                Spacer(minLength: 0)
                Menu {
                    Button(text("Move step up")) { move(by: -1) }.disabled(index == 0)
                    Button(text("Move step down")) { move(by: 1) }.disabled(index == siblingCount - 1)
                    Divider()
                    Button(text("Remove step"), role: .destructive) {
                        _ = BuiltInAutomationStepEditing.remove(step.id, from: &root)
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuIndicator(.hidden)
                .accessibilityLabel(text("Step actions"))
            }
            if needsFind {
                TextField(text(isLiteralFind ? "Find (literal text)" : "Regular expression"), text: binding.find)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!step.enabled)
                    .accessibilityIdentifier("clipy.workflow.find." + step.id.uuidString)
            }
            if [.replace, .regexReplace].contains(step.operation) {
                TextField(text("Replace with"), text: binding.replacement)
                    .textFieldStyle(.roundedBorder).disabled(!step.enabled)
            }
            if step.operation == .conditional {
                branchSection("Then", otherwise: false)
                branchSection("Otherwise", otherwise: true)
            } else if step.operation.isCondition {
                Text(text("Then continue with the following steps. Otherwise stop this workflow."))
                    .font(.caption).foregroundStyle(.secondary)
            } else if step.operation == .notify {
                Text(text("Sends a notification when this branch completes. Clipboard content is never included."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipy.workflow.step." + step.id.uuidString)
    }

    private var needsFind: Bool {
        [.replace, .regexReplace, .regexExtract, .containsText, .matchesRegex].contains(step.operation)
            || (step.operation == .conditional && [.containsText, .matchesRegex].contains(step.condition))
    }

    private var legacyConditionTitle: String {
        switch step.operation {
        case .requireText: "Input is text"
        case .requireImage: "Input is an image"
        default: step.operation.title
        }
    }
    private var isLiteralFind: Bool {
        [.replace, .containsText].contains(step.operation)
            || (step.operation == .conditional && step.condition == .containsText)
    }

    private func branchSection(_ title: String, otherwise: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text(title)).fontWeight(.semibold)
            // Type erasure is local to the recursive UI edge. The persisted
            // definition remains a concrete tree of value types.
            AnyView(BuiltInAutomationBranchEditor(root: $root, parent: step.id, otherwise: otherwise, bundle: bundle))
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor.opacity(0.35)).frame(width: 2) }
        .disabled(!step.enabled)
    }

    private func move(by offset: Int) {
        guard let siblings = BuiltInAutomationStepEditing.branch(in: root, parent: parent, otherwise: otherwise),
              siblings.indices.contains(index + offset) else { return }
        let target = offset < 0 ? siblings[index - 1].id : (index + 2 < siblings.count ? siblings[index + 2].id : nil)
        _ = BuiltInAutomationStepEditing.move(step.id, in: &root, parent: parent, otherwise: otherwise, before: target)
    }
}

private extension BuiltInAutomationStep.Operation {
    var isCondition: Bool { [.conditional, .requireText, .requireImage, .containsText, .matchesRegex].contains(self) }
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
                if otherwise { return insert(step, into: &steps[index].otherwiseSteps, parent: nil, otherwise: false, before: before) }
                return insert(step, into: &steps[index].thenSteps, parent: nil, otherwise: false, before: before)
            }
            if insert(step, into: &steps[index].thenSteps, parent: parent, otherwise: otherwise, before: before) { return true }
            if insert(step, into: &steps[index].otherwiseSteps, parent: parent, otherwise: otherwise, before: before) { return true }
        }
        return false
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
