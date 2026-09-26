import Foundation
import Observation

enum WorkflowStepsDisplayMode: String, CaseIterable {
    case visual
    case syntax
}

/// One workflow window retains rule-text drafts independently of its selected
/// workflow or display mode. Only a successful explicit Apply changes steps.
/// Owning semantics: docs/v2/V2-13-workflow-rule-syntax.md.
@MainActor @Observable
final class WorkflowStepsEditorState {
    private var drafts: [UUID: WorkflowStepsEditorDraft] = [:]

    var hasUnappliedChanges: Bool { drafts.values.contains { $0.hasUnappliedChanges } }
    var unappliedWorkflowIDs: Set<UUID> {
        Set(drafts.compactMap { $0.value.hasUnappliedChanges ? $0.key : nil })
    }

    func hasUnappliedChanges(for workflowID: UUID) -> Bool {
        drafts[workflowID]?.hasUnappliedChanges ?? false
    }

    func draft(for workflowID: UUID) -> WorkflowStepsEditorDraft? { drafts[workflowID] }

    func prepare(_ workflowID: UUID, steps: [BuiltInAutomationStep]) {
        if let draft = drafts[workflowID] { draft.synchronize(with: steps) }
        else { drafts[workflowID] = WorkflowStepsEditorDraft(steps: steps) }
    }

    func discard(_ workflowID: UUID) { drafts[workflowID]?.discardSource() }
    func discardAll() { drafts.values.forEach { $0.discardSource() } }
    func forget(_ workflowID: UUID) { drafts.removeValue(forKey: workflowID)?.discardSource() }
}

@MainActor @Observable
final class WorkflowStepsEditorDraft {
    private(set) var mode: WorkflowStepsDisplayMode = .visual
    private(set) var source = ""
    private(set) var diagnostic: BuiltInAutomationSyntaxError?
    private(set) var diagnosticIsInSource = false
    private(set) var failureMessage: String?
    private(set) var isProcessing = false
    private(set) var didApplySource = false
    private(set) var renderRequest = 0

    private var currentSteps: [BuiltInAutomationStep]
    private var baselineSteps: [BuiltInAutomationStep]
    private var baselineSource: String?
    private var activeOperation: UUID?
    private var reloadRequested = false

    var hasUnappliedChanges: Bool {
        guard let baselineSource else { return !source.isEmpty }
        return !source.utf8.elementsEqual(baselineSource.utf8)
    }

    var hasVisualConflict: Bool { hasUnappliedChanges && currentSteps != baselineSteps }
    var hasPreparedSource: Bool { baselineSource != nil }

    init(steps: [BuiltInAutomationStep]) {
        currentSteps = steps
        baselineSteps = steps
    }

    func setMode(_ value: WorkflowStepsDisplayMode) {
        guard mode != value else { return }
        cancelProcessing()
        mode = value
        renderRequest += 1
    }

    func updateSource(_ value: String) {
        guard !source.utf8.elementsEqual(value.utf8) else { return }
        cancelProcessing()
        source = value
        diagnostic = nil
        failureMessage = nil
        didApplySource = false
    }

    func synchronize(with steps: [BuiltInAutomationStep]) {
        guard currentSteps != steps else { return }
        cancelProcessing()
        currentSteps = steps
        didApplySource = false
        renderRequest += 1
    }

    func requestReload() {
        reloadRequested = true
        renderRequest += 1
    }

    /// The view-owned task cancels its detached formatter when changing mode,
    /// workflow or closing. Late formatting never replaces a newer text edit.
    func prepareSourceIfNeeded() async {
        guard mode == .syntax else { return }
        let force = reloadRequested
        reloadRequested = false
        guard force || (!hasUnappliedChanges && (baselineSource == nil || currentSteps != baselineSteps)) else { return }
        let steps = currentSteps
        let operationID = beginProcessing()
        let task = Task.detached(priority: .userInitiated) { try BuiltInAutomationSyntax.render(steps) }
        defer { finishProcessing(operationID) }
        do {
            let rendered = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard !Task.isCancelled, activeOperation == operationID, currentSteps == steps else { return }
            source = rendered
            baselineSource = rendered
            baselineSteps = steps
        } catch is CancellationError {
        } catch let error as BuiltInAutomationSyntaxError {
            if activeOperation == operationID { diagnostic = error }
        } catch {
            if activeOperation == operationID { failureMessage = "Rule text could not be prepared. Try again." }
        }
    }

    /// Parse returns a candidate only. The view replaces its live binding and
    /// acknowledges it in one MainActor turn after checking the visual input.
    func parseSource() async -> [BuiltInAutomationStep]? {
        guard hasUnappliedChanges else { return nil }
        let text = source
        let operationID = beginProcessing()
        let task = Task.detached(priority: .userInitiated) { try BuiltInAutomationSyntax.parse(text) }
        defer { finishProcessing(operationID) }
        do {
            let parsed = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard !Task.isCancelled, activeOperation == operationID,
                  source.utf8.elementsEqual(text.utf8) else { return nil }
            return parsed
        } catch is CancellationError {
        } catch let error as BuiltInAutomationSyntaxError {
            if activeOperation == operationID {
                diagnostic = error
                diagnosticIsInSource = true
            }
        } catch {
            if activeOperation == operationID { failureMessage = "Rule text could not be applied. Try again." }
        }
        return nil
    }

    func acceptApplied(_ steps: [BuiltInAutomationStep]) {
        currentSteps = steps
        baselineSteps = steps
        baselineSource = source
        diagnostic = nil
        failureMessage = nil
        didApplySource = true
    }

    func discardSource() {
        cancelProcessing()
        source = ""
        baselineSource = nil
        baselineSteps = currentSteps
        diagnostic = nil
        failureMessage = nil
        didApplySource = false
        reloadRequested = false
        mode = .visual
        renderRequest += 1
    }

    private func beginProcessing() -> UUID {
        let id = UUID()
        activeOperation = id
        isProcessing = true
        diagnostic = nil
        diagnosticIsInSource = false
        failureMessage = nil
        didApplySource = false
        return id
    }

    private func finishProcessing(_ id: UUID) {
        guard activeOperation == id else { return }
        activeOperation = nil
        isProcessing = false
    }

    private func cancelProcessing() {
        activeOperation = nil
        isProcessing = false
    }
}

/// Parser columns count Characters. Convert its one-based location to a
/// native UTF-16 selection without splitting a surrogate pair or grapheme.
enum WorkflowSyntaxLocation {
    static func selection(in source: String, line: Int, column: Int) -> NSRange {
        let lines = source.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
        guard !lines.isEmpty else { return NSRange(location: 0, length: 0) }
        let target = lines[min(max(0, line - 1), lines.count - 1)]
        let index = target.index(target.startIndex, offsetBy: max(0, column - 1), limitedBy: target.endIndex)
            ?? target.endIndex
        let end = index < target.endIndex ? target.index(after: index) : index
        return NSRange(index..<end, in: source)
    }
}
