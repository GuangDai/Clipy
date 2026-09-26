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
        catch is CancellationError { }
        catch { failure = .unreadableWorkflows }
    }

    func save(_ workflow: BuiltInAutomationWorkflow, orderedIDs: [UUID] = []) throws {
        try saveAll([workflow], orderedIDs: orderedIDs)
    }

    /// Revert needs the latest saved definition, including another window's
    /// edit or deletion. A failed read leaves the last readable snapshot intact.
    func refresh() throws {
        let current = try readCurrent()
        workflows = current
        failure = nil
    }

    /// Save only the supplied drafts, together with their visible priority, in
    /// one preferences write. Other windows' unrelated definitions are retained.
    func saveAll(_ drafts: [BuiltInAutomationWorkflow], orderedIDs: [UUID] = []) throws {
        guard failure == nil else { throw BuiltInAutomationFailure.unreadableWorkflows }
        guard Set(drafts.map(\.id)).count == drafts.count,
              Set(orderedIDs).count == orderedIDs.count else {
            throw BuiltInAutomationFailure.invalidWorkflow
        }
        let normalized = try drafts.map { draft in
            var workflow = draft
            workflow.name = workflow.name.trimmingCharacters(in: .whitespacesAndNewlines)
            try Self.validate(workflow)
            return workflow
        }
        var updated = try readCurrent()
        for workflow in normalized {
            if let index = updated.firstIndex(where: { $0.id == workflow.id }) {
                updated[index] = workflow
            } else {
                updated.append(workflow)
            }
        }
        guard updated.count <= 50 else { throw BuiltInAutomationFailure.workflowLimit }
        // Reorder just this window's known definitions in their existing slots.
        // Unknown drafts are not implicitly saved and other windows' additions
        // keep their relative placement and exact definitions.
        let order = Set(orderedIDs)
        let slots = updated.indices.filter { order.contains(updated[$0].id) }
        let byID = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })
        let ordered = orderedIDs.compactMap { byID[$0] }
        for (slot, workflow) in zip(slots, ordered) {
            updated[slot] = workflow
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
        let data: Data
        do { data = try JSONEncoder().encode(updated) }
        catch {
            if let failure = BuiltInAutomation.definitionNestingFailure(for: error) { throw failure }
            throw error
        }
        guard data.count <= 4 * BuiltInAutomation.maximumBytes else {
            throw BuiltInAutomationFailure.textTooLarge
        }
        // Validate the actual bytes with the same reader a fresh library and
        // automatic execution use. Foundation's encoding and decoding nesting
        // limits need not be identical; a failed draft never replaces saved data.
        do { _ = try Self.decodeDefinitions(data) }
        catch {
            if let failure = BuiltInAutomation.definitionNestingFailure(for: error) { throw failure }
            throw error
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
            guard let data = saved as? Data else {
                throw BuiltInAutomationFailure.unreadableWorkflows
            }
            return try Self.decodeDefinitions(data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            failure = .unreadableWorkflows
            throw BuiltInAutomationFailure.unreadableWorkflows
        }
    }

    /// The automatic runner validates the same exact saved bytes as an editor,
    /// without constructing an observable library for every captured copy.
    static func decodeDefinitions(_ data: Data) throws -> [BuiltInAutomationWorkflow] {
        guard data.count <= 4 * BuiltInAutomation.maximumBytes else {
            throw BuiltInAutomationFailure.unreadableWorkflows
        }
        let decoded = try JSONDecoder().decode([BuiltInAutomationWorkflow].self, from: data)
        guard decoded.count <= 50, Set(decoded.map(\.id)).count == decoded.count else {
            throw BuiltInAutomationFailure.unreadableWorkflows
        }
        for workflow in decoded { try validate(workflow) }
        return decoded
    }

    /// The editor uses the same definition checks as persistence, without
    /// writing preferences or running the workflow against test content.
    static func validationFailure(for workflow: BuiltInAutomationWorkflow) -> BuiltInAutomationFailure? {
        do {
            var normalized = workflow
            normalized.name = workflow.name.trimmingCharacters(in: .whitespacesAndNewlines)
            try validate(normalized)
            return nil
        } catch {
            return (error as? BuiltInAutomationFailure) ?? .invalidWorkflow
        }
    }

    private static func validate(_ workflow: BuiltInAutomationWorkflow) throws {
        guard !workflow.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !workflow.steps.isEmpty else {
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
        typealias ValidationFrame = (remaining: ArraySlice<BuiltInAutomationStep>, notificationAllowed: Bool)
        func frame(_ children: [BuiltInAutomationStep], insideCondition: Bool) -> ValidationFrame {
            // Flat notifications may precede their sibling guard, but cannot
            // borrow permission from an unrelated conditional branch.
            (children[...], insideCondition || children.contains {
                $0.enabled && [.requireText, .requireImage, .containsText, .matchesRegex].contains($0.operation)
            })
        }
        var pending = [frame(steps, insideCondition: insideCondition)]
        while var current = pending.popLast() {
            try Task.checkCancellation()
            guard let step = current.remaining.popFirst() else { continue }
            pending.append(current)
            guard step.find.utf8.count <= 16_384, step.replacement.utf8.count <= 16_384 else {
                throw BuiltInAutomationFailure.definitionTooLarge
            }
            guard step.enabled else { continue }
            if step.operation == .replace && step.find.isEmpty { throw BuiltInAutomationFailure.emptyFind }
            if [.regexReplace, .regexExtract, .matchesRegex].contains(step.operation) {
                guard !step.find.isEmpty, (try? NSRegularExpression(pattern: step.find)) != nil else {
                    throw BuiltInAutomationFailure.invalidRegex
                }
            }
            if step.operation == .notify && !current.notificationAllowed {
                throw BuiltInAutomationFailure.notificationNeedsCondition
            }
            if step.operation == .conditional {
                try step.effectivePredicate.validate()
                pending.append(frame(step.otherwiseSteps, insideCondition: true))
                pending.append(frame(step.thenSteps, insideCondition: true))
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
    private(set) var isCancelled = false
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

    private func recordNotificationFailure(_ failure: BuiltInAutomationFailure, request: UUID) {
        guard generation == request else { return }
        self.failure = failure
    }

    func cancel() {
        guard isRunning || isQueued else { return }
        invalidate()
        isCancelled = true
    }

    func invalidate() {
        generation = UUID()
        task?.cancel()
        task = nil
        isRunning = false
        isQueued = false
        isCancelled = false
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
                        do {
                            try await sendNotification(workflow?.name ?? notificationName)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            try Task.checkCancellation()
                            // Notification delivery is the final effect. Its
                            // failure does not discard the completed transform,
                            // so Copy/Apply do not require another computation.
                            await model.recordNotificationFailure(
                                (error as? BuiltInAutomationFailure) ?? .notificationFailed,
                                request: request
                            )
                        }
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
                if error is CancellationError { self.isCancelled = true }
                else { self.failure = (error as? BuiltInAutomationFailure) ?? .historyUnavailable }
                self.isRunning = false
                self.isQueued = false
                self.task = nil
            }
        }
    }
}
