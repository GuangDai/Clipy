/// PanelTheme.swift — the panel chrome's shared layout tokens (spacing
/// scale, corner radii, density-driven row metrics, header/footer/banner
/// chrome). This is the single source for panel chrome spacing so every
/// panel view stays consistent; it is a vocabulary of constants, not a
/// theming engine, and stays Foundation/CoreGraphics-only. Unlike the
/// public `PanelGeometry`, it is `package`-internal: only the SwiftPM
/// panel views (and their in-package tests) consume it — the AppKit
/// composition root in ClipyApp cannot see `package` symbols.
import CoreGraphics
import Foundation

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

    /// The snippet line limit for a row density. `comfortable` keeps
    /// today's two-line `HistoryRowView` snippet.
    package static func snippetLineLimit(
        for density: HistoryRowDensity
    ) -> Int {
        switch density {
        case .compact: return 1
        case .comfortable: return 2
        }
    }

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
