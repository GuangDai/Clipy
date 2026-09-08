import Foundation
@testable import HistoryCore
import Testing
@testable import ClipyApp

@MainActor
struct HistoryRowMetadataPriorityTests {
    @Test(arguments: [
        ("com.apple.Safari", "Safari"),
        ("com.example.very.long.namespace.DocumentEditor", "DocumentEditor"),
        ("Terminal", "Terminal"),
    ])
    func sourceMetadataUsesACompactNameWithoutChangingTheObservedIdentifier(
        source: String, expected: String
    ) {
        let row = fixture(source: source)
        let rendering = model(row)
        #expect(rendering.sourceDisplayName == expected)
        #expect(row.lastSource == source)
    }

    @Test func missingSourceDoesNotInventAnApplication() {
        #expect(model(fixture(source: nil)).sourceDisplayName == nil)
    }

    @Test func fullTimestampDistinguishesDaysAndUsesTheSuppliedTimeZone() {
        let today = fixture(source: nil)
        let yesterday = fixture(source: nil, copiedAt: today.lastCopiedAt.addingTimeInterval(-86_400))
        let utc = model(today)
        let previousDay = model(yesterday)
        let shifted = model(today, zone: TimeZone(secondsFromGMT: -36_000)!)
        #expect(utc.absoluteDateTimeText.contains("January 15, 2027"))
        #expect(previousDay.absoluteDateTimeText.contains("January 14, 2027"))
        #expect(shifted.absoluteDateTimeText.contains("January 14, 2027"))
        #expect(utc.absoluteDateTimeText != previousDay.absoluteDateTimeText)
        #expect(utc.absoluteDateTimeText != shifted.absoluteDateTimeText)
        #expect(utc.relativeTimeText == "1m ago")
    }

    private func model(_ row: HistoryRow, zone: TimeZone = TimeZone(secondsFromGMT: 0)!) -> HistoryRowRenderingModel {
        HistoryRowRenderingModel(row: row, now: row.lastCopiedAt.addingTimeInterval(60),
            locale: Locale(identifier: "en_US_POSIX"), timeZone: zone)
    }

    private func fixture(source: String?, copiedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> HistoryRow {
        HistoryRow(item: HistoryItemReference(id: HistoryItemID(rawValue: UUID()),
            contentVersion: ContentVersion(rawValue: 1)), title: "Content comes first",
            typeIdentifiers: ["public.utf8-plain-text"], lastCopiedAt: copiedAt,
            copyCount: 1, lastSource: source, pinnedPosition: nil, search: nil)
    }
}
