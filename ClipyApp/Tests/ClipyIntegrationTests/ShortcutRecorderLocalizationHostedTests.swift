/// Real app-bundle localization resources rendered into the recorder sheet.
import Foundation
import Testing
@testable import ClipyApp

@MainActor
struct ShortcutRecorderLocalizationHostedTests {
    @Test(arguments: ["en", "zh-Hans"])
    func recorderSheetUsesItsAppResourcesInEveryPackagedLanguage(_ language: String) throws {
        // Bundle.main is the hosting Clipy.app, not the test bundle or the
        // PresentationUI SwiftPM bundle. Missing packaged resources fail here.
        let localization = try #require(Bundle.main.localizations.first {
            $0.caseInsensitiveCompare(language) == .orderedSame
        })
        let root = try #require(Bundle.main.resourceURL)
        let url = root.appendingPathComponent("\(localization).lproj", isDirectory: true)
        let bundle = try #require(Bundle(url: url))

        let literals = [
            "Change Summon Shortcut",
            "Press a key together with Command, Control, Option, or Shift.",
            "Recording…",
            "Use a non-modifier key with at least one modifier.",
            "Cancel",
            "Record summon shortcut",
        ]
        let expected = language == "en"
            ? literals
            : [
                "更改唤出面板快捷键",
                "请将某个键与 Command、Control、Option 或 Shift 同时按下。",
                "录制中…",
                "请使用至少一个修饰键加一个非修饰键的组合。",
                "取消",
                "录制唤出面板快捷键",
            ]
        for (literal, value) in zip(literals, expected) {
            #expect(ShortcutRecorderCopy.text(literal, bundle: bundle) == value)
        }
    }
}
