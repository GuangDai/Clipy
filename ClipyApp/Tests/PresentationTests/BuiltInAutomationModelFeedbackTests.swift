import Foundation
@testable import ClipyApp
import Testing

@MainActor
struct BuiltInAutomationModelFeedbackTests {
    @Test func notificationFailureKeepsTheCompletedOutputAvailable() async {
        for failure in [BuiltInAutomationFailure.notificationDenied, .notificationFailed] {
            let model = BuiltInAutomationModel(notify: { _ in throw failure })
            let steps: [BuiltInAutomationStep] = [
                .init(operation: .conditional, condition: .isText, thenSteps: [
                    .init(operation: .uppercase), .init(operation: .notify)
                ])
            ]
            model.preview(input: .text("ready"), steps: steps, runEffects: true)
            await waitForCompletion(model)

            #expect(model.failure == failure)
            #expect(model.result == "READY")
            #expect(model.output?.originalInput == .text("ready"))
            #expect(model.isCurrent(source: "ready", steps: steps))
            #expect(!model.isCancelled)
        }
    }

    @Test func unexpectedNotificationErrorIsDeliveryFailureAndKeepsResult() async {
        let model = BuiltInAutomationModel(notify: { _ in throw CocoaError(.fileWriteUnknown) })
        model.preview(input: .text("ready"), steps: [
            .init(operation: .requireText), .init(operation: .uppercase), .init(operation: .notify)
        ], runEffects: true)
        await waitForCompletion(model)
        #expect(model.failure == .notificationFailed)
        #expect(model.result == "READY")
    }

    @Test func cancellingQueuedPreviewHasExplicitFeedbackAndCanRunAgain() async {
        let model = BuiltInAutomationModel()
        let steps = [BuiltInAutomationStep(operation: .uppercase)]
        model.preview(source: "cancel this", steps: steps)
        #expect(model.isQueued)
        model.cancel()
        #expect(model.isCancelled)
        #expect(!model.isRunning && !model.isQueued)
        #expect(model.result == nil && model.failure == nil)
        #expect(!model.isCurrent(source: "cancel this", steps: steps))

        model.preview(source: "next", steps: steps)
        #expect(!model.isCancelled)
        await waitForCompletion(model)
        #expect(model.result == "NEXT")
        model.invalidate()
        #expect(!model.isCancelled && model.result == nil)
    }

    @Test func cancelledNotificationCannotPublishFailureIntoNextPreview() async {
        let notification = HeldWorkflowNotification()
        let model = BuiltInAutomationModel(notify: { _ in try await notification.send() })
        model.preview(input: .text("old"), steps: [
            .init(operation: .requireText), .init(operation: .notify)
        ], runEffects: true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await notification.started), ContinuousClock.now < deadline { await Task.yield() }
        #expect(await notification.started)
        model.cancel()
        #expect(model.isCancelled)
        model.preview(source: "next", steps: [.init(operation: .uppercase)])
        await notification.release()
        await waitForCompletion(model)
        #expect(model.result == "NEXT")
        #expect(model.failure == nil && !model.isCancelled)
    }

    private func waitForCompletion(_ model: BuiltInAutomationModel) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while (model.isQueued || model.isRunning), ContinuousClock.now < deadline { await Task.yield() }
        #expect(!model.isQueued && !model.isRunning)
    }
}

private actor HeldWorkflowNotification {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func send() async throws {
        started = true
        await withCheckedContinuation { continuation = $0 }
        throw BuiltInAutomationFailure.notificationDenied
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
