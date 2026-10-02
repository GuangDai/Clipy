import Foundation
import Testing
@testable import ClipyApp

struct AppLanguageSettingsTests {
    @Test func languageChoicePersistsAndUnknownValuesFollowSystem() throws {
        let suite = "AppLanguageSettings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(AppLanguageSettings.load(from: defaults) == .system)
        for language in AppLanguage.allCases {
            AppLanguageSettings.store(language, in: defaults)
            let reopened = try #require(UserDefaults(suiteName: suite))
            #expect(AppLanguageSettings.load(from: reopened) == language)
        }
        defaults.set("unsupported-language", forKey: AppLanguageSettings.defaultsKey)
        #expect(AppLanguageSettings.load(from: defaults) == .system)
    }

    @Test func explicitLanguageSelectsRealAppResourcesAcrossSurfaces() {
        let chinese = AppLocalization.bundle(for: AppLanguage.simplifiedChinese)
        let english = AppLocalization.bundle(for: AppLanguage.english)

        #expect(AppLanguageCopy.text("Language", bundle: chinese) == "语言")
        #expect(AppLanguageCopy.text("Follow System", bundle: english) == "Follow System")
        #expect(SettingsCopy.text("Startup", bundle: chinese) == "启动")
        #expect(LocalAutomationSettingsCopy.text("Automation", bundle: chinese) == "自动化")
        #expect(BuiltInAutomationCopy.text("Workflows", bundle: chinese) == "工作流")
        #expect(PreviewPresentationCopy.text("Preview Information", bundle: chinese) == "预览信息")
        #expect(PanelActionsCopy.text("Close", bundle: english) == "Close")
        #expect(StatusMenuCopy.text("Show Clipboard History", bundle: chinese) == "显示剪贴板历史记录")
    }

    @Test func systemChoiceUsesNativeAppPreferencesAndExplicitLocaleStaysIndependent() {
        #expect(AppLocalization.bundle(for: AppLanguage.system) === Bundle.main)
        #expect(AppLocalization.locale(for: .system).identifier
                == (Bundle.main.preferredLocalizations.first ?? Bundle.main.developmentLocalization ?? "en"))
        #expect(AppLocalization.locale(for: .english).language.languageCode?.identifier == "en")
        #expect(AppLocalization.locale(for: .simplifiedChinese).language.languageCode?.identifier == "zh")
        #expect(SettingsCopy.text("Startup", bundle: PanelActionsCopy.bundle(for: Locale(identifier: "en_US"))) == "Startup")
        #expect(SettingsCopy.text("Startup", bundle: PanelActionsCopy.bundle(for: Locale(identifier: "zh_Hans_CN"))) == "启动")
    }

    @Test func unsupportedLocaleUsesDevelopmentLanguage() {
        let bundle = AppLocalization.bundle(for: Locale(identifier: "de_DE"))
        #expect(SettingsCopy.text("Startup", bundle: bundle) == "Startup")
    }
}
