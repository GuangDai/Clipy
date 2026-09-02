/// HistoryRowRenderingTests — deterministic relative-time rendering at the
/// explicit `now` seam owned by the panel list, plus the absolute
/// time-of-day half the wide row presentation shows. The production list
/// supplies one minute-aligned timeline date to every row; these tests use
/// literal dates so no timer, sleep, or WindowServer is involved.
import Foundation
import HistoryCore
import PresentationUI
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

    /// The wide presentation's absolute half: 1,800,000,000 is
    /// 2027-01-15 08:00:00 UTC, and the time of day is fixed per item, so
    /// the text is independent of `now`. The injected zone/locale pin the
    /// `timeStyle: .short` shape ("8:00 AM") deterministically — the
    /// production default keeps the user's own locale and zone.
    @Test func widePresentationRendersTheAbsoluteTimeOfDay() {
        let copiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let row = fixtureRow(lastCopiedAt: copiedAt)

        let rendering = HistoryRowRenderingModel(
            row: row,
            now: copiedAt.addingTimeInterval(59),
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(identifier: "UTC")!
        )

        #expect(rendering.absoluteTimeText == "8:00 AM")
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
