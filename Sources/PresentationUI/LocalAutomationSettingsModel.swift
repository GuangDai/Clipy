import HistoryCore
import Observation

/// The concrete Settings interaction owner. A high-risk permission stays off
/// while its confirmation is presented; only that alert's affirmative action
/// submits the corresponding grant (V2-05 §0.2–§0.3).
@Observable @MainActor
final class LocalAutomationSettingsModel {
    private let settings: LocalAutomationSettings
    private(set) var state: LocalAutomationSettingsState?
    private(set) var isWorking = false
    private(set) var failed = false
    var confirmsDeletionGrant = false
    var confirmsRevisionGrant = false

    init(settings: LocalAutomationSettings) { self.settings = settings }

    var statusText: String {
        if let state { return state.enabled ? "Enabled" : "Disabled" }
        return failed ? "Unavailable" : "Loading…"
    }

    func load() async { await perform(settings.load) }
    func enable() async { await perform(settings.enable) }
    func revoke() async { await perform(settings.revoke) }

    func requestCapability(_ capability: ExternalCapability, enabled: Bool) async {
        guard !isWorking, !Task.isCancelled else { return }
        if capability == .deleteItem, enabled {
            confirmsDeletionGrant = true
        } else if capability == .reviseContent, enabled {
            confirmsRevisionGrant = true
        } else {
            await changeCapability(capability, enabled: enabled)
        }
    }

    func cancelDeletionGrant() { confirmsDeletionGrant = false }
    func cancelRevisionGrant() { confirmsRevisionGrant = false }

    func confirmDeletionGrant() async {
        confirmsDeletionGrant = false
        await changeCapability(.deleteItem, enabled: true)
    }

    func confirmRevisionGrant() async {
        confirmsRevisionGrant = false
        await changeCapability(.reviseContent, enabled: true)
    }

    private func changeCapability(_ capability: ExternalCapability, enabled: Bool) async {
        await perform { try await settings.setCapability(capability, enabled) }
    }

    private func perform(_ action: @MainActor () async throws -> LocalAutomationSettingsState) async {
        guard !isWorking, !Task.isCancelled else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let updated = try await action()
            // The model outlives a tab's cancelled .task. An entered action
            // can still finish (including an already-committed mutation),
            // and isWorking prevents a later operation from overtaking it.
            // Accept its actual result rather than leaving the tab loading.
            state = updated
            failed = false
        } catch {
            // Cancellation may leave a mutation's outcome unknown. Expose
            // the existing Retry, which reads state and never replays it.
            failed = true
        }
    }
}
