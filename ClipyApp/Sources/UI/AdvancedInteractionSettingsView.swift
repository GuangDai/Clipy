import Foundation
import SwiftUI

/// Native grouped controls expose the existing panel interaction timings.
/// Sliders produce bounded whole milliseconds; there is no half-valid
/// numeric draft for a concurrent Settings update to consume (V2-07 §6/§9).
struct AdvancedInteractionSettingsView: View {
    @Environment(\.locale) private var interfaceLocale
    @Environment(\.historyBrowsingPreferences) private var browsingPreferences
    @Environment(\.searchHistoryStore) private var searchHistoryStore
    private let defaults: UserDefaults
    @State private var settings: AdvancedInteractionSettings

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _settings = State(initialValue: AdvancedInteractionSettings.load(from: defaults))
    }

    var body: some View {
        let _ = interfaceLocale
        Form {
            Section {
                Toggle(AdvancedInteractionSettingsCopy.text("Remember search between opens"),
                       isOn: binding(\.remembersSearch))
                    .accessibilityIdentifier("clipy.settings.interaction.rememberSearch")
                Toggle(AdvancedInteractionSettingsCopy.text("Select rows when the pointer moves over them"),
                       isOn: binding(\.selectsOnHover))
                    .accessibilityIdentifier("clipy.settings.interaction.selectOnHover")
            } header: {
                Text(AdvancedInteractionSettingsCopy.text("Browsing"))
            } footer: {
                Text(AdvancedInteractionSettingsCopy.text(
                    "The current search draft is remembered between panel opens only while Clipy is running. Saved searches below are managed separately. With pointer selection off, click a row or use the arrow keys."
                ))
            }

            if let browsingPreferences {
                HistoryBrowsingSettingsSection(preferences: browsingPreferences)
            }

            if let searchHistoryStore {
                SearchHistorySettingsSection(store: searchHistoryStore)
            }

            Section {
                timingControl(
                    "Preview delay", keyPath: \.previewDelayMilliseconds,
                    range: AdvancedInteractionSettings.previewDelayRange,
                    identifier: "clipy.settings.interaction.previewDelay"
                )
                timingControl(
                    "Hide preview after leaving", keyPath: \.pointerGraceMilliseconds,
                    range: AdvancedInteractionSettings.pointerGraceRange,
                    identifier: "clipy.settings.interaction.pointerGrace"
                )
            } header: {
                Text(AdvancedInteractionSettingsCopy.text("Preview timing"))
            } footer: {
                Text(AdvancedInteractionSettingsCopy.text(
                    "A longer delay keeps previews steady while browsing. A longer hide delay gives you more time to move into the preview."
                ))
            }

            Section {
                Button(AdvancedInteractionSettingsCopy.text("Restore interaction defaults")) {
                    let restored = AdvancedInteractionSettings()
                    restored.store(to: defaults)
                    settings = restored
                    browsingPreferences?.restoreDefaults()
                }
                .accessibilityIdentifier("clipy.settings.interaction.restoreDefaults")
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let latest = AdvancedInteractionSettings.load(from: defaults)
            if settings != latest { settings = latest }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AdvancedInteractionSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                settings = AdvancedInteractionSettings.update(in: defaults) { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func timingControl(
        _ title: String,
        keyPath: WritableKeyPath<AdvancedInteractionSettings, Int>,
        range: ClosedRange<Int>,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(AdvancedInteractionSettingsCopy.text(title))
                Spacer(minLength: 8)
                Text(Duration.milliseconds(settings[keyPath: keyPath]), format: .units(
                    allowed: [.milliseconds], width: .abbreviated
                ))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { Double(settings[keyPath: keyPath]) },
                set: { value in
                    guard value.isFinite else { return }
                    let bounded = min(max(value, Double(range.lowerBound)), Double(range.upperBound))
                    binding(keyPath).wrappedValue = Int(bounded.rounded())
                }
            ), in: Double(range.lowerBound)...Double(range.upperBound), step: 50)
            .accessibilityLabel(AdvancedInteractionSettingsCopy.text(title))
            .accessibilityIdentifier(identifier)
        }
    }
}
