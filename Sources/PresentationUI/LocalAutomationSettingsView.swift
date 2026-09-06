import Foundation
import HistoryCore
import SwiftUI

public struct LocalAutomationSettingsState: Sendable, Equatable {
    public let enabled: Bool
    public let grants: Set<ExternalCapability>

    public init(enabled: Bool, grants: Set<ExternalCapability>) {
        self.enabled = enabled
        self.grants = grants
    }
}

/// App-owned enrollment and service lifecycle enter Settings as user actions;
/// credential custody, paths and Storage never enter the UI (V2-05 §0.3).
@MainActor
public struct LocalAutomationSettings {
    let load: @MainActor () async throws -> LocalAutomationSettingsState
    let enable: @MainActor () async throws -> LocalAutomationSettingsState
    let revoke: @MainActor () async throws -> LocalAutomationSettingsState
    let setCapability: @MainActor (ExternalCapability, Bool) async throws -> LocalAutomationSettingsState

    public init(
        load: @escaping @MainActor () async throws -> LocalAutomationSettingsState,
        enable: @escaping @MainActor () async throws -> LocalAutomationSettingsState,
        revoke: @escaping @MainActor () async throws -> LocalAutomationSettingsState,
        setCapability: @escaping @MainActor (ExternalCapability, Bool) async throws -> LocalAutomationSettingsState
    ) {
        self.load = load
        self.enable = enable
        self.revoke = revoke
        self.setCapability = setCapability
    }
}

struct LocalAutomationSettingsView: View {
    let settings: LocalAutomationSettings
    @State private var state: LocalAutomationSettingsState?
    @State private var isWorking = false
    @State private var failed = false
    @State private var confirmsDeletionGrant = false

    var body: some View {
        Form {
            Section {
                Text(LocalAutomationSettingsCopy.text(statusText))
                    .accessibilityIdentifier("clipy.settings.automation.status")
                Text(LocalAutomationSettingsCopy.text(
                    "Local Automation lets programs using your account call clipyctl. Enable it, then grant each permission separately."
                ))
                if state?.enabled == true || failed {
                    Button(LocalAutomationSettingsCopy.text("Revoke Access"), role: .destructive) {
                        Task { await perform(settings.revoke) }
                    }
                    .accessibilityIdentifier("clipy.settings.automation.revoke")
                } else {
                    Button(LocalAutomationSettingsCopy.text("Enable Local Automation")) {
                        Task { await perform(settings.enable) }
                    }
                    .disabled(state == nil)
                    .accessibilityIdentifier("clipy.settings.automation.enable")
                }
            } header: {
                Text(LocalAutomationSettingsCopy.text("Local Automation"))
            }
            if state?.enabled == true {
                Section {
                    capabilityToggle(.browsePreview, title: "Browse Previews", identifier: "browse")
                    capabilityToggle(.readEffectiveContent, title: "Read Current Content", identifier: "read")
                    capabilityToggle(.organize, title: "Pin and Unpin Items", identifier: "organize")
                    capabilityToggle(.deleteItem, title: "Delete Items", identifier: "delete")
                } header: {
                    Text(LocalAutomationSettingsCopy.text("Permissions"))
                } footer: {
                    Text(LocalAutomationSettingsCopy.text(
                        "Permissions are independent. Enabling Local Automation grants none. All programs using your account share these permissions."
                    ))
                }
            }
            if failed {
                Section {
                    Text(LocalAutomationSettingsCopy.text("Could not update Local Automation. Retry or revoke access."))
                    Button(LocalAutomationSettingsCopy.text("Retry")) {
                        Task { await perform(settings.load) }
                    }
                    .accessibilityIdentifier("clipy.settings.automation.retry")
                }
            }
            if isWorking { ProgressView() }
        }
        .formStyle(.grouped)
        .disabled(isWorking)
        .task { await perform(settings.load) }
        .alert(LocalAutomationSettingsCopy.text("Allow Programs to Delete History?"), isPresented: $confirmsDeletionGrant) {
            Button(LocalAutomationSettingsCopy.text("Allow Deletion"), role: .destructive) {
                Task { await changeCapability(.deleteItem, enabled: true) }
            }
            Button(LocalAutomationSettingsCopy.text("Cancel"), role: .cancel) {}
        } message: {
            Text(LocalAutomationSettingsCopy.text(
                "Programs using your account will be able to permanently delete individual clipboard items without asking again. This cannot be undone."
            ))
        }
    }

    private func capabilityToggle(
        _ capability: ExternalCapability, title: String, identifier: String
    ) -> some View {
        Toggle(LocalAutomationSettingsCopy.text(title), isOn: Binding(
            get: { state?.grants.contains(capability) == true },
            set: { enabled in
                if capability == .deleteItem, enabled {
                    confirmsDeletionGrant = true
                } else {
                    Task { await changeCapability(capability, enabled: enabled) }
                }
            }
        ))
        .accessibilityIdentifier("clipy.settings.automation.grant.\(identifier)")
    }

    private var statusText: String {
        if let state { return state.enabled ? "Enabled" : "Disabled" }
        return failed ? "Unavailable" : "Loading…"
    }

    private func changeCapability(_ capability: ExternalCapability, enabled: Bool) async {
        await perform { try await settings.setCapability(capability, enabled) }
    }

    private func perform(_ action: @MainActor () async throws -> LocalAutomationSettingsState) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let updated = try await action()
            guard !Task.isCancelled else { return }
            state = updated
            failed = false
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
    }
}

enum LocalAutomationSettingsCopy {
    static func text(_ key: String) -> String {
        Bundle.module.localizedString(forKey: key, value: key, table: "LocalAutomationSettings")
    }
}
