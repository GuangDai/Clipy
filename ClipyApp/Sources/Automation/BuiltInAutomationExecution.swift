import Foundation
import HistoryCore

extension BuiltInAutomation {
    /// Select one representation per original clipboard item. An OCR workflow
    /// prefers image bytes; ordinary text workflows prefer the exact text codec.
    static func inputs(
        from representations: [HistoryRepresentation], workflow: BuiltInAutomationWorkflow
    ) -> [BuiltInAutomationInput] {
        let imageFirst = workflow.steps.contains { $0.enabled && [.requireImage, .recognizeText].contains($0.operation) }
        let groups = Dictionary(grouping: representations, by: \.pasteboardItemIndex)
        return groups.keys.sorted().compactMap { index in
            let values = groups[index] ?? []
            let image = values.first { ["public.png", "public.jpeg", "public.tiff", "public.heic"].contains($0.typeIdentifier) }
            let text = values.lazy.compactMap { EditorTextCodec.decode($0)?.text }.first
            if imageFirst, let image { return .image(image.bytes) }
            if let text { return .text(text) }
            return image.map { .image($0.bytes) }
        }
    }

    static func evaluate(
        _ inputs: [BuiltInAutomationInput], workflow: BuiltInAutomationWorkflow
    ) async throws -> BuiltInAutomationOutput {
        var first: BuiltInAutomationOutput?
        var count = 0
        for input in inputs {
            let result = try await run(input, steps: workflow.steps)
            if result.matchedConditions {
                count += 1
                if first == nil { first = result }
            }
        }
        var result = first ?? .init(value: .text(""), requestsNotification: false, matchedConditions: false)
        result.matchedItemCount = count
        return result
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
                let prefersImage = workflow.steps.contains { $0.enabled && [.requireImage, .recognizeText].contains($0.operation) }
                source = try await BuiltInAutomationClipboard.read(image: prefersImage)
            } else { source = input }
            // A manual source has no trustworthy copy provenance. Source/time
            // restrictions must not be silently bypassed or fabricated.
            guard workflow.scope.includes(application: nil, copiedAt: nil, now: now) else {
                return .init(value: source, requestsNotification: false, matchedConditions: false)
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
            var count = 0
            repeat {
                try Task.checkCancellation()
                let page = try await history.browse(.init(kind: .recent, limit: pageSize, cursor: cursor))
                for row in page.rows.prefix(remaining) {
                    remaining -= 1
                    guard workflow.scope.includes(application: row.lastSource, copiedAt: row.lastCopiedAt, now: now) else { continue }
                    let payload = try await history.pastePayload(for: row.item.id)
                    guard payload.item == row.item else { throw BuiltInAutomationFailure.historyUnavailable }
                    let result = try await evaluate(inputs(from: payload.representations, workflow: workflow), workflow: workflow)
                    if result.matchedConditions {
                        count += 1
                        if first == nil { first = result }
                    }
                }
                cursor = page.next
            } while remaining > 0 && cursor != nil
            var result = first ?? .init(value: .text(""), requestsNotification: false, matchedConditions: false)
            result.matchedItemCount = count
            return result
        }
    }
}

/// Independent of browsing and capture persistence. One active computation and
/// the latest pending copy bound retained content while OCR is running. Startup
/// clipboard capture never enters here; only new accepted observations do.
@MainActor
final class BuiltInAutomationAutomaticRunner {
    private var task: Task<Void, Never>?
    private var pending: ClipboardCapture?
    private let notify: @Sendable (String) async throws -> Void
    private let defaults: UserDefaults
    private(set) var lastFailure: BuiltInAutomationFailure?

    init(defaults: UserDefaults = .standard,
         notify: @escaping @Sendable (String) async throws -> Void = BuiltInAutomationNotifications.send) {
        self.defaults = defaults
        self.notify = notify
    }

    func submit(_ capture: ClipboardCapture) {
        guard !capture.isConcealed else { return }
        guard BuiltInAutomationLibrary(defaults: defaults).workflows.contains(where: { $0.trigger.includesAutomatic }) else { return }
        pending = capture
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            while let capture = pending, !Task.isCancelled {
                pending = nil
                let definitions = BuiltInAutomationLibrary(defaults: defaults).workflows
                for workflow in definitions where workflow.trigger.includesAutomatic {
                    guard !Task.isCancelled else { break }
                    guard workflow.scope.includes(application: capture.origin.sourceApplication,
                                                   copiedAt: capture.observedAt, now: Date()) else { continue }
                    let representations = capture.representations.map {
                        HistoryRepresentation(typeIdentifier: $0.typeIdentifier, bytes: $0.bytes, pasteboardItemIndex: $0.pasteboardItemIndex)
                    }
                    do {
                        let computation = Task.detached(priority: .utility) {
                            try await BuiltInAutomation.evaluate(
                                BuiltInAutomation.inputs(from: representations, workflow: workflow), workflow: workflow
                            )
                        }
                        let result = try await withTaskCancellationHandler {
                            try await computation.value
                        } onCancel: { computation.cancel() }
                        try Task.checkCancellation()
                        guard BuiltInAutomationLibrary(defaults: defaults).workflows.contains(workflow) else { continue }
                        if result.matchedConditions && result.requestsNotification { try await notify(workflow.name) }
                        lastFailure = nil
                    } catch is CancellationError { break }
                    catch { lastFailure = (error as? BuiltInAutomationFailure) ?? .notificationFailed }
                }
            }
            task = nil
            if let next = pending {
                pending = nil
                submit(next)
            }
        }
    }

    func stop() {
        pending = nil
        task?.cancel()
        // Keep the active task until it settles, so restart cannot admit
        // overlapping native OCR work or have an older completion clear it.
    }

#if DEBUG
    func waitForPendingWorkForTesting() async { await task?.value }
#endif
}
