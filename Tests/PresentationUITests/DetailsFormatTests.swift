import Foundation
import Testing
@testable import PresentationUI

struct DetailsFormatTests {
    @Test(arguments: ["en_US", "zh_Hans_CN", "de_DE"], [0, 9 * 3_600])
    func dateStyleMatchesThePreviousMediumFormatter(localeIdentifier: String, offset: Int) throws {
        let locale = Locale(identifier: localeIdentifier)
        let zone = try #require(TimeZone(secondsFromGMT: offset))
        let previous = DateFormatter()
        previous.locale = locale
        previous.timeZone = zone
        previous.dateStyle = .medium
        previous.timeStyle = .medium
        // Independent legacy API oracle, including different months and
        // periods of the day. Compare full strings, not normalized fields.
        for seconds in [0.0, 725_857_445.0, 746_899_199.0] {
            let instant = Date(timeIntervalSinceReferenceDate: seconds)
            #expect(DetailsFormat.dateTime(instant, locale: locale, timeZone: zone)
                == previous.string(from: instant))
        }
    }

    @Test func countsFollowTheSelectedRegionWithoutNarrowingUnsignedFacts() {
        #expect(DetailsFormat.count(1_234, locale: Locale(identifier: "en_US")) == "1,234")
        #expect(DetailsFormat.count(1_234, locale: Locale(identifier: "de_DE")) == "1.234")
        #expect(DetailsFormat.count(1_234, locale: Locale(identifier: "ar_EG")) == "١٬٢٣٤")
        #expect(DetailsFormat.count(UInt64.max, locale: Locale(identifier: "en_US"))
            == "18,446,744,073,709,551,615")
    }

    @Test func byteFactsKeepEnglishLabelsAndUseTheSelectedNumericRegion() {
        let english = Locale(identifier: "en_US")
        #expect(DetailsFormat.bytes(1, locale: english) == "1 byte")
        #expect(DetailsFormat.bytes(4, locale: english) == "4 bytes")
        #expect(DetailsFormat.bytes(13, locale: english) == "13 bytes")
        #expect(DetailsFormat.bytes(70, locale: english) == "70 bytes")
        #expect(DetailsFormat.bytes(1_500_000, locale: english) == "1.5 MB")
        let german = DetailsFormat.bytes(1_500_000, locale: Locale(identifier: "de_DE"))
        #expect(german.hasPrefix("1,5") && german.hasSuffix("MB"))
        let chinese = DetailsFormat.bytes(70, locale: Locale(identifier: "zh_Hans_CN"))
        #expect(chinese.contains("70") && chinese.contains("字节"))
    }

    @Test func occurrenceAndRevisionDatesUseTheViewLocaleAndTimeZone() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let instant = try #require(calendar.date(from: DateComponents(
            year: 2024, month: 1, day: 2, hour: 3, minute: 4, second: 5
        )))
        let english = DetailsFormat.dateTime(instant, locale: Locale(identifier: "en_US"), timeZone: utc)
        #expect(english.contains("Jan") && english.contains("2024") && english.contains("3:04:05"))
        let chinese = DetailsFormat.dateTime(instant, locale: Locale(identifier: "zh_Hans_CN"), timeZone: utc)
        #expect(chinese.contains("2024年") && chinese.contains("1月2日"))
        #expect(chinese != english)

        // Reusing a locale after another call must not retain the preceding
        // view's locale or zone. Both dates still describe the same instant.
        let tokyo = try #require(TimeZone(secondsFromGMT: 9 * 3_600))
        let shifted = DetailsFormat.dateTime(instant, locale: Locale(identifier: "en_US"), timeZone: tokyo)
        #expect(shifted.contains("12:04:05"))
        #expect(DetailsFormat.dateTime(instant, locale: Locale(identifier: "en_US"), timeZone: utc) == english)
    }
}
