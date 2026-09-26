import SwiftUI
import UniformTypeIdentifiers
import HistoryCore

/// Definitions and their transient test input stay separate. Selecting another
/// workflow retains this window's drafts; only Save enables its automatic run.
struct BuiltInAutomationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.workflowExecutionQueue) private var executionQueue
    @State private var workspace: BuiltInAutomationWorkspace
    @State private var model = BuiltInAutomationModel()
    @State private var hasAppeared = false
    @State private var editsScope = false
    @State private var definitionMessage: DefinitionMessage?
    @State private var confirmsReset = false
    @State private var choosesApplications = false
    @State private var inputFailure: BuiltInAutomationFailure?
    @State private var executionMessage: String?
    @State private var confirmsClose = false
    @State private var deletionTarget: BuiltInAutomationWorkflow?
    @State private var confirmsDeletion = false
    @State private var showsFilters = false
    @State private var comparisonMode = ComparisonMode.sideBySide
    @State private var lastRunUsedEffects = false
    @State private var pendingApply: String?
    @State private var definitionFailure: BuiltInAutomationFailure?
    @State private var importsWorkflow = false
    @State private var exportsWorkflow = false
    @State private var importedWorkflow: BuiltInAutomationWorkflow?
    @State private var exportDocument: BuiltInAutomationFileDocument?
    @State private var importTask: Task<Void, Never>?
    @State private var stepEditorState = WorkflowStepsEditorState()
    @AppStorage("workflowCompactRows") private var compactRows = false

    private enum ComparisonMode: String, CaseIterable {
        case sideBySide = "Compare", input = "Input", result = "Result"
    }
    private struct DefinitionMessage {
        let workflow: BuiltInAutomationWorkflow
        let text: String
    }
    private let history: (any ClipboardHistory)?
    private let apply: (@MainActor (String) -> Void)?

    init(source: String = "", history: (any ClipboardHistory)? = nil, apply: (@MainActor (String) -> Void)? = nil) {
        _workspace = State(initialValue: BuiltInAutomationWorkspace(source: source, editorInput: apply != nil))
        self.history = history
        self.apply = apply
    }

    private var copyBundle: Bundle { PanelActionsCopy.bundle(for: locale) }
    private func text(_ key: String) -> String { BuiltInAutomationCopy.text(key, bundle: copyBundle) }
    private var workflow: BuiltInAutomationWorkflow { workspace.workflow }
    private var saveMessage: String? {
        get {
            guard let definitionMessage, definitionMessage.workflow == workflow else { return nil }
            return text(definitionMessage.text)
        }
        nonmutating set { definitionMessage = newValue.map { DefinitionMessage(workflow: workflow, text: $0) } }
    }
    private var drafts: [BuiltInAutomationWorkflow] { workspace.drafts }
    private var visibleDrafts: [BuiltInAutomationWorkflow] {
        workspace.visibleDrafts(includingUnsavedIDs: stepEditorState.unappliedWorkflowIDs)
    }
    private var library: BuiltInAutomationLibrary { workspace.library }
    private var input: BuiltInAutomationInput { .text(workspace.source) }
    private var isCurrent: Bool { model.isCurrent(input: input, steps: workflow.steps) }
    private var isBusy: Bool { model.isRunning || model.isQueued }
    private var isDirty: Bool { workspace.isDirty(workflow) }
    private var hasUnappliedRules: Bool { stepEditorState.hasUnappliedChanges(for: workflow.id) }
    private var hasChangesToKeep: Bool { workspace.hasUnsavedChanges || stepEditorState.hasUnappliedChanges }
    private var canRun: Bool { !hasUnappliedRules && workflow.steps.contains(where: \.enabled) }
    private var canApply: Bool {
        model.output?.matchedConditions == true && model.result?.isEmpty == false
            && model.output?.value != input && !isBusy && isCurrent && !hasUnappliedRules
    }
    private var showsManualInput: Bool { apply != nil || workflow.scope.source == .input }
    private var originalInput: BuiltInAutomationInput? {
        showsManualInput ? input : model.output?.originalInput
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(text("Workflows")).font(.title2.weight(.semibold))
                    .accessibilityIdentifier("clipy.workflow.title")
                Spacer()
                Button(text("Close")) { requestClose() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            HSplitView {
                sidebar.frame(minWidth: 190, idealWidth: 220, maxWidth: 280)
                VStack(spacing: 0) {
                    editorHeader
                    Divider()
                    VSplitView {
                        definitionArea.frame(minHeight: 140, idealHeight: 330)
                        comparisonArea.frame(minHeight: 150, idealHeight: 250)
                    }
                    Divider()
                    executionFooter
                }
                .frame(minWidth: 620)
            }
        }
        .font(.body)
        .controlSize(.regular)
        // Attached sheets begin below the Settings toolbar. On a small
        // display, a 650 pt minimum pushes Run/Preview underneath the Dock.
        // Both editors scroll independently so the footer can stay visible.
        .frame(minWidth: 900, idealWidth: 1060, minHeight: 560, idealHeight: 780)
        .onAppear {
            guard !hasAppeared else { return }
            hasAppeared = true
            if let executionQueue { model = BuiltInAutomationModel(executionQueue: executionQueue) }
            definitionFailure = BuiltInAutomationLibrary.validationFailure(for: workflow)
        }
        .onChange(of: workflow) { _, _ in
            definitionFailure = BuiltInAutomationLibrary.validationFailure(for: workflow)
            invalidatePreview()
        }
        .onChange(of: input) { _, _ in invalidatePreview() }
        .onDisappear { model.invalidate(); importTask?.cancel() }
        .fileImporter(isPresented: $importsWorkflow, allowedContentTypes: [.json]) { result in
            if case let .success(url) = result { importWorkflow(from: url) }
            else if case .failure = result { saveMessage = (BuiltInAutomationTransfer.Failure.unreadable.message) }
        }
        .fileExporter(isPresented: $exportsWorkflow, item: exportDocument, contentTypes: [.json],
                      defaultFilename: workflow.name.replacingOccurrences(of: "/", with: "-") + ".clipy-workflow",
                      onCompletion: { result in
            switch result {
            case .success: saveMessage = ("Workflow exported. Test input and results were not included.")
            case .failure: saveMessage = ("The workflow could not be exported. Try another location.")
            }
        })
        .sheet(item: $importedWorkflow) { imported in
            BuiltInAutomationImportReview(workflow: imported, bundle: copyBundle) {
                add(imported.duplicated(named: imported.name))
                saveMessage = ("Workflow imported as a manual draft. Review and save it when ready.")
            }
        }
        .interactiveDismissDisabled(hasChangesToKeep)
        .confirmationDialog(text("Save changes before closing?"), isPresented: $confirmsClose) {
            Button(text(pendingApply == nil ? "Save all and close" : "Save all and apply")) { save(all: true, close: true) }
                .disabled(library.failure != nil || stepEditorState.hasUnappliedChanges)
            Button(text(pendingApply == nil ? "Discard changes and close" : "Apply without saving workflows"), role: .destructive) { finishClosing() }
                .accessibilityIdentifier("clipy.workflow.discard-close")
            Button(text("Keep editing"), role: .cancel) { pendingApply = nil }
                .accessibilityIdentifier("clipy.workflow.keep-editing")
        } message: {
            if stepEditorState.hasUnappliedChanges {
                Text(text("There is unapplied rule text in this window. Apply it before saving, or discard it when closing."))
            } else {
                Text(text(pendingApply == nil
                          ? "There are unsaved workflow definitions in this window. Temporary test input is not saved."
                          : "Apply keeps the result in the content editor. Choose whether to save your workflow definitions as well."))
            }
        }
        .confirmationDialog(text("Delete workflow?"), isPresented: $confirmsDeletion) {
            Button(text("Delete workflow"), role: .destructive) {
                if let target = deletionTarget { remove(target.id) }
                deletionTarget = nil
            }
            .accessibilityIdentifier("clipy.workflow.confirm-delete")
            Button(text("Cancel"), role: .cancel) { deletionTarget = nil }
        } message: {
            Text(deletionTarget?.name ?? "")
            Text(text("This removes the definition and stops future automatic runs. Clipboard history is unchanged."))
        }
        .fileImporter(isPresented: $choosesApplications, allowedContentTypes: [.application], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result {
                var identifiers = workflow.scope.applicationIDs
                for url in urls {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    guard let identifier = Bundle(url: url)?.bundleIdentifier?.lowercased() else { continue }
                    if !identifiers.contains(identifier) { identifiers.append(identifier) }
                }
                workspace.workflow.scope.applications = identifiers.joined(separator: ", ")
            }
        }
        .confirmationDialog(text("Reset saved workflows?"), isPresented: $confirmsReset) {
            Button(text("Reset saved workflows"), role: .destructive) {
                invalidatePreview()
                workspace.resetSavedDefinitions()
            }
        } message: { Text(text("This removes saved workflow definitions. Clipboard history is unchanged.")) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(text("Workflow library")).font(.headline)
                Spacer()
                if importTask != nil { ProgressView().controlSize(.small) }
                Menu {
                    Button(text("New workflow")) {
                        add(BuiltInAutomationWorkflow(name: "", steps: [.init(operation: .trim)]))
                    }
                    Divider()
                    Button(text("Import workflow…")) { importsWorkflow = true }
                        .disabled(importTask != nil)
                        .accessibilityIdentifier("clipy.workflow.import")
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
            TextField(text("Search workflows"), text: $workspace.query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("clipy.workflow.search")
            Picker(text("Show workflows"), selection: $workspace.filter) {
                ForEach(BuiltInAutomationFilter.allCases, id: \.self) { Text(text($0.title)).tag($0) }
            }
            .labelsHidden()
            .accessibilityIdentifier("clipy.workflow.filter")
            Text(text(workspace.canReorder
                      ? "Saved automatic workflows run in this order. Drag to change priority."
                      : "Clear filters to change execution order."))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(visibleDrafts) { draft in
                        sidebarRow(draft, index: drafts.firstIndex(where: { $0.id == draft.id }) ?? 0)
                    }
                    if visibleDrafts.isEmpty {
                        Text(text("No matching workflows")).foregroundStyle(.secondary).padding(.vertical)
                        Button(text("Clear filters")) { workspace.query = ""; workspace.filter = .all }
                    }
                    Color.clear.frame(height: 20)
                        .dropDestination(for: String.self, isEnabled: true) { values, _ in _ = reorderWorkflow(values.first, before: nil) }
                }
            }
            .accessibilityIdentifier("clipy.workflow.sidebar")
            Toggle(text("Compact list"), isOn: $compactRows).toggleStyle(.checkbox)
                .accessibilityIdentifier("clipy.workflow.compact")
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
                        if workspace.isDirty(draft) || stepEditorState.hasUnappliedChanges(for: draft.id) {
                            Image(systemName: "circle.fill").font(.system(size: 5))
                                .accessibilityLabel(text("Unsaved changes"))
                        }
                    }
                    if !compactRows {
                        Text(text(draft.trigger.title)).font(.caption).foregroundStyle(.secondary)
                        if stepEditorState.hasUnappliedChanges(for: draft.id) {
                            Text(WorkflowSyntaxCopy.text("Unapplied rule text", bundle: copyBundle))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if let saved = library.workflows.first(where: { $0.id == draft.id }), saved.trigger.includesAutomatic {
                            Label(text("Automatic version saved"), systemImage: "bolt.fill")
                                .font(.caption2).foregroundStyle(.secondary)
                        } else if draft.trigger.includesAutomatic {
                            Text(text("Save to enable automatic runs")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(9)
            .contentShape(Rectangle())
            .background(workflow.id == draft.id ? Color.accentColor.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(workflow.id == draft.id ? .isSelected : [])
        .accessibilityIdentifier("clipy.workflow.row." + draft.id.uuidString)
        .draggable("workflow:" + draft.id.uuidString)
        .dropDestination(for: String.self, isEnabled: true) { values, _ in _ = reorderWorkflow(values.first, before: draft.id) }
        .contextMenu {
            Button(text("Duplicate workflow")) { duplicate(draft) }
                .disabled(stepEditorState.hasUnappliedChanges(for: draft.id))
            Button(text("Move workflow up")) { moveWorkflow(draft.id, by: -1) }.disabled(index == 0 || !workspace.canReorder)
            Button(text("Move workflow down")) { moveWorkflow(draft.id, by: 1) }.disabled(index == drafts.count - 1 || !workspace.canReorder)
            Divider()
            Button(text("Delete workflow"), role: .destructive) { requestRemoval(draft.id) }
        }
    }

    private var editorHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(text("Workflow name"), text: $workspace.workflow.name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("clipy.workflow.name")
                Button(text("Save workflow")) { save() }
                    .disabled(!isDirty || library.failure != nil || hasUnappliedRules)
                    .keyboardShortcut("s", modifiers: .command)
                    .accessibilityIdentifier("clipy.workflow.save")
                Menu {
                    Button(text("Duplicate workflow")) { duplicate(workflow) }
                        .disabled(hasUnappliedRules)
                    Button(text("Export workflow…")) { exportWorkflow() }
                        .disabled(hasUnappliedRules)
                        .accessibilityIdentifier("clipy.workflow.export")
                    Button(text("Save all changes")) { save(all: true) }
                        .disabled(!workspace.hasUnsavedChanges || library.failure != nil || stepEditorState.hasUnappliedChanges)
                    Button(text("Revert changes")) {
                        let id = workflow.id
                        do {
                            try workspace.discardSelection(preservingDraftIDs: stepEditorState.unappliedWorkflowIDs)
                            stepEditorState.discard(id)
                            invalidatePreview()
                        }
                        catch { saveMessage = (BuiltInAutomationFailure.unreadableWorkflows.message) }
                    }
                        .disabled(!isDirty && !hasUnappliedRules)
                    Divider()
                    Button(text("Move workflow up")) { moveWorkflow(workflow.id, by: -1) }
                        .disabled(drafts.first?.id == workflow.id || !workspace.canReorder)
                    Button(text("Move workflow down")) { moveWorkflow(workflow.id, by: 1) }
                        .disabled(drafts.last?.id == workflow.id || !workspace.canReorder)
                    Divider()
                    Button(text("Delete workflow"), role: .destructive) { requestRemoval(workflow.id) }
                } label: { Image(systemName: "ellipsis") }
                .menuIndicator(.hidden)
                .accessibilityLabel(text("Workflow actions"))
                .accessibilityIdentifier("clipy.workflow.actions")
            }
            Text(saveMessage ?? text(isDirty ? "Unsaved changes" : "Saved"))
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("clipy.workflow.save-status")
            if hasUnappliedRules {
                Label(text("Apply or discard rule text changes before saving, running or exporting this workflow."),
                      systemImage: "pencil.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("clipy.workflow.unapplied-rules")
            }
            if !workflow.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let failure = definitionFailure {
                Label(text(failure.message), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("clipy.workflow.validation")
            }
        }
        .padding(14)
    }

    private var definitionArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(text("Workflow configuration"), selection: $editsScope) {
                Text(text("Steps")).tag(false)
                    .accessibilityIdentifier("clipy.workflow.configuration.steps")
                Text(text("Trigger and scope")).tag(true)
                    .accessibilityIdentifier("clipy.workflow.configuration.scope")
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("clipy.workflow.configuration")
            if editsScope {
                ScrollView { scopeControls.padding(2) }
            } else {
                ScrollView {
                    WorkflowStepsWorkspaceEditor(workflowID: workflow.id, steps: $workspace.workflow.steps,
                                                 state: stepEditorState, bundle: copyBundle)
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
            Picker(text("Trigger"), selection: $workspace.workflow.trigger) {
                ForEach(BuiltInAutomationTrigger.allCases, id: \.self) { Text(text($0.title)).tag($0) }
            }
            .accessibilityIdentifier("clipy.workflow.trigger")
            Picker(text("Manual input"), selection: $workspace.workflow.scope.source) {
                ForEach(BuiltInAutomationScope.Source.allCases, id: \.self) { Text(text($0.title)).tag($0) }
            }
            .disabled(apply != nil)
            .accessibilityIdentifier("clipy.workflow.scope")
            Text(text(workflow.scope.source == .history
                      ? "Checks a bounded range of history in its current order. No history item is changed."
                      : "Manual input has no recorded source application or copy time."))
                .font(.caption).foregroundStyle(.secondary)
            if workflow.scope.source == .history {
                Stepper(value: $workspace.workflow.scope.historyLimit, in: 1...1000) {
                    Text(text("History items to check") + ": \(workflow.scope.historyLimit)")
                }
                .accessibilityIdentifier("clipy.workflow.history-limit")
            }
            DisclosureGroup(isExpanded: $showsFilters) {
                scopeFilters.padding(.top, 8)
            } label: {
                Label(text("Source and time filters"), systemImage: "line.3.horizontal.decrease")
            }
            .disclosureGroupStyle(AppDisclosureGroupStyle(identifier: "clipy.workflow.scope.filters"))
            if !workflow.scope.applicationIDs.isEmpty || workflow.scope.timeRange != .any {
                HStack {
                    Text(text("Source or time filters are active")).font(.caption)
                    Spacer()
                    Button(text("Clear filters")) {
                        workspace.workflow.scope.applications = ""
                        workspace.workflow.scope.timeRange = .any
                    }
                }
                if workflow.scope.source != .history {
                    Label(text("These filters only match recorded copies. Manual preview will not match this input."),
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(text("Automatic runs check new copies only, never existing history. Save the workflow to enable automatic runs. Source and time filters need a recorded copy; untracked manual input will not match these filters."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var scopeFilters: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(text("Source applications"))
                Spacer()
                Button(text("Choose Applications…")) { choosesApplications = true }
                    .accessibilityIdentifier("clipy.workflow.choose-applications")
            }
            TextField(text("Source apps (bundle IDs, comma separated; empty means all)"), text: $workspace.workflow.scope.applications)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("clipy.workflow.source-apps")
            Picker(text("Copy time"), selection: $workspace.workflow.scope.timeRange) {
                ForEach(BuiltInAutomationScope.TimeRange.allCases, id: \.self) { Text(text($0.title)).tag($0) }
            }
            .accessibilityIdentifier("clipy.workflow.time-range")
            if workflow.scope.timeRange == .custom {
                DatePicker(text("From"), selection: $workspace.workflow.scope.startDate)
                DatePicker(text("Through"), selection: $workspace.workflow.scope.endDate)
            }
            if !workflow.scope.validTimeRange {
                Label(text("Choose an end date on or after the start date."), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var comparisonArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker(text("Preview display"), selection: $comparisonMode) {
                    ForEach(ComparisonMode.allCases, id: \.self) { Text(text($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                .accessibilityIdentifier("clipy.workflow.display")
                Spacer()
                if let output = model.output, output.matchedConditions {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(output.value.byteCount), countStyle: .binary))
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel(text("Result size"))
                }
            }
            HStack(alignment: .top, spacing: 12) {
                if comparisonMode != .result {
                    comparisonColumn(label: showsManualInput && apply == nil ? "Test text" : "Before", original: true)
                }
                if comparisonMode != .input {
                    comparisonColumn(label: "After", original: false)
                }
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
                    text: original && showsManualInput && apply == nil ? $workspace.source : .constant(value?.text ?? ""),
                    accessibilityLabel: text(label),
                    isEditable: original && showsManualInput && apply == nil,
                    accessibilityIdentifier: original ? "clipy.workflow.source" : "clipy.workflow.result"
                )
                .overlay(alignment: .topLeading) {
                    if !original && model.output == nil {
                        Text(text(isBusy ? "Preparing result…" : "Preview to see the result here."))
                            .font(.callout).foregroundStyle(.secondary).padding(12)
                            .allowsHitTesting(false)
                    }
                }
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
                    Button(text("Cancel preview")) { model.cancel() }
                } else {
                    Button(text("Preview result")) { run(effects: false) }
                        .disabled(!canRun).accessibilityIdentifier("clipy.workflow.preview")
                        .keyboardShortcut("r", modifiers: .command)
                    Button(text("Run workflow")) { run(effects: true) }
                        .disabled(!canRun || !workflow.trigger.includesManual)
                        .accessibilityIdentifier("clipy.workflow.run")
                }
                Spacer()
                if apply != nil {
                    Button(text("Apply to draft")) {
                        guard canApply, let result = model.result else { return }
                        pendingApply = result
                        if hasChangesToKeep { confirmsClose = true }
                        else { finishClosing() }
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
                            executionMessage = "Result copied."
                        } catch { inputFailure = error as? BuiltInAutomationFailure }
                    }
                    .disabled(model.output?.matchedConditions != true || isBusy || !isCurrent || hasUnappliedRules)
                    .accessibilityIdentifier("clipy.workflow.copy")
                }
            }
            Text(text(apply != nil
                      ? "Apply changes the draft only. Save Revision in the editor to keep the result. Original content and earlier revisions remain available."
                      : "Preview never sends notifications. Run executes the selected branches and their notifications."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !workflow.steps.contains(where: \.enabled) {
                Text(text("Enable or add a step to preview this workflow.")).font(.caption).foregroundStyle(.secondary)
            } else if !workflow.trigger.includesManual {
                Text(text("Manual Run is off for this trigger. Preview is still available."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    @ViewBuilder private var executionStatus: some View {
        if let failure = inputFailure ?? model.failure {
            Label(text(failure.message), systemImage: "exclamationmark.triangle")
                .accessibilityIdentifier("clipy.workflow.error")
        } else if let executionMessage {
            Text(text(executionMessage)).foregroundStyle(.secondary)
        } else if model.isCancelled {
            Label(text("Cancelled. No result was applied."), systemImage: "stop.circle")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("clipy.workflow.cancelled")
        } else if model.output?.matchedConditions == false {
            Text(text("Conditions did not match. No notification was sent.")).foregroundStyle(.secondary)
        } else if let output = model.output {
            Label(text(lastRunUsedEffects ? "Workflow finished." : "Preview ready. No notification was sent."), systemImage: "checkmark.circle")
                .accessibilityIdentifier(containsConditions(workflow.steps)
                                         ? "clipy.workflow.conditions-matched" : "clipy.workflow.completed")
            if output.value == originalInput {
                Text(text("The result is unchanged.")).font(.caption).foregroundStyle(.secondary)
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
        guard canRun else { return }
        executionMessage = nil
        inputFailure = nil
        lastRunUsedEffects = effects
        model.preview(input: input, steps: workflow.steps, runEffects: effects,
                      workflow: apply == nil ? workflow : nil, history: history, notificationName: workflow.name)
    }

    private func invalidatePreview() {
        model.invalidate()
        inputFailure = nil
        executionMessage = nil
    }

    private func select(_ id: UUID) {
        guard id != workflow.id else { return }
        invalidatePreview()
        workspace.select(id)
    }

    private func add(_ value: BuiltInAutomationWorkflow) {
        invalidatePreview()
        workspace.add(value)
        editsScope = false
    }

    private func duplicate(_ value: BuiltInAutomationWorkflow) {
        guard !stepEditorState.hasUnappliedChanges(for: value.id) else { return }
        let name = value.name.isEmpty ? text("Untitled workflow") : value.name
        add(value.duplicated(named: name + " " + text("copy")))
        saveMessage = ("Copy created as a manual workflow. Save it when ready.")
    }

    private func exportWorkflow() {
        guard !hasUnappliedRules else { return }
        do {
            exportDocument = BuiltInAutomationFileDocument(data: try BuiltInAutomationTransfer.export(workflow))
            exportsWorkflow = true
        } catch {
            saveMessage = ((error as? BuiltInAutomationTransfer.Failure)?.message
                               ?? "The workflow could not be exported. Try another location.")
        }
    }

    private func importWorkflow(from url: URL) {
        guard importTask == nil else { return }
        saveMessage = nil
        let maximumBytes = BuiltInAutomationTransfer.maximumFileBytes
        importTask = Task {
            defer { importTask = nil }
            do {
                let reader = Task.detached(priority: .userInitiated) {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    return try BuiltInAutomationTransfer.read(url, maximumBytes: maximumBytes)
                }
                let data = try await withTaskCancellationHandler {
                    try await reader.value
                } onCancel: {
                    reader.cancel()
                }
                try Task.checkCancellation()
                importedWorkflow = try BuiltInAutomationTransfer.decode(data)
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                saveMessage = ((error as? BuiltInAutomationTransfer.Failure)?.message
                                   ?? BuiltInAutomationTransfer.Failure.unreadable.message)
            }
        }
    }

    private func save(all: Bool = false, close: Bool = false) {
        guard all ? !stepEditorState.hasUnappliedChanges : !hasUnappliedRules else { return }
        do {
            if all {
                try workspace.saveAll(preservingDraftIDs: stepEditorState.unappliedWorkflowIDs)
            } else {
                try workspace.saveSelection(preservingDraftIDs: stepEditorState.unappliedWorkflowIDs)
            }
            saveMessage = ("Workflow saved. Source and preview text are never saved with it.")
            if close { finishClosing() }
        } catch {
            saveMessage = ((error as? BuiltInAutomationFailure)?.message ?? BuiltInAutomationFailure.invalidWorkflow.message)
        }
    }

    private func requestClose() {
        pendingApply = nil
        if hasChangesToKeep { confirmsClose = true }
        else { dismiss() }
    }

    private func finishClosing() {
        if let pendingApply { apply?(pendingApply) }
        pendingApply = nil
        dismiss()
    }

    private func requestRemoval(_ id: UUID) {
        guard let target = drafts.first(where: { $0.id == id }) else { return }
        if library.workflows.contains(where: { $0.id == id }) || workspace.changedDrafts.contains(where: { $0.id == id })
            || stepEditorState.hasUnappliedChanges(for: id) {
            deletionTarget = target
            confirmsDeletion = true
        } else { remove(id) }
    }

    private func remove(_ id: UUID) {
        do {
            try workspace.remove(id, preservingDraftIDs: stepEditorState.unappliedWorkflowIDs)
            stepEditorState.forget(id)
            invalidatePreview()
        } catch { saveMessage = (BuiltInAutomationFailure.unreadableWorkflows.message) }
    }

    private func moveWorkflow(_ id: UUID, by offset: Int) {
        guard let index = drafts.firstIndex(where: { $0.id == id }), drafts.indices.contains(index + offset) else { return }
        let target = offset < 0 ? drafts[index - 1].id : (index + 2 < drafts.count ? drafts[index + 2].id : nil)
        _ = reorderWorkflow("workflow:" + id.uuidString, before: target)
    }

    private func reorderWorkflow(_ payload: String?, before target: UUID?) -> Bool {
        guard workspace.canReorder, let payload, payload.hasPrefix("workflow:"),
              let id = UUID(uuidString: String(payload.dropFirst(9))),
              id != target, drafts.contains(where: { $0.id == id }) else { return false }
        do {
            try workspace.move(id, before: target, preservingDraftIDs: stepEditorState.unappliedWorkflowIDs)
            return true
        }
        catch { saveMessage = (BuiltInAutomationFailure.unreadableWorkflows.message); return false }
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
