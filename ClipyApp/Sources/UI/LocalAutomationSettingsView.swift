import Foundation
import HistoryCore
import SwiftUI

struct LocalAutomationSettingsState: Sendable, Equatable {
    let enabled: Bool
    let grants: Set<ExternalCapability>

    init(enabled: Bool, grants: Set<ExternalCapability>) {
        self.enabled = enabled
        self.grants = grants
    }
}

/// Discoverable bundled tool and explicit desktop actions; no enrollment or
/// credentials are needed to display its location or request command help.
@MainActor
struct LocalAutomationCommandLine {
    let executablePath: String
    let helpCommand: String
    let reveal: @MainActor () -> Void
    let copyHelpCommand: @MainActor () -> Bool

    init(
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
struct LocalAutomationSettings {
    let commandLine: LocalAutomationCommandLine?
    let load: @MainActor () async throws -> LocalAutomationSettingsState
    let enable: @MainActor () async throws -> LocalAutomationSettingsState
    let revoke: @MainActor () async throws -> LocalAutomationSettingsState
    let setCapability: @MainActor (ExternalCapability, Bool) async throws -> LocalAutomationSettingsState

    init(
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

    @State private var showsAdvancedDetails = false

    var body: some View {
        Form {
            accessSection
            commandLineSection
            if model.state?.enabled == true {
                readingPermissionsSection
                writingPermissionsSection
            }
            if model.failed {
                Section {
                    Label(LocalAutomationSettingsCopy.text("Could not update Local Automation. Retry or revoke access."),
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Button(LocalAutomationSettingsCopy.text("Retry")) {
                        Task { await model.load() }
                    }
                    .accessibilityIdentifier("clipy.settings.automation.retry")
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.isWorking)
        .task { await model.load() }
    }

    private var accessSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: model.state?.enabled == true ? "checkmark.circle.fill" : "lock.circle")
                    .font(.title2)
                    .foregroundStyle(model.state?.enabled == true ? Color.green : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalAutomationSettingsCopy.text(model.statusText))
                        .font(.headline)
                        .accessibilityIdentifier("clipy.settings.automation.status")
                    Text(AutomationMaintenancePresentation.text(
                        "Use scripts and Terminal with your clipboard history. You choose what programs can do."
                    ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if model.isWorking {
                    ProgressView().controlSize(.small)
                }
            }
            if model.state?.enabled == true || model.failed {
                Button(LocalAutomationSettingsCopy.text("Revoke Access"), role: .destructive) {
                    Task { await model.revoke() }
                }
                .accessibilityIdentifier("clipy.settings.automation.revoke")
            } else {
                Button(LocalAutomationSettingsCopy.text("Enable Local Automation")) {
                    Task { await model.enable() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.state == nil)
                .accessibilityIdentifier("clipy.settings.automation.enable")
            }
        } header: {
            Text(LocalAutomationSettingsCopy.text("Local Automation"))
        } footer: {
            Text(AutomationMaintenancePresentation.text(
                "Access starts with no permissions. Programs running as your account share the permissions below."
            ))
        }
    }

    private var commandLineSection: some View {
        Section {
            if let commandLine = model.commandLine {
                Text(AutomationMaintenancePresentation.text(
                    "Copy the help command into Terminal to see commands for browsing, searching, and reading history."
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack {
                        copyHelpButton
                        revealToolButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        copyHelpButton
                        revealToolButton
                    }
                }
                if let notice = model.commandLineNotice {
                    Text(LocalAutomationSettingsCopy.text(notice))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("clipy.settings.automation.cli.notice")
                }
                DisclosureGroup(isExpanded: $showsAdvancedDetails) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(AutomationMaintenancePresentation.text("Tool Location"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(commandLine.executablePath)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("clipy.settings.automation.cli.path")
                        Text(AutomationMaintenancePresentation.text("Help Command"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(commandLine.helpCommand)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 6)
                } label: {
                    Text(AutomationMaintenancePresentation.text("Advanced Details"))
                }
                .accessibilityIdentifier("clipy.settings.automation.advanced")
            } else {
                Text(LocalAutomationSettingsCopy.text("The bundled command-line tool is unavailable."))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(LocalAutomationSettingsCopy.text("Command Line"))
        } footer: {
            Text(AutomationMaintenancePresentation.text("Help works without enabling access. Grant Browse Previews to start using history commands."))
        }
    }

    private var copyHelpButton: some View {
        Button(LocalAutomationSettingsCopy.text("Copy Help Command")) { model.copyHelpCommand() }
            .accessibilityIdentifier("clipy.settings.automation.cli.copyHelp")
    }

    private var revealToolButton: some View {
        Button(LocalAutomationSettingsCopy.text("Reveal in Finder")) { model.revealCommandLine() }
            .accessibilityIdentifier("clipy.settings.automation.cli.reveal")
    }

    private var readingPermissionsSection: some View {
        Section {
            capabilityToggle(.browsePreview, title: "Browse Previews", identifier: "browse",
                             summary: "List and search item previews.")
            capabilityToggle(.readEffectiveContent, title: "Read Current Content", identifier: "read",
                             summary: "Read the current text, images, and other clipboard formats.")
        } header: {
            Text(AutomationMaintenancePresentation.text("Read History"))
        }
    }

    private var writingPermissionsSection: some View {
        Section {
            capabilityToggle(.organize, title: "Pin and Unpin Items", identifier: "organize",
                             summary: "Keep important items pinned, or unpin them.")
            capabilityToggle(.deleteItem, title: "Delete Items", identifier: "delete",
                             summary: "Permanently remove individual history items.")
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
            capabilityToggle(.reviseContent, title: "Revise Current Content", identifier: "revise",
                             summary: "Save content changes as new revisions. Earlier content stays retained.")
                .alert(LocalAutomationSettingsCopy.text("Allow Programs to Revise Current Content?"), isPresented: $model.confirmsRevisionGrant) {
                    Button(LocalAutomationSettingsCopy.text("Allow Revisions"), role: .destructive) {
                        Task { await model.confirmRevisionGrant() }
                    }
                    Button(LocalAutomationSettingsCopy.text("Cancel"), role: .cancel) { model.cancelRevisionGrant() }
                } message: {
                    Text(LocalAutomationSettingsCopy.revisionDisclosure())
                }
        } header: {
            Text(AutomationMaintenancePresentation.text("Change History"))
        } footer: {
            Text(LocalAutomationSettingsCopy.text(
                "Permissions are independent. Enabling Local Automation grants none. All programs using your account share these permissions."
            ))
        }
    }

    private func capabilityToggle(
        _ capability: ExternalCapability, title: String, identifier: String, summary: String
    ) -> some View {
        Toggle(isOn: Binding(
            get: { model.state?.grants.contains(capability) == true },
            set: { enabled in
                Task { await model.requestCapability(capability, enabled: enabled) }
            }
        )) {
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalAutomationSettingsCopy.text(title))
                Text(AutomationMaintenancePresentation.text(summary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("clipy.settings.automation.grant.\(identifier)")
    }
}

enum LocalAutomationSettingsCopy {
    static let bundle = Bundle.main

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
