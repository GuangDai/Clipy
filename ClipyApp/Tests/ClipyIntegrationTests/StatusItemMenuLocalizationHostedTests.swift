/// Real app-bundle localization resources rendered into the AppKit menu.
import AppKit
import Foundation
import Testing
@testable import ClipyApp

@MainActor
struct StatusItemMenuLocalizationHostedTests {
    private final class CaptureState {
        var paused = false
        var canToggle = true
    }

    @Test func existingMenuUsesTheNewLanguageOnItsNextPresentation() throws {
        let suite = "StatusItemLanguage.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        AppLanguageSettings.store(.english, in: defaults)
        let state = CaptureState()
        let owner = StatusItemMenu(
            isCapturePaused: { state.paused },
            canToggleCapturePause: { state.canToggle },
            onShowHistory: {}, onToggleCapturePause: {}, onOpenSettings: {}, onQuit: {}, onMenuDidClose: {},
            languageDefaults: defaults
        )
        let items = owner.menu.items.filter { !$0.isSeparatorItem }
        #expect(items.map(\.title) == ["Show Clipboard History", "Pause Clipboard Monitoring for 5 Minutes", "Settings…", "Quit Clipy"])

        AppLanguageSettings.store(.simplifiedChinese, in: defaults)
        state.paused = true
        owner.menu.delegate?.menuNeedsUpdate?(owner.menu)

        #expect(items.map(\.title) == ["显示剪贴板历史记录", "恢复剪贴板监控", "设置…", "退出 Clipy"])
        #expect(owner.menu.items.filter { !$0.isSeparatorItem }.first === items.first)
        AppLanguageSettings.store(.english, in: defaults)
        owner.menu.delegate?.menuNeedsUpdate?(owner.menu)
        #expect(items.map(\.title) == ["Show Clipboard History", "Resume Clipboard Monitoring", "Settings…", "Quit Clipy"])
    }

    @Test(arguments: ["en", "zh-Hans"])
    func menuUsesItsAppResourcesAndRefreshesTheLocalizedPauseTitle(_ language: String) throws {
        // Bundle.main is the hosting Clipy.app, not the test bundle or the
        // PresentationUI SwiftPM bundle. Missing packaged resources fail here.
        let localization = try #require(Bundle.main.localizations.first {
            $0.caseInsensitiveCompare(language) == .orderedSame
        })
        let root = try #require(Bundle.main.resourceURL)
        let url = root.appendingPathComponent("\(localization).lproj", isDirectory: true)
        let bundle = try #require(Bundle(url: url))
        let state = CaptureState()
        let owner = StatusItemMenu(
            isCapturePaused: { state.paused },
            canToggleCapturePause: { state.canToggle },
            onShowHistory: {},
            onToggleCapturePause: {},
            onOpenSettings: {},
            onQuit: {},
            onMenuDidClose: {},
            localizationBundle: bundle
        )

        let expected = language == "en"
            ? ["Show Clipboard History", "Pause Clipboard Monitoring for 5 Minutes", "Settings…", "Quit Clipy"]
            : ["显示剪贴板历史记录", "暂停剪贴板监控 5 分钟", "设置…", "退出 Clipy"]
        let items = owner.menu.items.filter { !$0.isSeparatorItem }
        #expect(items.map(\.title) == expected)

        state.paused = true
        owner.menu.delegate?.menuNeedsUpdate?(owner.menu)
        #expect(items[1].title == (language == "en"
            ? "Resume Clipboard Monitoring" : "恢复剪贴板监控"))
        #expect(items[1].isEnabled)

        state.paused = false
        state.canToggle = false
        owner.menu.delegate?.menuNeedsUpdate?(owner.menu)
        #expect(items[1].title == expected[1])
        #expect(!items[1].isEnabled)
    }
}
