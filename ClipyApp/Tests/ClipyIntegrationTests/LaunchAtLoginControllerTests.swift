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
    private var continuation: CheckedContinuation<Void, Never>?

    func runThenFail() async throws {
        entered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        throw Failure.rejected
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
            register: { try await gate.runThenFail() },
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

        gate.finish()
        for _ in 0..<4 { await Task.yield() }
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
