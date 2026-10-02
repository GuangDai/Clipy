import Foundation
import Testing
@testable import ClipyApp

@Suite("Retained history usage localization")
struct HistoryUsageCopyTests {
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
