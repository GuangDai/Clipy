/// Real app-bundle String Catalog compiled tables behind App Intents copy.
import Foundation
import Testing
@testable import ClipyApp

@MainActor
struct LocalizableCatalogHostedTests {
    /// LocalizedStringResource resolves against Bundle.main's "Localizable"
    /// table at render time, so the compiled catalog must reach the built
    /// app's zh-Hans sub-bundle exactly like a plain .strings table. A
    /// missing entry falls back to the English key and fails here.
    @Test
    func appIntentTitlesAndFailuresResolveTheirZhHansCatalogEntries() throws {
        let localization = try #require(Bundle.main.localizations.first {
            $0.caseInsensitiveCompare("zh-Hans") == .orderedSame
        })
        let root = try #require(Bundle.main.resourceURL)
        let url = root.appendingPathComponent("\(localization).lproj", isDirectory: true)
        let bundle = try #require(Bundle(url: url))

        let titles = [
            "Search Clipboard History",
            "Get Clipboard Item Details",
            "Copy Clipboard History Item",
            "Pin Clipboard History Item",
            "Unpin Clipboard History Item",
            "Remove Clipboard History Item",
        ]
        let expectedTitles = [
            "搜索剪贴板历史记录",
            "获取剪贴板项目详情",
            "复制剪贴板历史记录项目",
            "置顶剪贴板历史记录项目",
            "取消置顶剪贴板历史记录项目",
            "移除剪贴板历史记录项目",
        ]
        let failures = [
            "The clipboard request is invalid.",
            "Clipboard access is not allowed.",
            "The clipboard item is no longer available.",
            "Clipboard history is temporarily unavailable.",
            "The clipboard could not be updated.",
        ]
        let expectedFailures = [
            "剪贴板请求无效。",
            "不允许访问剪贴板。",
            "该剪贴板项目已不可用。",
            "剪贴板历史记录暂时不可用。",
            "无法更新剪贴板。",
        ]
        for (literal, value) in zip(titles, expectedTitles) {
            #expect(
                bundle.localizedString(
                    forKey: literal,
                    value: literal,
                    table: "Localizable"
                ) == value
            )
        }
        for (literal, value) in zip(failures, expectedFailures) {
            #expect(
                bundle.localizedString(
                    forKey: literal,
                    value: literal,
                    table: "Localizable"
                ) == value
            )
        }

        // The entity surface the Shortcuts UI renders beyond the intent
        // titles: the entity display name, the search-mode enum, and the
        // property titles (ClipboardIntentModels' LocalizedStringResource
        // literals resolve against the same table).
        let modelLiterals = [
            "Clipboard History Item",
            "Search Mode",
            "Exact",
            "Fuzzy",
            "Regular Expression",
            "Title",
            "Type Identifiers",
            "Last Copied",
            "Copy Count",
            "Source Application",
            "Pinned",
            "Revision Count",
        ]
        let expectedModelLiterals = [
            "剪贴板历史记录项目",
            "搜索模式",
            "精确",
            "模糊",
            "正则表达式",
            "标题",
            "类型标识符",
            "最近复制",
            "复制次数",
            "来源应用",
            "已置顶",
            "修订版本数",
        ]
        for (literal, value) in zip(modelLiterals, expectedModelLiterals) {
            #expect(
                bundle.localizedString(
                    forKey: literal,
                    value: literal,
                    table: "Localizable"
                ) == value
            )
        }
    }
}
