import Foundation
import Testing
@testable import ClipyApp

@Suite("History list localization")
struct HistoryListCopyTests {
    @Test(arguments: [AppLanguage.english, .simplifiedChinese])
    func searchMissKeepsTheLiteralQuery(language: AppLanguage) {
        let query = "100% %@ “Cafe\u{301}”\n剪贴板"
        let message = HistoryListCopy.searchMiss(query, bundle: AppLocalization.bundle(for: language))
        #expect(message.range(of: query, options: .literal) != nil)
    }
}
