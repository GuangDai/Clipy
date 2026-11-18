/// PanelContentFitTests — the analytic panel-height oracle
/// (`PanelContentFit`): the floor, per-row heights (text vs image slots,
/// snippet lines, density, font size), chrome deltas (filter chip, failure
/// banner, windowed navigation, pagination control), and the
/// floor/ceiling clamp. Pure value tests in the style of
/// FloatingPreviewPlacementTests — no view hosting.
import Foundation
@testable import HistoryCore
@testable import ClipyApp
import Testing

@Suite("Panel content-fit height oracle")
struct PanelContentFitTests {

    private func textRow() -> PanelContentFit.RowDescriptor {
        PanelContentFit.RowDescriptor()
    }

    private var imageRow: PanelContentFit.RowDescriptor {
        PanelContentFit.RowDescriptor(usesLargeImageSlot: true)
    }

    /// Compact/medium: a 16pt content line plus 4pt padding and 4pt insets.
    @Test func textRowHeightAtTheDefaultAppearance() {
        #expect(
            PanelContentFit.rowHeight(
                textRow(), density: .compact, fontSize: .medium
            ) == 24
        )
        // Comfortable: a 24pt slot plus 8pt padding and 4pt insets.
        #expect(
            PanelContentFit.rowHeight(
                textRow(), density: .comfortable, fontSize: .medium
            ) == 36
        )
    }

    @Test func imageRowsUseTheGenerousImageSlot() {
        // 44pt slot exceeds any title block at the default typography.
        #expect(
            PanelContentFit.rowHeight(
                imageRow, density: .compact, fontSize: .medium
            ) == 52
        )
        #expect(
            PanelContentFit.rowHeight(
                imageRow, density: .comfortable, fontSize: .medium
            ) == 68
        )
    }

    @Test(arguments: [0, 1, 3, 5, 6])
    func shortListsKeepFiveCompactRowsBelowBothSearchRows(rowCount: Int) {
        var input = PanelContentFit.Input()
        input.unpinnedRows = Array(repeating: textRow(), count: rowCount)
        let expectedHeight = PanelContentFit.headerHeight + CGFloat(max(5, rowCount)) * 24 + 6
        if rowCount == 0 { #expect(PanelContentFit.idealHeight(input) == PanelContentFit.headerHeight + 52 + 6) }
        #expect(PanelContentFit.clampedHeight(PanelContentFit.idealHeight(input), ceiling: 420) == expectedHeight)
    }

    @Test func pinnedAndRecentGroupsShareOneCompactSeparator() {
        var input = PanelContentFit.Input()
        input.pinnedRows = [textRow()]
        input.unpinnedRows = [imageRow]
        let header = PanelContentFit.headerHeight
        #expect(PanelContentFit.idealHeight(input) == header + 9 + 24 + 52 + 6)
        input.unpinnedRows = []
        #expect(PanelContentFit.idealHeight(input) == header + 24 + 6)
        input.showsPaginationControl = true
        #expect(PanelContentFit.idealHeight(input) == header + 9 + 24 + 28 + 6)
    }

    @Test func chromeDeltasAddTheirOwnHeights() {
        var base = PanelContentFit.Input()
        base.unpinnedRows = [textRow()]
        let baseHeight = PanelContentFit.idealHeight(base)

        var withChip = base
        withChip.isFilterChipVisible = true
        #expect(
            PanelContentFit.idealHeight(withChip) - baseHeight
                == PanelContentFit.filterChipDelta
        )
        #expect(PanelContentFit.filterChipDelta == 21)

        var withBanner = base
        withBanner.isFailureBannerVisible = true
        #expect(
            PanelContentFit.idealHeight(withBanner) - baseHeight
                == PanelContentFit.failureBannerHeight
        )
        #expect(PanelContentFit.failureBannerHeight == 47)

        var withPagination = base
        withPagination.showsPaginationControl = true
        #expect(
            PanelContentFit.idealHeight(withPagination) - baseHeight
                == PanelContentFit.paginationRowHeight
        )
    }

    @Test func rootNoticesAddSpaceAboveTheReadingFloorWithinTheExistingCeiling() {
        var input = PanelContentFit.Input()
        input.unpinnedRows = [textRow()]
        let noNoticeDemand = PanelContentFit.idealHeight(input)
        let noNoticeHeight = PanelContentFit.clampedHeight(noNoticeDemand, ceiling: 420)
        #expect(noNoticeDemand < PanelContentFit.minimumHeight)
        input.topNoticeHeight = 58
        let noticeDemand = PanelContentFit.idealHeight(input)
        #expect(PanelContentFit.clampedHeight(noticeDemand, ceiling: 420) == noNoticeHeight + input.topNoticeHeight)
        #expect(PanelContentFit.clampedHeight(noticeDemand, ceiling: noNoticeHeight + 20) == noNoticeHeight + 20)
        input.topNoticeHeight = 0
        #expect(PanelContentFit.idealHeight(input) == noNoticeDemand)
    }

    @Test func theIdealClampsAtThePersistedCeiling() {
        var input = PanelContentFit.Input()
        input.unpinnedRows = (0 ..< 40).map { _ in textRow() }
        let ideal = PanelContentFit.idealHeight(input)
        #expect(ideal > 420)
        #expect(PanelContentFit.clampedHeight(ideal, ceiling: 420) == 420)
        #expect(PanelContentFit.clampedHeight(ideal, ceiling: 200) == 200)
        #expect(PanelContentFit.clampedHeight(ideal, ceiling: 40) == PanelContentFit.minimumHeight)
        #expect(PanelContentFit.clampedHeight(10, ceiling: 420) == PanelContentFit.minimumHeight)
    }

    /// A pushed Details/editor destination or the quick-look overlay fills
    /// the whole panel: while `prefersFullHeight` is set the demand clamps
    /// to the persisted ceiling instead of the row-derived height (a short
    /// list grows the panel, top-edge-pinned), and clearing the flag refits
    /// to the rows.
    @Test func fullHeightDestinationDemandsThePersistedCeiling() {
        var input = PanelContentFit.Input()
        input.unpinnedRows = [textRow(), textRow()]
        // Live fitting retains room for five rows.
        let rowFit = PanelContentFit.clampedHeight(
            PanelContentFit.idealHeight(input), ceiling: 420
        )
        #expect(rowFit == PanelContentFit.minimumHeight)

        input.prefersFullHeight = true
        let fullHeight = PanelContentFit.idealHeight(input)
        #expect(fullHeight == PanelContentFit.fullHeightDemand)
        #expect(PanelContentFit.clampedHeight(fullHeight, ceiling: 420) == 420)
        #expect(PanelContentFit.clampedHeight(fullHeight, ceiling: 40) == PanelContentFit.minimumHeight)

        // Popping the destination / dismissing the overlay refits to rows.
        input.prefersFullHeight = false
        #expect(
            PanelContentFit.clampedHeight(
                PanelContentFit.idealHeight(input), ceiling: 420
            ) == rowFit
        )
    }

    @Test func rowDescriptorsMapTheSameClassificationAsTheRowView() {
        let reference = HistoryItemReference(
            id: HistoryItemID(rawValue: UUID()),
            contentVersion: ContentVersion(rawValue: 1)
        )
        let imageHistoryRow = HistoryRow(
            item: reference,
            title: "Screenshot",
            typeIdentifiers: ["public.png"],
            lastCopiedAt: Date(timeIntervalSince1970: 1_787_000_000),
            copyCount: 1,
            lastSource: nil,
            pinnedPosition: nil,
            search: nil
        )
        #expect(
            PanelContentFit.RowDescriptor(
                row: imageHistoryRow, linePreference: .one, density: .compact, forSearchResults: false
            ).usesLargeImageSlot
        )
        let textHistoryRow = HistoryRow(
            item: reference,
            title: "Note",
            typeIdentifiers: ["public.utf8-plain-text"],
            lastCopiedAt: Date(timeIntervalSince1970: 1_787_000_000),
            copyCount: 1,
            lastSource: nil,
            pinnedPosition: nil,
            search: nil
        )
        let descriptor = PanelContentFit.RowDescriptor(
            row: textHistoryRow, linePreference: .two, density: .compact, forSearchResults: false
        )
        #expect(!descriptor.usesLargeImageSlot)
        #expect(descriptor.textLineCount == 2)
    }

    @Test func multiLineBrowseTitlesFitTheSelectedTypography() {
        let row = titleRow()
        let twoLines = PanelContentFit.RowDescriptor(
            row: row, linePreference: .two, density: .comfortable, forSearchResults: false
        )
        let threeLines = PanelContentFit.RowDescriptor(
            row: row, linePreference: .three, density: .compact, forSearchResults: false
        )

        // Comfortable/medium: two 16pt title lines plus 12pt padding/insets.
        // Previously this row was only 36pt high, leaving 24pt for its title.
        #expect(PanelContentFit.rowHeight(twoLines, density: .comfortable, fontSize: .medium) == 44)
        // An explicit three-line preference also works in compact density.
        #expect(PanelContentFit.rowHeight(threeLines, density: .compact, fontSize: .large) == 62)

        var input = PanelContentFit.Input()
        input.density = .comfortable
        input.unpinnedRows = [twoLines, twoLines]
        #expect(PanelContentFit.idealHeight(input) == PanelContentFit.headerHeight + 88 + PanelContentFit.bottomSlack)
    }

    @Test func searchResultsUseOneHeightAcrossTitleBodyAndImageMatches() {
        let rows = [
            titleRow(search: SearchPresentation(snippet: nil, matchedRanges: [])),
            titleRow(search: SearchPresentation(snippet: "Body evidence", matchedRanges: [])),
            titleRow(typeIdentifiers: ["public.png"]),
        ]
        for (preference, lineCount) in [(HistorySnippetLineCount.automatic, 1), (.three, 3)] {
            let descriptors = rows.map {
                PanelContentFit.RowDescriptor(row: $0, linePreference: preference,
                                             density: .comfortable, forSearchResults: true)
            }
            #expect(descriptors.allSatisfy { $0.textLineCount == lineCount && !$0.usesLargeImageSlot })
            let heights = descriptors.map { PanelContentFit.rowHeight($0, density: .comfortable, fontSize: .medium) }
            #expect(Set(heights).count == 1)
        }
    }

    @Test func imageRowsGrowWhenTheTitleExceedsTheThumbnailSlot() {
        let descriptor = PanelContentFit.RowDescriptor(
            row: titleRow(typeIdentifiers: ["public.png"]), linePreference: .three, density: .compact, forSearchResults: false
        )
        // Three 18pt title lines exceed the compact 44pt image slot.
        #expect(PanelContentFit.rowHeight(descriptor, density: .compact, fontSize: .large) == 62)
        // Comfortable's 56pt slot still accommodates those three lines.
        #expect(PanelContentFit.rowHeight(descriptor, density: .comfortable, fontSize: .large) == 68)
    }

    private func titleRow(
        typeIdentifiers: [String] = ["public.utf8-plain-text"],
        search: SearchPresentation? = nil
    ) -> HistoryRow {
        HistoryRow(
            item: HistoryItemReference(
                id: HistoryItemID(rawValue: UUID()), contentVersion: ContentVersion(rawValue: 1)
            ),
            title: "First title line\nSecond title line\nThird title line",
            typeIdentifiers: typeIdentifiers,
            lastCopiedAt: Date(timeIntervalSince1970: 1_787_000_000),
            copyCount: 1,
            lastSource: nil,
            pinnedPosition: nil,
            search: search
        )
    }
}
