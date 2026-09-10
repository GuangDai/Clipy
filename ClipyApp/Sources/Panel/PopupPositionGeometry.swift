/// PopupPositionGeometry.swift — the panel placement math (Maccy's
/// `PopupPosition.origin(size:statusBarButton:)` + `NSScreen+ForPopup`
/// replicated), written as a pure function over explicit inputs so the
/// geometry is testable headlessly without an `NSScreen`/`NSStatusItem`.
/// The AppKit-side callers (AppDelegate/FloatingPanel/FloatingPreviewPanel)
/// gather the inputs; the mode value itself comes from PresentationUI's
/// `PopupPositionMode`.
import AppKit
import Foundation

/// Which side of the main panel displays the floating preview pane.
/// `PopupPositionGeometry.floatingPreviewFrame` chooses this from screen
/// geometry; `FloatingPreviewPanel` applies it without ever resizing the
/// main panel.
enum PreviewPlacement: Equatable, Sendable {
    case leading
    case trailing
}

/// Pure panel-origin geometry for `PopupPositionMode` (Maccy
/// `PopupPosition.origin` semantics, plus a uniform visible-frame clamp so
/// no mode can spill the panel off the active screen), plus the floating
/// preview pane's beside-the-panel placement.
enum PopupPositionGeometry {

    /// The floating preview pane's frame beside the presented main panel
    /// (the redesign's transient preview: fixed width, the main panel's
    /// height with a 420pt minimum, top edges aligned when the screen allows,
    /// never a main-panel resize).
    /// The pane goes on the trailing side when the screen's visible frame
    /// has room for width + gap there, otherwise the leading side; the
    /// result is clamped into the visible frame either way. A `nil` visible
    /// frame conservatively picks trailing without a clamp.
    static func floatingPreviewFrame(
        beside mainPanelFrame: NSRect,
        in screenVisibleFrame: NSRect?,
        previewWidth: CGFloat = PanelGeometry.floatingPreviewWidth,
        gap: CGFloat = PanelGeometry.floatingPreviewGap
    ) -> (frame: NSRect, placement: PreviewPlacement) {
        let desiredHeight = max(mainPanelFrame.height, PanelGeometry.floatingPreviewMinimumHeight)
        let size = NSSize(
            width: previewWidth,
            height: screenVisibleFrame.map { min(desiredHeight, $0.height) } ?? desiredHeight
        )
        let trailingX = mainPanelFrame.maxX + gap
        let leadingX = mainPanelFrame.minX - gap - previewWidth

        let placement: PreviewPlacement
        if let screenVisibleFrame {
            placement = trailingX + previewWidth <= screenVisibleFrame.maxX
                ? .trailing
                : .leading
        } else {
            placement = .trailing
        }

        // Top edges align before the screen clamp. A short browsing panel
        // must not compress the independent preview's controls and content.
        var frame = NSRect(
            origin: NSPoint(
                x: placement == .trailing ? trailingX : leadingX,
                y: mainPanelFrame.maxY - size.height
            ),
            size: size
        )
        if let screenVisibleFrame {
            frame.origin = clamped(frame.origin, size: size, into: screenVisibleFrame)
        }
        return (frame, placement)
    }

    /// Computes the panel's top-left screen-space origin (AppKit window
    /// origins are bottom-left of the window; every mode below returns the
    /// BOTTOM-left origin ready for `setFrameOrigin`).
    ///
    /// - Parameters:
    ///   - mode: the placement mode (status-item clicks pass `.statusItem`
    ///     directly, like Maccy's `performStatusItemClick`).
    ///   - panelSize: the panel's full size.
    ///   - statusItemButtonScreenFrame: the status-item button's frame in
    ///     screen coordinates; `nil` when unavailable (falls back to
    ///     `.cursor`, Maccy's behavior).
    ///   - mouseLocation: `NSEvent.mouseLocation` at summon time.
    ///   - screens: each screen's full frame and current safe drawing frame.
    ///     Menu-bar and Dock points belong to the full frame, even though the
    ///     resulting panel must fit within that screen's visible frame.
    ///   - lastPositionAnchor: the persisted normalized anchor (top-middle
    ///     of the panel within its screen's visible frame) for
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
            // The anchor is the panel's TOP-MIDDLE point within its screen's
            // visible frame.
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
    /// panel's top-middle point within its screen's visible frame. The
    /// transient floating preview never shares this frame, so the anchor
    /// always describes the whole panel.
    static func normalizedAnchor(
        forPanelFrame panelFrame: NSRect,
        in screenVisibleFrame: NSRect
    ) -> NSPoint {
        guard screenVisibleFrame.width > 0, screenVisibleFrame.height > 0 else {
            return NSPoint(x: 0.5, y: 1)
        }
        return NSPoint(
            x: (panelFrame.midX - screenVisibleFrame.minX)
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
