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

/// The drag-end verdict for the preview divider (V2-07 §3): settle at the
/// dragged width through the existing clamp/guard/persist chain, or
/// collapse the pane when the raw — or fling-predicted — proposed width
/// falls below `PanelGeometry.previewCollapseThreshold`.
package enum PreviewDragOutcome: Equatable {
    case settle
    case collapse
}

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
    /// frame and the AppKit `setFrame` width. Package (GOV-3): the AppKit
    /// frame math composes the persisted dimensions instead (`persistedSize`
    /// / `persistedPreviewColumnWidth`); only this module's content frame
    /// needs the default-width shortcut.
    package static func totalWidth(previewOpen: Bool) -> CGFloat {
        contentWidth + (previewOpen ? dividerWidth + previewWidth : 0)
    }

    // MARK: Preview column width

    /// The narrowest preview column the divider drag admits. Package
    /// (GOV-3): the bounds are divider-drag vocabulary; cross-module reads
    /// go through the clamped persisted helpers.
    package static let minimumPreviewColumnWidth: CGFloat = 240

    /// The widest preview column the divider drag admits. Package (GOV-3).
    package static let maximumPreviewColumnWidth: CGFloat = 480

    /// The UserDefaults key for the persisted preview column width.
    public static let previewColumnWidthDefaultsKey =
        "clipy.panel.previewColumnWidth"

    /// Clamps a requested preview column width into the draggable bounds.
    /// Package (GOV-3): the persisted helpers below are the seam; the raw
    /// clamp serves this module's divider drag and their internal chain.
    package static func clampedPreviewColumnWidth(_ width: CGFloat) -> CGFloat {
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

    // MARK: Preview divider interactions

    /// The raw (pre-clamp) proposed width below which a divider drag-end
    /// collapses the preview pane instead of settling (V2-07 §3
    /// drag-to-dismiss). Deliberately below `minimumPreviewColumnWidth`:
    /// the band between the two is the collapse affordance the live drag
    /// renders down to `previewDragVisualFloor`, and it never persists.
    package static let previewCollapseThreshold: CGFloat = 200

    /// The narrowest width the column renders mid-drag so the collapse
    /// affordance reads. Visual only: a settled width still clamps to
    /// `minimumPreviewColumnWidth`, and a drag ending below
    /// `previewCollapseThreshold` collapses rather than persisting.
    package static let previewDragVisualFloor: CGFloat = 160

    /// The soft stops a live divider drag snaps to within
    /// `previewSnapTolerance`; the default `previewWidth` (320) is one.
    package static let previewSnapStops: [CGFloat] = [280, 320, 400]

    /// The ± distance around a soft stop that snaps (V2-07 §3).
    package static let previewSnapTolerance: CGFloat = 8

    /// The closed-pane edge opener: an invisible strip this wide sits on
    /// the preview-side content edge (V2-07 §3).
    package static let previewEdgeOpenerWidth: CGFloat = 6

    /// The placement-signed inward pull distance that opens the closed
    /// preview from the edge strip; shorter pulls and outward drags are
    /// ignored so the strip never fires on a click or a brush.
    package static let previewEdgeOpenDistance: CGFloat = 48

    /// The raw width a divider drag proposes BEFORE any clamping: the
    /// start width plus the placement-signed translation (a trailing
    /// preview narrows as the pointer moves right, a leading preview
    /// widens — the same sign rule the live drag applies).
    package static func rawPreviewDragWidth(
        startWidth: CGFloat,
        translation: CGFloat,
        placement: PreviewPlacement
    ) -> CGFloat {
        startWidth + (placement == .trailing ? -translation : translation)
    }

    /// Drag-to-collapse (V2-07 §3): the raw end width OR the fling's raw
    /// predicted-end width below `previewCollapseThreshold` collapses the
    /// pane (the view routes the verdict through the manual-toggle close
    /// path); anything at or above the threshold settles through the
    /// existing clamp/guard/persist chain.
    package static func previewDragOutcome(
        startWidth: CGFloat,
        translation: CGFloat,
        predictedEndTranslation: CGFloat,
        placement: PreviewPlacement
    ) -> PreviewDragOutcome {
        let rawEnd = rawPreviewDragWidth(
            startWidth: startWidth,
            translation: translation,
            placement: placement
        )
        let rawPredictedEnd = rawPreviewDragWidth(
            startWidth: startWidth,
            translation: predictedEndTranslation,
            placement: placement
        )
        return rawEnd < previewCollapseThreshold
            || rawPredictedEnd < previewCollapseThreshold
            ? .collapse
            : .settle
    }

    /// The magnetic snap (V2-07 §3): a width within
    /// `previewSnapTolerance` of a soft stop lands on the stop. The live
    /// drag applies it after clamping and after the browsing-column guard
    /// and keeps the guarded width whenever the snap would exceed the
    /// guard's ceiling, so a snap can never squeeze the browsing column
    /// below `minimumContentWidth`.
    package static func snappedPreviewColumnWidth(
        _ width: CGFloat
    ) -> CGFloat {
        for stop in previewSnapStops
        where abs(width - stop) <= previewSnapTolerance {
            return stop
        }
        return width
    }

    /// Whether a closed-pane edge pull opens the preview: the
    /// placement-signed inward component of the drag's translation must
    /// reach `previewEdgeOpenDistance` (a trailing edge opens on a
    /// LEFTWARD pull, a leading edge on a rightward one).
    package static func previewEdgeDragOpens(
        translation: CGFloat,
        placement: PreviewPlacement
    ) -> Bool {
        let inward = placement == .trailing ? -translation : translation
        return inward >= previewEdgeOpenDistance
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
