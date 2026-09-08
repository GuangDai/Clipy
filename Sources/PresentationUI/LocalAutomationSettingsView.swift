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

/// Discoverable bundled tool and explicit desktop actions; no enrollment or
/// credentials are needed to display its location or request command help.
@MainActor
public struct LocalAutomationCommandLine {
    let executablePath: String
    let helpCommand: String
    let reveal: @MainActor () -> Void
    let copyHelpCommand: @MainActor () -> Bool

    public init(
        executablePath: String, helpCommand: String,
        reveal: @escaping @MainActor () -> Void,
        copyHelpCommand: @escaping @MainActor () -> Bool
    ) {
        self.executablePath = executablePath
        self.helpCommand = helpCommand
        self.reveal = reveal
        self.copyHelpCommand = copyHelpCommand
    }
}

/// App-owned enrollment and service lifecycle enter Settings as user actions;
/// credential custody and Storage never enter the UI (V2-05 §0.3).
@MainActor
public struct LocalAutomationSettings {
    let commandLine: LocalAutomationCommandLine?
    let load: @MainActor () async throws -> LocalAutomationSettingsState
    let enable: @MainActor () async throws -> LocalAutomationSettingsState
    let revoke: @MainActor () async throws -> LocalAutomationSettingsState
    let setCapability: @MainActor (ExternalCapability, Bool) async throws -> LocalAutomationSettingsState

    public init(
        load: @escaping @MainActor () async throws -> LocalAutomationSettingsState,
        enable: @escaping @MainActor () async throws -> LocalAutomationSettingsState,
        revoke: @escaping @MainActor () async throws -> LocalAutomationSettingsState,
        setCapability: @escaping @MainActor (ExternalCapability, Bool) async throws -> LocalAutomationSettingsState,
        commandLine: LocalAutomationCommandLine? = nil
    ) {
        self.commandLine = commandLine
        self.load = load
        self.enable = enable
        self.revoke = revoke
        self.setCapability = setCapability
    }
}

struct LocalAutomationSettingsView: View {
    @State private var model: LocalAutomationSettingsModel

    init(settings: LocalAutomationSettings) {
        _model = State(initialValue: LocalAutomationSettingsModel(settings: settings))
    }

    var body: some View {
        Form {
            Section {
                Text(LocalAutomationSettingsCopy.text(model.statusText))
                    .accessibilityIdentifier("clipy.settings.automation.status")
                Text(LocalAutomationSettingsCopy.text(
                    "Local Automation lets programs using your account call clipyctl. Enable it, then grant each permission separately."
                ))
                if model.state?.enabled == true || model.failed {
                    Button(LocalAutomationSettingsCopy.text("Revoke Access"), role: .destructive) {
                        Task { await model.revoke() }
                    }
                    .accessibilityIdentifier("clipy.settings.automation.revoke")
                } else {
                    Button(LocalAutomationSettingsCopy.text("Enable Local Automation")) {
                        Task { await model.enable() }
                    }
                    .disabled(model.state == nil)
                    .accessibilityIdentifier("clipy.settings.automation.enable")
                }
            } header: {
                Text(LocalAutomationSettingsCopy.text("Local Automation"))
            }
            if model.state?.enabled == true {
                Section {
                    capabilityToggle(.browsePreview, title: "Browse Previews", identifier: "browse")
                    capabilityToggle(.readEffectiveContent, title: "Read Current Content", identifier: "read")
                    capabilityToggle(.organize, title: "Pin and Unpin Items", identifier: "organize")
                    capabilityToggle(.deleteItem, title: "Delete Items", identifier: "delete")
                        .alert(LocalAutomationSettingsCopy.text("Allow Programs to Delete History?"), isPresented: $model.confirmsDeletionGrant) {
                            Button(LocalAutomationSettingsCopy.text("Allow Deletion"), role: .destructive) {
                                Task { await model.confirmDeletionGrant() }
                            }
                            Button(LocalAutomationSettingsCopy.text("Cancel"), role: .cancel) { model.cancelDeletionGrant() }
                        } message: {
                            Text(LocalAutomationSettingsCopy.text(
                                "Programs using your account will be able to permanently delete individual clipboard items without asking again. This cannot be undone."
                            ))
                        }
                    capabilityToggle(.reviseContent, title: "Revise Current Content", identifier: "revise")
                        .alert(LocalAutomationSettingsCopy.text("Allow Programs to Revise Current Content?"), isPresented: $model.confirmsRevisionGrant) {
                            Button(LocalAutomationSettingsCopy.text("Allow Revisions"), role: .destructive) {
                                Task { await model.confirmRevisionGrant() }
                            }
                            Button(LocalAutomationSettingsCopy.text("Cancel"), role: .cancel) { model.cancelRevisionGrant() }
                        } message: {
                            Text(LocalAutomationSettingsCopy.revisionDisclosure())
                        }
                } header: {
                    Text(LocalAutomationSettingsCopy.text("Permissions"))
                } footer: {
                    Text(LocalAutomationSettingsCopy.text(
                        "Permissions are independent. Enabling Local Automation grants none. All programs using your account share these permissions."
                    ))
                }
            }
            Section {
                if let commandLine = model.commandLine {
                    Text(commandLine.executablePath)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("clipy.settings.automation.cli.path")
                    Text(commandLine.helpCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    HStack {
                        Button(LocalAutomationSettingsCopy.text("Reveal in Finder")) {
                            model.revealCommandLine()
                        }
                        .accessibilityIdentifier("clipy.settings.automation.cli.reveal")
                        Button(LocalAutomationSettingsCopy.text("Copy Help Command")) {
                            model.copyHelpCommand()
                        }
                        .accessibilityIdentifier("clipy.settings.automation.cli.copyHelp")
                    }
                    Text(LocalAutomationSettingsCopy.text(
                        "Paste the help command into Terminal for request examples and raw content output. Help works before enabling access."
                    ))
                    Text(LocalAutomationSettingsCopy.text(
                        "To list history, enable Local Automation, grant Browse Previews, then use the browsePreview example from help. Keep Clipy running while using the command line."
                    ))
                    if let notice = model.commandLineNotice {
                        Text(LocalAutomationSettingsCopy.text(notice))
                            .accessibilityIdentifier("clipy.settings.automation.cli.notice")
                    }
                } else {
                    Text(LocalAutomationSettingsCopy.text("The bundled command-line tool is unavailable."))
                }
            } header: {
                Text(LocalAutomationSettingsCopy.text("Command Line"))
            }
            if model.failed {
                Section {
                    Text(LocalAutomationSettingsCopy.text("Could not update Local Automation. Retry or revoke access."))
                    Button(LocalAutomationSettingsCopy.text("Retry")) {
                        Task { await model.load() }
                    }
                    .accessibilityIdentifier("clipy.settings.automation.retry")
                }
            }
            if model.isWorking { ProgressView() }
        }
        .formStyle(.grouped)
        .disabled(model.isWorking)
        .task { await model.load() }
    }

    private func capabilityToggle(
        _ capability: ExternalCapability, title: String, identifier: String
    ) -> some View {
        Toggle(LocalAutomationSettingsCopy.text(title), isOn: Binding(
            get: { model.state?.grants.contains(capability) == true },
            set: { enabled in
                Task { await model.requestCapability(capability, enabled: enabled) }
            }
        ))
        .accessibilityIdentifier("clipy.settings.automation.grant.\(identifier)")
    }

}

enum LocalAutomationSettingsCopy {
    static let bundle = Bundle.module

    static func text(_ key: String, bundle: Bundle? = nil) -> String {
        (bundle ?? Self.bundle).localizedString(forKey: key, value: key, table: "LocalAutomationSettings")
    }

    static func revisionDisclosure(bundle: Bundle? = nil) -> String {
        text(
            "Programs using your account will be able to change an item's current content without asking again. Each change appends an immutable revision. Original content and older revisions remain retained until removed by retention or item deletion; revision is not erasure. This permission does not grant content reading or deletion.",
            bundle: bundle
        )
    }
}
