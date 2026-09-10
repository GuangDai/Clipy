/// Shared typography and spacing for the app's compact clipboard surfaces.
/// System text styles preserve platform sizing and appearance; actual content
/// and the window proposal determine layout, without width-based mode switches.
import CoreGraphics
import Foundation
import SwiftUI

enum PanelTheme {
    // MARK: Spacing scale

    static let spacingXXXSmall: CGFloat = 2
    static let spacingXXSmall: CGFloat = 4
    static let spacingXSmall: CGFloat = 6
    static let spacingSmall: CGFloat = 8
    static let spacingMedium: CGFloat = 10
    static let spacingLarge: CGFloat = 12
    static let spacingXLarge: CGFloat = 16

    // MARK: Corner radii

    static let cornerRadiusSmall: CGFloat = 6
    static let cornerRadiusMedium: CGFloat = 8
    static let cornerRadiusLarge: CGFloat = 10

    // MARK: Density-driven row metrics

    static func thumbnailSize(
        for density: HistoryRowDensity
    ) -> CGFloat {
        switch density {
        case .compact: return 20
        case .comfortable: return 28
        }
    }

    /// Generous fixed content height for an image row's aspect-fit
    /// thumbnail slot. Text and type rows keep the compact
    /// `thumbnailSize(for:)` slot above; only image rows grow.
    static func imageThumbnailHeight(
        for density: HistoryRowDensity
    ) -> CGFloat {
        switch density {
        case .compact: return 44
        case .comfortable: return 56
        }
    }

    static func rowVerticalPadding(
        for density: HistoryRowDensity
    ) -> CGFloat {
        switch density {
        case .compact: return 2
        case .comfortable: return 4
        }
    }

    // MARK: Row typography (HistoryRowFontSize)

    static func titleFont(for size: HistoryRowFontSize) -> Font {
        switch size {
        case .small: return .callout
        case .medium: return .body
        case .large: return .title3
        }
    }

    static func snippetFont(for size: HistoryRowFontSize) -> Font {
        switch size {
        case .small: return .footnote
        case .medium: return .subheadline
        case .large: return .callout
        }
    }

    static func timestampFont(for size: HistoryRowFontSize) -> Font {
        switch size {
        case .small: return .caption2
        case .medium: return .caption
        case .large: return .footnote
        }
    }

    static func metadataFont(for size: HistoryRowFontSize) -> Font {
        switch size {
        case .small: return .caption2
        case .medium: return .caption
        case .large: return .caption
        }
    }

    // The pin badge (8pt bold capsule) and the type-symbol fallback (15pt)
    // keep their fixed sizes: they scale with the density-owned thumbnail
    // slot, not with the row's text settings.

    // MARK: Header, footer, and banner chrome

    static let headerHorizontalPadding: CGFloat = 12
    static let headerTopPadding: CGFloat = 8
    static let headerBottomPadding: CGFloat = 6
    static let footerHorizontalPadding: CGFloat = 12
    static let footerVerticalPadding: CGFloat = 8
    static let footerSpacing: CGFloat = 8
    static let bannerHorizontalPadding: CGFloat = 12
    static let bannerVerticalPadding: CGFloat = 8
}
