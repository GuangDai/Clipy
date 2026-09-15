import Foundation
@testable import HistoryCore
@testable import ClipyApp
import Testing

@MainActor
struct BuiltInAutomationExecutionQueueTests {
    @Test func cancellationWaitsForNativeCompletionBeforeNextRequest() async throws {
        let queue = BuiltInAutomationExecutionQueue()
        let native = WorkflowNativeCompletion()
        let first = Task {
            try await queue.execute(retainedBytes: 1) {
                await native.startAndWait()
                return .init(value: .text("old"), requestsNotification: false)
            }
        }
        await native.waitUntilStarted()
        first.cancel()
        var secondStarted = false
        let second = Task {
            try await queue.execute(retainedBytes: 1, onStart: { secondStarted = true }) {
                .init(value: .text("next"), requestsNotification: false)
            }
        }
        await waitForQueue(queue, count: 1)
        #expect(!secondStarted, "Cancellation cannot release a still-running native request")
        await native.finish()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await second.value.value.text == "next")
        #expect(secondStarted)
    }

    @Test func queuedModelShowsWaitingAndCancelledRequestDoesNotRun() async throws {
        let queue = BuiltInAutomationExecutionQueue()
        let native = WorkflowNativeCompletion()
        let first = Task {
            try await queue.execute(retainedBytes: 1) {
                await native.startAndWait()
                return .init(value: .text("first"), requestsNotification: false)
            }
        }
        await native.waitUntilStarted()
        let model = BuiltInAutomationModel(executionQueue: queue)
        model.preview(source: "waiting", steps: [.init(operation: .uppercase)])
        await waitForQueue(queue, count: 1)
        #expect(model.isQueued && !model.isRunning)
        model.invalidate()
        await waitForQueue(queue, count: 0)
        await native.finish()
        _ = try await first.value
        #expect(model.result == nil && !model.isQueued && !model.isRunning)
    }

    @Test func capacityRejectsVisiblyWithoutReplacingAnAcceptedRequest() async throws {
        let queue = BuiltInAutomationExecutionQueue()
        let native = WorkflowNativeCompletion()
        let first = Task {
            try await queue.execute(retainedBytes: BuiltInAutomationExecutionQueue.maximumRetainedBytes) {
                await native.startAndWait()
                return .init(value: .text("accepted"), requestsNotification: false)
            }
        }
        await native.waitUntilStarted()
        await #expect(throws: BuiltInAutomationFailure.executionQueueFull) {
            try await queue.execute(retainedBytes: 1) {
                .init(value: .text("overflow"), requestsNotification: false)
            }
        }
        await native.finish()
        #expect(try await first.value.value.text == "accepted")
    }

    @Test func automaticCapturesPreserveArrivalOrderAndSavedPriority() async throws {
        let suite = "WorkflowFIFO.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = BuiltInAutomationLibrary(defaults: defaults)
        try library.save(.init(name: "Failing JSON", steps: [.init(operation: .prettyJSON)], trigger: .newCopies))
        for text in ["ONE", "TWO", "THREE"] {
            let first = BuiltInAutomationWorkflow(name: "A-\(text)", steps: [
                .init(operation: .conditional, find: text, thenSteps: [.init(operation: .lowercase), .init(operation: .notify)])
            ], trigger: .newCopies)
            let second = BuiltInAutomationWorkflow(name: "B-\(text)", steps: [
                .init(operation: .conditional, find: text, thenSteps: [.init(operation: .lowercase), .init(operation: .notify)])
            ], trigger: .newCopies)
            try library.save(first)
            try library.save(second)
            try library.move(id: second.id, before: first.id)
        }
        #expect(BuiltInAutomationLibrary(defaults: defaults).workflows.map(\.name)
            == ["Failing JSON", "B-ONE", "A-ONE", "B-TWO", "A-TWO", "B-THREE", "A-THREE"])
        let delivery = WorkflowDeliveryLog()
        let runner = BuiltInAutomationAutomaticRunner(defaults: defaults, notify: { await delivery.record($0) })
        for text in ["ONE", "TWO", "THREE"] { runner.submit(capture(text)) }
        await runner.waitForPendingWorkForTesting()
        #expect(await delivery.names == ["B-ONE", "A-ONE", "B-TWO", "A-TWO", "B-THREE", "A-THREE"])
        #expect(runner.lastFailure == .invalidJSON, "One failing workflow does not block later workflows or copies")
    }

    @Test func deletingAnAutomaticWorkflowWhileQueuedSuppressesItsNotification() async throws {
        let suite = "WorkflowDeleted.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = BuiltInAutomationLibrary(defaults: defaults)
        let workflow = BuiltInAutomationWorkflow(name: "Deleted", steps: [
            .init(operation: .conditional, condition: .isText, thenSteps: [.init(operation: .notify)])
        ], trigger: .newCopies)
        try library.save(workflow)
        let queue = BuiltInAutomationExecutionQueue()
        let native = WorkflowNativeCompletion()
        let first = Task {
            try await queue.execute(retainedBytes: 1) {
                await native.startAndWait()
                return .init(value: .text("first"), requestsNotification: false)
            }
        }
        await native.waitUntilStarted()
        let delivery = WorkflowDeliveryLog()
        let runner = BuiltInAutomationAutomaticRunner(defaults: defaults, executionQueue: queue,
                                                       notify: { await delivery.record($0) })
        runner.submit(capture("captured"))
        await waitForQueue(queue, count: 1)
        try library.remove(workflow.id)
        await native.finish()
        _ = try await first.value
        await runner.waitForPendingWorkForTesting()
        #expect(await delivery.names.isEmpty)
    }

    @Test func automaticOverflowIsPublishedAndAllAcceptedCopiesRemainQueued() async throws {
        let suite = "WorkflowOverflow.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try BuiltInAutomationLibrary(defaults: defaults).save(.init(name: "Notify", steps: [
            .init(operation: .conditional, condition: .isText, thenSteps: [.init(operation: .notify)])
        ], trigger: .newCopies))
        let delivery = WorkflowDeliveryLog()
        let runner = BuiltInAutomationAutomaticRunner(defaults: defaults, notify: { await delivery.record($0) })
        var visibleFailure: BuiltInAutomationFailure?
        runner.onFailureChanged = { visibleFailure = $0 }
        for index in 0...BuiltInAutomationAutomaticRunner.maximumPendingCaptures {
            runner.submit(capture("copy \(index)"))
        }
        #expect(visibleFailure == .executionQueueFull)
        await runner.waitForPendingWorkForTesting()
        #expect(await delivery.names.count == BuiltInAutomationAutomaticRunner.maximumPendingCaptures)
        #expect(visibleFailure == .executionQueueFull)
    }

    private func capture(_ text: String) -> ClipboardCapture {
        .init(representations: [.init(typeIdentifier: "public.utf8-plain-text", bytes: Data(text.utf8))],
              origin: .init(sourceApplication: "test.app", lineageHint: nil), observedAt: Date())
    }

    private func waitForQueue(_ queue: BuiltInAutomationExecutionQueue, count: Int) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while queue.pendingRequestCountForTesting != count && ContinuousClock.now < deadline { await Task.yield() }
        #expect(queue.pendingRequestCountForTesting == count)
    }
}

private actor WorkflowNativeCompletion {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<Void, Never>?

    func startAndWait() async {
        started = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { completion = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finish() { completion?.resume(); completion = nil }
}

private actor WorkflowDeliveryLog {
    private(set) var names: [String] = []
    func record(_ name: String) { names.append(name) }
}
