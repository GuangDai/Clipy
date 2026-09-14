import SwiftUI

/// One explicit preview precedes applying to the editor's draft. The caller
/// retains the item's expected ContentVersion and owns Save Revision (03a §5).
struct BuiltInAutomationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var source: String
    @State private var workflow = BuiltInAutomationWorkflow(name: "", steps: [.init(operation: .trim)])
    @State private var library = BuiltInAutomationLibrary()
    @State private var model = BuiltInAutomationModel()
    @State private var saveMessage: String?
    @State private var confirmsReset = false
    private let apply: (@MainActor (String) -> Void)?

    init(source: String = "", apply: (@MainActor (String) -> Void)? = nil) {
        _source = State(initialValue: source)
        self.apply = apply
    }

    private var copyBundle: Bundle { PanelActionsCopy.bundle(for: locale) }
    private func text(_ key: String) -> String { BuiltInAutomationCopy.text(key, bundle: copyBundle) }
    private var resultUnchanged: Bool {
        model.result.map { $0.utf8.elementsEqual(source.utf8) } ?? false
    }
    private var canApply: Bool {
        model.result != nil && model.result?.isEmpty == false && !resultUnchanged
            && !model.isRunning && model.isCurrent(source: source, steps: workflow.steps)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(text("Text workflows")).font(.title2.weight(.semibold))
                Spacer()
                Menu(text("Load workflow")) {
                    ForEach(BuiltInAutomationWorkflow.presets) { preset in
                        Button(text(preset.name)) {
                            workflow = preset
                            workflow.name = text(preset.name)
                            saveMessage = nil
                        }
                    }
                    if !library.workflows.isEmpty {
                        Divider()
                        ForEach(library.workflows) { saved in
                            Button(saved.name) { workflow = saved; saveMessage = nil }
                        }
                    }
                }
            }
            Text(text("Steps run in order on this text. Preview the result before applying it to your draft."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    workflowEditor
                    HStack {
                        TextField(text("Workflow name"), text: $workflow.name)
                            .accessibilityIdentifier("clipy.workflow.name")
                        Button(text("Save workflow")) {
                            do {
                                try library.save(workflow)
                                saveMessage = text("Workflow saved. Source and preview text are never saved with it.")
                            } catch {
                                saveMessage = text((error as? BuiltInAutomationFailure)?.message ?? BuiltInAutomationFailure.invalidWorkflow.message)
                            }
                        }
                        .disabled(library.failure != nil)
                        if library.workflows.contains(where: { $0.id == workflow.id }) {
                            Button(text("Delete workflow"), role: .destructive) {
                                do { try library.remove(workflow.id); saveMessage = text("Workflow deleted.") }
                                catch { saveMessage = text(BuiltInAutomationFailure.unreadableWorkflows.message) }
                            }
                        }
                    }
                    if let failure = library.failure {
                        HStack {
                            Label(text(failure.message), systemImage: "exclamationmark.triangle")
                            Button(text("Reset saved workflows"), role: .destructive) { confirmsReset = true }
                        }
                        .font(.callout)
                    }
                    if let saveMessage { Text(saveMessage).font(.caption).foregroundStyle(.secondary) }
                    previewArea
                    if let failure = model.failure {
                        Label(text(failure.message), systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .accessibilityIdentifier("clipy.workflow.error")
                    }
                    if resultUnchanged {
                        Text(text("No changes. Try another step or adjust the workflow."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if apply != nil && model.result?.isEmpty == true {
                        Text(text("The result is empty. Adjust the steps before applying to this format."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(2)
            }
            HStack {
                if model.isRunning {
                    ProgressView().controlSize(.small)
                    Button(text("Cancel preview")) { model.invalidate() }
                } else {
                    Button(text("Preview result")) { model.preview(source: source, steps: workflow.steps) }
                        .disabled(!workflow.steps.contains(where: \.enabled))
                        .accessibilityIdentifier("clipy.workflow.preview")
                }
                Spacer()
                Button(text("Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if let apply {
                    Button(text("Apply to draft")) {
                        guard canApply, let result = model.result else { return }
                        apply(result)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canApply)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("clipy.workflow.apply")
                }
            }
            if apply != nil {
                Text(text("Apply changes the draft only. Save Revision in the editor to keep the result. Original content and earlier revisions remain available."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 720, minHeight: 480, idealHeight: 700)
        .onChange(of: workflow.steps) { _, _ in model.invalidate() }
        .onChange(of: source) { _, _ in model.invalidate() }
        .onDisappear { model.invalidate() }
        .confirmationDialog(text("Reset saved workflows?"), isPresented: $confirmsReset) {
            Button(text("Reset saved workflows"), role: .destructive) { library.reset() }
        } message: { Text(text("This removes saved workflow definitions. Clipboard history is unchanged.")) }
    }

    private var workflowEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(workflow.steps) { step in
                        let binding = stepBinding(step)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Toggle(text("Enable step"), isOn: binding.enabled).labelsHidden()
                                Picker(text("Operation"), selection: binding.operation) {
                                    ForEach(BuiltInAutomationStep.Operation.allCases, id: \.self) { operation in
                                        Text(text(operation.title)).tag(operation)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: .infinity)
                                Button { move(step.id, by: -1) } label: { Image(systemName: "arrow.up") }
                                    .help(text("Move step up"))
                                    .accessibilityLabel(text("Move step up"))
                                    .disabled(workflow.steps.first?.id == step.id)
                                Button { move(step.id, by: 1) } label: { Image(systemName: "arrow.down") }
                                    .help(text("Move step down"))
                                    .accessibilityLabel(text("Move step down"))
                                    .disabled(workflow.steps.last?.id == step.id)
                                Button { workflow.steps.removeAll { $0.id == step.id } } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .help(text("Remove step"))
                                .accessibilityLabel(text("Remove step"))
                            }
                            if step.operation == .replace {
                                HStack {
                                    TextField(text("Find (literal text)"), text: binding.find)
                                    TextField(text("Replace with"), text: binding.replacement)
                                }
                                .disabled(!step.enabled)
                            }
                        }
                    }
                }
                .padding(2)
            }
            .frame(minHeight: 64, idealHeight: 130, maxHeight: 180)
            HStack {
                Button(text("Add step"), systemImage: "plus") { workflow.steps.append(.init(operation: .trim)) }
                    .disabled(workflow.steps.count >= BuiltInAutomation.maximumSteps)
                Spacer()
                Text(text("Line steps use LF line endings; sorting uses exact UTF-8 order."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var previewArea: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(text(apply == nil ? "Test text" : "Before")).font(.headline)
                if apply == nil {
                    TextEditor(text: $source)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled(true)
                        .accessibilityLabel(text("Test text"))
                } else { previewText(source, label: text("Before")) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(text("After")).font(.headline)
                previewText(model.result ?? text("Run a preview to see the result here."), label: text("After"))
            }
        }
        .frame(height: 220)
    }

    private func previewText(_ value: String, label: String) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(verbatim: String(value.prefix(12_000)))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(8)
            if value.count > 12_000 {
                Text(text("Preview shows the first 12,000 characters. Apply uses the complete result."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(label)
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = workflow.steps.firstIndex(where: { $0.id == id }),
              workflow.steps.indices.contains(index + offset) else { return }
        workflow.steps.swapAt(index, index + offset)
    }

    private func stepBinding(_ snapshot: BuiltInAutomationStep) -> Binding<BuiltInAutomationStep> {
        Binding {
            workflow.steps.first { $0.id == snapshot.id } ?? snapshot
        } set: { value in
            guard let index = workflow.steps.firstIndex(where: { $0.id == snapshot.id }) else { return }
            workflow.steps[index] = value
        }
    }
}

/// Embeddable in the Automation settings tab, with no nested grouped Form.
struct BuiltInAutomationSettingsView: View {
    @Environment(\.locale) private var locale
    @State private var showsWorkflows = false

    private func text(_ key: String) -> String {
        BuiltInAutomationCopy.text(key, bundle: PanelActionsCopy.bundle(for: locale))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text("Text workflows")).font(.headline)
            Text(text("Clean up text, sort lines and format JSON inside Clipy. Save reusable steps here, then run them from Edit Content."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(text("Manage workflows…")) { showsWorkflows = true }
                .accessibilityIdentifier("clipy.settings.workflows.manage")
        }
        .sheet(isPresented: $showsWorkflows) { BuiltInAutomationView() }
    }
}
