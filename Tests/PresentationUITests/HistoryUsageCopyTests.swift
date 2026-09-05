import Foundation
import Testing
@testable import PresentationUI

@Suite("Retained history usage localization")
struct HistoryUsageCopyTests {
    private func bundle(_ language: String) throws -> Bundle {
        let localization = try #require(HistoryUsageCopy.bundle.localizations.first {
            $0.caseInsensitiveCompare(language) == .orderedSame
        })
        let root = try #require(HistoryUsageCopy.bundle.resourceURL)
        return try #require(Bundle(url: root.appendingPathComponent(
            "\(localization).lproj", isDirectory: true
        )))
    }

    @Test("both languages distinguish retained content from physical disk usage")
    func usageMeaning() throws {
        #expect(HistoryUsageCopy.disclosure(bundle: try bundle("en")) ==
            "Content size includes originals and retained revisions. "
                + "Actual disk usage may differ.")
        let chinese = try bundle("zh-Hans")
        #expect(HistoryUsageCopy.disclosure(bundle: chinese) ==
            "内容用量包括原始内容和保留的修订版本，可能与实际磁盘占用不同。")
        #expect(HistoryUsageCopy.text("Pinned Items", bundle: chinese) == "置顶项目数")
        #expect(HistoryUsageCopy.text("Usage unavailable.", bundle: chinese) == "用量暂不可用。")
    }

    @Test("byte formatting distinguishes measured zero, singular bytes and compact large totals")
    func zeroAndLargeByteCounts() {
        let english = Locale(identifier: "en_US")
        #expect(HistoryUsageCopy.contentBytes(0, locale: english) == "0 bytes")
        #expect(HistoryUsageCopy.contentBytes(1, locale: english) == "1 byte")
        #expect(HistoryUsageCopy.contentBytes(
            1_500_000_000, locale: english
        ) == "1.5 GB")
    }

    @Test("byte totals use the selected numeric region")
    func numericRegion() {
        let german = HistoryUsageCopy.contentBytes(
            1_500_000_000, locale: Locale(identifier: "de_DE")
        )
        #expect(german.hasPrefix("1,5"))
        #expect(german.hasSuffix("GB"))
        let chinese = HistoryUsageCopy.contentBytes(
            1_500_000_000, locale: Locale(identifier: "zh_Hans_CN")
        )
        #expect(chinese.hasPrefix("1.5"))
        #expect(chinese.hasSuffix("GB"))
    }
}
