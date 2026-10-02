import SwiftUI

/// The two surfaces have independent opening policies. Remembering layout
/// remains a separate, content-free choice from remembering a reading item.
struct HistoryBrowsingSettingsSection: View {
    @Environment(\.locale) private var interfaceLocale
    @Bindable var preferences: HistoryBrowsingPreferences

    var body: some View {
        let _ = interfaceLocale
        Section {
            openingPicker("Floating panel opens at", selection: $preferences.panelOpeningPosition,
                identifier: "clipy.settings.browsing.panel-position")
            openingPicker("Settings History opens at", selection: $preferences.workspaceOpeningPosition,
                identifier: "clipy.settings.browsing.workspace-position")
            if preferences.readingItemID(for: .panel) != nil || preferences.readingItemID(for: .workspace) != nil {
                Button(HistoryBrowsingCopy.text("Forget saved reading positions")) {
                    preferences.clearReadingPosition(for: .panel)
                    preferences.clearReadingPosition(for: .workspace)
                }
                .accessibilityIdentifier("clipy.settings.browsing.forget-positions")
            }
        } header: {
            Text(HistoryBrowsingCopy.text("Opening position"))
        } footer: {
            Text(HistoryBrowsingCopy.text("Last read saves only the record’s identifier, separately for each surface. It does not save clipboard content or search text. If that record is no longer available in the current results, browsing returns to the start with a notice."))
        }

        Section {
            Toggle(HistoryBrowsingCopy.text("Remember History workspace layout"),
                   isOn: $preferences.remembersWorkspaceLayout)
                .accessibilityIdentifier("clipy.settings.browsing.remember-layout")
            Button(HistoryBrowsingCopy.text("Reset History workspace layout")) {
                preferences.resetWorkspaceLayout()
            }
            .accessibilityIdentifier("clipy.settings.browsing.reset-layout")
        } header: {
            Text(HistoryBrowsingCopy.text("History workspace"))
        } footer: {
            Text(HistoryBrowsingCopy.text("Remembers the list and preview widths, sort order, and row density. Turning this off keeps the current layout until the workspace closes and removes its saved layout."))
        }
    }

    private func openingPicker(
        _ title: String, selection: Binding<HistoryOpeningPosition>, identifier: String
    ) -> some View {
        Picker(HistoryBrowsingCopy.text(title), selection: selection) {
            Text(HistoryBrowsingCopy.text("Start of list (current sort order)")).tag(HistoryOpeningPosition.latest)
            Text(HistoryBrowsingCopy.text("Last read position")).tag(HistoryOpeningPosition.lastRead)
        }
        .accessibilityIdentifier(identifier)
    }
}
