import Foundation
import HistoryCore
import Testing
@testable import ClipyApp

@Suite("Search saving presentation")
struct SearchLibraryCopyTests {
    @Test func privacyRejectionAndDisabledHistoryHaveDifferentExplanations() throws {
        let chinese = try localizedBundle("zh-Hans")
        #expect(SearchLibraryCopy.feedback(.disabled, bundle: chinese)
            == .cancelled("搜索保存处于关闭状态，开启后才能保存搜索条件。"))
        #expect(SearchLibraryCopy.feedback(.recentSearchesDisabled, bundle: chinese)
            == .cancelled("自动搜索历史处于关闭状态，仍可手动收藏。"))
        #expect(SearchLibraryCopy.feedback(.excluded, bundle: chinese)
            == .cancelled("搜索条件匹配排除规则，本次未保存。"))
        #expect(SearchLibraryCopy.feedback(.saved, bundle: chinese)
            == .success("搜索条件已保存。"))
    }

    @Test func destructiveActionsExplainWhichCollectionsAreRemoved() throws {
        let chinese = try localizedBundle("zh-Hans")
        #expect(SearchLibraryCopy.text(
            "This removes favorites and recent search conditions. Clipboard history is unchanged.", bundle: chinese
        ) == "这会删除收藏和最近搜索条件，不影响剪贴板历史。")
        #expect(SearchLibraryCopy.text(
            "Turning off automatic history clears recent searches and keeps favorites.", bundle: chinese
        ) == "关闭自动记录会清空最近搜索，收藏会保留。")
        #expect(SearchLibraryCopy.text("Favorites", bundle: chinese) == "收藏")
        #expect(SearchLibraryCopy.text("Recent searches", bundle: chinese) == "最近搜索")
    }

    @Test func aSavedSummaryDescribesFiltersWithoutTurningQueryTextIntoResults() throws {
        let chinese = try localizedBundle("zh-Hans")
        var filters = HistorySearchFilters()
        filters.sourceApplication = "com.example.Editor"
        filters.sourceMatch = .bundleIdentifier
        filters.dateRange = .today
        let definition = HistorySearchDefinition(
            query: "query-only-secret", mode: .exact, typeFilter: .text,
            pinnedOnly: true, filters: filters, sortOrder: .oldestFirst
        )
        let summary = SearchLibraryCopy.summary(definition, bundle: chinese)
        #expect(summary.contains("com.example.Editor"))
        #expect(summary.contains(HistorySearchCopy.text("Today", bundle: chinese)))
        #expect(summary.contains(HistorySearchCopy.sortTitle(.oldestFirst, bundle: chinese)))
        #expect(!summary.contains(definition.query))
    }

    private func localizedBundle(_ language: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }
}
