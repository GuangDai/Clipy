/// Shared dimensions for the app-owned panel and its SwiftUI content.
/// Preferences retain usable finite sizes without an arbitrary maximum;
/// the current window and display provide transient fitting constraints.
/// The persisted height is the content-fit CEILING, not a fixed height:
/// while the panel is open, `FloatingPanel.fitToContent` shrinks it to the
/// analytic ideal (`PanelContentFit`) down to the floor and back up to the
/// persisted value.
import CoreGraphics
import Foundation

/// The panel's default dimensions (a hard-coded 360×420 default frame is
/// the browsing-surface contract; the floating preview lives in its own
/// `FloatingPreviewPanel` window beside the panel and never changes this
/// geometry). The browsing width and the height are user-resizable within
/// the bounds below; every consumer derives the live size through the
/// clamping helpers.
enum PanelGeometry {
    /// The browsing column (search header + list + footer) default width.
    static let contentWidth: CGFloat = 360

    /// The default panel height — the default content-fit ceiling.
    static let height: CGFloat = 420

    // MARK: Floating preview

    /// The floating preview panel's fixed width (the redesign's transient
    /// side pane; it never resizes the main panel).
    static let floatingPreviewWidth: CGFloat = 340

    /// File actions, PDF paging and recovery need a usable viewport even
    /// when a single history row shrinks the browsing panel to 111pt.
    static let floatingPreviewMinimumHeight: CGFloat = 420

    /// The gap between the main panel and the floating preview pane.
    static let floatingPreviewGap: CGFloat = 8

    // MARK: User resizing

    /// The narrowest browsing column the user can resize to.
    static let minimumContentWidth: CGFloat = 360

    /// The shortest panel height the user can resize to — the content-fit
    /// floor (header + one text row + slack), shared with the oracle so a
    /// live resize and an auto-fit agree on the same minimum.
    static let minimumHeight: CGFloat = PanelContentFit.minimumHeight

    /// The UserDefaults key for the persisted browsing-column width.
    static let panelContentWidthDefaultsKey = "clipy.panelContentWidth"

    /// The UserDefaults key for the persisted panel height ceiling.
    static let panelHeightDefaultsKey = "clipy.panelHeight"

    /// Clamps a requested browsing-column width into the resizable bounds.
    static func clampedContentWidth(_ width: CGFloat) -> CGFloat {
        width.isFinite ? max(width, minimumContentWidth) : contentWidth
    }

    /// Clamps a requested panel height into the resizable bounds.
    static func clampedHeight(_ height: CGFloat) -> CGFloat {
        height.isFinite ? max(height, minimumHeight) : Self.height
    }

    /// The persisted panel size, clamped into the resizable bounds. An
    /// absent or invalid (non-numeric or non-finite) key falls back to that
    /// dimension's default, so a damaged defaults entry can never produce a
    /// frame the two sides disagree on.
    static func persistedSize(
        from defaults: UserDefaults
    ) -> (contentWidth: CGFloat, height: CGFloat) {
        (
            contentWidth: persistedDimension(
                forKey: panelContentWidthDefaultsKey,
                in: defaults,
                fallback: contentWidth,
                minimum: minimumContentWidth
            ),
            height: persistedDimension(
                forKey: panelHeightDefaultsKey,
                in: defaults,
                fallback: height,
                minimum: minimumHeight
            )
        )
    }

    /// Persists the panel size already clamped, so the stored value is
    /// always one `persistedSize(from:)` would return unchanged.
    static func persistSize(
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
        minimum: CGFloat
    ) -> CGFloat {
        guard let number = defaults.object(forKey: key) as? NSNumber,
              number.doubleValue.isFinite
        else { return fallback }
        return max(CGFloat(number.doubleValue), minimum)
    }
}
