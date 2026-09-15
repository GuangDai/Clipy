import Foundation
import Observation
import HistoryCore

/// UserDefaults contains named step definitions only, never source or result
/// text. Invalid persisted definitions stay untouched until an explicit reset.
@MainActor @Observable
final class BuiltInAutomationLibrary {
    static let defaultsKey = "builtInTextWorkflows"
    private(set) var workflows: [BuiltInAutomationWorkflow] = []
    private(set) var failure: BuiltInAutomationFailure?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        do { workflows = try readCurrent() }
        catch { failure = .unreadableWorkflows }
    }

    func save(_ workflow: BuiltInAutomationWorkflow) throws {
        guard failure == nil else { throw BuiltInAutomationFailure.unreadableWorkflows }
        var normalized = workflow
        normalized.name = normalized.name.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.validate(normalized)
        var updated = try readCurrent()
        if let index = updated.firstIndex(where: { $0.id == normalized.id }) {
            updated[index] = normalized
        } else {
            guard updated.count < 50 else { throw BuiltInAutomationFailure.workflowLimit }
            updated.append(normalized)
        }
        try persist(updated)
    }

    func remove(_ id: UUID) throws {
        guard failure == nil else { throw BuiltInAutomationFailure.unreadableWorkflows }
        try persist(readCurrent().filter { $0.id != id })
    }

    func move(id: UUID, before destination: UUID?) throws {
        guard failure == nil else { throw BuiltInAutomationFailure.unreadableWorkflows }
        var updated = try readCurrent()
        guard id != destination, let source = updated.firstIndex(where: { $0.id == id }) else { return }
        if let destination, !updated.contains(where: { $0.id == destination }) { return }
        let workflow = updated.remove(at: source)
        let target = destination.flatMap { destination in updated.firstIndex(where: { $0.id == destination }) } ?? updated.endIndex
        updated.insert(workflow, at: target)
        try persist(updated)
    }

    func reset() {
        defaults.removeObject(forKey: Self.defaultsKey)
        workflows = []
        failure = nil
    }

    private func persist(_ updated: [BuiltInAutomationWorkflow]) throws {
        let data = try JSONEncoder().encode(updated)
        guard data.count <= 4 * BuiltInAutomation.maximumBytes else {
            throw BuiltInAutomationFailure.textTooLarge
        }
        defaults.set(data, forKey: Self.defaultsKey)
        workflows = updated
    }

    /// Multiple native windows can own independent libraries. Each mutation
    /// refreshes current definitions synchronously on the main actor so saving
    /// from an older window cannot erase another window's unrelated workflows.
    private func readCurrent() throws -> [BuiltInAutomationWorkflow] {
        do {
            guard let saved = defaults.object(forKey: Self.defaultsKey) else { return [] }
            guard let data = saved as? Data, data.count <= 4 * BuiltInAutomation.maximumBytes else {
                throw BuiltInAutomationFailure.unreadableWorkflows
            }
            let decoded = try JSONDecoder().decode([BuiltInAutomationWorkflow].self, from: data)
            guard decoded.count <= 50, Set(decoded.map(\.id)).count == decoded.count else {
                throw BuiltInAutomationFailure.unreadableWorkflows
            }
            for workflow in decoded { try Self.validate(workflow) }
            return decoded
        } catch {
            failure = .unreadableWorkflows
            throw BuiltInAutomationFailure.unreadableWorkflows
        }
    }

    private static func validate(_ workflow: BuiltInAutomationWorkflow) throws {
        guard !workflow.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !workflow.steps.isEmpty,
              Set(workflow.steps.map(\.id)).count == workflow.steps.count else {
            throw BuiltInAutomationFailure.invalidWorkflow
        }
        try BuiltInAutomation.validateStepTree(workflow.steps)
        guard workflow.name.utf8.count <= 200 else { throw BuiltInAutomationFailure.definitionTooLarge }
        guard (1...1000).contains(workflow.scope.historyLimit), workflow.scope.validTimeRange else {
            throw BuiltInAutomationFailure.invalidScope
        }
        try validateSteps(workflow.steps, insideCondition: false)
    }

    private static func validateSteps(_ steps: [BuiltInAutomationStep], insideCondition: Bool) throws {
        // Old flat workflows deferred effects until all their guards passed,
        // even when a notification appeared before a guard. Keep that behavior.
        var notificationAllowed = insideCondition || steps.contains {
            $0.enabled && [.requireText, .requireImage, .containsText, .matchesRegex].contains($0.operation)
        }
        for step in steps {
            guard step.find.utf8.count <= 16_384, step.replacement.utf8.count <= 16_384 else {
                throw BuiltInAutomationFailure.definitionTooLarge
            }
            guard step.enabled else { continue }
            if step.operation == .replace && step.find.isEmpty { throw BuiltInAutomationFailure.emptyFind }
            if [.regexReplace, .regexExtract, .matchesRegex].contains(step.operation)
                || (step.operation == .conditional && step.condition == .matchesRegex) {
                guard !step.find.isEmpty, (try? NSRegularExpression(pattern: step.find)) != nil else {
                    throw BuiltInAutomationFailure.invalidRegex
                }
            }
            if [.requireText, .requireImage, .containsText, .matchesRegex].contains(step.operation) {
                notificationAllowed = true
            }
            if step.operation == .notify && !notificationAllowed {
                throw BuiltInAutomationFailure.notificationNeedsCondition
            }
            if step.operation == .conditional {
                try validateSteps(step.thenSteps, insideCondition: true)
                try validateSteps(step.otherwiseSteps, insideCondition: true)
            }
        }
    }
}

@MainActor @Observable
final class BuiltInAutomationModel {
    private(set) var output: BuiltInAutomationOutput?
    var result: String? { output?.matchedConditions == true ? output?.value.text : nil }
    @ObservationIgnored private let notify: @Sendable (String) async throws -> Void

    @ObservationIgnored let executionQueue: BuiltInAutomationExecutionQueue

    init(executionQueue: BuiltInAutomationExecutionQueue = .init(),
         notify: @escaping @Sendable (String) async throws -> Void = BuiltInAutomationNotifications.send) {
        self.executionQueue = executionQueue
        self.notify = notify
    }
    private(set) var failure: BuiltInAutomationFailure?
    private(set) var isRunning = false
    private(set) var isQueued = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var previewSource: BuiltInAutomationInput?
    @ObservationIgnored private var previewSteps: [BuiltInAutomationStep]?

    func isCurrent(source: String, steps: [BuiltInAutomationStep]) -> Bool {
        isCurrent(input: .text(source), steps: steps)
    }

    func isCurrent(input: BuiltInAutomationInput, steps: [BuiltInAutomationStep]) -> Bool {
        previewSource == input && previewSteps == steps
    }

    private func isCurrentRequest(_ request: UUID) -> Bool { generation == request }

    func invalidate() {
        generation = UUID()
        task?.cancel()
        task = nil
        isRunning = false
        isQueued = false
        output = nil
        failure = nil
        previewSource = nil
        previewSteps = nil
    }

    func preview(source: String, steps: [BuiltInAutomationStep]) {
        preview(input: .text(source), steps: steps)
    }

    func preview(input: BuiltInAutomationInput, steps: [BuiltInAutomationStep], runEffects: Bool = false,
                 workflow: BuiltInAutomationWorkflow? = nil, history: (any ClipboardHistory)? = nil,
                 notificationName: String = "") {
        invalidate()
        let request = generation
        previewSource = input
        previewSteps = steps
        // Read the current clipboard synchronously at the request boundary.
        // Waiting in the shared queue must not silently change this input.
        let capturedInput: BuiltInAutomationInput
        var capturedWorkflow = workflow
        do {
            if workflow?.scope.source == .clipboard {
                capturedInput = try BuiltInAutomationClipboard.read(image: BuiltInAutomation.prefersImage(steps))
                capturedWorkflow?.scope.source = .input
            } else { capturedInput = input }
        } catch {
            failure = (error as? BuiltInAutomationFailure) ?? .clipboardUnavailable
            return
        }
        let definition = capturedWorkflow
        let queue = executionQueue
        let sendNotification = notify
        isQueued = true
        task = Task { [weak self] in
            guard let model = self else { return }
            do {
                let value = try await queue.execute(retainedBytes: capturedInput.byteCount, onStart: { [weak self] in
                    guard let self, self.generation == request else { return }
                    self.isQueued = false
                    self.isRunning = true
                }) {
                    let value: BuiltInAutomationOutput
                    if let definition {
                        value = try await BuiltInAutomation.evaluateManual(input: capturedInput, workflow: definition, history: history)
                    } else {
                        value = try await BuiltInAutomation.run(capturedInput, steps: steps)
                    }
                    try Task.checkCancellation()
                    if runEffects && value.matchedConditions && value.requestsNotification {
                        guard await model.isCurrentRequest(request) else { throw CancellationError() }
                        try await sendNotification(workflow?.name ?? notificationName)
                        try Task.checkCancellation()
                    }
                    return value
                }
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.output = value
                self.isRunning = false
                self.isQueued = false
                self.task = nil
            } catch {
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.failure = (error as? BuiltInAutomationFailure) ?? .historyUnavailable
                self.isRunning = false
                self.isQueued = false
                self.task = nil
            }
        }
    }
}
