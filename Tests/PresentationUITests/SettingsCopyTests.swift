import Foundation
import Testing
@testable import PresentationUI

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

    @Test("Chinese settings preserve destructive scope and recovery guidance")
    func translatedSettings() throws {
        let chinese = try bundle("zh-Hans")
        #expect(SettingsCopy.text("General", bundle: chinese) == "通用")
        #expect(SettingsCopy.text(
            "Remove every item, including pinned items?", bundle: chinese
        ) == "移除全部项目，包括置顶项目？")
        #expect(SettingsCopy.text(
            "Approval is required in System Settings.", bundle: chinese
        ) == "需要在系统设置中批准。")
        #expect(SettingsCopy.text(
            "Panel position and size changes apply the next time the panel opens.",
            bundle: chinese
        ) == "面板位置和大小的更改将在下次打开面板时生效。")
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
