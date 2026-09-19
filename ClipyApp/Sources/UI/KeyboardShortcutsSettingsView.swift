import AppKit
import SwiftUI

enum KeyboardShortcutsCopy {
    static func text(_ key: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: key, value: key, table: "KeyboardShortcuts")
    }

    static func conflict(_ action: PanelShortcutAction, bundle: Bundle = .main) -> String {
        String(format: text("Already assigned to %@. Choose another shortcut, or clear that action first.", bundle: bundle),
               text(action.title, bundle: bundle))
    }

    static func failure(_ error: PanelShortcutFailure, bundle: Bundle = .main) -> String {
        switch error {
        case .conflict(let action): conflict(action, bundle: bundle)
        case .globalConflict:
            text("Already assigned to Show or hide history. Choose another shortcut, or change the global shortcut first.", bundle: bundle)
        case .reservedShortcut:
            text("This combination is used for typing or a standard macOS command. Choose another shortcut.", bundle: bundle)
        case .invalidShortcut:
            text("Press a key with optional Command, Control, Option or Shift. Modifier keys alone cannot be recorded.", bundle: bundle)
        }
    }
}

/// Direct shortcut preferences over the app's existing controls. Clearing a
/// row persists an explicit unassigned value; recording/reset errors preserve
/// the old shortcut and identify the conflicting action.
struct KeyboardShortcutsSettingsView: View {
    private struct RecordingTarget: Identifiable {
        let action: PanelShortcutAction
        var id: String { action.rawValue }
    }

    @Environment(\.locale) private var locale
    @State private var settings: PanelShortcutSettings
    @State private var recording: RecordingTarget?
    @State private var failure: String?
    @State private var failureAction: PanelShortcutAction?
    private let summonShortcut: SummonShortcutSettings?
    private let defaults: UserDefaults

    init(summonShortcut: SummonShortcutSettings?, defaults: UserDefaults = .standard) {
        self.summonShortcut = summonShortcut
        self.defaults = defaults
        _settings = State(initialValue: PanelShortcutSettings.load(from: defaults))
    }

    private var bundle: Bundle { PanelActionsCopy.bundle(for: locale) }
    private func text(_ key: String) -> String { KeyboardShortcutsCopy.text(key, bundle: bundle) }

    var body: some View {
        Form {
            if let summonShortcut {
                Section {
                    summonControl(summonShortcut)
                } header: {
                    Text(text("Global"))
                } footer: {
                    Text(text("The summon shortcut works while another app is active. If you clear it, open Clipy from the menu bar."))
                }
            }
            shortcutSection("Browsing", actions: [.focusSearch, .keepOpen, .pauseCapture])
            shortcutSection("Selected item", actions: [.remove, .togglePin, .pinToTop, .pinToBottom, .showDetails])
            shortcutSection("Preview", actions: [.quickLook, .togglePreview, .retryPreview])
            shortcutSection("Search", actions: [.exactSearch, .fuzzySearch, .regexpSearch, .clearSearch, .clearFilters])
            Section {
                if failureAction == nil, let failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("clipy.settings.keyboard.error")
                }
                Button(text("Restore all panel shortcuts to defaults")) {
                    do {
                        for action in PanelShortcutAction.allCases {
                            if let chord = action.defaultChord { try validateAgainstSummon(chord) }
                        }
                        PanelShortcutSettings.resetAll(in: defaults)
                        settings = PanelShortcutSettings.load(from: defaults)
                        failure = nil
                    } catch {
                        show(error, action: nil)
                    }
                }
                .accessibilityIdentifier("clipy.settings.keyboard.resetAll")
            } footer: {
                Text(text("Panel shortcuts work while the history panel is active. Return pastes, Escape closes, Command-comma opens Settings, and Command-Q quits. Native text editing and navigation keys keep their standard behavior."))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $recording) { target in
            PanelShortcutRecorderSheet(action: target.action) { chord in
                try validateAgainstSummon(chord)
                try PanelShortcutSettings.update(target.action, to: chord, in: defaults)
                settings = PanelShortcutSettings.load(from: defaults)
                failure = nil
            }
            .onAppear { summonShortcut?.beginRecording() }
            .onDisappear { summonShortcut?.endRecording() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            settings = PanelShortcutSettings.load(from: defaults)
        }
    }

    private func shortcutSection(_ title: String, actions: [PanelShortcutAction]) -> some View {
        Section {
            ForEach(actions, id: \.rawValue) { action in shortcutRow(action) }
        } header: {
            HStack {
                Text(text(title))
                Spacer()
                Button(text("Restore defaults")) {
                    do {
                        for action in actions {
                            if let chord = action.defaultChord { try validateAgainstSummon(chord) }
                        }
                        try PanelShortcutSettings.reset(actions, in: defaults)
                        settings = PanelShortcutSettings.load(from: defaults)
                        failure = nil
                    } catch {
                        if let first = actions.first { show(error, action: first) }
                    }
                }
                .controlSize(.small)
                .help(text("Restore the default shortcuts in this group"))
                .accessibilityLabel(text("Restore defaults") + ": " + text(title))
                .accessibilityIdentifier("clipy.settings.keyboard.group.\(actions.first?.rawValue ?? title).reset")
            }
        }
    }

    private func shortcutRow(_ action: PanelShortcutAction) -> some View {
        let chord = settings.binding(for: action)
        return VStack(alignment: .leading, spacing: 6) {
            SettingsFieldLayout {
                Text(text(action.title))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(chord?.displayName ?? text("Not set")) {
                        failure = nil
                        recording = RecordingTarget(action: action)
                    }
                    .font(.body.monospaced())
                    .frame(minWidth: 86)
                    .help(text("Click to record a shortcut"))
                    .accessibilityLabel(text(action.title))
                    .accessibilityValue(chord?.displayName ?? text("Not set"))
                    .accessibilityIdentifier("clipy.settings.keyboard.\(action.rawValue).record")
                    Button {
                        change(action, to: nil)
                    } label: { Image(systemName: "xmark.circle") }
                        .disabled(chord == nil)
                        .help(text("Clear shortcut"))
                        .accessibilityLabel(text("Clear shortcut") + ": " + text(action.title))
                        .accessibilityIdentifier("clipy.settings.keyboard.\(action.rawValue).clear")
                    Button {
                        do {
                            if let chord = action.defaultChord { try validateAgainstSummon(chord) }
                            try PanelShortcutSettings.reset(action, in: defaults)
                            settings = PanelShortcutSettings.load(from: defaults)
                            failure = nil
                        } catch { show(error, action: action) }
                    } label: { Image(systemName: "arrow.counterclockwise") }
                        .help(text("Restore default"))
                        .accessibilityLabel(text("Restore default") + ": " + text(action.title))
                        .accessibilityIdentifier("clipy.settings.keyboard.\(action.rawValue).reset")
                }
            }
            if failureAction == action, let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("clipy.settings.keyboard.error")
            }
        }
    }

    @ViewBuilder
    private func summonControl(_ settings: SummonShortcutSettings) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsFieldLayout {
                Text(text("Show or hide history"))
                HStack(spacing: 8) {
                    Button(summonLabel(settings.status)) { settings.beginChange() }
                        .font(.body.monospaced())
                        .disabled(!settings.canChange)
                        .help(text("Click to record a shortcut"))
                        .accessibilityLabel(text("Show or hide history"))
                        .accessibilityValue(summonLabel(settings.status))
                        .accessibilityIdentifier("clipy.settings.shortcut.change")
                    Button { settings.clear() } label: { Image(systemName: "xmark.circle") }
                        .disabled(!settings.canClear)
                        .help(text("Clear shortcut"))
                        .accessibilityLabel(text("Clear shortcut"))
                        .accessibilityIdentifier("clipy.settings.shortcut.clear")
                    Button { settings.reset() } label: { Image(systemName: "arrow.counterclockwise") }
                        .disabled(!settings.canReset)
                        .help(text("Restore default"))
                        .accessibilityLabel(text("Restore default"))
                        .accessibilityIdentifier("clipy.settings.shortcut.reset")
                }
            }
            if case let .unavailable(requested, retainedCurrent) = settings.status {
                Label(SettingsCopy.shortcutUnavailable(requested), systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("clipy.settings.shortcut.error")
                if let retainedCurrent {
                    Text(SettingsCopy.retainedShortcut(retainedCurrent))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(SettingsCopy.text("Retry")) { settings.retry() }
                    .disabled(!settings.canRetry)
                    .accessibilityIdentifier("clipy.settings.shortcut.retry")
            }
            if settings.warning == .showColorsConflict {
                Text(SettingsCopy.text("This shortcut is also the standard Show Colors shortcut."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("clipy.settings.shortcut.warning")
            }
            if let conflict = settings.conflictingPanelAction {
                Label(KeyboardShortcutsCopy.conflict(conflict, bundle: bundle), systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("clipy.settings.shortcut.conflict")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipy.settings.shortcut.status")
    }

    private func summonLabel(_ status: SummonShortcutStatus) -> String {
        switch status {
        case .stopped: SettingsCopy.text("Not registered")
        case .disabled: text("Not set")
        case .current(let chord): chord
        case .unavailable(let requested, let retainedCurrent): retainedCurrent ?? requested
        }
    }

    private func change(_ action: PanelShortcutAction, to chord: PanelShortcutChord?) {
        do {
            if let chord { try validateAgainstSummon(chord) }
            try PanelShortcutSettings.update(action, to: chord, in: defaults)
            settings = PanelShortcutSettings.load(from: defaults)
            failure = nil
        } catch { show(error, action: action) }
    }

    private func show(_ error: any Error, action: PanelShortcutAction?) {
        failureAction = action
        failure = KeyboardShortcutsCopy.failure(error as? PanelShortcutFailure ?? .invalidShortcut, bundle: bundle)
    }

    private func validateAgainstSummon(_ chord: PanelShortcutChord) throws {
        if chord == summonShortcut?.currentPanelChord { throw PanelShortcutFailure.globalConflict }
    }
}

private struct PanelShortcutRecorderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var failure: PanelShortcutFailure?
    let action: PanelShortcutAction
    let onCandidate: @MainActor (PanelShortcutChord) throws -> Void

    private var bundle: Bundle { PanelActionsCopy.bundle(for: locale) }
    private func text(_ key: String) -> String { KeyboardShortcutsCopy.text(key, bundle: bundle) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text(action.title)).font(.headline)
            Text(text("Press the new shortcut. Press Escape to cancel."))
                .foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                Text(text("Recording…")).font(.body.monospaced()).allowsHitTesting(false)
                PanelShortcutRecorderInput(accessibilityLabel: text("Record shortcut")) { keyCode, flags, characters in
                    guard keyCode != 53 else { dismiss(); return }
                    guard let chord = PanelShortcutChord(keyCode: keyCode,
                        modifierFlagsRawValue: flags, charactersIgnoringModifiers: characters) else {
                        failure = .invalidShortcut
                        return
                    }
                    do { try onCandidate(chord); dismiss() }
                    catch { failure = error as? PanelShortcutFailure ?? .invalidShortcut }
                }
                .accessibilityLabel(text("Record shortcut"))
                .accessibilityIdentifier("clipy.settings.keyboard.recorder")
            }
            .frame(height: 40)
            if let failure {
                Label(KeyboardShortcutsCopy.failure(failure, bundle: bundle), systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("clipy.settings.keyboard.recordingError")
            }
            HStack {
                Spacer()
                Button(text("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("clipy.settings.keyboard.recordingCancel")
            }
        }
        .padding(20)
        .frame(width: 430)
    }
}

/// Reuses the same AppKit first responder and scoped key-event monitor as
/// global summon recording; only panel key admission differs.
private struct PanelShortcutRecorderInput: NSViewRepresentable {
    let accessibilityLabel: String
    let onRawKey: @MainActor (UInt16, UInt, String?) -> Void

    func makeNSView(context: Context) -> SummonShortcutRecorderInputView {
        let view = SummonShortcutRecorderInputView(onRawKey: onRawKey)
        view.setAccessibilityLabel(accessibilityLabel)
        return view
    }

    func updateNSView(_ nsView: SummonShortcutRecorderInputView, context: Context) {
        nsView.onRawKey = onRawKey
        nsView.setAccessibilityLabel(accessibilityLabel)
        nsView.focusForRecording()
    }

    static func dismantleNSView(_ nsView: SummonShortcutRecorderInputView, coordinator: ()) {
        nsView.stopMonitoringKeyEvents()
    }
}
