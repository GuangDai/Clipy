@testable import HistoryCore
import Testing
@testable import ClipyApp

@MainActor
struct LocalAutomationSettingsCancellationTests {
    @Test(arguments: [true, false])
    func returningWhileCancelledLoadIsPendingAlwaysLeavesARecoverableTab(succeeds: Bool) async {
        let pending = PendingSettingsResponse()
        let current = LocalAutomationSettingsState(enabled: true, grants: [.browsePreview])
        var loads = 0
        let settings = LocalAutomationSettings(
            load: {
                loads += 1
                if loads == 1 { return try await pending.wait() }
                return current
            },
            enable: { Issue.record("Load recovery must not enable access"); return current },
            revoke: { Issue.record("Load recovery must not revoke access"); return current },
            setCapability: { _, _ in Issue.record("Load recovery must not change grants"); return current }
        )
        let model = LocalAutomationSettingsModel(settings: settings)
        let firstAppearance = Task { await model.load() }
        await pending.waitUntilEntered()
        #expect(model.isWorking)
        firstAppearance.cancel()

        // SwiftUI starts another .task on returning to the tab before the
        // cancelled action has finished. It starts no second read.
        await model.load()
        #expect(loads == 1)
        #expect(model.state == nil)
        pending.finish(succeeds ? .success(current) : .failure(CancellationError()))
        await firstAppearance.value

        #expect(!model.isWorking)
        if succeeds {
            #expect(model.state == current)
            #expect(!model.failed)
            #expect(model.statusText == "Enabled")
        } else {
            #expect(model.state == nil)
            #expect(model.failed)
            #expect(model.statusText == "Unavailable")
            await model.load()
            #expect(loads == 2)
            #expect(model.state == current)
            #expect(!model.failed)
        }
    }

    enum Mutation: CaseIterable, Equatable, Sendable { case enable, revoke, grant }

    @Test(arguments: Mutation.allCases, [true, false])
    func cancelledMutationRecoveryReadsActualStateWithoutRepeatingTheCommand(
        mutation: Mutation, succeeds: Bool
    ) async {
        let pending = PendingSettingsResponse()
        let before = LocalAutomationSettingsState(
            enabled: mutation != .enable,
            grants: mutation == .revoke ? [.browsePreview] : []
        )
        let after = LocalAutomationSettingsState(
            enabled: mutation != .revoke,
            grants: mutation == .grant ? [.browsePreview] : []
        )
        var mutationCalls = 0
        var loads = 0
        @MainActor func runCommand() async throws -> LocalAutomationSettingsState {
            mutationCalls += 1
            return try await pending.wait()
        }
        let model = LocalAutomationSettingsModel(settings: LocalAutomationSettings(
            load: { loads += 1; return loads == 1 ? before : after },
            enable: { try await runCommand() },
            revoke: { try await runCommand() },
            setCapability: { _, _ in try await runCommand() }
        ))
        await model.load()
        let command = Task {
            switch mutation {
            case .enable: await model.enable()
            case .revoke: await model.revoke()
            case .grant: await model.requestCapability(.browsePreview, enabled: true)
            }
        }
        await pending.waitUntilEntered()
        command.cancel()
        await model.load()
        #expect(loads == 1)
        pending.finish(succeeds ? .success(after) : .failure(CancellationError()))
        await command.value

        #expect(!model.isWorking)
        #expect(model.failed == !succeeds)
        #expect(model.state == (succeeds ? after : before))
        #expect(mutationCalls == 1)
        // The supplied command result can be lost after the app committed.
        // Retry only asks for the next actual state; it never sends enable,
        // revoke or setCapability again.
        await model.load()
        #expect(loads == 2)
        #expect(mutationCalls == 1)
        #expect(model.state == after)
        #expect(!model.failed)
    }

    @Test func alreadyCancelledTaskDoesNotEnterACommandOrOpenItsConfirmation() async {
        let current = LocalAutomationSettingsState(enabled: false, grants: [])
        var calls = 0
        let model = LocalAutomationSettingsModel(settings: LocalAutomationSettings(
            load: { calls += 1; return current },
            enable: { calls += 1; return current },
            revoke: { calls += 1; return current },
            setCapability: { _, _ in calls += 1; return current }
        ))
        let cancelled = Task {
            await model.enable()
            await model.requestCapability(.deleteItem, enabled: true)
            await model.load()
        }
        cancelled.cancel()
        await cancelled.value
        #expect(calls == 0)
        #expect(!model.confirmsDeletionGrant)
        #expect(!model.isWorking)
    }
}

/// Suspends only the Settings dependency's response. This is an interaction
/// fixture, not a History writer or an enrollment implementation.
@MainActor
private final class PendingSettingsResponse {
    private var response: CheckedContinuation<LocalAutomationSettingsState, any Error>?
    private var entered: CheckedContinuation<Void, Never>?

    func wait() async throws -> LocalAutomationSettingsState {
        try await withCheckedThrowingContinuation { continuation in
            response = continuation
            entered?.resume()
            entered = nil
        }
    }

    func waitUntilEntered() async {
        guard response == nil else { return }
        await withCheckedContinuation { entered = $0 }
    }

    func finish(_ result: Result<LocalAutomationSettingsState, any Error>) {
        response?.resume(with: result)
        response = nil
    }
}
