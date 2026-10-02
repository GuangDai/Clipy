import Foundation
import Testing
@testable import ClipyApp

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

    @Test("copy counts preserve plural forms, grouping, and the complete unsigned range")
    func localizedOccurrences() throws {
        let english = try bundle("en")
        let chinese = try bundle("zh-Hans")
        let cases: [(UInt64, String)] = [
            (1, "1"), (2, "2"), (5_000, "5,000"),
            (UInt64(Int64.max), "9,223,372,036,854,775,807"),
            (UInt64(Int64.max) + 1, "9,223,372,036,854,775,808"),
            (UInt64.max, "18,446,744,073,709,551,615"),
        ]
        for (count, digits) in cases {
            let noun = count == 1 ? "time" : "times"
            #expect(HistoryRowCopy.copyCount(count, locale: Locale(identifier: "en_US")) == "×\(digits)")
            #expect(HistoryRowCopy.copiedCount(
                count, bundle: english, locale: Locale(identifier: "en_US")
            ) == "Copied \(digits) \(noun)")
            #expect(HistoryRowCopy.copiedCount(
                count, bundle: chinese, locale: Locale(identifier: "zh_Hans_CN")
            ) == "已复制 \(digits) 次")
        }
    }

    @Test("language and numeric region are independent")
    func regionalGrouping() throws {
        let german = Locale(identifier: "de_DE")
        #expect(HistoryRowCopy.copyCount(5_000, locale: german) == "×5.000")
        #expect(HistoryRowCopy.copiedCount(
            5_000, bundle: try bundle("zh-Hans"), locale: german
        ) == "已复制 5.000 次")
    }

}
