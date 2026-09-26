import SwiftUI

/// A condition edits the same value tree used by execution and text syntax.
/// Indentation and group headings keep All/Any/Not scope visible, following
/// Shortcuts' If/Otherwise model without introducing another execution graph.
struct BuiltInAutomationConditionEditor: View {
    @Binding var predicate: BuiltInAutomationPredicate
    let bundle: Bundle
    let identifier: String
    var isEnabled = true
    var isNested = false
    @State private var isExpanded = false

    private func text(_ key: String) -> String { BuiltInAutomationCopy.text(key, bundle: bundle) }

    var body: some View {
        Group {
            if isNested, isCompound {
                DisclosureGroup(isExpanded: $isExpanded) {
                    // Build only the requested level. A deeply nested tree
                    // does not create hundreds of offscreen editors at once.
                    if isExpanded { conditionContent.padding(.top, 4) }
                } label: {
                    collapsedSummary
                }
                .disclosureGroupStyle(AppDisclosureGroupStyle(
                    identifier: "clipy.workflow.condition-disclosure." + identifier
                ))
            } else {
                conditionContent
            }
        }
        .disabled(!isEnabled)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipy.workflow.predicate." + identifier)
    }

    private var isCompound: Bool {
        if case .match = predicate { return false }
        return true
    }

    private var collapsedSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(summaryTitle(predicate)).fontWeight(.medium)
            switch predicate {
            case .all(let children), .any(let children):
                if children.isEmpty {
                    Label(text("Add a condition to this group."), systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Text(String(format: text("Conditions in this group: %lld"), Int64(children.count)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .not(let child):
                Text(summaryTitle(child)).font(.caption).foregroundStyle(.secondary)
            case .match:
                EmptyView()
            }
        }
        .lineLimit(2)
    }

    private func summaryTitle(_ value: BuiltInAutomationPredicate) -> String {
        switch value {
        case .all: text("All conditions")
        case .any: text("Any condition")
        case .not: text("Not")
        case .match(let condition, let find):
            if condition == .containsText || condition == .matchesRegex {
                text(condition.title) + ": " + find
            } else { text(condition.title) }
        }
    }

    private var conditionContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch predicate {
            case .match(let condition, let find):
                matchEditor(condition: condition, find: find)
            case .all(let children):
                groupEditor(children: children, all: true)
            case .any(let children):
                groupEditor(children: children, all: false)
            case .not(let child):
                HStack {
                    Label(text("Not"), systemImage: "exclamationmark.circle")
                        .fontWeight(.medium)
                    Spacer()
                    Button(text("Remove negation")) { predicate = child }
                        .buttonStyle(.borderless)
                }
                Text(text("The condition below must not match."))
                    .font(.caption).foregroundStyle(.secondary)
                AnyView(BuiltInAutomationConditionEditor(
                    predicate: negatedBinding(fallback: child), bundle: bundle,
                    identifier: identifier + ".not", isEnabled: isEnabled, isNested: true
                ))
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.accentColor.opacity(0.3)).frame(width: 2)
                }
            }
        }
    }

    private func matchEditor(condition: BuiltInAutomationStep.Condition, find: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker(text("Condition"), selection: Binding(
                    get: { if case .match(let current, _) = predicate { return current }; return condition },
                    set: { newCondition in
                        if case .match(_, let currentFind) = predicate {
                            predicate = .match(newCondition, currentFind)
                        }
                    }
                )) {
                    ForEach(BuiltInAutomationStep.Condition.allCases, id: \.self) { value in
                        Text(text(value.title)).tag(value)
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier("clipy.workflow.condition." + identifier)
                conditionActions
            }
            if condition == .containsText || condition == .matchesRegex {
                TextField(text(condition == .containsText ? "Find (literal text)" : "Regular expression"), text: Binding(
                    get: { if case .match(_, let current) = predicate { return current }; return find },
                    set: { newFind in
                        if case .match(let currentCondition, _) = predicate {
                            predicate = .match(currentCondition, newFind)
                        }
                    }
                ), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .accessibilityIdentifier("clipy.workflow.find." + identifier)
                if condition == .containsText {
                    Text(text("Matches exact text, including letter case and spacing."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                let issues = isEnabled ? BuiltInAutomationStep(
                    operation: .conditional, enabled: isEnabled, find: find, condition: condition
                ).parameterIssues() : []
                ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                    Label(text(issue.message), systemImage: issue.isError ? "exclamationmark.circle" : "info.circle")
                        .font(.caption).foregroundStyle(issue.isError ? Color.orange : Color.secondary)
                }
            }
        }
    }

    private var conditionActions: some View {
        Menu {
            Button(text("Combine with All")) { predicate = .all([predicate, .match(.isText, "")]) }
            Button(text("Combine with Any")) { predicate = .any([predicate, .match(.isText, "")]) }
            Button(text("Negate condition")) { predicate = .not(predicate) }
        } label: { Image(systemName: "ellipsis.circle") }
        .menuIndicator(.hidden)
        .accessibilityLabel(text("Condition actions"))
        .accessibilityIdentifier("clipy.workflow.condition-actions." + identifier)
    }

    private func groupEditor(children: [BuiltInAutomationPredicate], all: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker(text("Match conditions"), selection: Binding(
                    get: { if case .all = predicate { return true }; return false },
                    set: { value in
                        switch predicate {
                        case .all(let current), .any(let current): predicate = value ? .all(current) : .any(current)
                        default: break
                        }
                    }
                )) {
                    Text(text("All conditions")).tag(true)
                    Text(text("Any condition")).tag(false)
                }
                .labelsHidden()
                .accessibilityIdentifier("clipy.workflow.condition-mode." + identifier)
                Spacer()
                Menu {
                    Button(text("Negate condition")) { predicate = .not(predicate) }
                    if children.count == 1, let only = children.first {
                        Button(text("Remove group")) { predicate = only }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuIndicator(.hidden)
                .accessibilityLabel(text("Condition group actions"))
            }
            Text(text(all ? "Every condition in this group must match." : "At least one condition in this group must match."))
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(children.enumerated()), id: \.offset) { index, child in
                    HStack(alignment: .top, spacing: 8) {
                        AnyView(BuiltInAutomationConditionEditor(
                            predicate: childBinding(at: index, fallback: child), bundle: bundle,
                            identifier: identifier + ".\(index)", isEnabled: isEnabled, isNested: true
                        ))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button(role: .destructive) { removeChild(at: index) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(text("Remove condition"))
                        .accessibilityIdentifier("clipy.workflow.remove-condition." + identifier + ".\(index)")
                    }
                    if index < children.count - 1 { Divider() }
                }
                if children.isEmpty {
                    Label(text("Add a condition to this group."), systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Menu {
                    Button(text("Add condition")) { append(.match(.isText, "")) }
                    Button(text("Add All group")) { append(.all([.match(.isText, "")])) }
                    Button(text("Add Any group")) { append(.any([.match(.isText, "")])) }
                } label: { Label(text("Add condition"), systemImage: "plus") }
                .menuStyle(.borderlessButton)
                .accessibilityIdentifier("clipy.workflow.add-condition." + identifier)
            }
            .padding(.leading, 14)
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.accentColor.opacity(0.3)).frame(width: 2)
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private func childBinding(at index: Int, fallback: BuiltInAutomationPredicate) -> Binding<BuiltInAutomationPredicate> {
        Binding(get: {
            switch predicate {
            case .all(let children), .any(let children): return children.indices.contains(index) ? children[index] : fallback
            default: return fallback
            }
        }, set: { replacement in
            switch predicate {
            case .all(var children):
                guard children.indices.contains(index) else { return }
                children[index] = replacement
                predicate = .all(children)
            case .any(var children):
                guard children.indices.contains(index) else { return }
                children[index] = replacement
                predicate = .any(children)
            default: break
            }
        })
    }

    private func negatedBinding(fallback: BuiltInAutomationPredicate) -> Binding<BuiltInAutomationPredicate> {
        Binding(get: { if case .not(let child) = predicate { return child }; return fallback },
                set: { child in if case .not = predicate { predicate = .not(child) } })
    }

    private func append(_ child: BuiltInAutomationPredicate) {
        switch predicate {
        case .all(let children): predicate = .all(children + [child])
        case .any(let children): predicate = .any(children + [child])
        default: break
        }
    }

    private func removeChild(at index: Int) {
        switch predicate {
        case .all(var children):
            guard children.indices.contains(index) else { return }
            children.remove(at: index)
            predicate = .all(children)
        case .any(var children):
            guard children.indices.contains(index) else { return }
            children.remove(at: index)
            predicate = .any(children)
        default: break
        }
    }
}
