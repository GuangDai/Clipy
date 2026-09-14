import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ClipyApp

@MainActor
struct PanelShortcutSettingsTests {
    @Test func clearingAndRemappingRemoveTheOldKeyEquivalent() throws {
        let name = "PanelShortcutSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try PanelShortcutSettings.update(.togglePin, to: nil, in: defaults)
        let cleared = PanelShortcutSettings.load(from: defaults)
        #expect(cleared.binding(for: .togglePin) == nil)
        #expect(cleared.keyboardShortcut(for: .togglePin) == nil)
        #expect(cleared.binding(for: .showDetails) == PanelShortcutAction.showDetails.defaultChord)

        let replacement = PanelShortcutChord(key: "K", modifiers: [.shift, .command])
        try PanelShortcutSettings.update(.togglePin, to: replacement, in: defaults)
        let loaded = PanelShortcutSettings.load(from: defaults)
        #expect(loaded.binding(for: .togglePin) == replacement)
        #expect(loaded.keyboardShortcut(for: .togglePin)?.key == KeyEquivalent("k"))
        #expect(loaded.keyboardShortcut(for: .togglePin)?.modifiers == [.shift, .command])
        try PanelShortcutSettings.reset(.togglePin, in: defaults)
        #expect(PanelShortcutSettings.load(from: defaults).binding(for: .togglePin) == PanelShortcutAction.togglePin.defaultChord)
    }

    @Test func conflictingEditCannotPartiallyOverwriteSavedBindings() throws {
        let name = "PanelShortcutSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try PanelShortcutSettings.update(.clearSearch, to: PanelShortcutChord(key: "k", modifiers: .command), in: defaults)
        let before = defaults.data(forKey: PanelShortcutSettings.defaultsKey)
        #expect(throws: PanelShortcutFailure.conflict(.clearSearch)) {
            try PanelShortcutSettings.update(.remove, to: PanelShortcutChord(key: "k", modifiers: .command), in: defaults)
        }
        #expect(defaults.data(forKey: PanelShortcutSettings.defaultsKey) == before)
        #expect(PanelShortcutSettings.load(from: defaults).binding(for: .remove) == PanelShortcutAction.remove.defaultChord)
    }

    @Test func restoringAGroupResolvesSwapsTogetherAndRejectsOutsideConflictsAtomically() throws {
        let name = "PanelShortcutSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try PanelShortcutSettings.update(.togglePin, to: nil, in: defaults)
        try PanelShortcutSettings.update(.showDetails, to: nil, in: defaults)
        try PanelShortcutSettings.update(.togglePin, to: PanelShortcutAction.showDetails.defaultChord, in: defaults)
        try PanelShortcutSettings.update(.showDetails, to: PanelShortcutAction.togglePin.defaultChord, in: defaults)
        try PanelShortcutSettings.reset([.togglePin, .showDetails], in: defaults)
        #expect(PanelShortcutSettings.load(from: defaults).binding(for: .togglePin) == PanelShortcutAction.togglePin.defaultChord)
        #expect(PanelShortcutSettings.load(from: defaults).binding(for: .showDetails) == PanelShortcutAction.showDetails.defaultChord)

        try PanelShortcutSettings.update(.togglePin, to: nil, in: defaults)
        try PanelShortcutSettings.update(.clearSearch, to: PanelShortcutAction.togglePin.defaultChord, in: defaults)
        let before = defaults.data(forKey: PanelShortcutSettings.defaultsKey)
        #expect(throws: PanelShortcutFailure.conflict(.clearSearch)) {
            try PanelShortcutSettings.reset([.togglePin, .showDetails], in: defaults)
        }
        #expect(defaults.data(forKey: PanelShortcutSettings.defaultsKey) == before)
    }

    @Test func standardTextAndWindowCommandsRemainOwnedByMacOS() throws {
        let name = "PanelShortcutSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let modifierChoices: [PanelShortcutModifiers] = [.command, [.command, .shift], [.command, .option]]
        for key in ["a", "c", "x", "v", "z", "y", "w", "q", "h", "m", ","] {
            for modifiers in modifierChoices {
                #expect(throws: PanelShortcutFailure.reservedShortcut) {
                    try PanelShortcutSettings.update(.remove, to: PanelShortcutChord(key: key, modifiers: modifiers), in: defaults)
                }
            }
        }
        for chord in [PanelShortcutChord(key: "b", modifiers: []),
                      PanelShortcutChord(key: "e", modifiers: .option),
                      PanelShortcutChord(key: "a", modifiers: .control)] {
            #expect(throws: PanelShortcutFailure.reservedShortcut) {
                try PanelShortcutSettings.update(.remove, to: chord, in: defaults)
            }
        }
        #expect(defaults.data(forKey: PanelShortcutSettings.defaultsKey) == nil)
    }

    @Test func searchEditingKeepsSpaceDeleteAndNavigationWhileCommandSearchWorks() {
        let settings = PanelShortcutSettings()
        #expect(settings.keyboardShortcut(for: .quickLook, whileEditingText: true) == nil)
        #expect(settings.keyboardShortcut(for: .remove, whileEditingText: true) == nil)
        #expect(settings.keyboardShortcut(for: .pinToTop, whileEditingText: true) == nil)
        #expect(settings.keyboardShortcut(for: .focusSearch, whileEditingText: true) != nil)
        #expect(settings.keyboardShortcut(for: .exactSearch, whileEditingText: true) != nil)
        #expect(settings.keyboardShortcut(for: .quickLook, whileEditingText: false) != nil)
    }

    @Test func unmodifiedFunctionKeysRoundTripAndRemainAvailableDuringSearchTyping() throws {
        let name = "PanelShortcutSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let chord = PanelShortcutChord(key: "f1", modifiers: [])
        try PanelShortcutSettings.update(.clearSearch, to: chord, in: defaults)
        let loaded = PanelShortcutSettings.load(from: defaults)
        #expect(loaded.binding(for: .clearSearch) == chord)
        #expect(loaded.keyboardShortcut(for: .clearSearch)?.key == KeyEquivalent("\u{F704}"))
        #expect(loaded.keyboardShortcut(for: .clearSearch, whileEditingText: true) != nil)
        #expect(loaded.keyboardShortcut(for: .clearSearch)?.modifiers == [])
    }

    @Test func corruptDuplicateBindingsDisableBothActionsInsteadOfChoosingTheDestructiveOne() throws {
        // Keep the uppercase key to exercise load normalization, but encode
        // the OptionSet using its actual Codable representation. A malformed
        // hand-written modifier object tests whole-document fallback instead
        // of the duplicate-binding path this test is meant to exercise.
        struct SavedBinding: Encodable {
            let key: String
            let modifiers: PanelShortcutModifiers
        }
        let data = try JSONEncoder().encode([
            "remove": SavedBinding(key: "P", modifiers: .command)
        ])
        let loaded = PanelShortcutSettings.load(data: data)
        #expect(loaded.binding(for: .remove) == nil)
        #expect(loaded.binding(for: .togglePin) == nil)
        #expect(loaded.binding(for: .showDetails) == PanelShortcutAction.showDetails.defaultChord)
    }

    @Test func recordingNormalizesLettersAndPreservesNavigationAndFunctionKeys() throws {
        let commandShift: NSEvent.ModifierFlags = [.command, .shift]
        let letter = try #require(PanelShortcutChord(keyCode: 40,
            modifierFlagsRawValue: commandShift.rawValue, charactersIgnoringModifiers: "K"))
        #expect(letter.key == "k")
        #expect(letter.displayName == "⇧⌘K")
        let commandOption: NSEvent.ModifierFlags = [.command, .option]
        let arrow = try #require(PanelShortcutChord(keyCode: 123,
            modifierFlagsRawValue: commandOption.rawValue,
            charactersIgnoringModifiers: nil))
        #expect(arrow.displayName == "⌥⌘←")
        let function = try #require(PanelShortcutChord(keyCode: 122,
            modifierFlagsRawValue: 0, charactersIgnoringModifiers: nil))
        #expect(function.key == "f1")
        #expect(PanelShortcutChord(keyCode: 36, modifierFlagsRawValue: 0,
            charactersIgnoringModifiers: "\r") == nil)
    }
}
