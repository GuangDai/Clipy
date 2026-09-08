import Foundation
import HistoryCore
import SwiftUI

/// A native sidebar keeps categories stable while each pane fills the
/// resizable Settings window. The exact retention draft outlives category
/// changes so navigating away never discards unsaved edits (V2-07 §6.3).
struct ClipySettingsView: View {

    /// The shared panel view state (step-9 design contract §3); settings
    /// mutations ride the same `ClipboardHistory` seam and its observation
    /// loop refreshes the panel after every commit.
    private let viewState: HistoryViewState

    /// Neutral immutable state plus narrow intents from the ClipyApp-owned
    /// ServiceManagement controller. The view does not own registration.
    private let launchAtLogin: LaunchAtLoginSettings?

    /// Framework-neutral Card 14B registration status and recovery intents.
    /// Carbon and persisted key facts remain owned by ClipyApp.
    private let summonShortcut: SummonShortcutSettings?

    /// Non-`nil` only when the composition root owns a floating panel whose
    /// placement the user can configure through the app-owned geometry.
    private let popupPosition: Binding<PopupPositionMode>?
    private let storageLocation: StorageLocationSettings?
    private let localAutomation: LocalAutomationSettings?

    /// One panel-owned configured snapshot and edit generation shared by the
    /// v1 count control and all V2 dimensions (DEC-RET-READ / Card 10A).
    /// Hoisting this state prevents two tab-local reads from rendering
    /// different durable configurations and gives the count field the same
    /// late-read fence as the expansion fields.
    @State private var retentionDraft = RetentionSettingsDraft()
    @State private var hasLoadedRetentionConfiguration = false
    @State private var retentionConfigurationFailure: String?
    @State private var retentionConfigurationRefreshGeneration = 0

    /// - Parameters:
    ///   - viewState: the shared interaction-state object (contract §3).
    ///   - launchAtLogin: when non-`nil`, the General tab shows the
    ///     "Launch at Login" state and controls; `nil` (previews, hosted
    ///     tests) omits the toggle entirely.
    ///   - summonShortcut: when non-`nil`, the General tab shows the current
    ///     binding or unavailable candidate plus Change/Retry/Reset recovery.
    ///   - popupPosition: when non-`nil`, the Appearance tab shows the panel
    ///     position picker bound to it; `nil` omits the picker entirely.
    ///   - storageLocation: when non-`nil`, Maintenance displays logical
    ///     content and approximate folder allocation with read-only intents.
    ///   - localAutomation: when non-`nil`, Automation exposes the app-owned
    ///     explicit enrollment, independent grants and revocation controls.
    init(
        viewState: HistoryViewState,
        launchAtLogin: LaunchAtLoginSettings? = nil,
        summonShortcut: SummonShortcutSettings? = nil,
        popupPosition: Binding<PopupPositionMode>? = nil,
        storageLocation: StorageLocationSettings? = nil,
        localAutomation: LocalAutomationSettings? = nil
    ) {
        self.viewState = viewState
        self.launchAtLogin = launchAtLogin
        self.summonShortcut = summonShortcut
        self.popupPosition = popupPosition
        self.storageLocation = storageLocation
        self.localAutomation = localAutomation
    }

    @AppStorage("clipy.settings.selectedCategory")
    private var savedCategory = SettingsCategory.general.rawValue

    private var category: SettingsCategory {
        let saved = SettingsCategory(rawValue: savedCategory) ?? .general
        if saved == .automation, localAutomation == nil { return .general }
        if saved == .maintenance, storageLocation == nil { return .general }
        return saved
    }

    private var selection: Binding<SettingsCategory?> {
        Binding(
            get: { category },
            set: { if let selected = $0 { savedCategory = selected.rawValue } }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                categoryRow(.general)
                categoryRow(.appearance)
                categoryRow(.retention)
                if localAutomation != nil { categoryRow(.automation) }
                if storageLocation != nil { categoryRow(.maintenance) }
            }
            .listStyle(.sidebar)
            .navigationTitle("Clipy")
            .navigationSplitViewColumnWidth(min: 150, ideal: 175, max: 230)
            .accessibilityIdentifier("clipy.settings.sidebar")
        } detail: {
            detail
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(category.title)
                .accessibilityIdentifier("clipy.settings.detail")
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 560, minHeight: 420)
        .task(id: retentionConfigurationRefreshGeneration) {
            await loadRetentionConfiguration()
        }
        .onDisappear {
            retentionDraft.invalidateLoadRequest()
            hasLoadedRetentionConfiguration = false
            retentionConfigurationFailure = nil
        }
    }

    private func categoryRow(_ item: SettingsCategory) -> some View {
        Button {
            savedCategory = item.rawValue
        } label: {
            Label(item.title, systemImage: item.symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tag(item)
        .accessibilityIdentifier("clipy.settings.category." + item.rawValue)
        .accessibilityAddTraits(category == item ? [.isSelected] : [])
    }

    @ViewBuilder
    private var detail: some View {
        switch category {
        case .general:
            GeneralSettingsTab(
                viewState: viewState,
                launchAtLogin: launchAtLogin,
                summonShortcut: summonShortcut
            )
        case .appearance:
            AppearanceSettingsTab(popupPosition: popupPosition)
        case .retention:
            RetentionSettingsTab(
                viewState: viewState,
                draft: $retentionDraft,
                hasLoadedRetentionConfiguration: hasLoadedRetentionConfiguration,
                retentionConfigurationFailure: retentionConfigurationFailure,
                retryRetentionConfiguration: { retentionConfigurationRefreshGeneration += 1 }
            )
        case .automation:
            if let localAutomation { LocalAutomationSettingsView(settings: localAutomation) }
        case .maintenance:
            if let storageLocation {
                MaintenanceSettingsView(history: viewState.history, location: storageLocation)
            }
        }
    }

    /// One public read supplies both tabs. A response racing a user edit is
    /// merged per field by `RetentionSettingsDraft`; the fact that the read
    /// completed still unlocks Apply because the authoritative comparison
    /// baseline arrived even when newer text wins the display merge.
    private func loadRetentionConfiguration() async {
        guard !Task.isCancelled else { return }
        let request = retentionDraft.beginLoadRequest()
        hasLoadedRetentionConfiguration = false
        retentionConfigurationFailure = nil
        do {
            let configuration = try await viewState.retentionConfiguration()
            guard !Task.isCancelled, retentionDraft.isCurrent(request) else { return }
            retentionDraft.acceptLoaded(configuration, requestedAt: request)
            hasLoadedRetentionConfiguration = true
            retentionConfigurationFailure = nil
        } catch let failure as HistoryFailure {
            guard !Task.isCancelled, retentionDraft.isCurrent(request) else { return }
            retentionConfigurationFailure = FailurePresentation.message(for: failure)
        } catch {
            guard !Task.isCancelled, retentionDraft.isCurrent(request) else { return }
            retentionConfigurationFailure = RetentionSettingsCopy.readFailure
        }
    }
}


private enum SettingsCategory: String, Hashable {
    case general, appearance, retention, automation, maintenance

    var title: String {
        switch self {
        case .general: SettingsCopy.text("General")
        case .appearance: SettingsCopy.text("Appearance")
        case .retention: RetentionSettingsCopy.tabTitle
        case .automation: LocalAutomationSettingsCopy.text("Automation")
        case .maintenance: MaintenanceSettingsCopy.text("Maintenance")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .retention: "clock.arrow.circlepath"
        case .automation: "terminal"
        case .maintenance: "internaldrive"
        }
    }
}
