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

    private func textRow(snippetLines: Int = 0) -> PanelContentFit.RowDescriptor {
        PanelContentFit.RowDescriptor(
            isImageRow: false,
            snippetLineCount: snippetLines
        )
    }

    private var imageRow: PanelContentFit.RowDescriptor {
        PanelContentFit.RowDescriptor(isImageRow: true, snippetLineCount: 0)
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

    @Test func snippetRowsGrowByTheEffectiveLineCount() {
        // 16pt title + 4pt gap + 15pt snippet + 8pt padding/insets.
        #expect(
            PanelContentFit.rowHeight(
                textRow(snippetLines: 1), density: .compact, fontSize: .medium
            ) == 43
        )
        #expect(
            PanelContentFit.rowHeight(
                textRow(snippetLines: 2), density: .compact, fontSize: .medium
            ) == 58
        )
    }

    @Test(arguments: [(0, CGFloat(160)), (1, 160), (3, 160), (5, 160), (6, 184)])
    func shortListsKeepFiveCompactRowsBelowTheToolbar(rowCount: Int, expectedHeight: CGFloat) {
        var input = PanelContentFit.Input()
        input.unpinnedRows = Array(repeating: textRow(), count: rowCount)
        // The empty message still needs 52pt; it does not consume a sixth
        // record row or raise the five-row floor (34 + 5×24 + 6 = 160).
        if rowCount == 0 { #expect(PanelContentFit.idealHeight(input) == 92) }
        #expect(PanelContentFit.clampedHeight(PanelContentFit.idealHeight(input), ceiling: 420) == expectedHeight)
    }

    @Test func pinnedAndRecentGroupsShareOneCompactSeparator() {
        var input = PanelContentFit.Input()
        input.pinnedRows = [textRow()]
        input.unpinnedRows = [imageRow]
        // 34pt toolbar + 9pt separator + 24pt text + 52pt image + 6pt slack.
        #expect(PanelContentFit.idealHeight(input) == 125)
        input.unpinnedRows = []
        #expect(PanelContentFit.idealHeight(input) == 64)
        input.showsPaginationControl = true
        #expect(PanelContentFit.idealHeight(input) == 101)
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
        #expect(PanelContentFit.clampedHeight(ideal, ceiling: 40) == 160)
        #expect(PanelContentFit.clampedHeight(10, ceiling: 420) == 160)
    }

    /// A pushed Details/editor destination or the quick-look overlay fills
    /// the whole panel: while `prefersFullHeight` is set the demand clamps
    /// to the persisted ceiling instead of the row-derived height (a short
    /// list grows the panel, top-edge-pinned), and clearing the flag refits
    /// to the rows.
    @Test func fullHeightDestinationDemandsThePersistedCeiling() {
        var input = PanelContentFit.Input()
        input.unpinnedRows = [textRow(), textRow()]
        // Two rows need only 88pt of content; live fitting retains five rows.
        let rowFit = PanelContentFit.clampedHeight(
            PanelContentFit.idealHeight(input), ceiling: 420
        )
        #expect(rowFit == 160)

        input.prefersFullHeight = true
        let fullHeight = PanelContentFit.idealHeight(input)
        #expect(fullHeight == PanelContentFit.fullHeightDemand)
        #expect(PanelContentFit.clampedHeight(fullHeight, ceiling: 420) == 420)
        #expect(PanelContentFit.clampedHeight(fullHeight, ceiling: 40) == 160)

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
                row: imageHistoryRow, snippetLineLimit: 1
            ).isImageRow
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
            row: textHistoryRow, snippetLineLimit: 2
        )
        #expect(!descriptor.isImageRow)
        #expect(descriptor.titleLineCount == 2)
        #expect(descriptor.snippetLineCount == 0)
    }

    @Test func multiLineBrowseTitlesFitTheSelectedTypography() {
        let row = titleRow()
        let twoLines = PanelContentFit.RowDescriptor(row: row, snippetLineLimit: 2)
        let threeLines = PanelContentFit.RowDescriptor(row: row, snippetLineLimit: 3)

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

    @Test func searchExcerptsKeepOneTitleLineWhileTitleMatchesUseThePreference() {
        let excerpt = PanelContentFit.RowDescriptor(
            row: titleRow(search: SearchPresentation(snippet: "Body evidence", matchedRanges: [])),
            snippetLineLimit: 3
        )
        #expect(excerpt.titleLineCount == 1)
        #expect(excerpt.snippetLineCount == 3)
        // 16pt title + 4pt gap + three 15pt snippet lines + 8pt padding/insets.
        #expect(PanelContentFit.rowHeight(excerpt, density: .compact, fontSize: .medium) == 73)

        let titleMatch = PanelContentFit.RowDescriptor(
            row: titleRow(search: SearchPresentation(snippet: nil, matchedRanges: [])),
            snippetLineLimit: 3
        )
        #expect(titleMatch.titleLineCount == 3)
        #expect(titleMatch.snippetLineCount == 0)
        #expect(PanelContentFit.rowHeight(titleMatch, density: .compact, fontSize: .medium) == 56)
    }

    @Test func imageRowsGrowWhenTheTitleExceedsTheThumbnailSlot() {
        let descriptor = PanelContentFit.RowDescriptor(
            row: titleRow(typeIdentifiers: ["public.png"]), snippetLineLimit: 3
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
