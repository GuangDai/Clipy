import SwiftUI
import UniformTypeIdentifiers
import HistoryCore

/// Definitions and their transient test input stay separate. Selecting another
/// workflow retains this window's drafts; only Save enables its automatic run.
struct BuiltInAutomationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.workflowExecutionQueue) private var executionQueue
    @State private var source: String
    @State private var workflow = BuiltInAutomationWorkflow(name: "", steps: [.init(operation: .trim)])
    @State private var drafts: [BuiltInAutomationWorkflow] = []
    @State private var draftInputs: [UUID: String] = [:]
    @State private var library = BuiltInAutomationLibrary()
    @State private var model = BuiltInAutomationModel()
    @State private var hasAppeared = false
    @State private var editsScope = false
    @State private var saveMessage: String?
    @State private var confirmsReset = false
    @State private var choosesApplications = false
    @State private var inputFailure: BuiltInAutomationFailure?
    @State private var executionMessage: String?
    private let history: (any ClipboardHistory)?
    private let apply: (@MainActor (String) -> Void)?

    init(source: String = "", history: (any ClipboardHistory)? = nil, apply: (@MainActor (String) -> Void)? = nil) {
        _source = State(initialValue: source)
        self.history = history
        self.apply = apply
    }

    private var copyBundle: Bundle { PanelActionsCopy.bundle(for: locale) }
    private func text(_ key: String) -> String { BuiltInAutomationCopy.text(key, bundle: copyBundle) }
    private var input: BuiltInAutomationInput { .text(source) }
    private var isCurrent: Bool { model.isCurrent(input: input, steps: workflow.steps) }
    private var isBusy: Bool { model.isRunning || model.isQueued }
    private var isDirty: Bool { library.workflows.first { $0.id == workflow.id } != workflow }
    private var canRun: Bool { workflow.steps.contains(where: \.enabled) }
    private var canApply: Bool {
        model.output?.matchedConditions == true && model.result?.isEmpty == false
            && model.output?.value != input && !isBusy && isCurrent
    }
    private var showsManualInput: Bool { apply != nil || workflow.scope.source == .input }
    private var originalInput: BuiltInAutomationInput? {
        showsManualInput ? input : model.output?.originalInput
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(text("Workflows")).font(.title2.weight(.semibold))
                Spacer()
                Button(text("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            HSplitView {
                sidebar.frame(minWidth: 190, idealWidth: 220, maxWidth: 280)
                VStack(spacing: 0) {
                    editorHeader
                    Divider()
                    VSplitView {
                        definitionArea.frame(minHeight: 230, idealHeight: 330)
                        comparisonArea.frame(minHeight: 190, idealHeight: 250)
                    }
                    Divider()
                    executionFooter
                }
                .frame(minWidth: 620)
            }
        }
        .font(.body)
        .controlSize(.regular)
        .frame(minWidth: 900, idealWidth: 1060, minHeight: 650, idealHeight: 780)
        .onAppear {
            guard !hasAppeared else { return }
            hasAppeared = true
            if let executionQueue { model = BuiltInAutomationModel(executionQueue: executionQueue) }
            // An editor invocation starts with Trim for its current draft. The
            // manager opens the first saved definition, retaining every other.
            drafts = library.workflows
            if apply == nil, let first = drafts.first { workflow = first }
            else { drafts.append(workflow) }
        }
        .onChange(of: workflow) { _, _ in
            retainDraft()
            invalidatePreview()
        }
        .onChange(of: input) { _, _ in invalidatePreview() }
        .onDisappear { model.invalidate() }
        .fileImporter(isPresented: $choosesApplications, allowedContentTypes: [.application], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result {
                var identifiers = workflow.scope.applicationIDs
                for url in urls {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    guard let identifier = Bundle(url: url)?.bundleIdentifier?.lowercased() else { continue }
                    if !identifiers.contains(identifier) { identifiers.append(identifier) }
                }
                workflow.scope.applications = identifiers.joined(separator: ", ")
            }
        }
        .confirmationDialog(text("Reset saved workflows?"), isPresented: $confirmsReset) {
            Button(text("Reset saved workflows"), role: .destructive) {
                invalidatePreview()
                library.reset()
            }
        } message: { Text(text("This removes saved workflow definitions. Clipboard history is unchanged.")) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(text("Execution order")).font(.headline)
                Spacer()
                Menu {
                    Button(text("New workflow")) {
                        add(BuiltInAutomationWorkflow(name: "", steps: [.init(operation: .trim)]))
                    }
                    Divider()
                    ForEach(BuiltInAutomationWorkflow.presets) { preset in
                        Button(text(preset.name)) {
                            var localized = preset
                            localized.name = text(preset.name)
                            add(localized)
                        }
                    }
                } label: { Image(systemName: "plus") }
                .menuIndicator(.hidden)
                .help(text("New workflow"))
                .accessibilityLabel(text("New workflow"))
                .accessibilityIdentifier("clipy.workflow.load")
            }
            Text(text("Runs from top to bottom. Drag to change priority."))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(drafts.enumerated()), id: \.element.id) { index, draft in
                        sidebarRow(draft, index: index)
                    }
                    Color.clear.frame(height: 20)
                        .dropDestination(for: String.self, isEnabled: true) { values, _ in _ = reorderWorkflow(values.first, before: nil) }
                }
            }
            .accessibilityIdentifier("clipy.workflow.sidebar")
            if let failure = library.failure {
                Text(text(failure.message)).font(.caption).foregroundStyle(.secondary)
                Button(text("Reset saved workflows"), role: .destructive) { confirmsReset = true }
            }
        }
        .padding(12)
        .background(.background.secondary)
    }

    private func sidebarRow(_ draft: BuiltInAutomationWorkflow, index: Int) -> some View {
        Button { select(draft.id) } label: {
            HStack(alignment: .top, spacing: 8) {
                Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .trailing)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(draft.name.isEmpty ? text("Untitled workflow") : draft.name)
                            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        if library.workflows.first(where: { $0.id == draft.id }) != draft {
                            Image(systemName: "circle.fill").font(.system(size: 5))
                                .accessibilityLabel(text("Unsaved changes"))
                        }
                    }
                    Text(text(draft.trigger.title)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(9)
            .contentShape(Rectangle())
            .background(workflow.id == draft.id ? Color.accentColor.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("clipy.workflow.row." + draft.id.uuidString)
        .draggable("workflow:" + draft.id.uuidString)
        .dropDestination(for: String.self, isEnabled: true) { values, _ in _ = reorderWorkflow(values.first, before: draft.id) }
        .contextMenu {
            Button(text("Move workflow up")) { moveWorkflow(draft.id, by: -1) }.disabled(index == 0)
            Button(text("Move workflow down")) { moveWorkflow(draft.id, by: 1) }.disabled(index == drafts.count - 1)
            Divider()
            Button(text("Delete workflow"), role: .destructive) { remove(draft.id) }
        }
    }

    private var editorHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(text("Workflow name"), text: $workflow.name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("clipy.workflow.name")
                Button(text("Save workflow")) { save() }
                    .disabled(!isDirty || library.failure != nil)
                    .keyboardShortcut("s", modifiers: .command)
                    .accessibilityIdentifier("clipy.workflow.save")
                Menu {
                    Button(text("Move workflow up")) { moveWorkflow(workflow.id, by: -1) }
                        .disabled(drafts.first?.id == workflow.id)
                    Button(text("Move workflow down")) { moveWorkflow(workflow.id, by: 1) }
                        .disabled(drafts.last?.id == workflow.id)
                    Divider()
                    Button(text("Delete workflow"), role: .destructive) { remove(workflow.id) }
                } label: { Image(systemName: "ellipsis") }
                .menuIndicator(.hidden)
                .accessibilityLabel(text("Workflow actions"))
                .accessibilityIdentifier("clipy.workflow.actions")
            }
            Text(saveMessage ?? text(isDirty ? "Unsaved changes" : "Saved"))
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("clipy.workflow.save-status")
        }
        .padding(14)
    }

    private var definitionArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(text("Workflow configuration"), selection: $editsScope) {
                Text(text("Steps")).tag(false)
                Text(text("Trigger and scope")).tag(true)
                    .accessibilityIdentifier("clipy.workflow.configuration.scope")
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("clipy.workflow.configuration")
            if editsScope {
                ScrollView { scopeControls.padding(2) }
            } else {
                ScrollView {
                    BuiltInAutomationStepsEditor(steps: $workflow.steps, bundle: copyBundle)
                        .padding(2)
                }
                Text(text("Drag steps between branches. Conditions choose Then or Otherwise; steps run from top to bottom."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    private var scopeControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(text("Trigger"), selection: $workflow.trigger) {
                ForEach(BuiltInAutomationTrigger.allCases, id: \.self) { Text(text($0.title)).tag($0) }
            }
            .accessibilityIdentifier("clipy.workflow.trigger")
            Picker(text("Manual input"), selection: $workflow.scope.source) {
                ForEach(BuiltInAutomationScope.Source.allCases, id: \.self) { Text(text($0.title)).tag($0) }
            }
            .disabled(apply != nil)
            .accessibilityIdentifier("clipy.workflow.scope")
            HStack {
                Text(text("Source applications"))
                Spacer()
                Button(text("Choose Applications…")) { choosesApplications = true }
                    .accessibilityIdentifier("clipy.workflow.choose-applications")
            }
            TextField(text("Source apps (bundle IDs, comma separated; empty means all)"), text: $workflow.scope.applications)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("clipy.workflow.source-apps")
            Picker(text("Copy time"), selection: $workflow.scope.timeRange) {
                ForEach(BuiltInAutomationScope.TimeRange.allCases, id: \.self) { Text(text($0.title)).tag($0) }
            }
            .accessibilityIdentifier("clipy.workflow.time-range")
            if workflow.scope.timeRange == .custom {
                DatePicker(text("From"), selection: $workflow.scope.startDate)
                DatePicker(text("Through"), selection: $workflow.scope.endDate)
            }
            if workflow.scope.source == .history {
                Stepper(value: $workflow.scope.historyLimit, in: 1...1000) {
                    Text(text("History items to check") + ": \(workflow.scope.historyLimit)")
                }
                .accessibilityIdentifier("clipy.workflow.history-limit")
            }
            Text(text("Automatic runs check new copies only, never existing history. Save the workflow to enable automatic runs. Source and time filters need a recorded copy; untracked manual input will not match these filters."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var comparisonArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                comparisonColumn(label: showsManualInput && apply == nil ? "Test text" : "Before", original: true)
                comparisonColumn(label: "After", original: false)
            }
            if !showsManualInput {
                Text(text("Preview reads the configured source. Before shows the exact input used for this result."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    private func comparisonColumn(label: String, original: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text(label)).font(.headline)
            let value = original ? originalInput : model.output?.value
            if case let .image(data) = value, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(nsColor: .textBackgroundColor))
                    .accessibilityLabel(text(original ? "Image input" : "After"))
            } else {
                BuiltInAutomationSourceEditor(
                    text: original && showsManualInput && apply == nil ? $source : .constant(value?.text ?? ""),
                    accessibilityLabel: text(label),
                    isEditable: original && showsManualInput && apply == nil,
                    accessibilityIdentifier: original ? "clipy.workflow.source" : "clipy.workflow.result"
                )
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var executionFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            executionStatus
            HStack {
                if isBusy {
                    ProgressView().controlSize(.small)
                    Text(text(model.isQueued ? "Waiting to run…" : "Running…")).foregroundStyle(.secondary)
                    Button(text("Cancel preview")) { model.invalidate() }
                } else {
                    Button(text("Preview result")) { run(effects: false) }
                        .disabled(!canRun).accessibilityIdentifier("clipy.workflow.preview")
                    Button(text("Run workflow")) { run(effects: true) }
                        .disabled(!canRun || !workflow.trigger.includesManual)
                        .accessibilityIdentifier("clipy.workflow.run")
                }
                Spacer()
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
                } else {
                    Button(text("Copy result")) {
                        guard isCurrent, let output = model.output else { return }
                        do {
                            try BuiltInAutomationClipboard.copy(output.value)
                            executionMessage = text("Result copied.")
                        } catch { inputFailure = error as? BuiltInAutomationFailure }
                    }
                    .disabled(model.output?.matchedConditions != true || isBusy || !isCurrent)
                    .accessibilityIdentifier("clipy.workflow.copy")
                }
            }
            Text(text(apply != nil
                      ? "Apply changes the draft only. Save Revision in the editor to keep the result. Original content and earlier revisions remain available."
                      : "Preview never sends notifications. Run executes the selected branches and their notifications."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }

    @ViewBuilder private var executionStatus: some View {
        if let failure = inputFailure ?? model.failure {
            Label(text(failure.message), systemImage: "exclamationmark.triangle")
                .accessibilityIdentifier("clipy.workflow.error")
        } else if let executionMessage {
            Text(executionMessage).foregroundStyle(.secondary)
        } else if model.output?.matchedConditions == false {
            Text(text("Conditions did not match. No notification was sent.")).foregroundStyle(.secondary)
        } else if let output = model.output {
            if containsConditions(workflow.steps) {
                Label(text("Workflow finished."), systemImage: "checkmark.circle")
                    .accessibilityIdentifier("clipy.workflow.conditions-matched")
            }
            if output.matchedItemCount > 1 {
                Text("\(output.matchedItemCount) " + text("items matched. Showing the first result; Copy result copies only this result."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func containsConditions(_ steps: [BuiltInAutomationStep]) -> Bool {
        steps.contains { $0.enabled && [.conditional, .requireText, .requireImage, .containsText, .matchesRegex].contains($0.operation) }
    }

    private func run(effects: Bool) {
        executionMessage = nil
        model.preview(input: input, steps: workflow.steps, runEffects: effects,
                      workflow: apply == nil ? workflow : nil, history: history, notificationName: workflow.name)
    }

    private func invalidatePreview() {
        model.invalidate()
        inputFailure = nil
        executionMessage = nil
        saveMessage = nil
    }

    private func retainDraft() {
        if let index = drafts.firstIndex(where: { $0.id == workflow.id }) { drafts[index] = workflow }
    }

    private func select(_ id: UUID) {
        guard id != workflow.id else { return }
        invalidatePreview()
        retainDraft()
        draftInputs[workflow.id] = source
        guard let next = drafts.first(where: { $0.id == id }) else { return }
        workflow = next
        if apply == nil { source = draftInputs[id] ?? "" }
    }

    private func add(_ value: BuiltInAutomationWorkflow) {
        invalidatePreview()
        retainDraft()
        drafts.append(value)
        select(value.id)
        editsScope = false
    }

    private func save() {
        do {
            try library.save(workflow)
            let following = drafts.drop(while: { $0.id != workflow.id }).dropFirst()
                .first { draft in library.workflows.contains { $0.id == draft.id } }
            try library.move(id: workflow.id, before: following?.id)
            if let saved = library.workflows.first(where: { $0.id == workflow.id }) { workflow = saved; retainDraft() }
            saveMessage = text("Workflow saved. Source and preview text are never saved with it.")
        } catch { saveMessage = text((error as? BuiltInAutomationFailure)?.message ?? BuiltInAutomationFailure.invalidWorkflow.message) }
    }

    private func remove(_ id: UUID) {
        invalidatePreview()
        do {
            if library.workflows.contains(where: { $0.id == id }) { try library.remove(id) }
            drafts.removeAll { $0.id == id }
            draftInputs.removeValue(forKey: id)
            if workflow.id == id {
                if let next = drafts.first { workflow = next; if apply == nil { source = draftInputs[next.id] ?? "" } }
                else {
                    workflow = BuiltInAutomationWorkflow(name: "", steps: [.init(operation: .trim)])
                    drafts.append(workflow)
                    if apply == nil { source = "" }
                }
            }
        } catch { saveMessage = text(BuiltInAutomationFailure.unreadableWorkflows.message) }
    }

    private func moveWorkflow(_ id: UUID, by offset: Int) {
        guard let index = drafts.firstIndex(where: { $0.id == id }), drafts.indices.contains(index + offset) else { return }
        let target = offset < 0 ? drafts[index - 1].id : (index + 2 < drafts.count ? drafts[index + 2].id : nil)
        _ = reorderWorkflow("workflow:" + id.uuidString, before: target)
    }

    private func reorderWorkflow(_ payload: String?, before target: UUID?) -> Bool {
        guard let payload, payload.hasPrefix("workflow:"), let id = UUID(uuidString: String(payload.dropFirst(9))),
              id != target, let index = drafts.firstIndex(where: { $0.id == id }) else { return false }
        let previous = drafts
        let moved = drafts.remove(at: index)
        if let target, let destination = drafts.firstIndex(where: { $0.id == target }) { drafts.insert(moved, at: destination) }
        else { drafts.append(moved) }
        guard library.workflows.contains(where: { $0.id == id }) else { return true }
        let following = drafts.drop(while: { $0.id != id }).dropFirst()
            .first { draft in library.workflows.contains { $0.id == draft.id } }
        do { try library.move(id: id, before: following?.id); return true }
        catch { drafts = previous; saveMessage = text(BuiltInAutomationFailure.unreadableWorkflows.message); return false }
    }
}
/// Embeddable in the Automation settings tab, with no nested grouped Form.
struct BuiltInAutomationSettingsView: View {
    var history: (any ClipboardHistory)? = nil
    var failure: BuiltInAutomationFailure? = nil
    @Environment(\.locale) private var locale
    @State private var showsWorkflows = false

    private func text(_ key: String) -> String {
        BuiltInAutomationCopy.text(key, bundle: PanelActionsCopy.bundle(for: locale))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text("Workflows")).font(.headline)
            Text(text("Process text and images with conditions, regular expressions, Apple OCR and matching notifications."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let failure {
                Label(text(failure.message), systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .accessibilityIdentifier("clipy.settings.workflows.failure")
            }
            Button(text("Manage workflows…")) { showsWorkflows = true }
                .accessibilityIdentifier("clipy.settings.workflows.manage")
        }
        .sheet(isPresented: $showsWorkflows) { BuiltInAutomationView(history: history) }
    }
}
