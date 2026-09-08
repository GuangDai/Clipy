/// Card 10C app-boundary tests. The controller consumes a four-operation
/// ServiceManagement adapter; tests substitute only that true external
/// boundary and never touch `SMAppService.mainApp` or History.
import Foundation
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
    private var continuation: CheckedContinuation<Void, Never>?
    private var entryContinuation: CheckedContinuation<Void, Never>?

    func run(shouldFail: Bool = true) async throws {
        entered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entryContinuation?.resume()
            entryContinuation = nil
        }
        if shouldFail { throw Failure.rejected }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }

    func waitForEntry() async {
        guard !entered else { return }
        await withCheckedContinuation { entryContinuation = $0 }
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

        await joinPendingOperation(controller) {}
        #expect(controller.presentation.state == .requiresApproval)
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

        await joinPendingOperation(controller) {}
        #expect(controller.presentation.state == .off)
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

        await joinPendingOperation(controller) {}
        #expect(controller.presentation.state == .off)
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
        await joinPendingOperation(registerController) {}
        #expect(registerController.presentation.operationFailed)
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
        await joinPendingOperation(unregisterController) {}
        #expect(unregisterController.presentation.operationFailed)
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
        await operation.waitForEntry()
        #expect(recorder.registerCount == 1)
        #expect(recorder.unregisterCount == 0)

        await joinPendingOperation(controller) { operation.finish() }
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
        await joinPendingOperation(controller) {}
        #expect(controller.presentation.operationFailed)
        #expect(!controller.presentation.operationPending)

        controller.setEnabled(true)
        #expect(!controller.presentation.operationFailed)
        #expect(controller.presentation.operationPending)
        await operation.waitForEntry()
        await joinPendingOperation(controller) { operation.finish() }
        #expect(controller.presentation.state == .on)
        #expect(!controller.presentation.operationFailed)
    }

    @Test("refresh before a scheduled operation starts preserves the user's request")
    @MainActor
    func refreshBeforeOperationStarts() async {
        let recorder = LaunchAtLoginOperationRecorder(status: .notRegistered)
        let controller = LaunchAtLoginController(operations: recorder.operations)

        recorder.statusAfterRegister = .enabled
        controller.setEnabled(true)
        controller.refresh()
        #expect(controller.presentation.operationPending)
        controller.setEnabled(false)

        await joinPendingOperation(controller) {}
        #expect(controller.presentation.state == .on)
        #expect(recorder.registerCount == 1)
        #expect(recorder.unregisterCount == 0)
    }

    @Test("activation refresh cannot overlap or hide an outstanding successful operation")
    @MainActor
    func refreshDuringSuccessfulOperation() async {
        let operation = NonCooperativeLaunchOperation()
        let recorder = LaunchAtLoginOperationRecorder(status: .requiresApproval)
        let controller = LaunchAtLoginController(operations: LaunchAtLoginOperations(
            status: { recorder.status },
            register: { recorder.registerCount += 1 },
            unregister: {
                recorder.unregisterCount += 1
                try await operation.run(shouldFail: false)
                recorder.status = .notRegistered
            },
            openSystemSettings: {}
        ))

        controller.setEnabled(false)
        await operation.waitForEntry()
        recorder.status = .enabled
        controller.refresh()
        #expect(controller.presentation.state == .on)
        #expect(controller.presentation.operationPending)
        controller.setEnabled(true)
        controller.setEnabled(false)
        #expect(recorder.registerCount == 0)
        #expect(recorder.unregisterCount == 1)

        await joinPendingOperation(controller) {
            operation.finish()
        }
        #expect(controller.presentation.state == .off)
        #expect(!controller.presentation.operationFailed)
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

    @Test("refresh during an operation preserves its failure and permits subsequent recovery")
    @MainActor
    func refreshPreservesPendingFailureAndLaterRecovery() async {
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
        await gate.waitForEntry()
        status.status = .enabled
        controller.refresh()
        #expect(controller.presentation.state == .on)
        #expect(!controller.presentation.operationFailed)
        #expect(controller.presentation.operationPending)

        await joinPendingOperation(controller) { gate.finish() }
        #expect(controller.presentation.state == .on)
        #expect(controller.presentation.operationFailed)
        #expect(!controller.presentation.operationPending)

        status.status = .notRegistered
        controller.refresh()
        #expect(controller.presentation.state == .off)
        #expect(!controller.presentation.operationFailed)
    }

    /// Join the actual completion publication; activation races need no
    /// elapsed-time deadline or repeated scheduler/status sampling.
    @MainActor
    private func joinPendingOperation(
        _ controller: LaunchAtLoginController,
        finish: @MainActor () -> Void
    ) async {
        guard controller.presentation.operationPending else {
            finish()
            return
        }
        await withCheckedContinuation { continuation in
            controller.onPresentationChanged = { value in
                guard !value.operationPending else { return }
                controller.onPresentationChanged = nil
                continuation.resume()
            }
            finish()
        }
    }

}
