import Foundation
import Testing
@testable import PresentationUI

@Suite("History list localization")
struct HistoryListCopyTests {
    private func bundle(_ language: String) throws -> Bundle {
        let localization = try #require(HistoryListCopy.bundle.localizations.first {
            $0.caseInsensitiveCompare(language) == .orderedSame
        })
        let root = try #require(HistoryListCopy.bundle.resourceURL)
        return try #require(Bundle(url: root.appendingPathComponent(
            "\(localization).lproj", isDirectory: true
        )))
    }

    @Test("Chinese captions distinguish empty history, filtering, and loading")
    func translatedStates() throws {
        let chinese = try bundle("zh-Hans")
        #expect(HistoryListCopy.text("Pinned", bundle: chinese) == "置顶")
        #expect(HistoryListCopy.text("Recent", bundle: chinese) == "最近")
        #expect(HistoryListCopy.text("No Results", bundle: chinese) == "无结果")
        #expect(HistoryListCopy.text("No Clipboard History", bundle: chinese) == "暂无剪贴板历史记录")
        #expect(HistoryListCopy.text(
            "Copy something and it will appear here.", bundle: chinese
        ) == "复制内容后，它会显示在这里。")
        #expect(HistoryListCopy.text(
            "No items match the current filter.", bundle: chinese
        ) == "没有符合当前筛选条件的项目。")
        #expect(HistoryListCopy.text("Loading more items", bundle: chinese) == "正在加载更多项目")
        #expect(HistoryListCopy.text("Load More", bundle: chinese) == "加载更多")
        #expect(HistoryListCopy.text(
            "Loading clipboard history", bundle: chinese
        ) == "正在加载剪贴板历史记录")
        #expect(HistoryListCopy.text("Toggle Pin", bundle: chinese) == "切换置顶状态")
    }

    @Test("search miss interpolation keeps the user's literal query in both languages")
    func literalQuery() throws {
        let query = "100% %@ “literal”\n剪贴板"
        #expect(HistoryListCopy.searchMiss(query, bundle: try bundle("en")) ==
            "No items match “100% %@ “literal”\n剪贴板”.")
        #expect(HistoryListCopy.searchMiss(query, bundle: try bundle("zh-Hans")) ==
            "没有与“100% %@ “literal”\n剪贴板”匹配的项目。")
    }

    @Test("English runtime journey labels keep their existing copy")
    func englishLabels() throws {
        let english = try bundle("en")
        #expect(HistoryListCopy.text("No Clipboard History", bundle: english) == "No Clipboard History")
        #expect(HistoryListCopy.text("No Results", bundle: english) == "No Results")
        #expect(HistoryListCopy.text("Load More", bundle: english) == "Load More")
        #expect(HistoryListCopy.text(
            "Loading clipboard history", bundle: english
        ) == "Loading clipboard history")
    }
}
