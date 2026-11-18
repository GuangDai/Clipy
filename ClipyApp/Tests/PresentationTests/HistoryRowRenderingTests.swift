import Foundation
import Testing
@testable import ClipyApp

@MainActor
struct HistoryRowRenderingTests {
    private let locale = Locale(identifier: "en_US_POSIX")
    private let utc = TimeZone(secondsFromGMT: 0)!

    @Test func compactCopyTimeDistinguishesYearsAndMinutes() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let date = try #require(calendar.date(from: DateComponents(
            year: 2027, month: 1, day: 15, hour: 8, minute: 15
        )))
        let yearBefore = try #require(calendar.date(byAdding: .year, value: -1, to: date))
        let current = HistoryRowCopyTime(date, locale: locale, timeZone: utc)
        let older = HistoryRowCopyTime(yearBefore, locale: locale, timeZone: utc)
        let later = HistoryRowCopyTime(date.addingTimeInterval(60), locale: locale, timeZone: utc)

        #expect(current.compact != older.compact)
        #expect(current.compact != later.compact)
        #expect(current.labeledFull.contains("2027"))
        #expect(older.labeledFull.contains("2026"))
    }

    @Test func compactAndFullCopyTimeUseTheDisplayedTimeZone() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let offset = -10 * 3_600
        let zone = try #require(TimeZone(secondsFromGMT: offset))
        let atUTC = HistoryRowCopyTime(date, locale: locale, timeZone: utc)
        let local = HistoryRowCopyTime(date, locale: locale, timeZone: zone)
        let localClockAtUTC = HistoryRowCopyTime(date.addingTimeInterval(Double(offset)), locale: locale, timeZone: utc)

        #expect(atUTC.compact != local.compact)
        #expect(local.compact == localClockAtUTC.compact)
        #expect(atUTC.labeledFull.contains("January 15"))
        #expect(local.labeledFull.contains("January 14"))
    }
}
