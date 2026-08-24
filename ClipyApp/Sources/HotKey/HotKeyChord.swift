/// HotKeyChord.swift — the app-internal value used by Clipy's configurable
/// Carbon summon shortcut. The value is deliberately just the two facts the
/// registration API consumes; it is not a command registry or a second input
/// routing layer (01 §2 composition-root ownership; REVIEW Card 14B).
import Carbon.HIToolbox

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

    /// Stable Settings text without guessing the person's current keyboard
    /// layout. The product default has its familiar literal; a custom chord
    /// remains inspectable by its exact Carbon facts because alternate-layout
    /// rendering remains an explicit signed-runtime gap for this slice.
    var settingsDisplayName: String {
        if self == .defaultSummon { return "⇧⌘C" }
        return "Key code \(keyCode), modifiers \(modifiers)"
    }
}

enum HotKeyChordWarning: Equatable, Sendable {
    case knownColorsShortcut
}
