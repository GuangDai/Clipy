/// PopupPositionGeometry.swift — the panel placement math (Maccy's
/// `PopupPosition.origin(size:statusBarButton:)` + `NSScreen+ForPopup`
/// replicated), written as a pure function over explicit inputs so the
/// geometry is testable headlessly without an `NSScreen`/`NSStatusItem`.
/// The AppKit-side callers (AppDelegate/FloatingPanel) gather the inputs;
/// the mode value itself comes from PresentationUI's `PopupPositionMode`.
import AppKit
import Foundation

/// Pure panel-origin geometry for `PopupPositionMode` (Maccy
/// `PopupPosition.origin` semantics, plus a uniform visible-frame clamp so
/// no mode can spill the panel off the active screen).
enum PopupPositionGeometry {

    /// Opens a preview within existing window space before growing toward
    /// the preferred side. Compact windows retain their list width; wider
    /// windows lend surplus space above the default comfortable list width.
    /// Screen fitting is transient and never changes persisted preferences.
    static func openingPreviewFrame(
        from mainSurfaceFrame: NSRect,
        in screenVisibleFrame: NSRect?,
        previewSide: PreviewSidePreference = .automatic,
        previewColumnWidth: CGFloat = PanelGeometry.previewWidth
    ) -> (panelFrame: NSRect, placement: PreviewPlacement) {
        // Use a wide window's existing space first. A compact window grows
        // only enough to keep a comfortable list beside the preferred pane.
        let paneWidth = PanelGeometry.dividerWidth + PanelGeometry.clampedPreviewColumnWidth(previewColumnWidth)
        let fitsExistingWidth = mainSurfaceFrame.width >= PanelGeometry.minimumContentWidth + paneWidth
        let desiredWidth = fitsExistingWidth ? mainSurfaceFrame.width
            : min(mainSurfaceFrame.width, PanelGeometry.contentWidth) + paneWidth
        let fittedWidth = min(desiredWidth, screenVisibleFrame?.width ?? desiredWidth)
        let previewExtension = max(0, fittedWidth - mainSurfaceFrame.width)
        var expandedFrame = mainSurfaceFrame
        expandedFrame.size.width = fittedWidth

        let trailingFits: Bool
        let leadingFits: Bool
        if let screenVisibleFrame {
            trailingFits = expandedFrame.maxX <= screenVisibleFrame.maxX
            leadingFits = mainSurfaceFrame.minX - previewExtension
                >= screenVisibleFrame.minX
        } else {
            trailingFits = true
            leadingFits = true
        }

        let placement: PreviewPlacement
        switch previewSide {
        case .automatic, .trailing:
            placement = trailingFits ? .trailing : .leading
        case .leading:
            placement = leadingFits ? .leading : .trailing
        }

        if placement == .leading {
            expandedFrame.origin.x -= previewExtension
        }
        if let screenVisibleFrame {
            expandedFrame.origin = clamped(expandedFrame.origin, size: expandedFrame.size, into: screenVisibleFrame)
        }
        return (expandedFrame, placement)
    }

    /// Resolves the stable history column's real screen frame from the panel
    /// frame and the same placement value used by HistoryPanelView.
    static func mainSurfaceFrame(
        in panelFrame: NSRect,
        previewPlacement: PreviewPlacement,
        previewVisible: Bool,
        mainSurfaceWidth: CGFloat = PanelGeometry.contentWidth
    ) -> NSRect {
        let leadingWidth = previewVisible && previewPlacement == .leading
            ? panelFrame.width - mainSurfaceWidth
            : 0
        return NSRect(
            x: panelFrame.minX + leadingWidth,
            y: panelFrame.minY,
            width: mainSurfaceWidth,
            height: panelFrame.height
        )
    }

    /// Computes the panel's top-left screen-space origin (AppKit window
    /// origins are bottom-left of the window; every mode below returns the
    /// BOTTOM-left origin ready for `setFrameOrigin`).
    ///
    /// - Parameters:
    ///   - mode: the placement mode (status-item clicks pass `.statusItem`
    ///     directly, like Maccy's `performStatusItemClick`).
    ///   - panelSize: the panel's full size (preview column included when
    ///     open).
    ///   - statusItemButtonScreenFrame: the status-item button's frame in
    ///     screen coordinates; `nil` when unavailable (falls back to
    ///     `.cursor`, Maccy's behavior).
    ///   - mouseLocation: `NSEvent.mouseLocation` at summon time.
    ///   - screens: each screen's full frame and current safe drawing frame.
    ///     Menu-bar and Dock points belong to the full frame, even though the
    ///     resulting panel must fit within that screen's visible frame.
    ///   - lastPositionAnchor: the persisted normalized anchor (top-middle
    ///     of the stable main surface within its screen's visible frame) for
    ///     `.lastPosition`; `nil` falls back to `.cursor`.
    static func origin(
        for mode: PopupPositionMode,
        panelSize: NSSize,
        statusItemButtonScreenFrame: NSRect?,
        mouseLocation: NSPoint,
        screens: [(frame: NSRect, visibleFrame: NSRect)],
        lastPositionAnchor: NSPoint?
    ) -> NSPoint {
        let targetFrame = targetVisibleFrame(
            for: mode, statusItemButtonScreenFrame: statusItemButtonScreenFrame,
            mouseLocation: mouseLocation, screens: screens
        ) ?? .zero

        switch mode {
        case .statusItem:
            guard let buttonFrame = statusItemButtonScreenFrame else {
                return cursorOrigin(panelSize: panelSize, mouseLocation: mouseLocation, frame: targetFrame)
            }
            // Under the button's left edge, hanging below the menu bar —
            // Maccy's `screenRect.minY - size.height` (Maccy clamps the
            // right edge; the shared clamp covers it).
            let raw = NSPoint(x: buttonFrame.minX, y: buttonFrame.minY - panelSize.height)
            return clamped(raw, size: panelSize, into: targetFrame)

        case .center:
            let raw = NSPoint(
                x: targetFrame.minX + (targetFrame.width - panelSize.width) / 2,
                y: targetFrame.minY + (targetFrame.height - panelSize.height) / 2
            )
            return clamped(raw, size: panelSize, into: targetFrame)

        case .lastPosition:
            guard let anchor = lastPositionAnchor else {
                return cursorOrigin(panelSize: panelSize, mouseLocation: mouseLocation, frame: targetFrame)
            }
            // The anchor is the stable main surface's TOP-MIDDLE point. A
            // main-only reopen makes that surface identical to the panel.
            let raw = NSPoint(
                x: targetFrame.minX + targetFrame.width * anchor.x - panelSize.width / 2,
                y: targetFrame.minY + targetFrame.height * anchor.y - panelSize.height
            )
            return clamped(raw, size: panelSize, into: targetFrame)

        case .cursor:
            return cursorOrigin(panelSize: panelSize, mouseLocation: mouseLocation, frame: targetFrame)
        }
    }

    /// AppKit excludes menu bars and the Dock from visibleFrame. Use full
    /// screen bounds to choose the display, then share its safe drawing area
    /// between origin placement and FloatingPanel's shrink-to-fit size.
    static func targetVisibleFrame(
        for mode: PopupPositionMode,
        statusItemButtonScreenFrame: NSRect?,
        mouseLocation: NSPoint,
        screens: [(frame: NSRect, visibleFrame: NSRect)]
    ) -> NSRect? {
        if mode == .statusItem, let button = statusItemButtonScreenFrame,
           let screen = screens.first(where: {
               $0.frame.contains(NSPoint(x: button.midX, y: button.midY))
           }) {
            return screen.visibleFrame
        }
        return screens.first(where: { $0.frame.contains(mouseLocation) })?.visibleFrame
            ?? screens.first?.visibleFrame
    }

    /// The `.cursor` origin shared by the fallbacks: top edge at the
    /// pointer, hanging downward (Maccy's `point.y -= size.height`).
    private static func cursorOrigin(
        panelSize: NSSize,
        mouseLocation: NSPoint,
        frame: NSRect
    ) -> NSPoint {
        let raw = NSPoint(x: mouseLocation.x, y: mouseLocation.y - panelSize.height)
        return clamped(raw, size: panelSize, into: frame)
    }

    /// The normalized (0…1) anchor persisted for `.lastPosition` — the
    /// stable main surface's top-middle point within its screen's visible
    /// frame (`mainSurfaceWidth` carries the live, possibly user-resized
    /// browsing-column width). The expanded window may shift at a screen
    /// edge, but transient preview width must not move a later main-only
    /// reopen (review Card 9F).
    static func normalizedAnchor(
        forPanelFrame panelFrame: NSRect,
        previewPlacement: PreviewPlacement,
        previewVisible: Bool,
        mainSurfaceWidth: CGFloat,
        in screenVisibleFrame: NSRect
    ) -> NSPoint {
        guard screenVisibleFrame.width > 0, screenVisibleFrame.height > 0 else {
            return NSPoint(x: 0.5, y: 1)
        }
        let mainSurface = mainSurfaceFrame(
            in: panelFrame,
            previewPlacement: previewPlacement,
            previewVisible: previewVisible,
            mainSurfaceWidth: mainSurfaceWidth
        )
        return NSPoint(
            x: (mainSurface.midX - screenVisibleFrame.minX)
                / screenVisibleFrame.width,
            y: (panelFrame.maxY - screenVisibleFrame.minY) / screenVisibleFrame.height
        )
    }

    /// Clamps the origin so the panel stays fully inside the frame; a panel
    /// larger than the frame pins to the frame's bottom-left.
    private static func clamped(_ origin: NSPoint, size: NSSize, into frame: NSRect) -> NSPoint {
        guard size.width <= frame.width, size.height <= frame.height else {
            return NSPoint(x: frame.minX, y: frame.minY)
        }
        return NSPoint(
            x: min(max(origin.x, frame.minX), frame.maxX - size.width),
            y: min(max(origin.y, frame.minY), frame.maxY - size.height)
        )
    }
}
