/// Card 10C app-boundary tests. The controller consumes a four-operation
/// ServiceManagement adapter; tests substitute only that true external
/// boundary and never touch `SMAppService.mainApp` or History.
import Foundation
import PresentationUI
import Testing
@testable import ClipyApp

@MainActor
private final class LaunchAtLoginOperationRecorder {
    enum Failure: Error { case rejected }

    var status: LaunchAtLoginSystemStatus
    var registerShouldFail = false
    var unregisterShouldFail = false
    var statusAfterRegister: LaunchAtLoginSystemStatus?
    var statusAfterUnregister: LaunchAtLoginSystemStatus?
    var registerCount = 0
    var unregisterCount = 0
    var openSettingsCount = 0

    init(status: LaunchAtLoginSystemStatus) {
        self.status = status
    }

    var operations: LaunchAtLoginOperations {
        LaunchAtLoginOperations(
            status: { [weak self] in self?.status ?? .notFound },
            register: { [weak self] in
                guard let self else { return }
                registerCount += 1
                if registerShouldFail { throw Failure.rejected }
                if let statusAfterRegister {
                    status = statusAfterRegister
                }
            },
            unregister: { [weak self] in
                guard let self else { return }
                unregisterCount += 1
                if unregisterShouldFail { throw Failure.rejected }
                if let statusAfterUnregister {
                    status = statusAfterUnregister
                }
            },
            openSystemSettings: { [weak self] in
                self?.openSettingsCount += 1
            }
        )
    }
}

@MainActor
private final class NonCooperativeLaunchOperation {
    enum Failure: Error { case rejected }

    private(set) var entered = false
    private(set) var completed = false
    private var continuation: CheckedContinuation<Void, Never>?

    func run(shouldFail: Bool = true) async throws {
        entered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        completed = true
        if shouldFail { throw Failure.rejected }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

@Suite("Launch-at-login controller")
struct LaunchAtLoginControllerTests {
    @Test("successful registration rereads authoritative status")
    @MainActor
    func successfulRegistrationRereadsStatus() async {
        let recorder = LaunchAtLoginOperationRecorder(status: .notRegistered)
        recorder.statusAfterRegister = .requiresApproval
        let controller = LaunchAtLoginController(operations: recorder.operations)

        controller.setEnabled(true)

        let settled = await waitUntil {
            controller.presentation.state == .requiresApproval
        }
        #expect(settled)
        #expect(recorder.registerCount == 1)
        #expect(!controller.presentation.operationFailed)
    }

    @Test("successful unregister rereads authoritative status")
    @MainActor
    func successfulUnregisterRereadsStatus() async {
        let recorder = LaunchAtLoginOperationRecorder(status: .enabled)
        recorder.statusAfterUnregister = .notRegistered
        let controller = LaunchAtLoginController(operations: recorder.operations)

        controller.setEnabled(false)

        let settled = await waitUntil {
            controller.presentation.state == .off
        }
        #expect(settled)
        #expect(recorder.unregisterCount == 1)
        #expect(!controller.presentation.operationFailed)
    }

    @Test("approval-required registration can still be unregistered")
    @MainActor
    func approvalRequiredCanUnregister() async {
        let recorder = LaunchAtLoginOperationRecorder(status: .requiresApproval)
        recorder.statusAfterUnregister = .notRegistered
        let controller = LaunchAtLoginController(operations: recorder.operations)

        #expect(controller.presentation.state == .requiresApproval)
        #expect(controller.presentation.isOn)
        controller.setEnabled(false)

        let settled = await waitUntil {
            controller.presentation.state == .off
        }
        #expect(settled)
        #expect(recorder.registerCount == 0)
        #expect(recorder.unregisterCount == 1)
        #expect(!controller.presentation.operationFailed)
    }

    @Test("all ServiceManagement statuses remain distinct")
    @MainActor
    func systemStatusesMapWithoutBooleanCollapse() {
        let cases: [(LaunchAtLoginSystemStatus, LaunchAtLoginState)] = [
            (.notRegistered, .off),
            (.enabled, .on),
            (.requiresApproval, .requiresApproval),
            (.notFound, .unavailable),
        ]

        for (status, expected) in cases {
            let recorder = LaunchAtLoginOperationRecorder(status: status)
            let controller = LaunchAtLoginController(
                operations: recorder.operations
            )
            #expect(controller.presentation.state == expected)
            #expect(!controller.presentation.operationFailed)
        }
    }

    @Test("register failure retains content-free off state")
    @MainActor
    func registerFailureRemainsVisible() async {
        let register = LaunchAtLoginOperationRecorder(status: .notRegistered)
        register.registerShouldFail = true
        let registerController = LaunchAtLoginController(
            operations: register.operations
        )
        registerController.setEnabled(true)
        let registerFailed = await waitUntil {
            registerController.presentation.operationFailed
        }
        #expect(registerFailed)
        #expect(registerController.presentation.state == .off)
        #expect(register.registerCount == 1)
    }

    @Test("unregister failure retains content-free on state")
    @MainActor
    func unregisterFailureRemainsVisible() async {
        let unregister = LaunchAtLoginOperationRecorder(status: .enabled)
        unregister.unregisterShouldFail = true
        let unregisterController = LaunchAtLoginController(
            operations: unregister.operations
        )
        unregisterController.setEnabled(false)
        let unregisterFailed = await waitUntil {
            unregisterController.presentation.operationFailed
        }
        #expect(unregisterFailed)
        #expect(unregisterController.presentation.state == .on)
        #expect(unregister.unregisterCount == 1)
    }

    @Test("pending operation suppresses repeated input and settles from system status")
    @MainActor
    func pendingOperationSuppressesRepeatedInput() async {
        let operation = NonCooperativeLaunchOperation()
        let recorder = LaunchAtLoginOperationRecorder(status: .notRegistered)
        let controller = LaunchAtLoginController(
            operations: LaunchAtLoginOperations(
                status: { recorder.status },
                register: {
                    recorder.registerCount += 1
                    try await operation.run(shouldFail: false)
                    recorder.status = .requiresApproval
                },
                unregister: { recorder.unregisterCount += 1 },
                openSystemSettings: {}
            )
        )

        controller.setEnabled(true)
        #expect(controller.presentation.operationPending)
        #expect(controller.presentation.state == .off)
        controller.setEnabled(true)
        controller.setEnabled(false)
        let entered = await waitUntil { operation.entered }
        #expect(entered)
        #expect(recorder.registerCount == 1)
        #expect(recorder.unregisterCount == 0)

        operation.finish()
        let settled = await waitUntil {
            !controller.presentation.operationPending
        }
        #expect(settled)
        #expect(controller.presentation.state == .requiresApproval)
        #expect(!controller.presentation.operationFailed)
    }

    @Test("retry clears the previous error while its system operation is pending")
    @MainActor
    func retryClearsPreviousFailureImmediately() async {
        let operation = NonCooperativeLaunchOperation()
        let recorder = LaunchAtLoginOperationRecorder(status: .notRegistered)
        let controller = LaunchAtLoginController(
            operations: LaunchAtLoginOperations(
                status: { recorder.status },
                register: {
                    recorder.registerCount += 1
                    if recorder.registerCount == 1 {
                        throw LaunchAtLoginOperationRecorder.Failure.rejected
                    }
                    try await operation.run(shouldFail: false)
                    recorder.status = .enabled
                },
                unregister: {},
                openSystemSettings: {}
            )
        )

        controller.setEnabled(true)
        let failed = await waitUntil { controller.presentation.operationFailed }
        #expect(failed)
        #expect(!controller.presentation.operationPending)

        controller.setEnabled(true)
        #expect(!controller.presentation.operationFailed)
        #expect(controller.presentation.operationPending)
        let entered = await waitUntil { operation.entered }
        #expect(entered)
        operation.finish()
        let settled = await waitUntil {
            !controller.presentation.operationPending
        }
        #expect(settled)
        #expect(controller.presentation.state == .on)
        #expect(!controller.presentation.operationFailed)
    }

    @Test("refresh before a scheduled operation starts prevents its external call")
    @MainActor
    func refreshBeforeOperationStarts() async {
        let recorder = LaunchAtLoginOperationRecorder(status: .notRegistered)
        let controller = LaunchAtLoginController(operations: recorder.operations)

        controller.setEnabled(true)
        controller.refresh()
        #expect(!controller.presentation.operationPending)

        // Join a subsequent operation so the queued main-actor work is driven
        // to completion; the superseded registration must never run.
        recorder.statusAfterUnregister = .notFound
        controller.setEnabled(false)
        let settled = await waitUntil {
            controller.presentation.state == .unavailable
        }
        #expect(settled)
        #expect(recorder.registerCount == 0)
        #expect(recorder.unregisterCount == 1)
    }

    @Test("refresh follows externally changed approval and registration status")
    @MainActor
    func refreshFollowsExternalChanges() {
        let recorder = LaunchAtLoginOperationRecorder(status: .notRegistered)
        let controller = LaunchAtLoginController(operations: recorder.operations)
        let states: [(LaunchAtLoginSystemStatus, LaunchAtLoginState)] = [
            (.requiresApproval, .requiresApproval),
            (.enabled, .on),
            (.notRegistered, .off),
            (.notFound, .unavailable),
            (.unknown, .unavailable),
        ]

        for (status, expected) in states {
            recorder.status = status
            controller.refresh()
            #expect(controller.presentation.state == expected)
            #expect(!controller.presentation.operationPending)
            #expect(!controller.presentation.operationFailed)
        }
        #expect(recorder.registerCount == 0)
        #expect(recorder.unregisterCount == 0)
    }

    @Test("requires approval opens the official settings destination")
    @MainActor
    func approvalRecoveryUsesExternalOperation() {
        let recorder = LaunchAtLoginOperationRecorder(status: .requiresApproval)
        let controller = LaunchAtLoginController(operations: recorder.operations)

        controller.openSystemSettings()

        #expect(recorder.openSettingsCount == 1)
        #expect(controller.presentation.state == .requiresApproval)
    }

    @Test("newer refresh fences a noncooperative stale failure")
    @MainActor
    func refreshFencesStaleCompletion() async {
        let gate = NonCooperativeLaunchOperation()
        let status = LaunchAtLoginOperationRecorder(status: .notRegistered)
        let operations = LaunchAtLoginOperations(
            status: { status.status },
            register: { try await gate.run() },
            unregister: {},
            openSystemSettings: {}
        )
        let controller = LaunchAtLoginController(operations: operations)

        controller.setEnabled(true)
        let entered = await waitUntil { gate.entered }
        #expect(entered)
        status.status = .enabled
        controller.refresh()
        #expect(controller.presentation.state == .on)
        #expect(!controller.presentation.operationFailed)
        #expect(!controller.presentation.operationPending)

        gate.finish()
        let completed = await waitUntil { gate.completed }
        #expect(completed)
        #expect(controller.presentation.state == .on)
        #expect(!controller.presentation.operationFailed)
    }

    @MainActor
    private func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
