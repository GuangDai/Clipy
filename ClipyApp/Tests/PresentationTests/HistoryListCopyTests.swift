import Foundation
import Testing
@testable import ClipyApp

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

    @Test("search miss interpolation keeps the user's literal query in both languages")
    func literalQuery() throws {
        let query = "100% %@ “literal”\n剪贴板"
        #expect(HistoryListCopy.searchMiss(query, bundle: try bundle("en")) ==
            "No items match “100% %@ “literal”\n剪贴板”.")
        #expect(HistoryListCopy.searchMiss(query, bundle: try bundle("zh-Hans")) ==
            "没有与“100% %@ “literal”\n剪贴板”匹配的项目。")
    }

}
