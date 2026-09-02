/// PanelTheme.swift — the panel chrome's shared layout tokens (spacing
/// scale, corner radii, density-driven row metrics, row typography, and
/// header/footer/banner chrome) plus `HistoryRowLayout`'s pure
/// wide-presentation rules. This is the single source for panel chrome
/// spacing so every panel view stays consistent; it is a vocabulary of
/// constants, not a theming engine. The row-typography mappings return
/// SwiftUI `Font` values, so the file imports SwiftUI alongside
/// Foundation/CoreGraphics — never AppKit. Unlike the public
/// `PanelGeometry`, it is `package`-internal: only the SwiftPM
/// panel views (and their in-package tests) consume it — the AppKit
/// composition root in ClipyApp cannot see `package` symbols.
import CoreGraphics
import Foundation
import SwiftUI

package enum PanelTheme {
    // MARK: Spacing scale

    package static let spacingXXXSmall: CGFloat = 2
    package static let spacingXXSmall: CGFloat = 4
    package static let spacingXSmall: CGFloat = 6
    package static let spacingSmall: CGFloat = 8
    package static let spacingMedium: CGFloat = 10
    package static let spacingLarge: CGFloat = 12
    package static let spacingXLarge: CGFloat = 16

    // MARK: Corner radii

    package static let cornerRadiusSmall: CGFloat = 6
    package static let cornerRadiusMedium: CGFloat = 8
    package static let cornerRadiusLarge: CGFloat = 10

    // MARK: Density-driven row metrics

    /// The leading thumbnail slot edge for a row density. `comfortable`
    /// keeps today's 36pt `HistoryRowView` slot, so adopting the token is
    /// visually neutral.
    package static func thumbnailSize(
        for density: HistoryRowDensity
    ) -> CGFloat {
        switch density {
        case .compact: return 28
        case .comfortable: return 36
        }
    }

    /// The vertical row padding for a row density. `comfortable` keeps
    /// today's 4pt `HistoryRowView` padding.
    package static func rowVerticalPadding(
        for density: HistoryRowDensity
    ) -> CGFloat {
        switch density {
        case .compact: return 2
        case .comfortable: return 4
        }
    }

    // MARK: Row typography (HistoryRowFontSize)

    /// The row title font for a typography size. `medium` reproduces the
    /// shipped `.headline` exactly; `small`/`large` step one text-style
    /// rung down/up.
    package static func titleFont(for size: HistoryRowFontSize) -> Font {
        switch size {
        case .small: return .subheadline
        case .medium: return .headline
        case .large: return .title3
        }
    }

    /// The search-snippet font for a typography size. `medium` reproduces
    /// the shipped `.subheadline` exactly.
    package static func snippetFont(for size: HistoryRowFontSize) -> Font {
        switch size {
        case .small: return .footnote
        case .medium: return .subheadline
        case .large: return .callout
        }
    }

    /// The trailing-timestamp font for a typography size. `medium`
    /// reproduces the shipped `.caption` exactly.
    package static func timestampFont(for size: HistoryRowFontSize) -> Font {
        switch size {
        case .small: return .caption2
        case .medium: return .caption
        case .large: return .footnote
        }
    }

    /// The secondary-metadata font (source name, copy count) for a
    /// typography size. `medium` reproduces the shipped `.caption2`
    /// exactly; `.caption2` is the text-style ladder's floor, so `small`
    /// holds there.
    package static func metadataFont(for size: HistoryRowFontSize) -> Font {
        switch size {
        case .small: return .caption2
        case .medium: return .caption2
        case .large: return .caption
        }
    }

    // The pin badge (8pt bold capsule) and the type-symbol fallback (15pt)
    // keep their fixed sizes: they scale with the density-owned thumbnail
    // slot, not with the row's text settings.

    // MARK: Header, footer, and banner chrome

    // Every value below matches the literal today's `HistoryPanelView`
    // already uses, so adopting the tokens is visually neutral.

    package static let headerHorizontalPadding: CGFloat = 12
    package static let headerTopPadding: CGFloat = 10
    package static let headerBottomPadding: CGFloat = 6
    package static let footerHorizontalPadding: CGFloat = 12
    package static let footerVerticalPadding: CGFloat = 8
    package static let footerSpacing: CGFloat = 8
    package static let bannerHorizontalPadding: CGFloat = 12
    package static let bannerVerticalPadding: CGFloat = 8
}

/// Pure row-layout rules for the browsing column's wide presentation.
/// The list measures its width once (`HistoryListView`'s single
/// `onGeometryChange`) and hands every row the resulting boolean; the
/// threshold decision itself lives here so it is unit-testable without
/// hosting a view.
package enum HistoryRowLayout {
    /// The browsing-column width at and above which rows breathe: the
    /// trailing timestamp switches from relative to the absolute time of
    /// day, the snippet gains one line above the configured base (hard cap
    /// 3), and the source line carries the full bundle identifier. 560 sits
    /// inside `PanelGeometry`'s 360–720 content-width range, so the user
    /// resize owns the crossing.
    package static let widePresentationMinimumWidth: CGFloat = 560

    /// Inclusive threshold: exactly 560pt is already wide.
    package static func usesWidePresentation(width: CGFloat) -> Bool {
        width >= widePresentationMinimumWidth
    }

    /// The effective summary/snippet line count: the base is the setting
    /// resolved against the row density (`.automatic` reproduces the
    /// shipped density mapping); wide presentation adds one line up to a
    /// hard cap of three. Automatic+comfortable therefore renders the
    /// spec'd narrow-2/wide-3 and automatic+compact the shipped
    /// narrow-1/wide-2; an explicit setting overrides density entirely, so
    /// a user-chosen `.one` is never overridden to three.
    package static func effectiveSnippetLineLimit(
        setting: HistorySnippetLineCount,
        density: HistoryRowDensity,
        isWide: Bool
    ) -> Int {
        let base = setting.baseLineLimit(density: density)
        return isWide ? min(base + 1, 3) : base
    }
}
