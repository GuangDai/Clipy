import Foundation
import Testing
@testable import ClipyApp

struct DetailsFormatTests {
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
