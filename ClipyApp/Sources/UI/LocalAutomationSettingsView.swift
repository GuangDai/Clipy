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

    private let history: (any ClipboardHistory)?
    private let workflowFailure: BuiltInAutomationFailure?

    init(settings: LocalAutomationSettings, history: (any ClipboardHistory)? = nil,
         workflowFailure: BuiltInAutomationFailure? = nil) {
        self.history = history
        self.workflowFailure = workflowFailure
        _model = State(initialValue: LocalAutomationSettingsModel(settings: settings))
    }

    @State private var showsAdvancedDetails = false
    @State private var showsContentPermissions = false

    var body: some View {
        Form {
            Section { BuiltInAutomationSettingsView(history: history, failure: workflowFailure) }
            accessSection
            if model.state?.enabled == true {
                readingPermissionsSection
                organizingPermissionsSection
                writingPermissionsSection
            }
            commandLineSection
        }
        .formStyle(.grouped)
        .task { await model.load() }
        .onChange(of: model.state?.grants.intersection([.reviseContent, .deleteItem])) { _, grants in
            if model.state?.enabled == true, grants?.isEmpty == false {
                showsContentPermissions = true
            }
        }
    }

    private var accessSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: model.failed ? "exclamationmark.circle" : model.state?.enabled == true ? "checkmark.circle.fill" : "lock.circle")
                    .font(.title2)
                    .foregroundStyle(model.failed ? Color.orange : model.state?.enabled == true ? Color.green : Color.secondary)
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
                        .accessibilityLabel(LocalAutomationSettingsCopy.text(model.statusText))
                }
            }
            if let state = model.state, state.enabled, !model.failed {
                Text(LocalAutomationSettingsCopy.permissionSummary(granted: state.grants.count, total: 5))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("clipy.settings.automation.permissionSummary")
            }
            HStack {
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
                Spacer()
                Button(LocalAutomationSettingsCopy.text("Refresh Status")) {
                    Task { await model.load() }
                }
                .accessibilityIdentifier(model.failed ? "clipy.settings.automation.retry" : "clipy.settings.automation.refresh")
            }
            .disabled(model.isWorking)
            if let message = model.failureMessage {
                Label(LocalAutomationSettingsCopy.text(message), systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("clipy.settings.automation.failure")
            } else if let notice = model.notice {
                Text(LocalAutomationSettingsCopy.text(notice))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("clipy.settings.automation.notice")
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
                        commandReference
                        Divider()
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
                .disclosureGroupStyle(AppDisclosureGroupStyle(identifier: "clipy.settings.automation.advanced"))
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
        } footer: {
            Text(AutomationMaintenancePresentation.text("Preview access includes content snippets. Full content requires its own permission."))
        }
    }

    private var organizingPermissionsSection: some View {
        Section {
            capabilityToggle(.organize, title: "Pin and Unpin Items", identifier: "organize",
                             summary: "Keep important items pinned, or unpin them.")
        } header: {
            Text(AutomationMaintenancePresentation.text("Organize History"))
        }
    }

    private var writingPermissionsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showsContentPermissions) {
                VStack(alignment: .leading, spacing: 16) {
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
                    Divider()
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
                }
                .padding(.vertical, 6)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AutomationMaintenancePresentation.text("Revise and Delete Items"))
                    Text(model.failed ? LocalAutomationSettingsCopy.text("Refresh to check permissions.") : LocalAutomationSettingsCopy.permissionSummary(
                        granted: model.state?.grants.intersection([.reviseContent, .deleteItem]).count ?? 0,
                        total: 2
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .disclosureGroupStyle(AppDisclosureGroupStyle(identifier: "clipy.settings.automation.contentPermissions"))
        } header: {
            Text(AutomationMaintenancePresentation.text("Change History"))
        } footer: {
            Text(LocalAutomationSettingsCopy.text(
                "Permissions are independent. Enabling Local Automation grants none. All programs using your account share these permissions."
            ))
        }
    }

    private var commandReference: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AutomationMaintenancePresentation.text("Commands and Permissions"))
                .font(.headline)
            commandReferenceRow("recent · search", permission: "Browse Previews")
            commandReferenceRow("read", permission: "Read Current Content")
            commandReferenceRow("pin · unpin", permission: "Pin and Unpin Items")
            commandReferenceRow("reviseContent (JSON)", permission: "Revise Current Content")
            commandReferenceRow("delete", permission: "Delete Items")
            Text(AutomationMaintenancePresentation.text("Reading returns content to your script; it does not paste or change the system clipboard."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func commandReferenceRow(_ commands: String, permission: String) -> some View {
        LabeledContent {
            Text(LocalAutomationSettingsCopy.text(permission))
                .font(.caption)
        } label: {
            Text(commands).font(.system(.caption, design: .monospaced))
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
        .disabled(!model.canEditCapabilities)
        .accessibilityIdentifier("clipy.settings.automation.grant.\(identifier)")
    }
}

enum LocalAutomationSettingsCopy {
    static let bundle = Bundle.main

    static func text(_ key: String, bundle: Bundle? = nil) -> String {
        (bundle ?? Self.bundle).localizedString(forKey: key, value: key, table: "LocalAutomationSettings")
    }

    static func permissionSummary(granted: Int, total: Int, bundle: Bundle? = nil) -> String {
        String(format: text("%1$lld of %2$lld permissions enabled", bundle: bundle), Int64(granted), Int64(total))
    }

    static func revisionDisclosure(bundle: Bundle? = nil) -> String {
        text(
            "Programs using your account will be able to change an item's current content without asking again. Each change appends an immutable revision. Original content and older revisions remain retained until removed by retention or item deletion; revision is not erasure. This permission does not grant content reading or deletion.",
            bundle: bundle
        )
    }
}
