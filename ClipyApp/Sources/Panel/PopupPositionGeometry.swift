/// PopupPositionGeometry.swift — the panel placement math (Maccy's
/// `PopupPosition.origin(size:statusBarButton:)` + `NSScreen+ForPopup`
/// replicated), written as a pure function over explicit inputs so the
/// geometry is testable headlessly without an `NSScreen`/`NSStatusItem`.
/// The AppKit-side callers (AppDelegate/FloatingPanel) gather the inputs;
/// the mode value itself comes from PresentationUI's `PopupPositionMode`.
import AppKit
import Foundation
import PresentationUI

/// Pure panel-origin geometry for `PopupPositionMode` (Maccy
/// `PopupPosition.origin` semantics, plus a uniform visible-frame clamp so
/// no mode can spill the panel off the active screen).
enum PopupPositionGeometry {

    /// Expands around the stable main surface. Prefer the trailing side;
    /// when that would cross the current screen's right edge, put the preview
    /// on the leading side. Without a screen, trailing is the conservative
    /// layout because it does not move the window origin.
    static func expandedPreviewFrame(
        preservingMainSurface mainSurfaceFrame: NSRect,
        in screenVisibleFrame: NSRect?
    ) -> (panelFrame: NSRect, placement: PreviewPlacement) {
        let expandedWidth = PanelGeometry.totalWidth(previewOpen: true)
        let leadingWidth = expandedWidth - PanelGeometry.contentWidth
        var expandedFrame = mainSurfaceFrame
        expandedFrame.size.width = expandedWidth

        guard let screenVisibleFrame,
              expandedFrame.maxX > screenVisibleFrame.maxX
        else {
            return (expandedFrame, .trailing)
        }

        expandedFrame.origin.x -= leadingWidth
        return (expandedFrame, .leading)
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
    ///   - screenVisibleFrames: the visible frames of all screens (the
    ///     "active" screen is the one containing the mouse — Maccy's
    ///     user-selectable `popupScreen` simplified to follow the pointer).
    ///   - lastPositionAnchor: the persisted normalized anchor (top-middle
    ///     of the stable main surface within its screen's visible frame) for
    ///     `.lastPosition`; `nil` falls back to `.cursor`.
    static func origin(
        for mode: PopupPositionMode,
        panelSize: NSSize,
        statusItemButtonScreenFrame: NSRect?,
        mouseLocation: NSPoint,
        screenVisibleFrames: [NSRect],
        lastPositionAnchor: NSPoint?
    ) -> NSPoint {
        let mouseScreen = frame(containing: mouseLocation, in: screenVisibleFrames)
            ?? screenVisibleFrames.first
            ?? .zero

        switch mode {
        case .statusItem:
            guard let buttonFrame = statusItemButtonScreenFrame else {
                return cursorOrigin(panelSize: panelSize, mouseLocation: mouseLocation, frame: mouseScreen)
            }
            let buttonScreen = frame(
                containing: NSPoint(x: buttonFrame.midX, y: buttonFrame.midY),
                in: screenVisibleFrames
            ) ?? mouseScreen
            // Under the button's left edge, hanging below the menu bar —
            // Maccy's `screenRect.minY - size.height` (Maccy clamps the
            // right edge; the shared clamp covers it).
            let raw = NSPoint(x: buttonFrame.minX, y: buttonFrame.minY - panelSize.height)
            return clamped(raw, size: panelSize, into: buttonScreen)

        case .center:
            let raw = NSPoint(
                x: mouseScreen.minX + (mouseScreen.width - panelSize.width) / 2,
                y: mouseScreen.minY + (mouseScreen.height - panelSize.height) / 2
            )
            return clamped(raw, size: panelSize, into: mouseScreen)

        case .lastPosition:
            guard let anchor = lastPositionAnchor else {
                return cursorOrigin(panelSize: panelSize, mouseLocation: mouseLocation, frame: mouseScreen)
            }
            // The anchor is the stable main surface's TOP-MIDDLE point. A
            // main-only reopen makes that surface identical to the panel.
            let raw = NSPoint(
                x: mouseScreen.minX + mouseScreen.width * anchor.x - panelSize.width / 2,
                y: mouseScreen.minY + mouseScreen.height * anchor.y - panelSize.height
            )
            return clamped(raw, size: panelSize, into: mouseScreen)

        case .cursor:
            return cursorOrigin(panelSize: panelSize, mouseLocation: mouseLocation, frame: mouseScreen)
        }
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
    /// main 400-point surface's top-middle point within its screen's visible
    /// frame. The expanded window may shift at a screen edge, but transient
    /// preview width must not move a later main-only reopen (review Card 9F).
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

    /// The visible frame containing a screen-space point, if any.
    private static func frame(containing point: NSPoint, in frames: [NSRect]) -> NSRect? {
        frames.first { $0.contains(point) }
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
