import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var title: String {
        switch self {
        case .system: AppLanguageCopy.text("Follow System")
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }
}

enum AppLanguageSettings {
    static let defaultsKey = "clipy.language"

    static func load(from defaults: UserDefaults = .standard) -> AppLanguage {
        AppLanguage(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .system
    }

    static func store(_ language: AppLanguage, in defaults: UserDefaults = .standard) {
        defaults.set(language.rawValue, forKey: defaultsKey)
    }
}

/// A preference read and native bundle lookup, with no global language holder.
/// Explicit bundle arguments in copy helpers remain useful for tests/previews.
enum AppLocalization {
    static var bundle: Bundle { bundle(for: AppLanguageSettings.load()) }

    static func bundle(for language: AppLanguage, resources: Bundle = .main) -> Bundle {
        switch language {
        case .system: resources
        case .simplifiedChinese, .english:
            bundle(for: Locale(identifier: language.rawValue), resources: resources)
        }
    }

    static func bundle(for locale: Locale, resources: Bundle = .main) -> Bundle {
        var preferences = [locale.identifier(.bcp47)]
        if let development = resources.developmentLocalization { preferences.append(development) }
        guard let localization = Bundle.preferredLocalizations(
            from: resources.localizations, forPreferences: preferences
        ).first,
              let resourceURL = resources.resourceURL,
              let localized = Bundle(url: resourceURL.appendingPathComponent(
                "\(localization).lproj", isDirectory: true
              )) else { return resources }
        return localized
    }

    /// Bundle's preferred language respects macOS per-app language overrides
    /// and launch arguments such as -AppleLanguages, independently of region.
    static func locale(for language: AppLanguage, resources: Bundle = .main) -> Locale {
        if language != .system { return Locale(identifier: language.rawValue) }
        let language = resources.preferredLocalizations.first ?? resources.developmentLocalization ?? "en"
        return Locale(identifier: language)
    }
}

enum AppLanguageCopy {
    static func text(_ key: String, bundle: Bundle = AppLocalization.bundle) -> String {
        bundle.localizedString(forKey: key, value: key, table: "AppLanguage")
    }
}

private struct AppLanguageModifier: ViewModifier {
    @AppStorage(AppLanguageSettings.defaultsKey) private var preference: AppLanguage = .system

    func body(content: Content) -> some View {
        content.environment(\.locale, AppLocalization.locale(for: preference))
    }
}

extension View {
    /// Changes only the environment; switching language keeps draft/state
    /// identities intact across Settings, floating panels and attached sheets.
    func appLanguage() -> some View { modifier(AppLanguageModifier()) }
}
