import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI

enum PanelShortcutAction: String, CaseIterable, Sendable, Codable {
    case focusSearch, exactSearch, fuzzySearch, regexpSearch, clearSearch, clearFilters
    case remove, togglePin, pinToTop, pinToBottom, showDetails
    case quickLook, togglePreview, retryPreview, previousPDFPage, nextPDFPage
    case keepOpen, pauseCapture

    enum Group: Sendable { case browsing, selection, preview }

    var group: Group {
        switch self {
        case .focusSearch, .exactSearch, .fuzzySearch, .regexpSearch, .clearSearch, .clearFilters,
             .keepOpen, .pauseCapture: .browsing
        case .remove, .togglePin, .pinToTop, .pinToBottom, .showDetails: .selection
        case .quickLook, .togglePreview, .retryPreview, .previousPDFPage, .nextPDFPage: .preview
        }
    }

    var title: String {
        switch self {
        case .focusSearch: "Focus search"
        case .exactSearch: "Exact search"
        case .fuzzySearch: "Fuzzy search"
        case .regexpSearch: "Regular expression search"
        case .clearSearch: "Clear search"
        case .clearFilters: "Clear filters"
        case .remove: "Remove selected item"
        case .togglePin: "Pin or unpin selected item"
        case .pinToTop: "Pin to top"
        case .pinToBottom: "Pin to bottom"
        case .showDetails: "Show details"
        case .quickLook: "Quick Look"
        case .togglePreview: "Show or hide preview"
        case .retryPreview: "Retry preview"
        case .previousPDFPage: "Previous PDF page"
        case .nextPDFPage: "Next PDF page"
        case .keepOpen: "Keep panel open"
        case .pauseCapture: "Pause capture for 5 minutes"
        }
    }

    var defaultChord: PanelShortcutChord? {
        switch self {
        case .focusSearch: PanelShortcutChord(key: "f", modifiers: .command)
        case .exactSearch: PanelShortcutChord(key: "1", modifiers: .command)
        case .fuzzySearch: PanelShortcutChord(key: "2", modifiers: .command)
        case .regexpSearch: PanelShortcutChord(key: "3", modifiers: .command)
        case .remove: PanelShortcutChord(key: "delete", modifiers: [])
        case .togglePin: PanelShortcutChord(key: "p", modifiers: .command)
        case .pinToTop: PanelShortcutChord(key: "upArrow", modifiers: [.option, .command])
        case .pinToBottom: PanelShortcutChord(key: "downArrow", modifiers: [.option, .command])
        case .showDetails: PanelShortcutChord(key: "i", modifiers: .command)
        case .quickLook: PanelShortcutChord(key: "space", modifiers: [])
        case .togglePreview: PanelShortcutChord(key: "p", modifiers: [.shift, .command])
        case .retryPreview: PanelShortcutChord(key: "r", modifiers: .command)
        case .previousPDFPage: PanelShortcutChord(key: "leftArrow", modifiers: [.option, .command])
        case .nextPDFPage: PanelShortcutChord(key: "rightArrow", modifiers: [.option, .command])
        case .clearSearch, .clearFilters, .keepOpen, .pauseCapture: nil
        }
    }
}

struct PanelShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt8
    static let command = Self(rawValue: 1)
    static let option = Self(rawValue: 2)
    static let control = Self(rawValue: 4)
    static let shift = Self(rawValue: 8)

    var eventModifiers: SwiftUI.EventModifiers {
        var result: SwiftUI.EventModifiers = []
        if contains(.command) { result.insert(.command) }
        if contains(.option) { result.insert(.option) }
        if contains(.control) { result.insert(.control) }
        if contains(.shift) { result.insert(.shift) }
        return result
    }
}

/// Logical key equivalents follow the active keyboard layout, just like
/// native menu shortcuts. Return, Escape, Tab and system editing commands
/// continue through AppKit's existing responder chain (V2-07 §9).
struct PanelShortcutChord: Codable, Hashable, Sendable {
    let key: String
    let modifiers: PanelShortcutModifiers

    init(key: String, modifiers: PanelShortcutModifiers) {
        self.key = key.count == 1 ? key.lowercased() : key
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        self.init(keyCode: event.keyCode, modifierFlagsRawValue: event.modifierFlags.rawValue,
                  charactersIgnoringModifiers: event.charactersIgnoringModifiers)
    }

    init?(keyCode: UInt16, modifierFlagsRawValue: UInt, charactersIgnoringModifiers: String?) {
        let flags = NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
        var modifiers: PanelShortcutModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        let key: String
        switch Int(keyCode) {
        case kVK_Space: key = "space"
        case kVK_Delete: key = "delete"
        case kVK_LeftArrow: key = "leftArrow"
        case kVK_RightArrow: key = "rightArrow"
        case kVK_DownArrow: key = "downArrow"
        case kVK_UpArrow: key = "upArrow"
        default:
            let functionKeyCodes = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5,
                kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
                kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
            if let index = functionKeyCodes.firstIndex(of: Int(keyCode)) {
                key = "f\(index + 1)"
            } else {
                guard let charactersIgnoringModifiers, charactersIgnoringModifiers.count == 1,
                      let scalar = charactersIgnoringModifiers.unicodeScalars.first else { return nil }
                guard scalar.value >= 33, scalar.value < 127 else { return nil }
                key = charactersIgnoringModifiers.lowercased()
            }
        }
        self.init(key: key, modifiers: modifiers)
    }

    var displayName: String {
        let prefix = (modifiers.contains(.control) ? "⌃" : "")
            + (modifiers.contains(.option) ? "⌥" : "")
            + (modifiers.contains(.shift) ? "⇧" : "")
            + (modifiers.contains(.command) ? "⌘" : "")
        let label: String
        switch key {
        case "space": label = "␣"
        case "delete": label = "⌫"
        case "leftArrow": label = "←"
        case "rightArrow": label = "→"
        case "upArrow": label = "↑"
        case "downArrow": label = "↓"
        default: label = key.uppercased()
        }
        return prefix + label
    }

    fileprivate var keyEquivalent: KeyEquivalent? {
        switch key {
        case "space": return .space
        case "delete": return .delete
        case "leftArrow": return .leftArrow
        case "rightArrow": return .rightArrow
        case "upArrow": return .upArrow
        case "downArrow": return .downArrow
        default:
            if let functionKeyNumber, let scalar = UnicodeScalar(0xF704 + functionKeyNumber - 1) {
                return KeyEquivalent(Character(scalar))
            }
            guard key.count == 1, let character = key.first,
                  let scalar = key.unicodeScalars.first,
                  scalar.value >= 33, scalar.value < 127 else { return nil }
            return KeyEquivalent(character)
        }
    }

    private var functionKeyNumber: UInt32? {
        guard key.first == "f", let number = UInt32(key.dropFirst()),
              (1...20).contains(number), key == "f\(number)" else { return nil }
        return number
    }

    fileprivate func validate() throws {
        guard modifiers.rawValue & ~UInt8(15) == 0, keyEquivalent != nil else {
            throw PanelShortcutFailure.invalidShortcut
        }
        // Bare printing keys type into search; Option-only keys compose
        // characters, and Control-only keys are native text navigation.
        if modifiers.intersection([.command, .control]).isEmpty,
           !(modifiers.isEmpty && (["space", "delete"].contains(key) || functionKeyNumber != nil)) {
            throw PanelShortcutFailure.reservedShortcut
        }
        if modifiers.contains(.control), !modifiers.contains(.command), !modifiers.contains(.option) {
            throw PanelShortcutFailure.reservedShortcut
        }
        if modifiers.contains(.command),
           ["a", "c", "x", "v", "z", "y", "w", "q", "h", "m", ","].contains(key) {
            throw PanelShortcutFailure.reservedShortcut
        }
    }

    fileprivate var requiresHistoryFocus: Bool {
        (modifiers.isEmpty && functionKeyNumber == nil)
            || ["delete", "leftArrow", "rightArrow", "upArrow", "downArrow"].contains(key)
    }
}

enum PanelShortcutFailure: Error, Equatable {
    case conflict(PanelShortcutAction)
    case globalConflict
    case reservedShortcut
    case invalidShortcut
}

struct PanelShortcutSettings: Equatable, Sendable {
    static let defaultsKey = "clipy.keyboard.panelShortcuts"
    private var bindings: [PanelShortcutAction: PanelShortcutChord] = Dictionary(uniqueKeysWithValues:
        PanelShortcutAction.allCases.compactMap { action in action.defaultChord.map { (action, $0) } }
    )

    func binding(for action: PanelShortcutAction) -> PanelShortcutChord? { bindings[action] }

    func keyboardShortcut(for action: PanelShortcutAction, whileEditingText: Bool = false) -> KeyboardShortcut? {
        guard let chord = bindings[action], let key = chord.keyEquivalent,
              !whileEditingText || !chord.requiresHistoryFocus else { return nil }
        return KeyboardShortcut(key, modifiers: chord.modifiers.eventModifiers)
    }

    static func load(from defaults: UserDefaults) -> Self {
        load(data: defaults.data(forKey: defaultsKey) ?? Data())
    }

    static func load(data: Data) -> Self {
        guard !data.isEmpty, data.count <= 32_768,
              let saved = try? JSONDecoder().decode([String: PanelShortcutChord?].self, from: data)
        else { return Self() }
        var result = Self()
        for action in PanelShortcutAction.allCases {
            guard let entry = saved[action.rawValue] else { continue }
            if let chord = entry {
                let normalized = PanelShortcutChord(key: chord.key, modifiers: chord.modifiers)
                guard (try? normalized.validate()) != nil else {
                    result.bindings[action] = nil
                    continue
                }
                result.bindings[action] = normalized
            } else {
                result.bindings[action] = nil
            }
        }
        // Corrupt duplicates are disabled on both sides. They must never
        // arbitrarily choose a destructive action by declaration order.
        let grouped = Dictionary(grouping: result.bindings.keys) { result.bindings[$0] }
        for actions in grouped.values where actions.count > 1 {
            for action in actions { result.bindings[action] = nil }
        }
        return result
    }

    @MainActor
    static func update(_ action: PanelShortcutAction, to chord: PanelShortcutChord?, in defaults: UserDefaults) throws {
        var latest = load(from: defaults)
        if let chord {
            try chord.validate()
            if let other = PanelShortcutAction.allCases.first(where: { $0 != action && latest.bindings[$0] == chord }) {
                throw PanelShortcutFailure.conflict(other)
            }
        }
        latest.bindings[action] = chord
        try latest.store(to: defaults)
    }

    @MainActor
    static func reset(_ action: PanelShortcutAction, in defaults: UserDefaults) throws {
        try update(action, to: action.defaultChord, in: defaults)
    }

    /// Restoring a section is one edit. Swapped keys within that section can
    /// return to their defaults together; a conflict outside it leaves the
    /// complete previous value untouched.
    @MainActor
    static func reset(_ actions: [PanelShortcutAction], in defaults: UserDefaults) throws {
        var latest = load(from: defaults)
        for action in actions { latest.bindings[action] = action.defaultChord }
        for action in actions {
            guard let chord = latest.bindings[action] else { continue }
            if let other = PanelShortcutAction.allCases.first(where: {
                $0 != action && latest.bindings[$0] == chord
            }) {
                throw PanelShortcutFailure.conflict(other)
            }
        }
        try latest.store(to: defaults)
    }

    @MainActor
    static func resetAll(in defaults: UserDefaults) {
        defaults.removeObject(forKey: defaultsKey)
    }

    private func store(to defaults: UserDefaults) throws {
        let saved: [String: PanelShortcutChord?] = Dictionary(uniqueKeysWithValues:
            PanelShortcutAction.allCases.map { ($0.rawValue, bindings[$0]) }
        )
        defaults.set(try JSONEncoder().encode(saved), forKey: Self.defaultsKey)
    }
}
