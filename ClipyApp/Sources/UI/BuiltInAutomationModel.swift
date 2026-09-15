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
        guard workflow.steps.count <= BuiltInAutomation.maximumSteps else {
            throw BuiltInAutomationFailure.tooManySteps
        }
        guard workflow.name.utf8.count <= 200 else { throw BuiltInAutomationFailure.definitionTooLarge }
        guard (1...1000).contains(workflow.scope.historyLimit), workflow.scope.validTimeRange else {
            throw BuiltInAutomationFailure.invalidScope
        }
        let enabled = workflow.steps.filter(\.enabled)
        if enabled.contains(where: { $0.operation == .notify }),
           !enabled.contains(where: { [.requireText, .requireImage, .containsText, .matchesRegex].contains($0.operation) }) {
            throw BuiltInAutomationFailure.notificationNeedsCondition
        }
        for step in workflow.steps {
            guard step.find.utf8.count <= 16_384, step.replacement.utf8.count <= 16_384 else {
                throw BuiltInAutomationFailure.definitionTooLarge
            }
            if step.enabled && step.operation == .replace && step.find.isEmpty {
                throw BuiltInAutomationFailure.emptyFind
            }
            if step.enabled && ([.regexReplace, .regexExtract, .matchesRegex].contains(step.operation)) {
                guard !step.find.isEmpty, (try? NSRegularExpression(pattern: step.find)) != nil else {
                    throw BuiltInAutomationFailure.invalidRegex
                }
            }
        }
    }
}

@MainActor @Observable
final class BuiltInAutomationModel {
    private(set) var output: BuiltInAutomationOutput?
    var result: String? { output?.matchedConditions == true ? output?.value.text : nil }
    @ObservationIgnored private let notify: @Sendable () async throws -> Void

    init(notify: @escaping @Sendable () async throws -> Void = BuiltInAutomationNotifications.send) {
        self.notify = notify
    }
    private(set) var failure: BuiltInAutomationFailure?
    private(set) var isRunning = false
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

    func invalidate() {
        generation = UUID()
        task?.cancel()
        task = nil
        isRunning = false
        output = nil
        failure = nil
        previewSource = nil
        previewSteps = nil
    }

    func preview(source: String, steps: [BuiltInAutomationStep]) {
        preview(input: .text(source), steps: steps)
    }

    func preview(input: BuiltInAutomationInput, steps: [BuiltInAutomationStep], runEffects: Bool = false,
                 workflow: BuiltInAutomationWorkflow? = nil, history: (any ClipboardHistory)? = nil) {
        invalidate()
        let request = generation
        previewSource = input
        previewSteps = steps
        isRunning = true
        let computation = Task.detached(priority: .userInitiated) {
            if let workflow {
                try await BuiltInAutomation.evaluateManual(input: input, workflow: workflow, history: history)
            } else {
                try await BuiltInAutomation.run(input, steps: steps)
            }
        }
        task = Task { [weak self] in
            do {
                let value = try await withTaskCancellationHandler {
                    try await computation.value
                } onCancel: { computation.cancel() }
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.output = value
                if runEffects && value.matchedConditions && value.requestsNotification {
                    try await self.notify()
                    guard self.generation == request, !Task.isCancelled else { return }
                }
                self.isRunning = false
                self.task = nil
            } catch {
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.failure = (error as? BuiltInAutomationFailure) ?? .historyUnavailable
                self.isRunning = false
                self.task = nil
            }
        }
    }
}
