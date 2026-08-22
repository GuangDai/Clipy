/// PanelGeometry.swift — the panel's fixed geometry vocabulary, shared by
/// PresentationUI (the SwiftUI content frames) and the ClipyApp composition
/// root (the AppKit panel's `setFrame` calls) so the two sides can never
/// disagree about how wide the window is (Maccy's `Defaults[.windowSize]` /
/// `SlideoutController.computeSizeWithPreview` pair, simplified: Clipy's
/// panel is fixed-size, and the preview column extends it by a constant on
/// the side selected by `PreviewPlacement`).
import CoreGraphics
import Foundation

/// The panel's fixed dimensions (the pre-preview contract was a hard-coded
/// 400×560 frame on `HistoryPanelView`; the preview column adds
/// `dividerWidth + previewWidth` on the selected side when open).
public enum PanelGeometry {
    /// The browsing column (search header + list + footer) width.
    public static let contentWidth: CGFloat = 400

    /// The preview column width when the preview pane is open.
    public static let previewWidth: CGFloat = 320

    /// The divider between the browsing and preview columns.
    public static let dividerWidth: CGFloat = 1

    /// The panel height (both columns).
    public static let height: CGFloat = 560

    /// The total window width for a given preview visibility — the single
    /// source of truth for both the SwiftUI frame and the AppKit
    /// `setFrame` width.
    public static func totalWidth(previewOpen: Bool) -> CGFloat {
        contentWidth + (previewOpen ? dividerWidth + previewWidth : 0)
    }
}
