import Foundation
import HistoryCore

extension BuiltInAutomation {
    /// Select one representation per original clipboard item. An OCR workflow
    /// prefers image bytes; ordinary text workflows prefer the exact text codec.
    static func inputs(
        from representations: [HistoryRepresentation], workflow: BuiltInAutomationWorkflow
    ) -> [BuiltInAutomationInput] {
        let imageFirst = prefersImage(workflow.steps)
        let groups = Dictionary(grouping: representations, by: \.pasteboardItemIndex)
        return groups.keys.sorted().compactMap { index in
            let values = groups[index] ?? []
            let image = values.first { ["public.png", "public.jpeg", "public.tiff", "public.heic"].contains($0.typeIdentifier) }
            if imageFirst, let image { return .image(image.bytes) }
            let text = values.lazy.compactMap { EditorTextCodec.decode($0)?.text }.first
            if let text { return .text(text) }
            return image.map { .image($0.bytes) }
        }
    }

    static func evaluate(
        _ inputs: [BuiltInAutomationInput], workflow: BuiltInAutomationWorkflow
    ) async throws -> BuiltInAutomationOutput {
        var first: BuiltInAutomationOutput?
        var count = 0
        var requestsNotification = false
        for input in inputs {
            let result = try await run(input, steps: workflow.steps)
            if result.matchedConditions {
                count += 1
                requestsNotification = requestsNotification || result.requestsNotification
                if first == nil { first = result }
            }
        }
        let result = first ?? .init(value: inputs.first ?? .text(""), requestsNotification: false,
                                    matchedConditions: false, originalInput: inputs.first)
        return .init(value: result.value, requestsNotification: requestsNotification,
                     matchedConditions: result.matchedConditions, matchedItemCount: count,
                     originalInput: result.originalInput)
    }

    static func evaluateManual(
        input: BuiltInAutomationInput, workflow: BuiltInAutomationWorkflow,
        history: (any ClipboardHistory)?
    ) async throws -> BuiltInAutomationOutput {
        let now = Date()
        switch workflow.scope.source {
        case .input, .clipboard:
            let source: BuiltInAutomationInput
            if workflow.scope.source == .clipboard {
                let imagePreferred = prefersImage(workflow.steps)
                source = try await BuiltInAutomationClipboard.read(image: imagePreferred)
            } else { source = input }
            // A manual source has no trustworthy copy provenance. Source/time
            // restrictions must not be silently bypassed or fabricated.
            guard workflow.scope.includes(application: nil, copiedAt: nil, now: now) else {
                return .init(value: source, requestsNotification: false, matchedConditions: false, originalInput: source)
            }
            return try await run(source, steps: workflow.steps)
        case .history:
            guard let history else { throw BuiltInAutomationFailure.historyUnavailable }
            var remaining = workflow.scope.historyLimit
            guard (1...1000).contains(remaining), workflow.scope.validTimeRange else {
                throw BuiltInAutomationFailure.invalidScope
            }
            // History cursors bind the original request limit. Keep it
            // constant, then truncate the last page to the user's range.
            let pageSize = min(remaining, 50)
            var cursor: HistoryPageCursor?
            var first: BuiltInAutomationOutput?
            var firstInput: BuiltInAutomationInput?
            var count = 0
            var requestsNotification = false
            repeat {
                try Task.checkCancellation()
                let page = try await history.browse(.init(kind: .recent, limit: pageSize, cursor: cursor))
                for row in page.rows.prefix(remaining) {
                    remaining -= 1
                    guard workflow.scope.includes(application: row.lastSource, copiedAt: row.lastCopiedAt, now: now) else { continue }
                    let payload = try await history.pastePayload(for: row.item.id)
                    guard payload.item == row.item else { throw BuiltInAutomationFailure.historyUnavailable }
                    let result = try await evaluate(inputs(from: payload.representations, workflow: workflow), workflow: workflow)
                    if firstInput == nil { firstInput = result.originalInput }
                    if result.matchedConditions {
                        count += 1
                        requestsNotification = requestsNotification || result.requestsNotification
                        if first == nil { first = result }
                    }
                }
                cursor = page.next
            } while remaining > 0 && cursor != nil
            let result = first ?? .init(value: firstInput ?? .text(""), requestsNotification: false,
                                        matchedConditions: false, originalInput: firstInput)
            return .init(value: result.value, requestsNotification: requestsNotification,
                         matchedConditions: result.matchedConditions, matchedItemCount: count,
                         originalInput: result.originalInput)
        }
    }
}

/// New committed copies retain arrival order while all workflow computation
/// shares the app-owned execution slot. Overflow is visible, never overwritten.
@MainActor
final class BuiltInAutomationAutomaticRunner {
    static let maximumPendingCaptures = 8
    static let maximumPendingBytes = 64 * 1_048_576
    let executionQueue: BuiltInAutomationExecutionQueue
    private var task: Task<Void, Never>?
    private var pending: [ClipboardCapture] = []
    private var pendingBytes = 0
    private var generation = UUID()
    private let notify: @Sendable (String) async throws -> Void
    private let defaults: UserDefaults
    private(set) var lastFailure: BuiltInAutomationFailure? {
        didSet { if oldValue != lastFailure { onFailureChanged?(lastFailure) } }
    }
    var onFailureChanged: (@MainActor (BuiltInAutomationFailure?) -> Void)? {
        didSet { onFailureChanged?(lastFailure) }
    }

    init(defaults: UserDefaults = .standard,
         executionQueue: BuiltInAutomationExecutionQueue = .init(),
         notify: @escaping @Sendable (String) async throws -> Void = BuiltInAutomationNotifications.send) {
        self.defaults = defaults
        self.executionQueue = executionQueue
        self.notify = notify
    }

    func submit(_ capture: ClipboardCapture) {
        guard !capture.isConcealed else { return }
        guard BuiltInAutomationLibrary(defaults: defaults).workflows.contains(where: { $0.trigger.includesAutomatic }) else { return }
        let bytes = Self.byteCount(capture)
        guard pending.count < Self.maximumPendingCaptures,
              bytes <= Self.maximumPendingBytes - pendingBytes else {
            lastFailure = .executionQueueFull
            return
        }
        pending.append(capture)
        pendingBytes += bytes
        startPendingWork()
    }

    private func startPendingWork() {
        guard task == nil, !pending.isEmpty else { return }
        task = Task { [weak self] in
            guard let self else { return }
            while !pending.isEmpty, !Task.isCancelled {
                let capture = pending.removeFirst()
                let requestGeneration = generation
                pendingBytes -= Self.byteCount(capture)
                // Saved list order is the priority. Freeze it for this copy;
                // later reorder operations affect subsequent captures only.
                let definitions = BuiltInAutomationLibrary(defaults: defaults).workflows
                let representations = capture.representations.map {
                    HistoryRepresentation(typeIdentifier: $0.typeIdentifier, bytes: $0.bytes, pasteboardItemIndex: $0.pasteboardItemIndex)
                }
                for workflow in definitions where workflow.trigger.includesAutomatic {
                    guard !Task.isCancelled else { break }
                    guard workflow.scope.includes(application: capture.origin.sourceApplication,
                                                   copiedAt: capture.observedAt, now: Date()) else { continue }
                    do {
                        let sendNotification = notify
                        _ = try await executionQueue.execute(retainedBytes: Self.byteCount(capture)) { [self] in
                            let result = try await BuiltInAutomation.evaluate(
                                BuiltInAutomation.inputs(from: representations, workflow: workflow), workflow: workflow
                            )
                            try Task.checkCancellation()
                            // An edited or removed definition cannot send a
                            // stale notification after its computation finishes.
                            guard await self.isSaved(workflow, generation: requestGeneration) else { return result }
                            if result.matchedConditions && result.requestsNotification {
                                try await sendNotification(workflow.name)
                                try Task.checkCancellation()
                            }
                            return result
                        }
                    } catch is CancellationError { break }
                    catch { lastFailure = (error as? BuiltInAutomationFailure) ?? .notificationFailed }
                }
            }
            task = nil
            startPendingWork()
        }
    }

    private func isSaved(_ workflow: BuiltInAutomationWorkflow, generation request: UUID) -> Bool {
        generation == request && BuiltInAutomationLibrary(defaults: defaults).workflows.contains(workflow)
    }

    private static func byteCount(_ capture: ClipboardCapture) -> Int {
        capture.representations.reduce(0) { $0 + $1.bytes.count }
    }

    func stop() {
        generation = UUID()
        pending.removeAll()
        pendingBytes = 0
        task?.cancel()
        // A resumed observer can append new captures while cancellation settles,
        // but the shared queue does not release the active native computation.
    }

#if DEBUG
    func waitForPendingWorkForTesting() async {
        while let active = task { await active.value }
    }
#endif
}
