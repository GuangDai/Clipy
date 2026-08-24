/// HistoryCountPresentationTests.swift — Card 8C's visible browse/search
/// count contract. A next-page cursor means the displayed row count is only
/// a lower bound, so both panel captions must disclose that incompleteness.
import Foundation
import PresentationUI
import Testing

@MainActor
struct HistoryCountPresentationTests {
    @Test func nextPageCountsUseAnExplicitLowerBound() {
        #expect(
            HistoryPanelView.itemCountText(
                count: 50,
                hasNextPage: true
            ) == "50+ items"
        )
        #expect(
            SearchHeaderView.resultCountText(
                count: 50,
                hasNextPage: true
            ) == "50+ results"
        )
    }

    @Test func completeCountsPreserveExactSingularAndPluralCopy() {
        #expect(
            HistoryPanelView.itemCountText(
                count: 1,
                hasNextPage: false
            ) == "1 item"
        )
        #expect(
            HistoryPanelView.itemCountText(
                count: 2,
                hasNextPage: false
            ) == "2 items"
        )
        #expect(
            SearchHeaderView.resultCountText(
                count: 1,
                hasNextPage: false
            ) == "1 result"
        )
        #expect(
            SearchHeaderView.resultCountText(
                count: 2,
                hasNextPage: false
            ) == "2 results"
        )
    }

    @Test func countTokensUseTheSuppliedLocaleRatherThanTheProcessDefault() {
        #expect(
            HistoryPanelView.itemCountText(
                count: 5_000,
                hasNextPage: false,
                locale: Locale(identifier: "en_US")
            ) == "5,000 items"
        )
        #expect(
            SearchHeaderView.resultCountText(
                count: 5_000,
                hasNextPage: true,
                locale: Locale(identifier: "de_DE")
            ) == "5.000+ results"
        )
    }
}
