import Foundation
import Testing
@testable import PresentationUI

@Suite("Retention settings localization")
struct RetentionSettingsCopyTests {
    // Use real resource bundles without changing process-wide language preferences.
    private func bundle(_ language: String) throws -> Bundle {
        let url = try #require(RetentionSettingsCopy.bundle.url(
            forResource: language, withExtension: "lproj"
        ))
        return try #require(Bundle(url: url))
    }

    @Test("labels and destructive confirmation resolve from translated resources")
    func translatedCopy() throws {
        let chinese = try bundle("zh-Hans")
        #expect(RetentionSettingsCopy.plain(
            "settings.retention.tab-title", "Retention", bundle: chinese
        ) == "保留")
        #expect(RetentionSettingsCopy.plain(
            "settings.retention.confirm-message", "missing", bundle: chinese
        ) == "更严格的限制可能会永久移除项目或修订版本。")
        #expect(RetentionSettingsCopy.plain(
            "settings.retention.feedback.no-change", "missing", bundle: chinese
        ) == "没有更改。")
        #expect(RetentionSettingsCopy.plain(
            "settings.retention.age.enforcement-note", "missing", bundle: try bundle("en")
        ) == "Age limits are checked when Clipy captures a clipboard change or "
            + "you apply retention settings. Time passing alone doesn't remove items.")
    }

    @Test("receipt plurals preserve zero, one, many and localized grouping",
          arguments: [0, 1, 2, 5_000])
    func englishReceiptPlurals(_ count: Int) throws {
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
    }

    @Test("Chinese receipt feedback uses its own plural rules and punctuation",
          arguments: [0, 1, 2, 5_000])
    func chineseReceiptFeedback(_ count: Int) throws {
        let chinese = try bundle("zh-Hans")
        let locale = Locale(identifier: "zh_Hans_CN")
        let digits = count == 5_000 ? "5,000" : String(count)
        let retired = RetentionSettingsCopy.itemsRetired(
            count, bundle: chinese, locale: locale
        )
        let pruned = RetentionSettingsCopy.revisionsPruned(
            count, bundle: chinese, locale: locale
        )
        #expect(RetentionSettingsCopy.clearedItemsRemoved(
            count, bundle: chinese, locale: locale
        ) == "已移除 \(digits) 个项目。")
        #expect(RetentionSettingsCopy.countLimitItemsRemoved(
            count, bundle: chinese, locale: locale
        ) == "已完成。已移除 \(digits) 个项目。")
        #expect(RetentionSettingsCopy.appliedSummary(
            retiredPhrase: retired, prunedPhrase: pruned,
            bundle: chinese, locale: locale
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
