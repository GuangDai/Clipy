import Foundation
import Testing
@testable import ClipyApp

@Suite("General and appearance settings localization")
struct SettingsCopyTests {
    private func bundle(_ language: String) throws -> Bundle {
        // SwiftPM normalizes localization directory casing; select the
        // actual bundled language without changing process-wide preferences.
        let localization = try #require(SettingsCopy.bundle.localizations.first {
            $0.caseInsensitiveCompare(language) == .orderedSame
        })
        let root = try #require(SettingsCopy.bundle.resourceURL)
        return try #require(Bundle(url: root.appendingPathComponent(
            "\(localization).lproj", isDirectory: true
        )))
    }

    @Test("Settings interpolation retains app identifiers and shortcut symbols")
    func interpolatedSettings() throws {
        let english = try bundle("en")
        let chinese = try bundle("zh-Hans")
        let bundleID = "com.example.percent%"
        #expect(SettingsCopy.removeIgnoredApp(
            bundleID, bundle: english
        ) == "Remove com.example.percent%")
        #expect(SettingsCopy.removeIgnoredApp(
            bundleID, bundle: chinese
        ) == "移除 com.example.percent%")
        #expect(SettingsCopy.shortcutUnavailable(
            "⇧⌘C", bundle: english
        ) == "⇧⌘C is unavailable.")
        #expect(SettingsCopy.shortcutUnavailable(
            "⇧⌘C", bundle: chinese
        ) == "⇧⌘C 不可用。")
        #expect(SettingsCopy.retainedShortcut(
            "⌥⌘V", bundle: english
        ) == "The current ⌥⌘V shortcut still works.")
        #expect(SettingsCopy.retainedShortcut(
            "⌥⌘V", bundle: chinese
        ) == "当前快捷键 ⌥⌘V 仍然可用。")
    }
}
