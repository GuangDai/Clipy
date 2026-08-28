/// PanelGeometry.swift — the panel's geometry vocabulary, shared by
/// PresentationUI (the SwiftUI content frames) and the ClipyApp composition
/// root (the AppKit panel's `setFrame` calls) so the two sides can never
/// disagree about how wide the window is (Maccy's `Defaults[.windowSize]` /
/// `SlideoutController.computeSizeWithPreview` pair, simplified: Clipy's
/// panel starts at a fixed default size, and the preview column extends it
/// by its free-form persisted width (default 320) on the side selected by
/// `PreviewPlacement`).
///
/// The dimension constants below are the DEFAULT size: the panel is
/// user-resizable within the minimum/maximum bounds, persisted under the
/// `clipy.panel*` UserDefaults keys. Both sides — the AppKit frame math and
/// the SwiftUI frames — must derive the live size through the clamping and
/// persistence helpers here so they can never disagree.
import CoreGraphics
import Foundation

/// The panel's default dimensions (the pre-preview contract was a hard-coded
/// 400×560 frame on `HistoryPanelView`; the preview column adds
/// `dividerWidth` plus its persisted width — default `previewWidth` — on the
/// selected side when open). The browsing-column width and the height are
/// user-resizable within the bounds below; every consumer derives the live
/// size through the clamping helpers.
public enum PanelGeometry {
    /// The browsing column (search header + list + footer) default width.
    public static let contentWidth: CGFloat = 400

    /// The preview column's default width when the preview pane is open.
    /// The divider drags the column to any width within the preview bounds
    /// below; an unset persisted width falls back to this constant, so the
    /// default geometry reproduces the pinned 400+1+320 frame.
    public static let previewWidth: CGFloat = 320

    /// The divider between the browsing and preview columns.
    public static let dividerWidth: CGFloat = 1

    /// The default panel height (both columns).
    public static let height: CGFloat = 560

    /// The total window width at the default content width for a given
    /// preview visibility — the single source of truth for both the SwiftUI
    /// frame and the AppKit `setFrame` width.
    public static func totalWidth(previewOpen: Bool) -> CGFloat {
        contentWidth + (previewOpen ? dividerWidth + previewWidth : 0)
    }

    // MARK: Preview column width

    /// The narrowest preview column the divider drag admits.
    public static let minimumPreviewColumnWidth: CGFloat = 240

    /// The widest preview column the divider drag admits.
    public static let maximumPreviewColumnWidth: CGFloat = 480

    /// The UserDefaults key for the persisted preview column width.
    public static let previewColumnWidthDefaultsKey =
        "clipy.panel.previewColumnWidth"

    /// Clamps a requested preview column width into the draggable bounds.
    public static func clampedPreviewColumnWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumPreviewColumnWidth), maximumPreviewColumnWidth)
    }

    /// The persisted preview column width, clamped into the draggable
    /// bounds. Same fail-open rule as `persistedSize(from:)`: an absent or
    /// invalid key falls back to the default `previewWidth`, so a damaged
    /// defaults entry can never produce a width the two sides disagree on.
    public static func persistedPreviewColumnWidth(
        from defaults: UserDefaults
    ) -> CGFloat {
        persistedDimension(
            forKey: previewColumnWidthDefaultsKey,
            in: defaults,
            fallback: previewWidth,
            minimum: minimumPreviewColumnWidth,
            maximum: maximumPreviewColumnWidth
        )
    }

    /// Persists the preview column width already clamped, so the stored
    /// value is always one `persistedPreviewColumnWidth(from:)` would
    /// return unchanged.
    public static func persistPreviewColumnWidth(
        _ width: CGFloat,
        to defaults: UserDefaults
    ) {
        defaults.set(
            Double(clampedPreviewColumnWidth(width)),
            forKey: previewColumnWidthDefaultsKey
        )
    }

    // MARK: User resizing

    /// The narrowest browsing column the user can resize to.
    public static let minimumContentWidth: CGFloat = 360

    /// The widest browsing column the user can resize to.
    public static let maximumContentWidth: CGFloat = 720

    /// The shortest panel height the user can resize to.
    public static let minimumHeight: CGFloat = 420

    /// The tallest panel height the user can resize to.
    public static let maximumHeight: CGFloat = 1_000

    /// The UserDefaults key for the persisted browsing-column width.
    public static let panelContentWidthDefaultsKey = "clipy.panelContentWidth"

    /// The UserDefaults key for the persisted panel height.
    public static let panelHeightDefaultsKey = "clipy.panelHeight"

    /// Clamps a requested browsing-column width into the resizable bounds.
    public static func clampedContentWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumContentWidth), maximumContentWidth)
    }

    /// Clamps a requested panel height into the resizable bounds.
    public static func clampedHeight(_ height: CGFloat) -> CGFloat {
        min(max(height, minimumHeight), maximumHeight)
    }

    /// The persisted panel size, clamped into the resizable bounds. An
    /// absent or invalid (non-numeric or non-finite) key falls back to that
    /// dimension's default, so a damaged defaults entry can never produce a
    /// frame the two sides disagree on.
    public static func persistedSize(
        from defaults: UserDefaults
    ) -> (contentWidth: CGFloat, height: CGFloat) {
        (
            contentWidth: persistedDimension(
                forKey: panelContentWidthDefaultsKey,
                in: defaults,
                fallback: contentWidth,
                minimum: minimumContentWidth,
                maximum: maximumContentWidth
            ),
            height: persistedDimension(
                forKey: panelHeightDefaultsKey,
                in: defaults,
                fallback: height,
                minimum: minimumHeight,
                maximum: maximumHeight
            )
        )
    }

    /// Persists the panel size already clamped, so the stored value is
    /// always one `persistedSize(from:)` would return unchanged.
    public static func persistSize(
        contentWidth: CGFloat,
        height: CGFloat,
        to defaults: UserDefaults
    ) {
        defaults.set(
            Double(clampedContentWidth(contentWidth)),
            forKey: panelContentWidthDefaultsKey
        )
        defaults.set(
            Double(clampedHeight(height)),
            forKey: panelHeightDefaultsKey
        )
    }

    /// One persisted dimension: only a finite number counts. A missing key
    /// or a wrong-typed/non-finite value reads as the default, never as the
    /// 0 `double(forKey:)` would report for an absent key.
    private static func persistedDimension(
        forKey key: String,
        in defaults: UserDefaults,
        fallback: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        guard let number = defaults.object(forKey: key) as? NSNumber,
              number.doubleValue.isFinite
        else { return fallback }
        return min(max(CGFloat(number.doubleValue), minimum), maximum)
    }
}
