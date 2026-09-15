import SwiftUI
import UniformTypeIdentifiers
import HistoryCore

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
    @State private var usesImageInput = false
    @State private var imageData: Data?
    @State private var choosesImage = false
    @State private var inputFailure: BuiltInAutomationFailure?
    @State private var executionMessage: String?
    @State private var imageLoadTask: Task<Void, Never>?
    @State private var imageLoadGeneration = UUID()
    @State private var isLoadingImage = false
    private let history: (any ClipboardHistory)?
    private let apply: (@MainActor (String) -> Void)?

    init(source: String = "", history: (any ClipboardHistory)? = nil, apply: (@MainActor (String) -> Void)? = nil) {
        _source = State(initialValue: source)
        self.history = history
        self.apply = apply
    }

    private var copyBundle: Bundle { PanelActionsCopy.bundle(for: locale) }
    private func text(_ key: String) -> String { BuiltInAutomationCopy.text(key, bundle: copyBundle) }
    private var input: BuiltInAutomationInput {
        usesImageInput ? .image(imageData ?? Data()) : .text(source)
    }
    private var resultUnchanged: Bool { model.output?.value == input }
    private var isCurrent: Bool { model.isCurrent(input: input, steps: workflow.steps) }
    private var canRun: Bool {
        !isLoadingImage && (apply == nil && workflow.scope.source != .input || !usesImageInput || imageData != nil)
            && workflow.steps.contains(where: \.enabled)
    }
    private var canApply: Bool {
        model.output?.matchedConditions == true && model.result != nil && model.result?.isEmpty == false && !resultUnchanged
            && !model.isRunning && isCurrent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(text("Workflows")).font(.title2.weight(.semibold))
                Spacer()
                Menu(text("Load workflow")) {
                    ForEach(BuiltInAutomationWorkflow.presets) { preset in
                        Button(text(preset.name)) {
                            load(preset)
                            workflow.name = text(preset.name)
                        }
                    }
                    if !library.workflows.isEmpty {
                        Divider()
                        ForEach(library.workflows) { saved in
                            Button(saved.name) { load(saved) }
                        }
                    }
                }
            }
            Text(text("Conditions decide whether the workflow continues. A notification is sent only when all enabled conditions match. Preview never sends notifications."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if apply == nil {
                        scopeControls
                        if workflow.scope.source != .history { inputControls }
                    }
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
                    if let output = model.output, output.matchedItemCount > 1 {
                        Text("\(output.matchedItemCount) " + text("items matched. Showing the first result; Copy result copies only this result."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let executionMessage { Text(executionMessage).font(.callout).foregroundStyle(.secondary) }
                    if let failure = inputFailure ?? model.failure {
                        Label(text(failure.message), systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .accessibilityIdentifier("clipy.workflow.error")
                    }
                    if model.output?.matchedConditions == false {
                        Text(text("Conditions did not match. No notification was sent."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if resultUnchanged && model.output?.matchedConditions == true {
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
                    Button(text("Preview result")) {
                        executionMessage = nil
                        model.preview(input: input, steps: workflow.steps,
                                      workflow: apply == nil ? workflow : nil, history: history, notificationName: workflow.name)
                    }
                        .disabled(!canRun)
                        .accessibilityIdentifier("clipy.workflow.preview")
                }
                if !model.isRunning {
                    Button(text("Run workflow")) {
                        executionMessage = nil
                        model.preview(input: input, steps: workflow.steps, runEffects: true,
                                      workflow: apply == nil ? workflow : nil, history: history, notificationName: workflow.name)
                    }
                    .disabled(!canRun || !workflow.trigger.includesManual)
                    .accessibilityIdentifier("clipy.workflow.run")
                }
                Spacer()
                if apply == nil {
                    Button(text("Copy result")) {
                        guard isCurrent, let output = model.output else { return }
                        do {
                            try BuiltInAutomationClipboard.copy(output.value)
                            executionMessage = text("Result copied.")
                        } catch { inputFailure = error as? BuiltInAutomationFailure }
                    }
                    .disabled(model.output?.matchedConditions != true || model.isRunning || !isCurrent)
                    .accessibilityIdentifier("clipy.workflow.copy")
                }
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
        .onChange(of: workflow.steps) { _, _ in invalidatePreview() }
        .onChange(of: workflow.scope) { _, _ in invalidatePreview() }
        .onChange(of: workflow.trigger) { _, _ in invalidatePreview() }
        .onChange(of: source) { _, _ in invalidatePreview() }
        .onChange(of: usesImageInput) { _, _ in
            cancelImageLoad()
            invalidatePreview()
        }
        .onChange(of: imageData) { _, _ in invalidatePreview() }
        .onDisappear { model.invalidate(); cancelImageLoad() }
        .fileImporter(isPresented: $choosesImage, allowedContentTypes: [.png, .jpeg, .tiff, .heic]) { result in
            switch result {
            case let .success(url): loadImage(url)
            case .failure: inputFailure = .invalidImage
            }
        }
        .confirmationDialog(text("Reset saved workflows?"), isPresented: $confirmsReset) {
            Button(text("Reset saved workflows"), role: .destructive) { library.reset() }
        } message: { Text(text("This removes saved workflow definitions. Clipboard history is unchanged.")) }
    }

    private var scopeControls: some View {
        DisclosureGroup(text("Trigger and scope")) {
            VStack(alignment: .leading, spacing: 10) {
                Picker(text("Trigger"), selection: $workflow.trigger) {
                    ForEach(BuiltInAutomationTrigger.allCases, id: \.self) { Text(text($0.title)).tag($0) }
                }
                .accessibilityIdentifier("clipy.workflow.trigger")
                Picker(text("Manual input"), selection: $workflow.scope.source) {
                    ForEach(BuiltInAutomationScope.Source.allCases, id: \.self) { Text(text($0.title)).tag($0) }
                }
                .accessibilityIdentifier("clipy.workflow.scope")
                TextField(text("Source apps (bundle IDs, comma separated; empty means all)"), text: $workflow.scope.applications)
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
            .padding(.top, 8)
        }
    }

    private var inputControls: some View {
        HStack {
            Picker(text("Input type"), selection: $usesImageInput) {
                Text(text("Text")).tag(false)
                Text(text("Image")).tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            .accessibilityIdentifier("clipy.workflow.input-type")
            Button(text("Read Clipboard")) {
                cancelImageLoad()
                do {
                    let value = try BuiltInAutomationClipboard.read(image: usesImageInput)
                    inputFailure = nil
                    switch value {
                    case let .text(text): source = text
                    case let .image(data): imageData = data
                    }
                } catch { inputFailure = error as? BuiltInAutomationFailure }
            }
            .accessibilityIdentifier("clipy.workflow.read-clipboard")
            if usesImageInput {
                Button(text("Choose Image…")) { choosesImage = true }
                if isLoadingImage { ProgressView().controlSize(.small) }
            }
            Spacer()
        }
    }

    @ViewBuilder private func imagePreview(_ data: Data?) -> some View {
        if let data, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(text("Image input"))
        } else {
            ContentUnavailableView(text("Choose an image"), systemImage: "photo")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load(_ saved: BuiltInAutomationWorkflow) {
        workflow = saved
        saveMessage = nil
        if apply == nil {
            usesImageInput = saved.steps.contains { $0.enabled && $0.operation == .requireImage }
        }
    }

    private func invalidatePreview() {
        model.invalidate()
        inputFailure = nil
        executionMessage = nil
    }

    private func cancelImageLoad() {
        imageLoadGeneration = UUID()
        imageLoadTask?.cancel()
        imageLoadTask = nil
        isLoadingImage = false
    }

    private func loadImage(_ url: URL) {
        cancelImageLoad()
        invalidatePreview()
        let generation = imageLoadGeneration
        isLoadingImage = true
        let read = Task.detached(priority: .userInitiated) {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= BuiltInAutomation.maximumImageBytes else { throw BuiltInAutomationFailure.imageTooLarge }
            try Task.checkCancellation()
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            try BuiltInAutomation.validateImage(data)
            try Task.checkCancellation()
            return data
        }
        imageLoadTask = Task {
            do {
                let data = try await withTaskCancellationHandler {
                    try await read.value
                } onCancel: { read.cancel() }
                guard !Task.isCancelled, imageLoadGeneration == generation else { return }
                imageData = data
            } catch {
                guard !Task.isCancelled, imageLoadGeneration == generation else { return }
                inputFailure = (error as? BuiltInAutomationFailure) ?? .invalidImage
            }
            isLoadingImage = false
            imageLoadTask = nil
        }
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
                            if [.replace, .regexReplace, .regexExtract, .containsText, .matchesRegex].contains(step.operation) {
                                HStack {
                                    TextField(text([.replace, .containsText].contains(step.operation) ? "Find (literal text)" : "Regular expression"), text: binding.find)
                                    if [.replace, .regexReplace].contains(step.operation) {
                                        TextField(text("Replace with"), text: binding.replacement)
                                    }
                                }
                                .disabled(!step.enabled)
                                if [.regexReplace, .regexExtract, .matchesRegex].contains(step.operation) {
                                    Text(text("ICU regular expressions. Replacement uses $0 for the full match and $1, $2 for groups. Extraction joins full matches with newlines."))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if step.operation == .notify {
                                Text(text("Notifies only when all enabled conditions match. Clipboard content is never included."))
                                    .font(.caption).foregroundStyle(.secondary)
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
                if apply == nil && workflow.scope.source == .history {
                    Text(text("Checks the selected range in history order. Source and time filters use each item's most recent copy."))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if usesImageInput {
                    imagePreview(imageData)
                } else if apply == nil {
                    BuiltInAutomationSourceEditor(text: $source, accessibilityLabel: text("Test text"))
                } else { previewText(source, label: text("Before")) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(text("After")).font(.headline)
                if case let .image(data) = model.output?.value {
                    imagePreview(data)
                } else {
                    previewText(model.result ?? text("Run a preview to see the result here."), label: text("After"))
                }
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
    var history: (any ClipboardHistory)? = nil
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
            Button(text("Manage workflows…")) { showsWorkflows = true }
                .accessibilityIdentifier("clipy.settings.workflows.manage")
        }
        .sheet(isPresented: $showsWorkflows) { BuiltInAutomationView(history: history) }
    }
}
