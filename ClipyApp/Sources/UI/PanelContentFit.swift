/// PanelContentFit.swift — the panel's analytic content-height oracle
/// (Maccy's content-fitting popup: the panel is exactly as tall as its
/// displayed content between a floor and the persisted height ceiling).
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
/// `clampedHeight(_:ceiling:)` applies the floor/ceiling contract. The
/// AppKit side (`FloatingPanel.fitToContent`) owns the actual frame change.
enum PanelContentFit {

    /// One displayed row's height-relevant facts: its slot kind (image rows
    /// carry the generous 44/56pt slot) and the effective snippet line
    /// count (0 when the row renders no snippet).
    struct RowDescriptor: Equatable, Sendable {
        let isImageRow: Bool
        let snippetLineCount: Int

        init(isImageRow: Bool, snippetLineCount: Int) {
            self.isImageRow = isImageRow
            self.snippetLineCount = snippetLineCount
        }

        /// Maps an authoritative row through the same classification the
        /// row view uses (`HistoryRowKind`, shared with the type filter).
        /// The oracle cannot measure snippet WRAPPING analytically; a row
        /// with a snippet is charged the configured line limit
        /// (`HistorySnippetLineCount.baseLineLimit(density:)`), the same
        /// bound the row view renders with.
        init(row: HistoryRow, snippetLineLimit: Int) {
            isImageRow = HistoryRowKind.classify(
                effectiveTypeIdentifiers: row.typeIdentifiers
            ) == .image
            snippetLineCount = row.search?.snippet == nil
                ? 0 : snippetLineLimit
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
        /// The Newer/Latest windowed-navigation bar (HistoryListView).
        var hasWindowedPages = false
        /// The trailing pagination control (Older button or loading row):
        /// `hasNextPage || isLoadingPage`, matching the list's condition.
        var showsPaginationControl = false
        /// The search header's removable active-filter summary chip.
        var isFilterChipVisible = false
        /// The browsing column's typed-failure banner.
        var isFailureBannerVisible = false
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
    static let searchFieldTextHeight: CGFloat = 22

    /// SearchHeaderView's field: its text line plus the vertical
    /// `PanelTheme.spacingXSmall` padding the field applies.
    static let searchFieldHeight: CGFloat =
        searchFieldTextHeight + 2 * PanelTheme.spacingXSmall

    /// The complete search-header strip: the field plus the
    /// HistoryPanelView header padding (`PanelTheme.headerTopPadding` /
    /// `headerBottomPadding`).
    static let headerHeight: CGFloat =
        PanelTheme.headerTopPadding + searchFieldHeight
            + PanelTheme.headerBottomPadding

    /// The active-filter chip's contribution when visible: the header
    /// VStack's `spacingXSmall` gap plus the caption-sized label.
    static let filterChipDelta: CGFloat =
        PanelTheme.spacingXSmall + filterChipLabelHeight
    private static let filterChipLabelHeight: CGFloat = 15

    // MARK: List chrome

    /// One `.inset` section header (Pinned / Recent): the small-caps label
    /// plus the list's own header padding, owned by the platform and
    /// pinned here.
    static let sectionHeaderHeight: CGFloat = 28

    /// The Newer/Latest windowed-navigation bar: the buttons plus their
    /// 6pt vertical padding (HistoryListView).
    static let windowedNavigationHeight: CGFloat = 34

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

    /// Title line heights behind `PanelTheme.titleFont(for:)`:
    /// small → .callout, medium → .body, large → .title3.
    static func titleLineHeight(for size: HistoryRowFontSize) -> CGFloat {
        switch size {
        case .small: return 19
        case .medium: return 21
        case .large: return 25
        }
    }

    /// Snippet line heights behind `PanelTheme.snippetFont(for:)`:
    /// small → .footnote, medium → .subheadline, large → .callout.
    static func snippetLineHeight(for size: HistoryRowFontSize) -> CGFloat {
        switch size {
        case .small: return 16
        case .medium: return 18
        case .large: return 19
        }
    }

    /// One row: `max(slot, title block)` plus the row's vertical padding
    /// (`PanelTheme.rowVerticalPadding`) and the hoisted list-row insets.
    /// The title block is one title line plus, when a snippet renders, the
    /// title/snippet gap (`PanelTheme.spacingXXSmall`) and the effective
    /// snippet lines.
    static func rowHeight(
        _ row: RowDescriptor,
        density: HistoryRowDensity,
        fontSize: HistoryRowFontSize
    ) -> CGFloat {
        let slot = row.isImageRow
            ? PanelTheme.imageThumbnailHeight(for: density)
            : PanelTheme.thumbnailSize(for: density)
        var titleBlock = titleLineHeight(for: fontSize)
        if row.snippetLineCount > 0 {
            titleBlock += PanelTheme.spacingXXSmall
                + CGFloat(row.snippetLineCount) * snippetLineHeight(for: fontSize)
        }
        return max(slot, titleBlock)
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

    /// The content-fit floor: header + ONE text row + slack at the product
    /// default appearance (compact density, medium type). Empty content
    /// still fits at the floor; `PanelGeometry.minimumHeight` is this same
    /// value, so a user resize can never go below it either.
    static let minimumHeight: CGFloat =
        headerHeight
            + rowHeight(
                RowDescriptor(isImageRow: false, snippetLineCount: 0),
                density: .compact,
                fontSize: .medium
            )
            + bottomSlack

    /// The ideal content height for the displayed rows and chrome: header
    /// (+ filter chip when visible), the windowed-navigation bar when
    /// paging, one section header per rendered section (Pinned only when
    /// pinned rows display; Recent when unpinned rows or the pagination
    /// control display — the list's exact conditions), the rows, the
    /// trailing pagination control, the failure banner, and bottom slack.
    /// `prefersFullHeight` short-circuits all of it: a pushed
    /// Details/editor destination or the quick-look overlay demands the
    /// whole persisted ceiling (`fullHeightDemand`).
    static func idealHeight(_ input: Input) -> CGFloat {
        guard !input.prefersFullHeight else { return fullHeightDemand }
        var height = headerHeight + bottomSlack
        if input.isFilterChipVisible {
            height += filterChipDelta
        }
        if input.hasWindowedPages {
            height += windowedNavigationHeight
        }
        if !input.pinnedRows.isEmpty {
            height += sectionHeaderHeight
            height += input.pinnedRows.reduce(0) {
                $0 + rowHeight($1, density: input.density, fontSize: input.fontSize)
            }
        }
        if !input.unpinnedRows.isEmpty || input.showsPaginationControl {
            height += sectionHeaderHeight
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
        return height
    }

    /// The fit contract: the ideal height clamped to [floor, ceiling]. The
    /// ceiling is the persisted height (a MAXIMUM, never a fixed height);
    /// a ceiling below the floor (a defaults value predating the floor)
    /// still yields the floor.
    static func clampedHeight(_ ideal: CGFloat, ceiling: CGFloat) -> CGFloat {
        min(max(ideal, minimumHeight), max(ceiling, minimumHeight))
    }
}
