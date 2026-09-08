/// HistoryRowRenderingTests — deterministic relative-time rendering at the
/// explicit `now` seam owned by the panel list, plus the complete local
/// timestamp exposed by the tooltip and VoiceOver. The production list
/// supplies one minute-aligned timeline date to every row; these tests use
/// literal dates so no timer, sleep, or WindowServer is involved.
import Foundation
@testable import HistoryCore
@testable import ClipyApp
import Testing

@MainActor
struct HistoryRowRenderingTests {

    @Test func suppliedNowAdvancesARecentlyCopiedRowFromSecondsToOneMinute() {
        let copiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let row = fixtureRow(lastCopiedAt: copiedAt)

        let atFiftyNineSeconds = HistoryRowRenderingModel(
            row: row,
            now: copiedAt.addingTimeInterval(59),
            locale: Locale(identifier: "en_US_POSIX")
        )
        let atOneMinute = HistoryRowRenderingModel(
            row: row,
            now: copiedAt.addingTimeInterval(60),
            locale: Locale(identifier: "en_US_POSIX")
        )

        #expect(atFiftyNineSeconds.relativeTimeText == "59s ago")
        #expect(atOneMinute.relativeTimeText == "1m ago")
    }

    /// The fixed tooltip includes the date so older items copied at the
    /// same time of day remain distinguishable. Locale and zone are supplied.
    @Test func tooltipRendersTheAbsoluteDateAndTime() {
        let copiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let row = fixtureRow(lastCopiedAt: copiedAt)

        let rendering = HistoryRowRenderingModel(
            row: row,
            now: copiedAt.addingTimeInterval(59),
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(identifier: "UTC")!
        )

        // ICU renders the day-period separator as a narrow no-break space
        // (U+202F) on current macOS (the literal below would pin a regular
        // space and fail); normalize both no-break variants so the pin
        // asserts the readable shape, not the platform's byte choice.
        #expect(
            rendering.absoluteDateTimeText
                .replacingOccurrences(of: "\u{202F}", with: " ")
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .contains("8:00 AM")
        )
        #expect(rendering.absoluteDateTimeText.contains("January 15, 2027"))
        #expect(rendering.relativeTimeText == "59s ago")
    }

    private func fixtureRow(lastCopiedAt: Date) -> HistoryRow {
        HistoryRow(
            item: HistoryItemReference(
                id: HistoryItemID(
                    rawValue: UUID(
                        uuidString: "00000000-0000-0000-0000-00000000B501"
                    )!
                ),
                contentVersion: ContentVersion(rawValue: 1)
            ),
            title: "Relative time",
            typeIdentifiers: ["public.utf8-plain-text"],
            lastCopiedAt: lastCopiedAt,
            copyCount: 1,
            lastSource: nil,
            pinnedPosition: nil,
            search: nil
        )
    }
}
