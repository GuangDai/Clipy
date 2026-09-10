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

    /// Compact/medium text row: max(20 slot, 21 title) + 2×2 padding +
    /// 2×2 list insets = 29 (PanelTheme + hoisted insets).
    @Test func textRowHeightAtTheDefaultAppearance() {
        #expect(
            PanelContentFit.rowHeight(
                textRow(), density: .compact, fontSize: .medium
            ) == 29
        )
        // Comfortable: the 28pt slot exceeds the title block; padding is 4.
        #expect(
            PanelContentFit.rowHeight(
                textRow(), density: .comfortable, fontSize: .medium
            ) == 40
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
        // Title block: 21 + 4 gap + 1×18 subheadline = 43, exceeding the
        // 20pt slot; + 2×2 padding + 2×2 insets.
        #expect(
            PanelContentFit.rowHeight(
                textRow(snippetLines: 1), density: .compact, fontSize: .medium
            ) == 51
        )
        #expect(
            PanelContentFit.rowHeight(
                textRow(snippetLines: 2), density: .compact, fontSize: .medium
            ) == 69
        )
    }

    @Test func emptyContentClampsToTheFloor() {
        // Empty: header (48) + bottom slack (6), below the floor.
        #expect(PanelContentFit.idealHeight(PanelContentFit.Input()) == 54)
        #expect(
            PanelContentFit.clampedHeight(
                PanelContentFit.idealHeight(PanelContentFit.Input()),
                ceiling: PanelGeometry.height
            ) == PanelContentFit.minimumHeight
        )
    }

    @Test func theFloorIsHeaderPlusOneTextRowPlusSlack() {
        #expect(
            PanelContentFit.minimumHeight
                == PanelContentFit.headerHeight
                    + PanelContentFit.rowHeight(
                        textRow(), density: .compact, fontSize: .medium
                    )
                    + PanelContentFit.bottomSlack
        )
        // Pinned literal: header 48 + row 29 + slack 6.
        #expect(PanelContentFit.minimumHeight == 83)
        // The window's resize minimum is the same floor.
        #expect(PanelGeometry.minimumHeight == PanelContentFit.minimumHeight)
    }

    @Test func rowsAndOneSectionHeaderSumIntoTheIdeal() {
        var input = PanelContentFit.Input()
        input.unpinnedRows = [textRow(), textRow(), textRow()]
        // header 48 + Recent header 28 + 3×29 + slack 6.
        #expect(PanelContentFit.idealHeight(input) == 169)
        #expect(
            PanelContentFit.clampedHeight(
                PanelContentFit.idealHeight(input), ceiling: 420
            ) == 169
        )
    }

    @Test func pinnedAndRecentSectionsEachCarryAHeader() {
        var input = PanelContentFit.Input()
        input.pinnedRows = [textRow()]
        input.unpinnedRows = [imageRow]
        // header 48 + 2×28 section headers + 29 text + 52 image + slack 6.
        #expect(PanelContentFit.idealHeight(input) == 191)
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

        var withWindowing = base
        withWindowing.hasWindowedPages = true
        #expect(
            PanelContentFit.idealHeight(withWindowing) - baseHeight
                == PanelContentFit.windowedNavigationHeight
        )

        var withPagination = base
        withPagination.showsPaginationControl = true
        #expect(
            PanelContentFit.idealHeight(withPagination) - baseHeight
                == PanelContentFit.paginationRowHeight
        )
    }

    @Test func theIdealClampsAtThePersistedCeiling() {
        var input = PanelContentFit.Input()
        input.unpinnedRows = (0 ..< 40).map { _ in textRow() }
        let ideal = PanelContentFit.idealHeight(input)
        #expect(ideal > 420)
        #expect(PanelContentFit.clampedHeight(ideal, ceiling: 420) == 420)
        // A ceiling below the floor (a pre-floor defaults value) still
        // yields the floor.
        #expect(PanelContentFit.clampedHeight(ideal, ceiling: 40) == 83)
        #expect(PanelContentFit.clampedHeight(10, ceiling: 420) == 83)
    }

    /// A pushed Details/editor destination or the quick-look overlay fills
    /// the whole panel: while `prefersFullHeight` is set the demand clamps
    /// to the persisted ceiling instead of the row-derived height (a short
    /// list grows the panel, top-edge-pinned), and clearing the flag refits
    /// to the rows.
    @Test func fullHeightDestinationDemandsThePersistedCeiling() {
        var input = PanelContentFit.Input()
        input.unpinnedRows = [textRow(), textRow()]
        // header 48 + Recent header 28 + 2×29 + slack 6.
        let rowFit = PanelContentFit.clampedHeight(
            PanelContentFit.idealHeight(input), ceiling: 420
        )
        #expect(rowFit == 140)

        input.prefersFullHeight = true
        let fullHeight = PanelContentFit.idealHeight(input)
        #expect(fullHeight == PanelContentFit.fullHeightDemand)
        #expect(PanelContentFit.clampedHeight(fullHeight, ceiling: 420) == 420)
        // A sub-floor legacy ceiling still yields the floor.
        #expect(PanelContentFit.clampedHeight(fullHeight, ceiling: 40) == 83)

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
        #expect(descriptor.snippetLineCount == 0)
    }
}
