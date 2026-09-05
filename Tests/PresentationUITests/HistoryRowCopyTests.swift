import Foundation
import Testing
@testable import PresentationUI

@Suite("History row metadata localization")
struct HistoryRowCopyTests {
    private func bundle(_ language: String) throws -> Bundle {
        let localization = try #require(HistoryRowCopy.bundle.localizations.first {
            $0.caseInsensitiveCompare(language) == .orderedSame
        })
        let root = try #require(HistoryRowCopy.bundle.resourceURL)
        return try #require(Bundle(url: root.appendingPathComponent(
            "\(localization).lproj", isDirectory: true
        )))
    }

    @Test("copy counts use localized grouping and translated plural forms",
          arguments: [UInt64(1), 2, 5_000])
    func localizedOccurrences(_ count: UInt64) throws {
        let english = try bundle("en")
        let chinese = try bundle("zh-Hans")
        let digits = count == 5_000 ? "5,000" : String(count)
        let noun = count == 1 ? "time" : "times"
        #expect(HistoryRowCopy.copyCount(count, locale: Locale(identifier: "en_US")) == "×\(digits)")
        #expect(HistoryRowCopy.copiedCount(
            count, bundle: english, locale: Locale(identifier: "en_US")
        ) == "Copied \(digits) \(noun)")
        #expect(HistoryRowCopy.copiedCount(
            count, bundle: chinese, locale: Locale(identifier: "zh_Hans_CN")
        ) == "已复制 \(digits) 次")
    }

    @Test("language and numeric region are independent")
    func regionalGrouping() throws {
        let german = Locale(identifier: "de_DE")
        #expect(HistoryRowCopy.copyCount(5_000, locale: german) == "×5.000")
        #expect(HistoryRowCopy.copiedCount(
            5_000, bundle: try bundle("zh-Hans"), locale: german
        ) == "已复制 5.000 次")
    }

    @Test("the unsigned occurrence maximum is formatted without narrowing")
    func completeOccurrenceRange() throws {
        let locale = Locale(identifier: "en_US")
        #expect(HistoryRowCopy.copyCount(UInt64.max, locale: locale) == "×18,446,744,073,709,551,615")
        #expect(HistoryRowCopy.copiedCount(
            UInt64.max, bundle: try bundle("en"), locale: locale
        ) == "Copied 18,446,744,073,709,551,615 times")
    }
}
