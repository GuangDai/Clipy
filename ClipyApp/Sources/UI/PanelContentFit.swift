/// PanelContentFit.swift — the panel's analytic content-height oracle
/// (content-fitting popup: the panel retains room for five compact records
/// below its toolbar, then grows with content up to the saved height ceiling).
/// SwiftUI List laziness makes runtime measurement unreliable, so the
/// ideal height is COMPUTED from the same sources of truth the views use:
/// PanelTheme metrics for slots/padding, the hoisted list-row insets the
/// list applies, and the platform text-style line heights behind
/// PanelTheme's Font mappings (hoisted here as named constants; the
/// Font-returning theme functions cannot expose metric values).
/// Pure Foundation/CoreGraphics + HistoryCore DTOs: no AppKit, no SwiftUI
/// (01 §8), so the oracle is testable headlessly.
import CoreGraphics
import Foundation
import HistoryCore

/// Analytic height math for the browsing surface. `Input` is the complete
/// content/chrome snapshot; `idealHeight(_:)` is a pure function of it;
/// `clampedHeight(_:ceiling:)` applies the user's size ceiling. The
/// AppKit side (`FloatingPanel.fitToContent`) owns the actual frame change.
enum PanelContentFit {

    /// One text block and one thumbnail height drive rendering, fitting and paging.
    struct RowDescriptor: Equatable, Sendable {
        let usesLargeImageSlot: Bool
        let textLineCount: Int

        init(usesLargeImageSlot: Bool = false, textLineCount: Int = 1) {
            self.usesLargeImageSlot = usesLargeImageSlot
            self.textLineCount = textLineCount
        }

        init(row: HistoryRow, linePreference: HistorySnippetLineCount,
             density: HistoryRowDensity, forSearchResults: Bool) {
            usesLargeImageSlot = !forSearchResults
                && HistoryRowKind.classify(effectiveTypeIdentifiers: row.typeIdentifiers) == .image
            textLineCount = linePreference.baseLineLimit(density: density, forSearchResults: forSearchResults)
        }
    }

    /// The complete height-relevant snapshot of the browsing surface:
    /// displayed rows per section, row typography, and chrome visibility.
    /// Equatable so the panel view can report only real changes.
    struct Input: Equatable, Sendable {
        var pinnedRows: [RowDescriptor] = []
        var unpinnedRows: [RowDescriptor] = []
        var density: HistoryRowDensity = .compact
        var fontSize: HistoryRowFontSize = .medium
        /// The trailing pagination control (Older button or loading row):
        /// `hasNextPage || isLoadingPage`, matching the list's condition.
        var showsPaginationControl = false
        /// Explicit metadata ordering keeps pinned rows in that order and
        /// therefore has no pinned/recent separator.
        var usesPinnedGrouping = true
        /// The search header's removable active-filter summary chip.
        var isFilterChipVisible = false
        /// The browsing column's typed-failure banner.
        var isFailureBannerVisible = false
        /// Root notices occupy normal layout above the browsing column.
        /// The root reports their natural height only when it changes.
        var topNoticeHeight: CGFloat = 0
        /// A pushed destination (Details/editor) or the quick-look overlay
        /// fills the whole panel: row-derived shrink-to-fit would clip it.
        /// While set the demand is the full persisted ceiling
        /// (`fullHeightDemand`); clearing it refits to the rows.
        var prefersFullHeight = false
    }

    // MARK: Hoisted view metrics (single source of truth)

    /// The list's per-row content insets (HistoryListView's
    /// `.listRowInsets`); hoisted so the oracle and the list share one
    /// source of truth.
    static let listRowVerticalInset: CGFloat = 2
    static let listRowHorizontalInset: CGFloat = 6

    /// The breathing room below the last row.
    static let bottomSlack: CGFloat = 6

    // MARK: Header chrome

    /// The plain text field's content line height (SearchHeaderView's
    /// `.textFieldStyle(.plain)` field at the platform's default text
    /// size). The view derives it from the platform control, so the value
    /// is hoisted here and pinned by PanelContentFitTests.
    static let searchFieldTextHeight: CGFloat = 16

    /// SearchHeaderView's field: its text line plus the vertical
    /// `PanelTheme.spacingXXSmall` padding the field applies.
    static let searchFieldHeight: CGFloat =
        searchFieldTextHeight + 2 * PanelTheme.spacingXXSmall

    /// The top strip remains the lower bound for legacy saved heights.
    static let searchStripHeight: CGFloat =
        PanelTheme.headerTopPadding + searchFieldHeight
            + PanelTheme.headerBottomPadding

    /// The mode, sort, and date controls live below the native editor.
    static let searchControlsHeight: CGFloat = 24
    static let headerHeight: CGFloat =
        searchStripHeight + PanelTheme.spacingXSmall + searchControlsHeight

    /// The active-filter chip's contribution when visible: the header
    /// VStack's `spacingXSmall` gap plus the caption-sized label.
    static let filterChipDelta: CGFloat =
        PanelTheme.spacingXSmall + filterChipLabelHeight
    private static let filterChipLabelHeight: CGFloat = 15

    // MARK: List chrome

    /// A single native divider with 4pt breathing room on either side.
    /// No headings or empty group space, including a pinned-only result.
    static let groupSeparatorHeight: CGFloat = 9


    /// The trailing pagination control — the loading row's small progress
    /// view plus its 6pt vertical padding, and the same bound covers the
    /// Older button row (HistoryListView).
    static let paginationRowHeight: CGFloat = 28

    /// The failure banner: its vertical padding, a two-line footnote
    /// message allowance (the banner wraps at the panel width), and the
    /// divider hairline.
    static let failureBannerHeight: CGFloat =
        2 * PanelTheme.bannerVerticalPadding + 2 * footnoteLineHeight + 1
    private static let footnoteLineHeight: CGFloat = 15

    // MARK: Row typography (PanelTheme's Font mappings)

    /// The system text line box scales with the actual point size. Ceil
    /// reserves a whole point for fractional sizes.
    static func titleLineHeight(for size: HistoryRowFontSize) -> CGFloat {
        ceil(CGFloat(size.points) * 1.2)
    }

    /// One row contains the fixed slot and the configured text block.
    static func rowHeight(
        _ row: RowDescriptor,
        density: HistoryRowDensity,
        fontSize: HistoryRowFontSize
    ) -> CGFloat {
        let slot = row.usesLargeImageSlot
            ? PanelTheme.imageThumbnailHeight(for: density)
            : PanelTheme.thumbnailSize(for: density)
        let textHeight = CGFloat(row.textLineCount) * titleLineHeight(for: fontSize)
        return max(slot, textHeight)
            + 2 * PanelTheme.rowVerticalPadding(for: density)
            + 2 * listRowVerticalInset
    }

    // MARK: Oracle

    /// The demand a full-height destination (`Input.prefersFullHeight`)
    /// publishes: an unbounded ideal that `clampedHeight` resolves to the
    /// persisted ceiling (still floored against a legacy sub-floor ceiling).
    /// The oracle stays ceiling-agnostic — the AppKit side owns the
    /// persisted value — so the flag maps to the ceiling through the
    /// existing clamp instead of a new parameter.
    static let fullHeightDemand: CGFloat = .greatestFiniteMagnitude

    /// Five compact, default-font record rows below the existing toolbar,
    /// plus the same bottom slack as the content-fit calculation. Optional
    /// filters, banners and pagination add demand above this natural floor.
    static let minimumHeight: CGFloat = headerHeight + bottomSlack + 5 * rowHeight(
        RowDescriptor(),
        density: .compact, fontSize: .medium
    )
    static let emptyStateHeight: CGFloat = 52

    /// The ideal content height for the displayed rows and chrome: header
    /// (+ filter chip when visible), the windowed-navigation bar when
    /// paging, one separator when pinned and recent groups both display,
    /// the rows, the
    /// trailing pagination control, the failure banner, and bottom slack.
    /// `prefersFullHeight` short-circuits all of it: a pushed
    /// Details/editor destination or the quick-look overlay demands the
    /// whole persisted ceiling (`fullHeightDemand`).
    static func idealHeight(_ input: Input) -> CGFloat {
        guard !input.prefersFullHeight else { return fullHeightDemand }
        var height = headerHeight + bottomSlack
        if input.pinnedRows.isEmpty, input.unpinnedRows.isEmpty,
           !input.showsPaginationControl {
            height += emptyStateHeight
        }
        if input.isFilterChipVisible {
            height += filterChipDelta
        }
        let showsGroupSeparator = input.usesPinnedGrouping && !input.pinnedRows.isEmpty
            && (!input.unpinnedRows.isEmpty || input.showsPaginationControl)
        if showsGroupSeparator { height += groupSeparatorHeight }
        if !input.pinnedRows.isEmpty {
            height += input.pinnedRows.reduce(0) {
                $0 + rowHeight($1, density: input.density, fontSize: input.fontSize)
            }
        }
        if !input.unpinnedRows.isEmpty || input.showsPaginationControl {
            height += input.unpinnedRows.reduce(0) {
                $0 + rowHeight($1, density: input.density, fontSize: input.fontSize)
            }
            if input.showsPaginationControl {
                height += paginationRowHeight
            }
        }
        if input.isFailureBannerVisible {
            height += failureBannerHeight
        }
        let notices = input.topNoticeHeight.isFinite ? max(0, input.topNoticeHeight) : 0
        // Notices add to the measured demand and leave the normal browsing
        // floor below them.
        return notices > 0 ? max(height, minimumHeight) + notices : height
    }

    /// Keep the normal browsing floor below notices, even at the smallest
    /// saved window height. The native owner then fits to the visible screen.
    static func clampedHeight(_ ideal: CGFloat, ceiling: CGFloat, topNoticeHeight: CGFloat = 0) -> CGFloat {
        let notices = topNoticeHeight.isFinite ? max(0, topNoticeHeight) : 0
        let floor = minimumHeight + notices
        return min(max(ideal, floor), max(ceiling, floor))
    }
}
