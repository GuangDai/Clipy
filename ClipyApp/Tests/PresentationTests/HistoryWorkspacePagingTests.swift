import Testing
@testable import ClipyApp

@Suite("Settings history page selection")
struct HistoryWorkspacePagingTests {
    @Test func cachedPagesSwitchImmediatelyWithoutLoadingMoreHistory() {
        var paging = HistoryWorkspacePaging()
        #expect(!paging.canMove(.previous, loadedRange: 1...150, hasPreviousPage: false, hasNextPage: true))
        #expect(paging.move(.next, loadedRange: 1...150, hasPreviousPage: false, hasNextPage: true) == nil)
        #expect(paging.pageNumber == 2)
        #expect(paging.visibleRange(in: 1...150) == 51...100)
        #expect(paging.rowOffsets(in: 1...150) == 50..<100)
        #expect(paging.pendingTarget == nil)
        #expect(paging.move(.previous, loadedRange: 1...150, hasPreviousPage: false, hasNextPage: true) == nil)
        #expect(paging.startOrdinal == 1)
        #expect(paging.rowOffsets(in: 1...150) == 0..<50)
    }

    @Test func loadingTheNextWindowKeepsCurrentRowsUntilTheRequestedPageArrives() {
        var paging = HistoryWorkspacePaging()
        paging.move(.next, loadedRange: 1...150, hasPreviousPage: false, hasNextPage: true)
        paging.move(.next, loadedRange: 1...150, hasPreviousPage: false, hasNextPage: true)
        #expect(paging.move(.next, loadedRange: 1...150, hasPreviousPage: false, hasNextPage: true) == .next)
        #expect(paging.startOrdinal == 101)
        #expect(paging.pendingTarget == 151)
        paging.reconcile(loadedRange: 1...150, isLoadingPage: true)
        #expect(paging.visibleRange(in: 1...150) == 101...150)
        #expect(!paging.canMove(.next, loadedRange: 1...150, hasPreviousPage: false, hasNextPage: true))
        #expect(paging.move(.previous, loadedRange: 1...150, hasPreviousPage: false, hasNextPage: true) == nil)
        #expect(paging.pendingTarget == 151)

        paging.reconcile(loadedRange: 51...200, isLoadingPage: false)
        #expect(paging.pageNumber == 4)
        #expect(paging.startOrdinal == 151)
        #expect(paging.rowOffsets(in: 51...200) == 100..<150)
        #expect(paging.pendingTarget == nil)
    }

    @Test func absolutePageSelectionSurvivesRepeatedThreePageWindowRetirementInBothDirections() {
        var paging = HistoryWorkspacePaging(pageLimit: 2)
        var loadedRange = 1...2
        for targetPage in 2...8 {
            #expect(paging.move(.next, loadedRange: loadedRange, hasPreviousPage: loadedRange.lowerBound > 1,
                                hasNextPage: true) == .next)
            loadedRange = (max(0, targetPage - 3) * 2 + 1)...(targetPage * 2)
            paging.reconcile(loadedRange: loadedRange, isLoadingPage: false)
            #expect(paging.pageNumber == targetPage)
            #expect(paging.visibleRange(in: loadedRange) == (targetPage * 2 - 1)...(targetPage * 2))
            #expect(paging.rowOffsets(in: loadedRange).count == 2)
        }

        for targetPage in stride(from: 7, through: 1, by: -1) {
            let target = targetPage * 2 - 1
            let wasCached = loadedRange.contains(target)
            let request = paging.move(.previous, loadedRange: loadedRange,
                                      hasPreviousPage: loadedRange.lowerBound > 1, hasNextPage: true)
            #expect(request == (wasCached ? nil : .previous))
            if !wasCached {
                loadedRange = target...(target + 5)
                paging.reconcile(loadedRange: loadedRange, isLoadingPage: false)
            }
            #expect(paging.pageNumber == targetPage)
            #expect(paging.visibleRange(in: loadedRange) == target...(target + 1))
            #expect(paging.rowOffsets(in: loadedRange).count == 2)
        }
        #expect(loadedRange == 1...6)
        #expect(!paging.canMove(.previous, loadedRange: loadedRange, hasPreviousPage: false, hasNextPage: true))
    }

    @Test func aShortLastPageUsesOnlyItsActualRowsAndDoesNotOfferAnotherPage() {
        var paging = HistoryWorkspacePaging()
        paging.move(.next, loadedRange: 1...125, hasPreviousPage: false, hasNextPage: false)
        paging.move(.next, loadedRange: 1...125, hasPreviousPage: false, hasNextPage: false)
        #expect(paging.pageNumber == 3)
        #expect(paging.visibleRange(in: 1...125) == 101...125)
        #expect(paging.rowOffsets(in: 1...125) == 100..<125)
        #expect(!paging.canMove(.next, loadedRange: 1...125, hasPreviousPage: false, hasNextPage: false))
        #expect(paging.canMove(.previous, loadedRange: 1...125, hasPreviousPage: false, hasNextPage: false))
    }

    @Test func failedRequestsInEitherDirectionPreserveTheSelectedPageAndAllowRetry() {
        var paging = HistoryWorkspacePaging()
        #expect(paging.move(.next, loadedRange: 1...50, hasPreviousPage: false, hasNextPage: true) == .next)
        paging.reconcile(loadedRange: 1...50, isLoadingPage: true)
        #expect(paging.pendingTarget == 51)
        paging.reconcile(loadedRange: 1...50, isLoadingPage: false)
        #expect(paging.startOrdinal == 1)
        #expect(paging.pendingTarget == nil)
        #expect(paging.canMove(.next, loadedRange: 1...50, hasPreviousPage: false, hasNextPage: true))

        paging.reconcile(loadedRange: 101...250, isLoadingPage: false)
        #expect(paging.startOrdinal == 101)
        #expect(paging.move(.previous, loadedRange: 101...250, hasPreviousPage: true, hasNextPage: true) == .previous)
        paging.reconcile(loadedRange: 101...250, isLoadingPage: false)
        #expect(paging.startOrdinal == 101)
        #expect(paging.pendingTarget == nil)
        #expect(paging.canMove(.previous, loadedRange: 101...250, hasPreviousPage: true, hasNextPage: true))
    }

    @Test func snapshotRestartSelectsTheFirstPageAndRetiresItsPendingNavigation() {
        var paging = HistoryWorkspacePaging()
        paging.reconcile(loadedRange: 151...300, isLoadingPage: false)
        paging.move(.previous, loadedRange: 151...300, hasPreviousPage: true, hasNextPage: true)
        #expect(paging.pendingTarget == 101)
        paging.reconcile(loadedRange: nil, isLoadingPage: false)
        #expect(paging.pageNumber == 1)
        #expect(paging.pendingTarget == nil)
        #expect(paging.rowOffsets(in: nil).isEmpty)
        paging.reconcile(loadedRange: 1...35, isLoadingPage: false)
        #expect(paging.visibleRange(in: 1...35) == 1...35)

        paging.reconcile(loadedRange: 151...300, isLoadingPage: false)
        paging.reconcile(loadedRange: 1...50, isLoadingPage: false)
        #expect(paging.startOrdinal == 1)
    }

    @Test func explicitRefreshOrQueryResetClearsSelectionEvenBeforeRowsAreReplaced() {
        var paging = HistoryWorkspacePaging()
        paging.move(.next, loadedRange: 1...100, hasPreviousPage: false, hasNextPage: true)
        paging.move(.next, loadedRange: 1...100, hasPreviousPage: false, hasNextPage: true)
        #expect(paging.pendingTarget == 101)
        paging.reset()
        #expect(paging.startOrdinal == 1)
        #expect(paging.pendingTarget == nil)
        #expect(paging.visibleRange(in: 1...100) == 1...50)
    }

    @Test func emptyResultsHaveNoRowsOrAvailableNavigation() {
        let paging = HistoryWorkspacePaging()
        #expect(paging.visibleRange(in: nil) == nil)
        #expect(paging.rowOffsets(in: nil) == 0..<0)
        #expect(!paging.canMove(.previous, loadedRange: nil, hasPreviousPage: true, hasNextPage: true))
        #expect(!paging.canMove(.next, loadedRange: nil, hasPreviousPage: true, hasNextPage: true))
    }

    @Test func restoredReadingOriginCanRequestPreviousWithoutMistakingItsOldRowsForSuccess() {
        var paging = HistoryWorkspacePaging()
        #expect(!paging.canMove(.previous, loadedRange: 1...50, hasPreviousPage: true,
                                hasNextPage: true, hasKnownRowOffset: true))
        #expect(paging.canMove(.previous, loadedRange: 1...50, hasPreviousPage: true,
                               hasNextPage: true, hasKnownRowOffset: false))
        #expect(paging.move(.previous, loadedRange: 1...50, hasPreviousPage: true,
                            hasNextPage: true, hasKnownRowOffset: false) == .previous)
        #expect(paging.pendingTarget == 1)
        paging.reconcile(loadedRange: 1...50, isLoadingPage: true)
        #expect(paging.pendingTarget == 1)
        #expect(paging.visibleRange(in: 1...50) == 1...50)
        #expect(!paging.canMove(.previous, loadedRange: 1...50, hasPreviousPage: true,
                                hasNextPage: true, hasKnownRowOffset: false))
        paging.reconcile(loadedRange: 1...100, isLoadingPage: false)
        #expect(paging.startOrdinal == 1)
        #expect(paging.pendingTarget == nil)
        #expect(paging.rowOffsets(in: 1...100) == 0..<50)
        #expect(paging.canMove(.previous, loadedRange: 1...100, hasPreviousPage: true,
                               hasNextPage: true, hasKnownRowOffset: false))
    }

    @Test func failedPreviousReadAtRestoredOriginRetainsTheCurrentPageAndCanRetry() {
        var paging = HistoryWorkspacePaging()
        paging.move(.previous, loadedRange: 1...50, hasPreviousPage: true,
                    hasNextPage: true, hasKnownRowOffset: false)
        paging.reconcile(loadedRange: 1...50, isLoadingPage: true)
        paging.reconcile(loadedRange: 1...50, isLoadingPage: false)
        #expect(paging.startOrdinal == 1)
        #expect(paging.pendingTarget == nil)
        #expect(paging.visibleRange(in: 1...50) == 1...50)
        #expect(paging.move(.previous, loadedRange: 1...50, hasPreviousPage: true,
                            hasNextPage: true, hasKnownRowOffset: false) == .previous)
        paging.reset()
        #expect(paging.pendingTarget == nil)
        #expect(paging.canMove(.next, loadedRange: 1...100, hasPreviousPage: false, hasNextPage: true))
    }

    @Test(arguments: [
        (false, true, false, true),
        (false, true, true, false),
        (false, false, false, false),
        (false, false, true, false),
        (true, true, false, false),
        (true, true, true, false),
        (true, false, false, false),
        (true, false, true, false)
    ])
    func aKnownBoundaryRestartsOnlyWhenASeekReachesTheBeginningOutsideAnExistingRefresh(
        wasKnown: Bool, isKnown: Bool, isLoading: Bool, expectsRestart: Bool
    ) {
        #expect(HistoryWorkspacePaging.shouldRestartAtKnownBoundary(
            wasKnown: wasKnown, isKnown: isKnown, isLoadingFirstPage: isLoading
        ) == expectsRestart)
    }

    @Test func restartingAfterAShortPrecedingPageKeepsRows126Through150InTheVisitedPages() {
        var paging = HistoryWorkspacePaging()
        // A seek at row 76, followed by two newer requests, creates storage
        // chunks [1...25, 26...75, 76...125]. They are not standard UI pages.
        paging.move(.previous, loadedRange: 1...100, hasPreviousPage: true,
                    hasNextPage: true, hasKnownRowOffset: false)
        paging.reconcile(loadedRange: 1...125, isLoadingPage: false)
        #expect(HistoryWorkspacePaging.shouldRestartAtKnownBoundary(
            wasKnown: false, isKnown: true, isLoadingFirstPage: false
        ))

        paging.reset()
        paging.reconcile(loadedRange: nil, isLoadingPage: false)
        paging.reconcile(loadedRange: 1...50, isLoadingPage: false)
        var visited = Array(1...50)
        var loadedRange = 1...50
        for targetPage in 2...4 {
            #expect(paging.move(.next, loadedRange: loadedRange, hasPreviousPage: false, hasNextPage: true) == .next)
            loadedRange = (max(0, targetPage - 3) * 50 + 1)...(targetPage * 50)
            paging.reconcile(loadedRange: loadedRange, isLoadingPage: false)
            if let visible = paging.visibleRange(in: loadedRange) { visited.append(contentsOf: visible) }
        }
        #expect(visited == Array(1...200))
        #expect(Array(visited[125..<150]) == Array(126...150))
    }
}
