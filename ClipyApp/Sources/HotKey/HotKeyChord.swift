/// HotKeyChord.swift — the app-internal value used by Clipy's configurable
/// Carbon summon shortcut. The value is deliberately just the two facts the
/// registration API consumes; it is not a command registry or a second input
/// routing layer (01 §2 composition-root ownership; REVIEW Card 14B).
import Carbon
import AppKit
import Foundation

struct HotKeyChord: Hashable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    /// Clipy's current product default. Apple lists Shift-Command-C as the
    /// standard "Show Colors" shortcut, so it remains usable but carries an
    /// exact warning for that conflict.
    static let defaultSummon = HotKeyChord(
        keyCode: UInt32(kVK_ANSI_C),
        modifiers: UInt32(cmdKey | shiftKey)
    )

    /// The warning is advisory, not a rejection: REVIEW Card 14B's selected
    /// behavior lets a person keep the existing default while making its exact
    /// Apple-documented Colors conflict visible. Other standard combinations
    /// stay outside this slice; this value is not a shortcut registry.
    var warning: HotKeyChordWarning? {
        self == .defaultSummon ? .knownColorsShortcut : nil
    }

    /// Native modifier symbols plus the current layout's key label. Carbon
    /// registration still uses the exact key code; display never changes it.
    @MainActor
    var settingsDisplayName: String {
        var prefix = ""
        if modifiers & UInt32(controlKey) != 0 { prefix += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { prefix += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { prefix += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { prefix += "⌘" }
        return prefix + (specialKeyLabel ?? keyboardLayoutLabel
            ?? String(format: ShortcutRecorderCopy.text("Key %u"), keyCode))
    }

    /// Compare a global physical chord with the panel's native logical key
    /// equivalents at recording time. A keyboard-layout change may change
    /// this display/collision fact but never the saved Carbon registration.
    @MainActor
    var panelShortcutChord: PanelShortcutChord? {
        guard let keyCode = UInt16(exactly: keyCode) else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return PanelShortcutChord(
            keyCode: keyCode, modifierFlagsRawValue: flags.rawValue,
            // NSEvent.charactersIgnoringModifiers retains Shift, including
            // punctuation such as ⇧1 → !. Use the same character when checking
            // a native panel key equivalent; unshifted labels miss conflicts.
            charactersIgnoringModifiers: keyboardLayoutCharacters(
                modifierKeyState: (modifiers & UInt32(shiftKey)) >> 8
            )?.lowercased()
        )
    }

    @MainActor
    func conflictingPanelAction(in settings: PanelShortcutSettings) -> PanelShortcutAction? {
        guard let chord = panelShortcutChord else { return nil }
        return PanelShortcutAction.allCases.first { settings.binding(for: $0) == chord }
    }

    private var specialKeyLabel: String? {
        switch Int(keyCode) {
        case kVK_Return: return "↩"
        case kVK_ANSI_KeypadEnter: return "⌤"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "␣"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        default:
            let functionKeys = [
                kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5,
                kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
                kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
            ]
            return functionKeys.firstIndex(of: Int(keyCode)).map { "F\($0 + 1)" }
        }
    }

    /// TIS Copy/Get ownership follows Core Foundation rules. Translation is
    /// synchronous and scoped to this display read; no layout pointer escapes.
    @MainActor
    private var keyboardLayoutLabel: String? {
        keyboardLayoutCharacters(
            modifierKeyState: 0, keyAction: UInt16(kUCKeyActionDisplay)
        )?.uppercased()
    }

    @MainActor
    private func keyboardLayoutCharacters(
        modifierKeyState: UInt32,
        keyAction: UInt16 = UInt16(kUCKeyActionDown)
    ) -> String? {
        guard let virtualKeyCode = UInt16(exactly: keyCode),
              let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        return withExtendedLifetime(inputSource) { () -> String? in
            let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 16)
            let result = UCKeyTranslate(
                layout, virtualKeyCode, keyAction, modifierKeyState,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState, characters.count, &length, &characters
            )
            guard result == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }
}

enum HotKeyChordWarning: Equatable, Sendable {
    case knownColorsShortcut
}
