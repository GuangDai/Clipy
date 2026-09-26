import Foundation
import HistoryCore
import SwiftUI

// MARK: General

/// General tab (contract §4.4): Launch at Login, the capture ignore list,
/// and explicit history clearing. Keyboard shortcuts have their own Settings
/// category. Panel placement lives
/// on the Appearance tab; retention controls are grouped together in
/// `RetentionSettingsTab` as required by `V2-07` §6.3.
struct GeneralSettingsTab: View {

    private let viewState: HistoryViewState
    private let launchAtLogin: LaunchAtLoginSettings?

    @AppStorage(AppLanguageSettings.defaultsKey) private var language: AppLanguage = .system

    @State private var status: SettingStatus?
    @State private var isWorking = false
    @State private var isConfirmingClearUnpinned = false
    @State private var isConfirmingClearAll = false
    @State private var isShowingClearActions = false

    init(
        viewState: HistoryViewState,
        launchAtLogin: LaunchAtLoginSettings?
    ) {
        self.viewState = viewState
        self.launchAtLogin = launchAtLogin
    }

    var body: some View {
        Form {
            Section(AppLanguageCopy.text("Language")) {
                Picker(AppLanguageCopy.text("Interface language"), selection: $language) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(language.title).tag(language)
                    }
                }
                .accessibilityIdentifier("clipy.settings.language")
                Text(AppLanguageCopy.text("Changes apply immediately. Your open drafts stay unchanged."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let launchAtLogin {
                Section(SettingsCopy.text("Startup")) {
                    launchAtLoginControl(launchAtLogin)
                }
            }
            CapturePrivacySettingsView()
            Section {
                DisclosureGroup(
                    AdaptiveSettingsCopy.text("Clear History"),
                    isExpanded: $isShowingClearActions
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        Button(SettingsCopy.text("Clear Unpinned Items…"), role: .destructive) {
                            isConfirmingClearUnpinned = true
                        }
                        .disabled(isWorking)
                        .confirmationDialog(
                            SettingsCopy.text("Remove all unpinned items?"),
                            isPresented: $isConfirmingClearUnpinned,
                            titleVisibility: .visible
                        ) {
                            Button(SettingsCopy.text("Clear Unpinned Items"), role: .destructive) {
                                Task { await performClear(.unpinned) }
                            }
                            Button(SettingsCopy.text("Cancel"), role: .cancel) {}
                        }
                        Button(SettingsCopy.text("Clear All History…"), role: .destructive) {
                            isConfirmingClearAll = true
                        }
                        .disabled(isWorking)
                        .confirmationDialog(
                            SettingsCopy.text("Remove every item, including pinned items?"),
                            isPresented: $isConfirmingClearAll,
                            titleVisibility: .visible
                        ) {
                            Button(SettingsCopy.text("Clear All History"), role: .destructive) {
                                Task { await performClear(.all) }
                            }
                            Button(SettingsCopy.text("Cancel"), role: .cancel) {}
                        }
                        if isWorking {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(SettingsCopy.text("Clearing history…"))
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("clipy.settings.general.clear-progress")
                        }
                        if let status {
                            SettingStatusView(status: status)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                }
                .disclosureGroupStyle(AppDisclosureGroupStyle(identifier: "clipy.settings.general.clear-history"))
            } footer: {
                Text(AdaptiveSettingsCopy.text("Clearing history permanently removes saved clipboard content."))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin?.refresh()
        }
    }

    @ViewBuilder
    private func launchAtLoginControl(
        _ settings: LaunchAtLoginSettings
    ) -> some View {
        Toggle(
            SettingsCopy.text("Launch at Login"),
            isOn: Binding(
                get: { settings.isOn },
                set: { settings.setEnabled($0) }
            )
        )
        .disabled(!settings.canToggle)
        .accessibilityIdentifier("clipy.settings.launch-at-login")

        switch settings.state {
        case .off, .on:
            EmptyView()
        case .requiresApproval:
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    SettingsCopy.text("Approval is required in System Settings."),
                    systemImage: "person.badge.clock"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(
                    "clipy.settings.launch-at-login.approval-required"
                )
                Button(SettingsCopy.text("Open Login Items Settings")) {
                    settings.openSystemSettings()
                }
                .accessibilityIdentifier(
                    "clipy.settings.launch-at-login.open-system-settings"
                )
            }
        case .unavailable:
            Label(
                SettingsCopy.text("Launch at Login is unavailable for this app."),
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(
                "clipy.settings.launch-at-login.unavailable"
            )
        }

        if settings.operationFailed {
            Label(
                SettingsCopy.text("The Launch at Login setting couldn't be changed."),
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.red)
            .accessibilityIdentifier(
                "clipy.settings.launch-at-login.operation-failed"
            )
        }
    }

    /// Performs one Danger Zone clear (03a §5 `clear`/`ClearScope`).
    ///
    /// The awaitable view-state intent preserves the receipt needed for the
    /// mandated "Removed N items." feedback while keeping receipt-confirmed
    /// Card 9B surface purge publication at the shared mutation owner. Every
    /// receipt state maps to deliberate feedback in `clearStatusFeedback` —
    /// no blanket "Done." catch-all (deep review Card 10).
    private func performClear(_ scope: ClearScope) async {
        guard !isWorking else { return }
        isWorking = true
        status = nil
        defer { isWorking = false }
        do {
            let receipt = try await viewState.clearAwaitingReceipt(scope)
            status = clearStatusFeedback(receipt)
        } catch let failure as HistoryFailure {
            status = .failure(FailurePresentation.message(for: failure))
        } catch {
            status = .failure(RetentionSettingsCopy.clearFailure)
        }
    }

}
