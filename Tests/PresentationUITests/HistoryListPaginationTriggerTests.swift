/// HistoryListPaginationTriggerTests — review Card 8B's pure presentation
/// regression seam. Pagination follows the final displayed row across the
/// complete Pinned + Recent ordering; it is not owned by either visual lane.
import Foundation
import HistoryCore
import PresentationUI
import Testing

struct HistoryListPaginationTriggerTests {
    @Test func allPinnedPageTriggersWhenItsLastRowAppears() {
        let firstPinned = itemID("00000000-0000-0000-0000-000000000801")
        let lastPinned = itemID("00000000-0000-0000-0000-000000000802")

        #expect(!HistoryListPaginationTrigger.shouldLoadNextPage(
            appearingRowID: firstPinned,
            lastDisplayedRowID: lastPinned,
            hasNextPage: true,
            isLoadingPage: false
        ))
        #expect(HistoryListPaginationTrigger.shouldLoadNextPage(
            appearingRowID: lastPinned,
            lastDisplayedRowID: lastPinned,
            hasNextPage: true,
            isLoadingPage: false
        ))
    }

    @Test func mixedPageTriggersOnlyForTheOverallLastRowIdentity() {
        let lastPinned = itemID("00000000-0000-0000-0000-000000000811")
        let lastRecent = itemID("00000000-0000-0000-0000-000000000812")

        #expect(!HistoryListPaginationTrigger.shouldLoadNextPage(
            appearingRowID: lastPinned,
            lastDisplayedRowID: lastRecent,
            hasNextPage: true,
            isLoadingPage: false
        ))
        #expect(HistoryListPaginationTrigger.shouldLoadNextPage(
            appearingRowID: lastRecent,
            lastDisplayedRowID: lastRecent,
            hasNextPage: true,
            isLoadingPage: false
        ))
    }

    @Test func exhaustedCursorBlocksTheLastRowTrigger() {
        let lastRow = itemID("00000000-0000-0000-0000-000000000821")

        #expect(!HistoryListPaginationTrigger.shouldLoadNextPage(
            appearingRowID: lastRow,
            lastDisplayedRowID: lastRow,
            hasNextPage: false,
            isLoadingPage: false
        ))
    }

    @Test func inFlightRequestBlocksTheLastRowTrigger() {
        let lastRow = itemID("00000000-0000-0000-0000-000000000831")

        #expect(!HistoryListPaginationTrigger.shouldLoadNextPage(
            appearingRowID: lastRow,
            lastDisplayedRowID: lastRow,
            hasNextPage: true,
            isLoadingPage: true
        ))
    }

    private func itemID(_ rawValue: String) -> HistoryItemID {
        HistoryItemID(rawValue: UUID(uuidString: rawValue)!)
    }
}
