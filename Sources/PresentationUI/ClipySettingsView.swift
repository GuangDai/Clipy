/// ClipySettingsView.swift — the Settings scene body (⌘,): a General tab
/// (the optional Launch-at-Login toggle, the summon-shortcut block, the
/// capture ignore list, and the Danger Zone clears), an Appearance tab
/// (panel placement, preview behavior, row density and typography, and the
/// panel-size reset), and a Retention tab (the unified
/// v1 count + V2-02 policy group; the first
/// release is M1 + V2-02, so this is the ONLY V2
/// settings surface — V2-07 §5 intro, §6.3).
/// Owning spec: docs/01-architecture.md §2 (PresentationUI responsibilities)
/// and §8 (target confinement); count policy: docs/03a-instruction-set.md
/// §5 (`setRetentionPolicy`, `clear`/`ClearScope`) with receipts per §6;
/// failure rendering: docs/03b-instruction-set.md §10 via
/// `FailurePresentation`; bounds: docs/06-cross-cutting.md §2
/// (`userMaximumUnpinnedRange` 1–5,000, default 200); retention:
/// docs/v2/V2-02-retention.md §3.1 (both-nil revision normalization),
/// §8.1 (action + receipt), §8.3 (admission ranges), §12 (receipt feedback);
/// UX: docs/v2/V2-07-ux.md §5.2, §6.3, §9 (accessibility).
/// SwiftUI over HistoryCore DTOs only — no AppKit, no SwiftData, and no
/// ServiceManagement (the login binding is wired by the ClipyApp
/// composition root, which owns SMAppService).
import Foundation
import HistoryCore
import SwiftUI

/// The Settings window content: a `TabView` with General, Appearance, and
/// Retention tabs (step-9 design contract §4.4). The container carries no
/// fixed frame; each tab declares its own ideal size (General 480×440,
/// Appearance 480×400, Retention 480×560) so the window takes the standard
/// per-tab resizing behavior when the selection changes.
///
/// The Retention tab opens from the authoritative configured-policy read
/// (`V2-07` §6.3 — Apply is gated on it, audit SPEC-IMPL-003), and the
/// General and Retention tabs mutate History through `HistoryViewState`,
/// reporting outcomes inline —
/// success text derived from the action's
/// `HistoryCommitOutcome` (03a §6), failures mapped by
/// `FailurePresentation.message(for:)` (03b §10) or by the retention
/// recovery guidance (V2-07 §5.2). Nothing here reads SwiftData, Domain
/// state, or fingerprints; only immutable `Sendable` HistoryCore values
/// cross the view-state boundary (01 §6).
public struct ClipySettingsView: View {

    /// The shared panel view state (step-9 design contract §3); settings
    /// mutations ride the same `ClipboardHistory` seam and its observation
    /// loop refreshes the panel after every commit.
    private let viewState: HistoryViewState

    /// Neutral immutable state plus narrow intents from the ClipyApp-owned
    /// ServiceManagement controller. This target never imports that framework.
    private let launchAtLogin: LaunchAtLoginSettings?

    /// Framework-neutral Card 14B registration status and recovery intents.
    /// Carbon and persisted key facts remain owned by ClipyApp.
    private let summonShortcut: SummonShortcutSettings?

    /// Non-`nil` only when the composition root owns a floating panel whose
    /// placement the user can configure (the geometry lives in ClipyApp —
    /// PresentationUI carries the mode value only).
    private let popupPosition: Binding<PopupPositionMode>?

    /// One panel-owned configured snapshot and edit generation shared by the
    /// v1 count control and all V2 dimensions (DEC-RET-READ / Card 10A).
    /// Hoisting this state prevents two tab-local reads from rendering
    /// different durable configurations and gives the count field the same
    /// late-read fence as the expansion fields.
    @State private var retentionDraft = RetentionSettingsDraft()
    @State private var hasLoadedRetentionConfiguration = false
    @State private var retentionConfigurationFailure: String?

    /// - Parameters:
    ///   - viewState: the shared interaction-state object (contract §3).
    ///   - launchAtLogin: when non-`nil`, the General tab shows the
    ///     "Launch at Login" state and controls; `nil` (previews, hosted
    ///     tests) omits the toggle entirely.
    ///   - summonShortcut: when non-`nil`, the General tab shows the current
    ///     binding or unavailable candidate plus Change/Retry/Reset recovery.
    ///   - popupPosition: when non-`nil`, the Appearance tab shows the panel
    ///     position picker bound to it; `nil` omits the picker entirely.
    public init(
        viewState: HistoryViewState,
        launchAtLogin: LaunchAtLoginSettings? = nil,
        summonShortcut: SummonShortcutSettings? = nil,
        popupPosition: Binding<PopupPositionMode>? = nil
    ) {
        self.viewState = viewState
        self.launchAtLogin = launchAtLogin
        self.summonShortcut = summonShortcut
        self.popupPosition = popupPosition
    }

    public var body: some View {
        TabView {
            GeneralSettingsTab(
                viewState: viewState,
                launchAtLogin: launchAtLogin,
                summonShortcut: summonShortcut
            )
                .tabItem { Label("General", systemImage: "gear") }
                .frame(width: 480, height: 440)
            AppearanceSettingsTab(popupPosition: popupPosition)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
                // The two added typography pickers (snippet lines, font
                // size) grew the tab beyond the shipped 320pt ideal height.
                .frame(width: 480, height: 400)
            RetentionSettingsTab(
                viewState: viewState,
                draft: $retentionDraft,
                hasLoadedRetentionConfiguration: hasLoadedRetentionConfiguration,
                retentionConfigurationFailure: retentionConfigurationFailure
            )
                .tabItem { Label("Retention", systemImage: "clock.arrow.circlepath") }
                .frame(width: 480, height: 560)
        }
        .task { await loadRetentionConfiguration() }
    }

    /// One public read supplies both tabs. A response racing a user edit is
    /// merged per field by `RetentionSettingsDraft`; the fact that the read
    /// completed still unlocks Apply because the authoritative comparison
    /// baseline arrived even when newer text wins the display merge.
    private func loadRetentionConfiguration() async {
        let request = retentionDraft.beginLoadRequest()
        do {
            let configuration = try await viewState.retentionConfiguration()
            retentionDraft.acceptLoaded(configuration, requestedAt: request)
            hasLoadedRetentionConfiguration = true
            retentionConfigurationFailure = nil
        } catch let failure as HistoryFailure {
            retentionConfigurationFailure = FailurePresentation.message(for: failure)
        } catch {
            retentionConfigurationFailure = "The current retention settings could not be read."
        }
    }
}

// MARK: General

/// General tab (contract §4.4): the optional Launch-at-Login toggle
/// ("Startup"), the summon-shortcut block with its Show-Colors advisory
/// ("Keyboard Shortcut"), the capture ignore list ("Privacy"), and the
/// Danger Zone clears. Panel placement lives
/// on the Appearance tab; retention controls are grouped together in
/// `RetentionSettingsTab` as required by `V2-07` §6.3.
private struct GeneralSettingsTab: View {

    private let viewState: HistoryViewState
    private let launchAtLogin: LaunchAtLoginSettings?
    private let summonShortcut: SummonShortcutSettings?

    @State private var status: SettingStatus?
    @State private var isWorking = false
    @State private var isConfirmingClearUnpinned = false
    @State private var isConfirmingClearAll = false

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
                Section("Startup") {
                    launchAtLoginControl(launchAtLogin)
                }
            }
            if let summonShortcut {
                Section("Keyboard Shortcut") {
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
                        .accessibilityLabel("Remove \(bundleID)")
                    }
                }
                HStack {
                    TextField(
                        "Bundle identifier, e.g. com.1password.1password",
                        text: $ignoredBundleIDDraft
                    )
                    Button("Add") { addIgnoredBundleID() }
                        .accessibilityIdentifier(
                            "clipy.settings.privacy.add-ignore"
                        )
                        .disabled(!canAddIgnoredBundleID)
                }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Clipboard contents from these apps are never recorded.")
            }
            .accessibilityIdentifier("clipy.settings.privacy.ignored-list")
            GroupBox("Danger Zone") {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Clear Unpinned Items…") {
                        isConfirmingClearUnpinned = true
                    }
                    .foregroundStyle(.red)
                    .disabled(isWorking)
                    .confirmationDialog(
                        "Remove all unpinned items?",
                        isPresented: $isConfirmingClearUnpinned,
                        titleVisibility: .visible
                    ) {
                        Button("Clear Unpinned Items", role: .destructive) {
                            Task { await performClear(.unpinned) }
                        }
                        Button("Cancel", role: .cancel) {}
                    }
                    Button("Clear All History…") {
                        isConfirmingClearAll = true
                    }
                    .foregroundStyle(.red)
                    .disabled(isWorking)
                    .confirmationDialog(
                        "Remove every item, including pinned items?",
                        isPresented: $isConfirmingClearAll,
                        titleVisibility: .visible
                    ) {
                        Button("Clear All History", role: .destructive) {
                            Task { await performClear(.all) }
                        }
                        Button("Cancel", role: .cancel) {}
                    }
                    if let status {
                        SettingStatusView(status: status)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
            LabeledContent("Summon shortcut", value: "Not registered")
                .accessibilityIdentifier("clipy.settings.shortcut.status")
        case .current(let chord):
            HStack {
                LabeledContent("Summon shortcut", value: chord)
                    .accessibilityIdentifier("clipy.settings.shortcut.status")
                shortcutChangeButton(settings)
                Button("Reset") { settings.reset() }
                    .disabled(!settings.canReset)
                    .accessibilityIdentifier("clipy.settings.shortcut.reset")
            }
        case .unavailable(let requested, let retainedCurrent):
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    "\(requested) is unavailable.",
                    systemImage: "exclamationmark.triangle"
                )
                .accessibilityIdentifier("clipy.settings.shortcut.status")
                if let retainedCurrent {
                    Text("The current \(retainedCurrent) shortcut still works.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    shortcutChangeButton(settings)
                    Button("Retry") { settings.retry() }
                        .disabled(!settings.canRetry)
                        .accessibilityIdentifier("clipy.settings.shortcut.retry")
                    Button("Reset") { settings.reset() }
                        .disabled(!settings.canReset)
                        .accessibilityIdentifier("clipy.settings.shortcut.reset")
                }
            }
        }

        if settings.warning == .showColorsConflict {
            Text("This shortcut is also the standard Show Colors shortcut.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("clipy.settings.shortcut.warning")
        }
    }

    private func shortcutChangeButton(
        _ settings: SummonShortcutSettings
    ) -> some View {
        Button("Change…") { settings.beginChange() }
            .disabled(!settings.canChange)
            .accessibilityIdentifier("clipy.settings.shortcut.change")
    }

    @ViewBuilder
    private func launchAtLoginControl(
        _ settings: LaunchAtLoginSettings
    ) -> some View {
        Toggle(
            "Launch at Login",
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
            HStack {
                Label(
                    "Approval is required in System Settings.",
                    systemImage: "person.badge.clock"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(
                    "clipy.settings.launch-at-login.approval-required"
                )
                Spacer(minLength: 8)
                Button("Open Login Items Settings") {
                    settings.openSystemSettings()
                }
                .accessibilityIdentifier(
                    "clipy.settings.launch-at-login.open-system-settings"
                )
            }
        case .unavailable:
            Label(
                "Launch at Login is unavailable for this app.",
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
                "The Launch at Login setting couldn't be changed.",
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
            status = .failure("The history could not be cleared.")
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

// MARK: Appearance

/// Appearance tab: the panel-chrome half of the Settings consolidation
/// surface (`V2-07` §6). Placement rides the composition root's optional
/// `PopupPositionMode` binding; row density, snippet line count, font size,
/// preview auto-open, and preview side persist through `@AppStorage` under
/// the `PanelAppearanceSettings` keys with the same product defaults its
/// `load(from:)` fails open to, so an untouched control and an absent
/// defaults entry always agree. The preview, row-density, and typography
/// preferences apply live; only panel position and the panel-size reset
/// apply the next time the panel opens, which the Panel section footer
/// discloses. The
/// preview column's width has no control here — the panel's own divider
/// drag owns it (`PanelGeometry.previewColumnWidthDefaultsKey`).
private struct AppearanceSettingsTab: View {

    private let popupPosition: Binding<PopupPositionMode>?

    /// `@AppStorage` reads and writes the persisted raw values; the enum
    /// conversion happens at the control's tag, keeping this view a pure
    /// projection of the same UserDefaults keys `PanelAppearanceSettings`
    /// owns. The wrapped defaults below are the documented product defaults.
    @AppStorage(PanelAppearanceSettings.rowDensityDefaultsKey)
    private var rowDensity: HistoryRowDensity = .comfortable
    @AppStorage(PanelAppearanceSettings.snippetLineCountDefaultsKey)
    private var snippetLineCount: HistorySnippetLineCount = .automatic
    @AppStorage(PanelAppearanceSettings.rowFontSizeDefaultsKey)
    private var rowFontSize: HistoryRowFontSize = .medium
    @AppStorage(PanelAppearanceSettings.previewAutoOpenDefaultsKey)
    private var isPreviewAutoOpenEnabled = true
    @AppStorage(PanelAppearanceSettings.previewSideDefaultsKey)
    private var previewSide: PreviewSidePreference = .automatic

    init(popupPosition: Binding<PopupPositionMode>?) {
        self.popupPosition = popupPosition
    }

    var body: some View {
        Form {
            Section {
                if let popupPosition {
                    Picker("Panel position", selection: popupPosition) {
                        ForEach(PopupPositionMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .accessibilityIdentifier(
                        "clipy.settings.appearance.panel-position"
                    )
                }
                Picker("Preview side", selection: $previewSide) {
                    ForEach(PreviewSidePreference.allCases, id: \.self) { side in
                        Text(previewSideLabel(side)).tag(side)
                    }
                }
                .accessibilityIdentifier(
                    "clipy.settings.appearance.preview-side"
                )
                Toggle(
                    "Open preview automatically",
                    isOn: $isPreviewAutoOpenEnabled
                )
                .accessibilityIdentifier(
                    "clipy.settings.appearance.preview-auto-open"
                )
                Button("Reset Panel Size to Default") {
                    Self.resetPersistedPanelSize()
                }
                .accessibilityIdentifier(
                    "clipy.settings.appearance.reset-panel-size"
                )
            } header: {
                Text("Panel")
            } footer: {
                Text("Panel position and size changes apply the next time the panel opens.")
            }
            Section("List") {
                Picker("Row density", selection: $rowDensity) {
                    ForEach(HistoryRowDensity.allCases, id: \.self) { density in
                        Text(rowDensityLabel(density)).tag(density)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier(
                    "clipy.settings.appearance.row-density"
                )
                Picker("Snippet lines", selection: $snippetLineCount) {
                    ForEach(HistorySnippetLineCount.allCases, id: \.self) { count in
                        Text(snippetLineCountLabel(count)).tag(count)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier(
                    "clipy.settings.appearance.snippet-lines"
                )
                Picker("Font size", selection: $rowFontSize) {
                    ForEach(HistoryRowFontSize.allCases, id: \.self) { size in
                        Text(rowFontSizeLabel(size)).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier(
                    "clipy.settings.appearance.font-size"
                )
            }
        }
        .formStyle(.grouped)
    }

    /// The settings-picker labels. They stay view-local so the persisted
    /// raw values remain the only cross-module vocabulary.
    private func previewSideLabel(_ side: PreviewSidePreference) -> String {
        switch side {
        case .automatic: return "Automatic"
        case .leading: return "Left"
        case .trailing: return "Right"
        }
    }

    private func rowDensityLabel(_ density: HistoryRowDensity) -> String {
        switch density {
        case .compact: return "Compact"
        case .comfortable: return "Comfortable"
        }
    }

    /// Auto stays short — a four-segment "Automatic" risks truncation; the
    /// explicit cases label with their raw counts.
    private func snippetLineCountLabel(_ count: HistorySnippetLineCount) -> String {
        switch count {
        case .automatic: return "Auto"
        case .one: return "1"
        case .two: return "2"
        case .three: return "3"
        }
    }

    private func rowFontSizeLabel(_ size: HistoryRowFontSize) -> String {
        switch size {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    /// Removing both keys returns the next panel open to the geometry
    /// defaults: `PanelGeometry.persistedSize(from:)` falls back per key,
    /// so a deleted entry is indistinguishable from a fresh install.
    private static func resetPersistedPanelSize() {
        let defaults = UserDefaults.standard
        defaults.removeObject(
            forKey: PanelGeometry.panelContentWidthDefaultsKey
        )
        defaults.removeObject(forKey: PanelGeometry.panelHeightDefaultsKey)
    }
}

// MARK: Retention

/// Retention tab — the unified count + V2-02 group (V2-07 §5.2/§6.3;
/// DC-23). The count remains its separate v1 `.setRetentionPolicy` action,
/// while age/storage/revision apply together through
/// `HistoryViewState.applyRetentionPolicies` (`.setRetentionPolicies`,
/// `V2-02` §8.1 — a set replaces the whole policy value).
///
/// Field bounds mirror the HistoryStorage admission ranges (`V2-02` §8.3)
/// one-for-one so Apply never sends a value storage will reject; disabling
/// a dimension sends `nil` for it (DC-23). Every control opens at the
/// persisted configured policy loaded on appear (`V2-07` §6.3's panel-open
/// read; audit SPEC-IMPL-003), and Apply stays disabled until that read
/// lands — an unexamined Apply against the neutral prefill could otherwise
/// silently wipe a real persisted policy. The read is the configured
/// policy only: no live usage readout exists on the public surface (the
/// OPEN-2 exclusion — V2-07 §5.2 "live storage indicator not available").
private struct RetentionSettingsTab: View {

    private let viewState: HistoryViewState

    /// Exact configured values plus whole-unit display text and edit
    /// generations. Keeping this as one value prevents one field from being
    /// rounded merely because another field was edited.
    @Binding private var draft: RetentionSettingsDraft
    private let hasLoadedRetentionConfiguration: Bool
    private let retentionConfigurationFailure: String?
    @State private var countStatus: SettingStatus?
    @State private var policyStatus: SettingStatus?
    @State private var isWorking = false
    @State private var pendingCountSubmission:
        RetentionSettingsDraft.CountSubmission?
    @State private var isConfirmingCountTightening = false
    @State private var pendingSubmission: RetentionSettingsDraft.Submission?
    @State private var isConfirmingTightening = false

    init(
        viewState: HistoryViewState,
        draft: Binding<RetentionSettingsDraft>,
        hasLoadedRetentionConfiguration: Bool,
        retentionConfigurationFailure: String?
    ) {
        self.viewState = viewState
        _draft = draft
        self.hasLoadedRetentionConfiguration = hasLoadedRetentionConfiguration
        self.retentionConfigurationFailure = retentionConfigurationFailure
    }

    var body: some View {
        ScrollView {
            Form {
                Section("Items") {
                    LabeledContent("Keep at most") {
                        HStack {
                            TextField("200", text: maximumUnpinnedText)
                                .frame(width: 88)
                                .multilineTextAlignment(.trailing)
                                .accessibilityLabel("Maximum unpinned items")
                                .accessibilityIdentifier(
                                    "clipy.settings.retention.maximum-unpinned"
                                )
                            Stepper(
                                "",
                                value: maximumUnpinnedStepperValue,
                                in: HistoryLimits.standard.userMaximumUnpinnedRange
                            )
                            .labelsHidden()
                            .accessibilityLabel("Maximum unpinned items")
                            Text("unpinned items")
                        }
                    }
                    if maximumUnpinnedValue == nil {
                        Text(unpinnedRangeHint)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Button("Apply Item Limit") {
                        requestMaximumUnpinnedApply()
                    }
                    .accessibilityIdentifier(
                        "clipy.settings.retention.apply-item-limit"
                    )
                    .disabled(
                        !draft.maximumUnpinnedInputIsValid
                            || !draft.hasCountChanges
                            || isWorking
                            || !hasLoadedRetentionConfiguration
                    )
                    .confirmationDialog(
                        "Apply a stricter item limit?",
                        isPresented: $isConfirmingCountTightening,
                        titleVisibility: .visible
                    ) {
                        Button("Apply Stricter Limit", role: .destructive) {
                            guard let submission = pendingCountSubmission else {
                                return
                            }
                            Task { await applyMaximumUnpinned(submission) }
                        }
                        Button("Cancel", role: .cancel) {
                            pendingCountSubmission = nil
                        }
                    } message: {
                        Text(
                            "A stricter limit can immediately remove unpinned items, and they can't be recovered."
                        )
                    }
                    // The status sits on its own row below the button so a
                    // long receipt or failure message can never squeeze the
                    // Apply button (V2-07 §9 inline feedback).
                    if let successMessage = draft.acceptedCountSuccessMessage {
                        SettingStatusView(status: .success(successMessage))
                            .accessibilityIdentifier(
                                "clipy.settings.retention.item-limit-status"
                            )
                    } else if let countStatus {
                        SettingStatusView(status: countStatus)
                            .accessibilityIdentifier(
                                "clipy.settings.retention.item-limit-status"
                            )
                    } else if let retentionConfigurationFailure {
                        SettingStatusView(status: .failure(retentionConfigurationFailure))
                    }
                }
                Section("Item age") {
                    Toggle("Limit item age", isOn: ageEnabled)
                        .accessibilityHint("Retire items whose last copy is older than the entered age.")
                        .accessibilityIdentifier("clipy.settings.retention.age-enabled")
                    ValueFieldRow(
                        label: "Maximum item age",
                        unit: "days",
                        accessibilityIdentifier: "clipy.settings.retention.age-days",
                        text: ageDaysText,
                        isEnabled: draft.ageEnabled,
                        isValid: draft.ageInputIsValid,
                        range: RetentionSettingsDraft.ageDaysRange
                    )
                    Text(RetentionSettingsDraft.ageEnforcementExplanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(
                            "clipy.settings.retention.age-enforcement"
                        )
                }
                Section("Storage") {
                    Toggle("Limit storage budget", isOn: storageEnabled)
                        .accessibilityHint("Retire the oldest unpinned items until history fits the budget.")
                        .accessibilityIdentifier("clipy.settings.retention.storage-enabled")
                    ValueFieldRow(
                        label: "Storage budget",
                        unit: RetentionSettingsDraft.mebibyteUnitLabel,
                        accessibilityIdentifier: "clipy.settings.retention.storage-mib",
                        text: storageMiBText,
                        isEnabled: draft.storageEnabled,
                        isValid: draft.storageInputIsValid,
                        range: RetentionSettingsDraft.storageMiBRange
                    )
                }
                Section("Revision limits") {
                    Toggle("Keep at most", isOn: revisionCountEnabled)
                        .accessibilityHint("Prune the oldest inactive revisions beyond this count.")
                    ValueFieldRow(
                        label: "Revisions per item",
                        unit: "revisions",
                        accessibilityIdentifier: "clipy.settings.retention.revision-count",
                        text: revisionCountText,
                        isEnabled: draft.revisionCountEnabled,
                        isValid: draft.revisionCountInputIsValid,
                        range: RetentionSettingsDraft.revisionCountRange
                    )
                    Toggle("Limit revision storage", isOn: revisionBytesEnabled)
                        .accessibilityHint("Prune the oldest inactive revisions until they fit this budget.")
                    ValueFieldRow(
                        label: "Revision storage per item",
                        unit: RetentionSettingsDraft.mebibyteUnitLabel,
                        accessibilityIdentifier: "clipy.settings.retention.revision-mib",
                        text: revisionMiBText,
                        isEnabled: draft.revisionBytesEnabled,
                        isValid: draft.revisionBytesInputIsValid,
                        range: RetentionSettingsDraft.revisionMiBRange
                    )
                }
                Section {
                    Button("Apply") {
                        requestApply()
                    }
                    .accessibilityIdentifier("clipy.settings.retention.apply")
                    .disabled(
                        !draft.inputIsValid || !draft.hasPolicyChanges || isWorking
                            || !hasLoadedRetentionConfiguration
                    )
                    .confirmationDialog(
                        "Apply stricter retention limits?",
                        isPresented: $isConfirmingTightening,
                        titleVisibility: .visible
                    ) {
                        Button("Apply Stricter Limits", role: .destructive) {
                            guard let submission = pendingSubmission else { return }
                            Task { await applyRetention(submission) }
                        }
                        Button("Cancel", role: .cancel) {
                            pendingSubmission = nil
                        }
                    } message: {
                        // Deep review `04` Red 10D: only a strict local
                        // tightening is destructive-confirmed; equal or
                        // looser policy values apply directly.
                        Text("Stricter limits can permanently remove items or revisions.")
                    }
                    // Same own-row treatment as the item-limit status above:
                    // a long receipt or failure message must not squeeze the
                    // Apply button.
                    if let successMessage = draft.acceptedSuccessMessage {
                        SettingStatusView(status: .success(successMessage))
                            .accessibilityIdentifier(
                                "clipy.settings.retention.policy-status"
                            )
                    } else if let policyStatus {
                        SettingStatusView(status: policyStatus)
                            .accessibilityIdentifier(
                                "clipy.settings.retention.policy-status"
                            )
                    } else if let retentionConfigurationFailure {
                        SettingStatusView(status: .failure(retentionConfigurationFailure))
                    }
                    Text("Changes apply to new and existing items at once.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding([.horizontal, .bottom])
        }
    }

    /// The parsed count, or `nil` when the text is not a whole number
    /// inside `userMaximumUnpinnedRange` (06 §2).
    private var maximumUnpinnedValue: Int? {
        draft.countSubmission()?.maximumUnpinnedItems
    }

    private var maximumUnpinnedText: Binding<String> {
        Binding(
            get: { draft.maximumUnpinnedText },
            set: {
                draft.setMaximumUnpinnedText($0)
                countStatus = nil
            }
        )
    }

    /// Stepper binding: reads the typed value clamped into the §2 range
    /// (an out-of-range or unparseable field steps from the nearest legal
    /// state instead of refusing), writes back plain decimal text.
    private var maximumUnpinnedStepperValue: Binding<Int> {
        Binding<Int>(
            get: {
                guard let typed = Int(
                    draft.maximumUnpinnedText
                        .trimmingCharacters(in: .whitespaces)
                ) else {
                    return HistoryLimits.standard.defaultMaximumUnpinnedItems
                }
                let range = HistoryLimits.standard.userMaximumUnpinnedRange
                return min(max(typed, range.lowerBound), range.upperBound)
            },
            set: {
                draft.setMaximumUnpinnedText(String($0))
                countStatus = nil
            }
        )
    }

    private var unpinnedRangeHint: String {
        let range = HistoryLimits.standard.userMaximumUnpinnedRange
        return "Enter a whole number from \(range.lowerBound) to \(range.upperBound)."
    }

    /// Count is part of the same destructive-retention family as the V2
    /// thresholds: lowering the configured value requires confirmation;
    /// equal or looser values apply directly (`04` Red 10D).
    private func requestMaximumUnpinnedApply() {
        guard draft.hasCountChanges,
              let submission = draft.countSubmission() else { return }
        if draft.maximumUnpinnedRequiresTightening(for: submission) {
            pendingCountSubmission = submission
            isConfirmingCountTightening = true
        } else {
            Task { await applyMaximumUnpinned(submission) }
        }
    }

    /// Applies the count policy and reports the receipt inline
    /// (`.retentionPolicySet(removedCount:)`, 03a §6; V2-07 §5.2). Every
    /// receipt state maps to deliberate feedback in
    /// `maximumUnpinnedStatusFeedback` — no blanket "Done." catch-all
    /// (deep review Card 10).
    private func applyMaximumUnpinned(
        _ submission: RetentionSettingsDraft.CountSubmission
    ) async {
        guard draft.isCurrent(submission) else { return }
        pendingCountSubmission = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let receipt = try await viewState.applyMaximumUnpinnedItems(
                submission.maximumUnpinnedItems
            )
            switch maximumUnpinnedStatusFeedback(receipt) {
            case .success(let successMessage):
                guard draft.acceptApplied(
                    submission,
                    successMessage: successMessage
                ) else { return }
                countStatus = nil
            case .failure(let message):
                // A committed receipt without `.retentionPolicySet` cannot
                // confirm this submission; the configured comparison
                // baseline stays put so the next Apply still compares
                // against the last known configuration.
                guard draft.isCurrent(submission) else { return }
                countStatus = .failure(message)
            }
        } catch let failure as HistoryFailure {
            guard draft.isCurrent(submission) else { return }
            countStatus = .failure(FailurePresentation.message(for: failure))
        } catch {
            guard draft.isCurrent(submission) else { return }
            countStatus = .failure("The setting could not be saved.")
        }
    }

    private var ageEnabled: Binding<Bool> {
        Binding(
            get: { draft.ageEnabled },
            set: {
                draft.setAgeEnabled($0)
                policyStatus = nil
            }
        )
    }

    private var ageDaysText: Binding<String> {
        Binding(
            get: { draft.ageDaysText },
            set: {
                draft.setAgeDaysText($0)
                policyStatus = nil
            }
        )
    }

    private var storageEnabled: Binding<Bool> {
        Binding(
            get: { draft.storageEnabled },
            set: {
                draft.setStorageEnabled($0)
                policyStatus = nil
            }
        )
    }

    private var storageMiBText: Binding<String> {
        Binding(
            get: { draft.storageMiBText },
            set: {
                draft.setStorageMiBText($0)
                policyStatus = nil
            }
        )
    }

    private var revisionCountEnabled: Binding<Bool> {
        Binding(
            get: { draft.revisionCountEnabled },
            set: {
                draft.setRevisionCountEnabled($0)
                policyStatus = nil
            }
        )
    }

    private var revisionCountText: Binding<String> {
        Binding(
            get: { draft.revisionCountText },
            set: {
                draft.setRevisionCountText($0)
                policyStatus = nil
            }
        )
    }

    private var revisionBytesEnabled: Binding<Bool> {
        Binding(
            get: { draft.revisionBytesEnabled },
            set: {
                draft.setRevisionBytesEnabled($0)
                policyStatus = nil
            }
        )
    }

    private var revisionMiBText: Binding<String> {
        Binding(
            get: { draft.revisionMiBText },
            set: {
                draft.setRevisionMiBText($0)
                policyStatus = nil
            }
        )
    }

    private func requestApply() {
        guard draft.hasPolicyChanges,
              let submission = draft.submission() else { return }
        if draft.requiresTighteningConfirmation(for: submission.policies) {
            pendingSubmission = submission
            isConfirmingTightening = true
        } else {
            Task { await applyRetention(submission) }
        }
    }

    /// Applies all dimensions as one policy value and reports the receipt
    /// inline (`.retentionPoliciesSet(retiredItems:prunedRevisions:)`,
    /// 03a §6 / `V2-02` §8.1; feedback per V2-07 §5.2). Every receipt state
    /// maps to deliberate feedback in `retentionPoliciesStatusFeedback` —
    /// no blanket "Done." catch-all (deep review Card 10).
    private func applyRetention(
        _ submission: RetentionSettingsDraft.Submission
    ) async {
        guard draft.isCurrent(submission) else { return }
        pendingSubmission = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let receipt = try await viewState.applyRetentionPolicies(submission.policies)
            switch retentionPoliciesStatusFeedback(receipt) {
            case .success(let successMessage):
                guard draft.acceptApplied(
                    submission,
                    successMessage: successMessage
                ) else { return }
                policyStatus = nil
            case .failure(let message):
                // A committed receipt without `.retentionPoliciesSet`
                // cannot confirm this submission; the configured
                // comparison baseline stays put so the next Apply still
                // compares against the last known configuration.
                guard draft.isCurrent(submission) else { return }
                policyStatus = .failure(message)
            }
        } catch let failure as HistoryFailure {
            guard draft.isCurrent(submission) else { return }
            policyStatus = .failure(Self.retentionFailureMessage(failure))
        } catch {
            guard draft.isCurrent(submission) else { return }
            policyStatus = .failure("The policies could not be saved.")
        }
    }

    /// Retention-specific recovery guidance (V2-07 §5.2): the set-time
    /// pinned-over-budget rejection and the unsatisfiable R2 budget carry
    /// their own text; every other failure falls through to the shared
    /// `FailurePresentation` mapping (03b §10).
    private static func retentionFailureMessage(_ failure: HistoryFailure) -> String {
        switch failure {
        case .invalidInput(.invalidRetentionPolicy):
            return "Pinned items exceed this budget. Unpin items or raise the budget."
        case .capacityExceeded(.storageBytes):
            return "This budget can't be satisfied with the current history."
        default:
            return FailurePresentation.message(for: failure)
        }
    }
}

// MARK: Shared helpers

/// One enable-gated numeric value row for the Retention tab: labeled
/// field + unit, disabled while its dimension is off, with the range hint
/// shown only while the enabled field's text is invalid (V2-07 §9 — the
/// field carries its own accessibility label; the caption is the
/// invalid-input state, never the only cue).
private struct ValueFieldRow: View {

    let label: String
    let unit: String
    let accessibilityIdentifier: String
    @Binding var text: String
    let isEnabled: Bool
    let isValid: Bool
    let range: ClosedRange<Int>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer(minLength: 12)
                TextField("", text: $text)
                    .frame(width: 88)
                    .multilineTextAlignment(.trailing)
                    .disabled(!isEnabled)
                    .accessibilityLabel(label)
                    .accessibilityIdentifier(accessibilityIdentifier)
                Text(unit)
                    .foregroundStyle(.secondary)
            }
            if isEnabled && !isValid {
                Text("Enter a whole number from \(range.lowerBound) to \(range.upperBound).")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

/// Inline outcome of one settings mutation: success carries receipt-derived
/// text, failure carries the already-mapped user-facing message. Internal
/// (not private) so the SwiftPM suites pin the receipt-feedback mapping
/// directly through `@testable`, like `validatedSettingsWholeNumber`.
internal enum SettingStatus: Equatable {
    case success(String)
    case failure(String)
}

/// One-line status rendering; the icon pairs with the text so the outcome
/// is never conveyed by color alone (V2-07 §9 point 3).
private struct SettingStatusView: View {

    let status: SettingStatus

    var body: some View {
        switch status {
        case .success(let message):
            Label(message, systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }
}

// MARK: Receipt feedback

/// Exact per-receipt feedback for one Danger Zone clear (deep review Card
/// 10): a committed clear reports its removed count ("Removed N items." —
/// plural-aware, 03a §6); `.unchanged` means the scope matched nothing, so
/// no History Commit exists and no removal is implied (02 §8); a commit
/// carrying another action's outcome is a boundary violation, rendered as a
/// failure rather than a blanket success.
internal func clearStatusFeedback(_ receipt: HistoryReceipt) -> SettingStatus {
    switch receipt {
    case .committed(let commit):
        guard case .cleared(count: let removed) = commit.outcome else {
            return .failure("The history could not be cleared.")
        }
        switch removed {
        case 0:
            return .success("Done.")
        case 1:
            return .success("Removed 1 item.")
        default:
            return .success("Removed \(removed) items.")
        }
    case .unchanged:
        return .success("Nothing to clear.")
    }
}

/// Exact per-receipt feedback for one item-count apply (deep review Card
/// 10): a committed `.setRetentionPolicy` reports its removed count
/// ("Done. N items removed." — plural-aware, 03a §6; V2-07 §5.2);
/// `.unchanged` means the submitted count already equals the persisted
/// value and nothing was written (02 §8/§12); a commit carrying another
/// action's outcome is a boundary violation, rendered as a failure rather
/// than a blanket success.
internal func maximumUnpinnedStatusFeedback(
    _ receipt: HistoryReceipt
) -> SettingStatus {
    switch receipt {
    case .committed(let commit):
        guard case .retentionPolicySet(removedCount: let removed)
                = commit.outcome else {
            return .failure("The setting could not be saved.")
        }
        switch removed {
        case 0:
            return .success("Done.")
        case 1:
            return .success("Done. 1 item removed.")
        default:
            return .success("Done. \(removed) items removed.")
        }
    case .unchanged:
        return .success("No change.")
    }
}

/// Exact per-receipt feedback for one V2-02 policy apply (deep review Card
/// 10): a committed `.setRetentionPolicies` reports retired items and
/// pruned revisions separately ("Done. N items retired, M revisions
/// pruned." — plural-aware; transparent data-minimization feedback,
/// `V2-02` §12); `.unchanged` means the submitted bundle already equals
/// the persisted policy and nothing was written (`V2-02` §4.4/§5.6); a
/// commit carrying another action's outcome is a boundary violation,
/// rendered as a failure rather than a blanket success.
internal func retentionPoliciesStatusFeedback(
    _ receipt: HistoryReceipt
) -> SettingStatus {
    switch receipt {
    case .committed(let commit):
        guard case .retentionPoliciesSet(
            retiredItems: let retired,
            prunedRevisions: let pruned
        ) = commit.outcome else {
            return .failure("The policies could not be saved.")
        }
        if retired == 0 && pruned == 0 {
            return .success("Done.")
        }
        let retiredPhrase = retired == 1
            ? "1 item retired"
            : "\(retired) items retired"
        let prunedPhrase = pruned == 1
            ? "1 revision pruned"
            : "\(pruned) revisions pruned"
        return .success("Done. \(retiredPhrase), \(prunedPhrase).")
    case .unchanged:
        return .success("No change.")
    }
}

#Preview("Settings") {
    ClipySettingsView(
        viewState: HistoryViewState(history: PreviewClipboardHistory.populated),
        launchAtLogin: LaunchAtLoginSettings(state: .on),
        summonShortcut: SummonShortcutSettings(
            status: .current("⇧⌘C"),
            warning: .showColorsConflict
        ),
        popupPosition: .constant(.cursor)
    )
}
