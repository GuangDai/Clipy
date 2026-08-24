/// SummonShortcutRecorderView.swift — the Settings-owned custom shortcut
/// recorder. AppKit supplies the virtual key code Carbon consumes; the view
/// admits only a non-modifier key plus at least one conventional modifier and
/// sends the resulting candidate through SummonShortcutController (Card 14B).
import AppKit
import Carbon.HIToolbox
import SwiftUI

enum SummonShortcutRecordingDecision: Equatable {
    case cancel
    case reject
    case candidate(HotKeyChord)

    /// `NSEvent.keyCode` is documented as the same hardware-independent value
    /// Carbon exposes as `kEventParamKeyCode`. Escape always cancels; bare keys
    /// and modifier keys never become global bindings (REVIEW UI-8).
    static func decide(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Self {
        if keyCode == UInt16(kVK_Escape) {
            return .cancel
        }

        let admittedFlags = modifierFlags.intersection([
            .command,
            .control,
            .option,
            .shift,
        ])
        guard !admittedFlags.isEmpty,
              !modifierKeyCodes.contains(keyCode)
        else {
            return .reject
        }

        var carbonModifiers: UInt32 = 0
        if admittedFlags.contains(.command) {
            carbonModifiers |= UInt32(cmdKey)
        }
        if admittedFlags.contains(.control) {
            carbonModifiers |= UInt32(controlKey)
        }
        if admittedFlags.contains(.option) {
            carbonModifiers |= UInt32(optionKey)
        }
        if admittedFlags.contains(.shift) {
            carbonModifiers |= UInt32(shiftKey)
        }
        return .candidate(HotKeyChord(
            keyCode: UInt32(keyCode),
            modifiers: carbonModifiers
        ))
    }

    private static let modifierKeyCodes: Set<UInt16> = [
        UInt16(kVK_CapsLock),
        UInt16(kVK_Shift),
        UInt16(kVK_RightShift),
        UInt16(kVK_Control),
        UInt16(kVK_RightControl),
        UInt16(kVK_Option),
        UInt16(kVK_RightOption),
        UInt16(kVK_Command),
        UInt16(kVK_RightCommand),
        UInt16(kVK_Function),
    ]
}

/// The sheet is intentionally transient: cancelling changes nothing, while a
/// candidate closes the sheet and lets Settings render either the new active
/// chord or the controller's visible unavailable/retained-current state.
struct SummonShortcutRecorderView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rejectedInput = false

    let onCandidate: @MainActor (HotKeyChord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Change Summon Shortcut")
                .font(.headline)
            Text("Press a key together with Command, Control, Option, or Shift.")
                .foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                Text("Recording…")
                    .font(.body.monospaced())
                    .allowsHitTesting(false)
                SummonShortcutRecorderInput { decision in
                    switch decision {
                    case .cancel:
                        dismiss()
                    case .reject:
                        rejectedInput = true
                    case .candidate(let chord):
                        onCandidate(chord)
                        dismiss()
                    }
                }
                .accessibilityIdentifier("clipy.settings.shortcut.recorder")
            }
            .frame(height: 36)

            if rejectedInput {
                Text("Use a non-modifier key with at least one modifier.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("clipy.settings.shortcut.recording-error")
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("clipy.settings.shortcut.recording-cancel")
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct SummonShortcutRecorderInput: NSViewRepresentable {
    let onDecision: @MainActor (SummonShortcutRecordingDecision) -> Void

    func makeNSView(context: Context) -> SummonShortcutRecorderInputView {
        SummonShortcutRecorderInputView(onDecision: onDecision)
    }

    func updateNSView(
        _ nsView: SummonShortcutRecorderInputView,
        context: Context
    ) {
        nsView.onDecision = onDecision
        nsView.focusForRecording()
    }

    static func dismantleNSView(
        _ nsView: SummonShortcutRecorderInputView,
        coordinator _: ()
    ) {
        nsView.stopMonitoringKeyEvents()
    }
}

@MainActor
final class SummonShortcutRecorderInputView: NSView {
    var onDecision: @MainActor (SummonShortcutRecordingDecision) -> Void
    private var keyEventMonitor: Any?

    init(
        onDecision: @escaping @MainActor (SummonShortcutRecordingDecision) -> Void
    ) {
        self.onDecision = onDecision
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.textField)
        setAccessibilityLabel("Record summon shortcut")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            stopMonitoringKeyEvents()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        startMonitoringKeyEvents()
        focusForRecording()
    }

    func focusForRecording() {
        guard let window, window.firstResponder !== self else { return }
        Task { @MainActor [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        record(
            keyCode: event.keyCode,
            modifierFlagsRawValue: event.modifierFlags.rawValue,
            isARepeat: event.isARepeat
        )
    }

    /// AppKit's app-local monitor receives keyDown before menu/key-equivalent
    /// dispatch. It exists only while this recorder is mounted, accepts only
    /// events for that exact sheet window, and returns nil so one physical key
    /// cannot reach a second product route.
    private func startMonitoringKeyEvents() {
        guard keyEventMonitor == nil, window != nil else { return }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            let eventWindowNumber = event.windowNumber
            let keyCode = event.keyCode
            let modifierFlagsRawValue = event.modifierFlags.rawValue
            let isARepeat = event.isARepeat
            let consumed = MainActor.assumeIsolated {
                guard let self,
                      self.window?.windowNumber == eventWindowNumber
                else { return false }
                self.record(
                    keyCode: keyCode,
                    modifierFlagsRawValue: modifierFlagsRawValue,
                    isARepeat: isARepeat
                )
                return true
            }
            return consumed ? nil : event
        }
    }

    /// Apple requires one removal per returned monitor token. Clear ownership
    /// before calling the framework so both SwiftUI dismantle and view detach
    /// are safe when they occur for the same sheet teardown.
    func stopMonitoringKeyEvents() {
        guard let keyEventMonitor else { return }
        self.keyEventMonitor = nil
        NSEvent.removeMonitor(keyEventMonitor)
    }

    /// The local monitor and direct responder fallback share one submission
    /// point. A repeat is consumed by its caller but cannot apply twice.
    private func record(
        keyCode: UInt16,
        modifierFlagsRawValue: UInt,
        isARepeat: Bool
    ) {
        guard !isARepeat else { return }
        onDecision(.decide(
            keyCode: keyCode,
            modifierFlags: NSEvent.ModifierFlags(
                rawValue: modifierFlagsRawValue
            )
        ))
    }

    /// Modifier-only input arrives as flagsChanged rather than keyDown. It is
    /// deliberately consumed as an incomplete chord and never submitted.
    override func flagsChanged(with event: NSEvent) {
        _ = event
    }
}
