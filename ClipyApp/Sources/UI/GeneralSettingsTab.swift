import Foundation
import HistoryCore
import SwiftUI

// MARK: General

/// General tab (contract §4.4): the optional Launch-at-Login toggle
/// ("Startup"), the summon-shortcut block with its Show-Colors advisory
/// ("Keyboard Shortcut"), the capture ignore list ("Privacy"), and the
/// Danger Zone clears. Panel placement lives
/// on the Appearance tab; retention controls are grouped together in
/// `RetentionSettingsTab` as required by `V2-07` §6.3.
struct GeneralSettingsTab: View {

    private let viewState: HistoryViewState
    private let launchAtLogin: LaunchAtLoginSettings?
    private let summonShortcut: SummonShortcutSettings?

    @State private var status: SettingStatus?
    @State private var isWorking = false
    @State private var isConfirmingClearUnpinned = false
    @State private var isConfirmingClearAll = false
    @State private var isShowingClearActions = false

    /// The capture ignore list, edited as one immutable value: loaded from
    /// UserDefaults on appear and re-stored after every accepted mutation.
    /// `@AppStorage` has no validated-value array story, and the
    /// composition root re-reads the key per capture event, so explicit
    /// load/store calls are both the simplest and the correct pattern.
    @State private var captureIgnoreList = CaptureIgnoreList()
    @State private var ignoredBundleIDDraft = ""

    init(
        viewState: HistoryViewState,
        launchAtLogin: LaunchAtLoginSettings?,
        summonShortcut: SummonShortcutSettings?
    ) {
        self.viewState = viewState
        self.launchAtLogin = launchAtLogin
        self.summonShortcut = summonShortcut
    }

    var body: some View {
        Form {
            if let launchAtLogin {
                Section(SettingsCopy.text("Startup")) {
                    launchAtLoginControl(launchAtLogin)
                }
            }
            if let summonShortcut {
                Section(SettingsCopy.text("Keyboard Shortcut")) {
                    summonShortcutControl(summonShortcut)
                }
            }
            Section {
                ForEach(captureIgnoreList.bundleIDs, id: \.self) { bundleID in
                    HStack {
                        Text(bundleID)
                            .font(.system(.caption, design: .monospaced))
                        Spacer(minLength: 8)
                        Button(role: .destructive) {
                            removeIgnoredBundleID(bundleID)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(SettingsCopy.removeIgnoredApp(bundleID))
                    }
                }
                HStack {
                    TextField(
                        SettingsCopy.text("Bundle identifier, e.g. com.1password.1password"),
                        text: $ignoredBundleIDDraft
                    )
                    Button(SettingsCopy.text("Add")) { addIgnoredBundleID() }
                        .accessibilityIdentifier(
                            "clipy.settings.privacy.add-ignore"
                        )
                        .disabled(!canAddIgnoredBundleID)
                }
            } header: {
                Text(SettingsCopy.text("Privacy"))
            } footer: {
                Text(SettingsCopy.text("Clipboard contents from these apps are never recorded."))
            }
            .accessibilityIdentifier("clipy.settings.privacy.ignored-list")
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
                        if let status {
                            SettingStatusView(status: status)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                }
                .accessibilityIdentifier("clipy.settings.general.clear-history")
            } footer: {
                Text(AdaptiveSettingsCopy.text("Clearing history permanently removes saved clipboard content."))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin?.refresh()
            captureIgnoreList = CaptureIgnoreList.load(from: .standard)
        }
    }

    @ViewBuilder
    private func summonShortcutControl(
        _ settings: SummonShortcutSettings
    ) -> some View {
        switch settings.status {
        case .stopped:
            LabeledContent(SettingsCopy.text("Summon shortcut"), value: SettingsCopy.text("Not registered"))
                .accessibilityIdentifier("clipy.settings.shortcut.status")
        case .current(let chord):
            LabeledContent(SettingsCopy.text("Summon shortcut"), value: chord)
                .accessibilityIdentifier("clipy.settings.shortcut.status")
            HStack {
                shortcutChangeButton(settings)
                Button(SettingsCopy.text("Reset")) { settings.reset() }
                    .disabled(!settings.canReset)
                    .accessibilityIdentifier("clipy.settings.shortcut.reset")
            }
        case .unavailable(let requested, let retainedCurrent):
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    SettingsCopy.shortcutUnavailable(requested),
                    systemImage: "exclamationmark.triangle"
                )
                .accessibilityIdentifier("clipy.settings.shortcut.status")
                if let retainedCurrent {
                    Text(SettingsCopy.retainedShortcut(retainedCurrent))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    shortcutChangeButton(settings)
                    Button(SettingsCopy.text("Retry")) { settings.retry() }
                        .disabled(!settings.canRetry)
                        .accessibilityIdentifier("clipy.settings.shortcut.retry")
                    Button(SettingsCopy.text("Reset")) { settings.reset() }
                        .disabled(!settings.canReset)
                        .accessibilityIdentifier("clipy.settings.shortcut.reset")
                }
            }
        }

        if settings.warning == .showColorsConflict {
            Text(SettingsCopy.text("This shortcut is also the standard Show Colors shortcut."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("clipy.settings.shortcut.warning")
        }
    }

    private func shortcutChangeButton(
        _ settings: SummonShortcutSettings
    ) -> some View {
        Button(SettingsCopy.text("Change…")) { settings.beginChange() }
            .disabled(!settings.canChange)
            .accessibilityIdentifier("clipy.settings.shortcut.change")
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
        isWorking = true
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

    /// Whether the current draft would be accepted: probes a copy with
    /// `CaptureIgnoreList.add` so the Add button is enabled exactly when a
    /// click can succeed (valid reverse-domain shape, not already listed).
    private var canAddIgnoredBundleID: Bool {
        var probe = captureIgnoreList
        return probe.add(ignoredBundleIDDraft)
    }

    /// Accepts the draft, persists the mutation, and clears the field; an
    /// invalid or duplicate draft leaves the list and the field unchanged.
    private func addIgnoredBundleID() {
        guard captureIgnoreList.add(ignoredBundleIDDraft) else { return }
        captureIgnoreList.store(to: .standard)
        ignoredBundleIDDraft = ""
    }

    /// Removes one entry and persists the mutation.
    private func removeIgnoredBundleID(_ bundleID: String) {
        captureIgnoreList.remove(bundleID)
        captureIgnoreList.store(to: .standard)
    }
}
