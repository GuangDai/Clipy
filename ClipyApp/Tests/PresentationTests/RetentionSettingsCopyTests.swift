import Foundation
import Testing
@testable import ClipyApp

@Suite("Retention settings localization")
struct RetentionSettingsCopyTests {
    // Use real resource bundles without changing process-wide language preferences.
    private func bundle(_ language: String) throws -> Bundle {
        // SwiftPM lowercases processed localization directories (zh-hans).
        // Resolve the exact requested language from the built bundle, without
        // Bundle's preferred-language resource lookup or an English fallback.
        let resources = RetentionSettingsCopy.bundle
        let localization = try #require(resources.localizations.first {
            $0.caseInsensitiveCompare(language) == .orderedSame
        })
        let root = try #require(resources.resourceURL)
        let url = root.appendingPathComponent("\(localization).lproj", isDirectory: true)
        return try #require(Bundle(url: url))
    }

    @Test("both receipt localizations preserve plurals and grouped counts",
          arguments: [0, 1, 2, 5_000])
    func receiptPlurals(_ count: Int) throws {
        let english = try bundle("en")
        let locale = Locale(identifier: "en_US")
        let digits = count == 5_000 ? "5,000" : String(count)
        let item = count == 1 ? "item" : "items"
        let revision = count == 1 ? "revision" : "revisions"
        #expect(RetentionSettingsCopy.clearedItemsRemoved(
            count, bundle: english, locale: locale
        ) == "Removed \(digits) \(item).")
        #expect(RetentionSettingsCopy.countLimitItemsRemoved(
            count, bundle: english, locale: locale
        ) == "Done. \(digits) \(item) removed.")
        #expect(RetentionSettingsCopy.itemsRetired(
            count, bundle: english, locale: locale
        ) == "\(digits) \(item) retired")
        #expect(RetentionSettingsCopy.revisionsPruned(
            count, bundle: english, locale: locale
        ) == "\(digits) \(revision) pruned")
        let chinese = try bundle("zh-Hans")
        let chineseLocale = Locale(identifier: "zh_Hans_CN")
        let retired = RetentionSettingsCopy.itemsRetired(
            count, bundle: chinese, locale: chineseLocale
        )
        let pruned = RetentionSettingsCopy.revisionsPruned(
            count, bundle: chinese, locale: chineseLocale
        )
        #expect(RetentionSettingsCopy.clearedItemsRemoved(
            count, bundle: chinese, locale: chineseLocale
        ) == "已移除 \(digits) 个项目。")
        #expect(RetentionSettingsCopy.countLimitItemsRemoved(
            count, bundle: chinese, locale: chineseLocale
        ) == "已完成。已移除 \(digits) 个项目。")
        #expect(RetentionSettingsCopy.appliedSummary(
            retiredPhrase: retired, prunedPhrase: pruned,
            bundle: chinese, locale: chineseLocale
        ) == "已完成。已移除 \(digits) 个项目，已清理 \(digits) 个修订版本。")
    }

    @Test("range hints respect language independently of numeric region")
    func rangeNumbers() throws {
        #expect(RetentionSettingsCopy.rangeHint(
            from: 1, to: 5_000, bundle: try bundle("en"),
            locale: Locale(identifier: "de_DE")
        ) == "Enter a whole number from 1 to 5.000.")
        #expect(RetentionSettingsCopy.rangeHint(
            from: 1, to: 5_000, bundle: try bundle("zh-Hans"),
            locale: Locale(identifier: "zh_Hans_CN")
        ) == "请输入 1 到 5,000 之间的整数。")
    }
}
