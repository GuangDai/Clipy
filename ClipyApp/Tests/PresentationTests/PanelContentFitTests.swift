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

    @Test func emptyContentFitsItsMessage() {
        // 34pt toolbar + 52pt empty message + 6pt bottom breathing room.
        #expect(PanelContentFit.idealHeight(PanelContentFit.Input()) == 92)
        #expect(
            PanelContentFit.clampedHeight(
                PanelContentFit.idealHeight(PanelContentFit.Input()),
                ceiling: PanelGeometry.height
            ) == 92
        )
    }

    @Test func aShortDemandHasNoArtificialFloor() {
        #expect(PanelContentFit.clampedHeight(32, ceiling: 420) == 32)
        #expect(PanelGeometry.minimumHeight == 0)
        #expect(PanelGeometry.minimumContentWidth == 0)
    }

    @Test func recentOnlyRowsDoNotPayForARedundantSectionHeading() {
        var input = PanelContentFit.Input()
        input.unpinnedRows = [textRow(), textRow(), textRow()]
        // 34pt toolbar + 3×24pt rows + 6pt breathing room.
        #expect(PanelContentFit.idealHeight(input) == 112)
        #expect(
            PanelContentFit.clampedHeight(
                PanelContentFit.idealHeight(input), ceiling: 420
            ) == 112
        )
    }

    @Test func pinnedAndRecentSectionsEachCarryAHeader() {
        var input = PanelContentFit.Input()
        input.pinnedRows = [textRow()]
        input.unpinnedRows = [imageRow]
        // 34pt toolbar + 2×28pt section headers + 24pt text + 52pt image + 6pt slack.
        #expect(PanelContentFit.idealHeight(input) == 172)
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
        #expect(PanelContentFit.clampedHeight(ideal, ceiling: 40) == 40)
        #expect(PanelContentFit.clampedHeight(10, ceiling: 420) == 10)
    }

    /// A pushed Details/editor destination or the quick-look overlay fills
    /// the whole panel: while `prefersFullHeight` is set the demand clamps
    /// to the persisted ceiling instead of the row-derived height (a short
    /// list grows the panel, top-edge-pinned), and clearing the flag refits
    /// to the rows.
    @Test func fullHeightDestinationDemandsThePersistedCeiling() {
        var input = PanelContentFit.Input()
        input.unpinnedRows = [textRow(), textRow()]
        // 34pt toolbar + 2×24pt rows + 6pt slack.
        let rowFit = PanelContentFit.clampedHeight(
            PanelContentFit.idealHeight(input), ceiling: 420
        )
        #expect(rowFit == 88)

        input.prefersFullHeight = true
        let fullHeight = PanelContentFit.idealHeight(input)
        #expect(fullHeight == PanelContentFit.fullHeightDemand)
        #expect(PanelContentFit.clampedHeight(fullHeight, ceiling: 420) == 420)
        #expect(PanelContentFit.clampedHeight(fullHeight, ceiling: 40) == 40)

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
