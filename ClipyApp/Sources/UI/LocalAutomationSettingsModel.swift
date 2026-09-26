import HistoryCore
import Observation

/// The concrete Settings interaction owner. A high-risk permission stays off
/// while its confirmation is presented; only that alert's affirmative action
/// submits the corresponding grant (V2-05 §0.2–§0.3).
@Observable @MainActor
final class LocalAutomationSettingsModel {
    private let settings: LocalAutomationSettings
    private(set) var state: LocalAutomationSettingsState?
    private(set) var workingText: String?
    private(set) var failureMessage: String?
    private(set) var notice: String?
    private(set) var commandLineNotice: String?
    private var pendingConfirmation: ExternalCapability?
    var confirmsDeletionGrant = false
    var confirmsRevisionGrant = false

    init(settings: LocalAutomationSettings) { self.settings = settings }

    var isWorking: Bool { workingText != nil }
    var failed: Bool { failureMessage != nil }

    var statusText: String {
        if let workingText { return workingText }
        if failed { return state == nil ? "Unavailable" : "Refresh Needed" }
        if let state { return state.enabled ? "Enabled" : "Disabled" }
        return "Loading…"
    }

    var canEditCapabilities: Bool { state?.enabled == true && !isWorking && !failed }

    var commandLine: LocalAutomationCommandLine? { settings.commandLine }

    func revealCommandLine() { settings.commandLine?.reveal() }

    func copyHelpCommand() {
        guard let commandLine = settings.commandLine else { return }
        commandLineNotice = commandLine.copyHelpCommand()
            ? "Help command copied." : "Could not copy the help command. Try again."
    }

    func load() async {
        await perform(
            settings.load, workingText: "Checking Access…",
            failureMessage: "Could not check access. Refresh to read the current permissions.",
            notice: state != nil || failed ? "Permissions are up to date." : nil
        )
    }

    func enable() async {
        await perform(
            settings.enable, workingText: "Enabling Access…",
            notice: "Local Automation enabled. Choose the permissions your scripts need."
        )
    }

    func revoke() async {
        await perform(
            settings.revoke, workingText: "Revoking Access…",
            notice: "Access revoked. Programs can no longer use Local Automation."
        )
    }

    func requestCapability(_ capability: ExternalCapability, enabled: Bool) async {
        guard canEditCapabilities, !Task.isCancelled,
              pendingConfirmation == nil,
              state?.grants.contains(capability) != enabled else { return }
        if capability == .deleteItem, enabled {
            pendingConfirmation = capability
            confirmsDeletionGrant = true
        } else if capability == .reviseContent, enabled {
            pendingConfirmation = capability
            confirmsRevisionGrant = true
        } else {
            await changeCapability(capability, enabled: enabled)
        }
    }

    func cancelDeletionGrant() {
        confirmsDeletionGrant = false
        if pendingConfirmation == .deleteItem { pendingConfirmation = nil }
    }

    func cancelRevisionGrant() {
        confirmsRevisionGrant = false
        if pendingConfirmation == .reviseContent { pendingConfirmation = nil }
    }

    func confirmDeletionGrant() async {
        confirmsDeletionGrant = false
        guard pendingConfirmation == .deleteItem else { return }
        pendingConfirmation = nil
        await changeCapability(.deleteItem, enabled: true)
    }

    func confirmRevisionGrant() async {
        confirmsRevisionGrant = false
        guard pendingConfirmation == .reviseContent else { return }
        pendingConfirmation = nil
        await changeCapability(.reviseContent, enabled: true)
    }

    private func changeCapability(_ capability: ExternalCapability, enabled: Bool) async {
        guard canEditCapabilities else { return }
        await perform(
            { try await settings.setCapability(capability, enabled) },
            workingText: "Saving Permission…", notice: "Permission updated."
        )
    }

    private func perform(
        _ action: @MainActor () async throws -> LocalAutomationSettingsState,
        workingText: String,
        failureMessage: String = "The change could not be confirmed. Refresh to check the current permissions before making another change.",
        notice: String? = nil
    ) async {
        guard !isWorking, !Task.isCancelled else { return }
        self.workingText = workingText
        self.notice = nil
        // A refresh or revocation invalidates the old confirmation. Keep its
        // identity separate from isPresented, which SwiftUI clears before
        // running the alert button's asynchronous action.
        pendingConfirmation = nil
        confirmsDeletionGrant = false
        confirmsRevisionGrant = false
        defer { self.workingText = nil }
        do {
            let updated = try await action()
            // The model outlives a tab's cancelled .task. An entered action
            // can still finish (including an already-committed mutation),
            // and isWorking prevents a later operation from overtaking it.
            // Accept its actual result rather than leaving the tab loading.
            state = updated
            self.failureMessage = nil
            self.notice = notice
        } catch {
            // Cancellation may leave a mutation's outcome unknown. Expose
            // the existing Retry, which reads state and never replays it.
            self.failureMessage = failureMessage
        }
    }
}
