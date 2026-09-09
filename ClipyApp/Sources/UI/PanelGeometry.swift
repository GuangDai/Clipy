/// Shared dimensions for the app-owned panel and its SwiftUI columns.
/// Preferences retain usable finite sizes without an arbitrary maximum;
/// the current window and display provide transient fitting constraints.
import CoreGraphics
import Foundation

/// The drag-end verdict for the preview divider (V2-07 §3): settle at the
/// dragged width through the existing clamp/guard/persist chain, or
/// collapse the pane when the actual release's raw proposed width
/// falls below `PanelGeometry.previewCollapseThreshold`.
enum PreviewDragOutcome: Equatable {
    case settle
    case collapse
}

/// The panel's default dimensions (the pre-preview contract was a hard-coded
/// 360×420 frame on `HistoryPanelView`; the preview column adds
/// `dividerWidth` plus its persisted width — default `previewWidth` — on the
/// selected side when open). The browsing-column width and the height are
/// user-resizable within the bounds below; every consumer derives the live
/// size through the clamping helpers.
enum PanelGeometry {
    /// The browsing column (search header + list + footer) default width.
    static let contentWidth: CGFloat = 360

    /// The preview column's default width when the preview pane is open.
    /// The divider drags the column to any width within the preview bounds
    /// below; an unset persisted width falls back to this constant, so the
    /// default geometry reproduces the pinned 400+1+320 frame.
    static let previewWidth: CGFloat = 320

    /// The divider between the browsing and preview columns.
    static let dividerWidth: CGFloat = 1

    /// The default panel height (both columns).
    static let height: CGFloat = 420

    /// The total window width at the default content width for a given
    /// preview visibility — the single source of truth for both the SwiftUI
    /// frame and the AppKit `setFrame` width. Package (GOV-3): the AppKit
    /// frame math composes the persisted dimensions instead (`persistedSize`
    /// / `persistedPreviewColumnWidth`); only this module's content frame
    /// needs the default-width shortcut.
    static func totalWidth(previewOpen: Bool) -> CGFloat {
        contentWidth + (previewOpen ? dividerWidth + previewWidth : 0)
    }

    // MARK: Preview column width

    /// The narrowest preview column the divider drag admits. Package
    /// (GOV-3): the bounds are divider-drag vocabulary; cross-module reads
    /// go through the clamped persisted helpers.
    static let minimumPreviewColumnWidth: CGFloat = 240

    /// The UserDefaults key for the persisted preview column width.
    static let previewColumnWidthDefaultsKey =
        "clipy.panel.previewColumnWidth"

    /// Clamps a requested preview column width into the draggable bounds.
    /// Package (GOV-3): the persisted helpers below are the seam; the raw
    /// clamp serves this module's divider drag and their internal chain.
    static func clampedPreviewColumnWidth(_ width: CGFloat) -> CGFloat {
        width.isFinite ? max(width, minimumPreviewColumnWidth) : previewWidth
    }

    /// A display constraint never overwrites the user's preferred divider
    /// width. The current window supplies the space left after the list.
    static func fittedPreviewColumnWidth(preferred: CGFloat, inPanelWidth width: CGFloat) -> CGFloat {
        min(clampedPreviewColumnWidth(preferred), max(0, width - minimumContentWidth - dividerWidth))
    }

    /// The persisted preview column width, clamped into the draggable
    /// bounds. Same fail-open rule as `persistedSize(from:)`: an absent or
    /// invalid key falls back to the default `previewWidth`, so a damaged
    /// defaults entry can never produce a width the two sides disagree on.
    static func persistedPreviewColumnWidth(
        from defaults: UserDefaults
    ) -> CGFloat {
        persistedDimension(
            forKey: previewColumnWidthDefaultsKey,
            in: defaults,
            fallback: previewWidth,
            minimum: minimumPreviewColumnWidth
        )
    }

    /// Persists the preview column width already clamped, so the stored
    /// value is always one `persistedPreviewColumnWidth(from:)` would
    /// return unchanged.
    static func persistPreviewColumnWidth(
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
    static let previewCollapseThreshold: CGFloat = 200

    /// The narrowest width the column renders mid-drag so the collapse
    /// affordance reads. Visual only: a settled width still clamps to
    /// `minimumPreviewColumnWidth`, and a drag ending below
    /// `previewCollapseThreshold` collapses rather than persisting.
    static let previewDragVisualFloor: CGFloat = 160

    /// The soft stops a live divider drag snaps to within
    /// `previewSnapTolerance`; the default `previewWidth` (320) is one.
    static let previewSnapStops: [CGFloat] = [280, 320, 400]

    /// The ± distance around a soft stop that snaps (V2-07 §3).
    static let previewSnapTolerance: CGFloat = 8

    /// The closed-pane edge opener: an invisible strip this wide sits on
    /// the preview-side content edge (V2-07 §3).
    static let previewEdgeOpenerWidth: CGFloat = 6

    /// The edge opener's inset from the window's content edge. A
    /// `.resizable` AppKit window keeps an edge live-resize track a few
    /// points wide that consumes presses before SwiftUI sees them, so a
    /// strip flush with the window edge is unreachable: an inward pull
    /// there resizes the window instead of opening the preview. Insetting
    /// by the same order as the strip width clears that track.
    static let previewEdgeOpenerInset: CGFloat = 6

    /// The placement-signed inward pull distance that opens the closed
    /// preview from the edge strip; shorter pulls and outward drags are
    /// ignored so the strip never fires on a click or a brush.
    static let previewEdgeOpenDistance: CGFloat = 48

    /// The raw width a divider drag proposes BEFORE any clamping: the
    /// start width plus the placement-signed translation (a trailing
    /// preview narrows as the pointer moves right, a leading preview
    /// widens — the same sign rule the live drag applies).
    static func rawPreviewDragWidth(
        startWidth: CGFloat,
        translation: CGFloat,
        placement: PreviewPlacement
    ) -> CGFloat {
        startWidth + (placement == .trailing ? -translation : translation)
    }

    /// Drag-to-collapse: only the actual release width below
    /// `previewCollapseThreshold` closes the pane. A divider is a positioning
    /// control, so velocity prediction does not override where it was left.
    /// At or above the threshold, use the existing clamp/guard/persist chain.
    static func previewDragOutcome(
        startWidth: CGFloat,
        translation: CGFloat,
        placement: PreviewPlacement
    ) -> PreviewDragOutcome {
        let rawEnd = rawPreviewDragWidth(
            startWidth: startWidth,
            translation: translation,
            placement: placement
        )
        return rawEnd < previewCollapseThreshold
            ? .collapse
            : .settle
    }

    /// The magnetic snap (V2-07 §3): a width within
    /// `previewSnapTolerance` of a soft stop lands on the stop. The live
    /// drag applies it after clamping and after the browsing-column guard
    /// and keeps the guarded width whenever the snap would exceed the
    /// guard's ceiling, so a snap can never squeeze the browsing column
    /// below `minimumContentWidth`.
    static func snappedPreviewColumnWidth(
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
    static func previewEdgeDragOpens(
        translation: CGFloat,
        placement: PreviewPlacement
    ) -> Bool {
        let inward = placement == .trailing ? -translation : translation
        return inward >= previewEdgeOpenDistance
    }

    // MARK: User resizing

    /// The narrowest browsing column the user can resize to.
    static let minimumContentWidth: CGFloat = 360

    /// The shortest panel height the user can resize to.
    static let minimumHeight: CGFloat = 420

    /// The UserDefaults key for the persisted browsing-column width.
    static let panelContentWidthDefaultsKey = "clipy.panelContentWidth"

    /// The UserDefaults key for the persisted panel height.
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
