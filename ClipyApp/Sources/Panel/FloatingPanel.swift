/// FloatingPanel.swift — the floating clipboard panel: Maccy's
/// `FloatingPanel` (Maccy/FloatingPanel.swift) replicated onto Clipy's
/// fixed-geometry surface — a non-activating `NSPanel` that becomes key
/// without foregrounding the app, positions itself per `PopupPositionMode`,
/// widens for the preview column without animation (Maccy's layout-storm
/// lesson), persists its dragged-to anchor for `.lastPosition`, and closes
/// on focus loss.
///
/// The panel is fixed-SIZE (no user resize in this step — Maccy's
/// resize/preview-split machinery is deliberately not replicated); the only
/// width change is the preview column, driven by `setPreviewVisible(_:)`.
import AppKit
import PresentationUI
import SwiftUI

/// The panel window. One instance per app run, created lazily on first
/// open and reused — closing only hides it (Maccy's model: the SwiftUI
/// content persists across open/close, so `HistoryPanelView`'s `.task`
/// activate fires once and the panel controller owns per-open
/// activate/deactivate of the view state).
@MainActor
final class FloatingPanel: NSPanel, NSWindowDelegate {

    /// Whether the panel is currently on screen.
    private(set) var isPresented = false

    /// Whether the preview column is currently shown (drives the width).
    private(set) var isPreviewVisible = false

    /// The preview pane state whose panel-lifecycle hooks the window
    /// delegate drives (Maccy's `windowDidBecomeKey` → `enableAutoOpen` /
    /// `windowDidResignKey` → `disableAutoOpen` pair).
    private let previewState: PreviewPaneState

    /// Invoked after every close (AppDelegate bookkeeping: deactivate the
    /// view state, reset the preview pane).
    private let onPanelClosed: () -> Void

    /// Set around programmatic `setFrame` calls so `windowDidMove` persists
    /// only USER drag positions as the `.lastPosition` anchor.
    private var isProgrammaticMove = false

    /// How the preview column last opened: pinned the right edge (extended
    /// left) or the left edge (extended right) — closing reverses it
    /// (Maccy's `computePlacement` anchor-edge rule).
    private var previewOpenedLeft = false

    init(
        rootView: PanelRootView,
        previewState: PreviewPaneState,
        onClosed: @escaping () -> Void
    ) {
        self.previewState = previewState
        self.onPanelClosed = onClosed
        super.init(
            contentRect: NSRect(
                x: 0, y: 0,
                width: PanelGeometry.contentWidth,
                height: PanelGeometry.height
            ),
            styleMask: [.nonactivatingPanel, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // Maccy's floating traits (Maccy/FloatingPanel.swift:49-58): above
        // other windows, visible on every space including full-screen, no
        // activation theft, no hide-on-deactivate (focus loss closes via
        // `resignKey` instead), transparent chrome under a rounded content
        // layer.
        animationBehavior = .none
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        // The panel is reused across closes — never let AppKit release it
        // out from under the AppDelegate.
        isReleasedWhenClosed = false

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 10
        hostingView.layer?.masksToBounds = true
        contentView = hostingView

        delegate = self
    }

    /// Text inputs inside the panel receive keyboard focus (Maccy's
    /// `canBecomeKey` override — the whole point of the non-activating
    /// panel technique).
    override var canBecomeKey: Bool { true }

    // MARK: - Open / close

    /// Positions the panel per `mode` and orders it front as key window
    /// WITHOUT activating the app (`orderFrontRegardless` + `makeKey` —
    /// Maccy's `open(height:at:)`; the user's previously focused app keeps
    /// focus ownership for the paste that follows).
    func open(at mode: PopupPositionMode, statusItemButtonScreenFrame: NSRect?) {
        let size = NSSize(
            width: PanelGeometry.totalWidth(previewOpen: isPreviewVisible),
            height: PanelGeometry.height
        )
        let origin = PopupPositionGeometry.origin(
            for: mode,
            panelSize: size,
            statusItemButtonScreenFrame: statusItemButtonScreenFrame,
            mouseLocation: NSEvent.mouseLocation,
            screenVisibleFrames: NSScreen.screens.map(\.visibleFrame),
            lastPositionAnchor: Self.savedAnchor()
        )
        setFrameProgrammatically(NSRect(origin: origin, size: size), display: false)
        orderFrontRegardless()
        makeKey()
        isPresented = true
    }

    /// Closes the panel (hides it; the instance is reused).
    override func close() {
        guard isPresented else { return }
        super.close()
        isPresented = false
        onPanelClosed()
    }

    /// Closes the panel when it loses key status — an outside click
    /// dismisses (Maccy's `resignKey`); a modal alert on top keeps it open
    /// (`NSApplication.alertWindow`, Maccy's `NSApplication+Windows.swift`
    /// helper replicated below).
    override func resignKey() {
        super.resignKey()
        if NSApp.alertWindow == nil {
            close()
        }
    }

    // MARK: - Preview width (Maccy's no-animation setFrame)

    /// Widens/narrows the panel by the preview column width in a single
    /// `setFrame` — never animated (an animated resize forces a full
    /// NSHostingView layout per display-link frame; Maccy documents the
    /// resulting layout storm). The anchor edge stays pinned: the column
    /// extends rightward unless that would spill past the screen, in which
    /// case it extends leftward (Maccy's `computePlacement`).
    func setPreviewVisible(_ visible: Bool) {
        guard visible != isPreviewVisible else { return }
        isPreviewVisible = visible
        guard isPresented else { return }
        let newWidth = PanelGeometry.totalWidth(previewOpen: visible)
        var frame = self.frame
        let delta = newWidth - frame.size.width
        frame.size.width = newWidth
        if delta > 0 {
            if let screenFrame = screen?.visibleFrame, frame.maxX > screenFrame.maxX {
                frame.origin.x -= delta
                previewOpenedLeft = true
            } else {
                previewOpenedLeft = false
            }
        } else if delta < 0, previewOpenedLeft {
            frame.origin.x -= delta  // delta < 0: shift right, pinning the right edge
        }
        setFrameProgrammatically(frame, display: true)
    }

    // MARK: - Window delegate

    /// Persists the user-dragged position as the normalized `.lastPosition`
    /// anchor (Maccy's `saveWindowPosition`, gated to user drags only).
    func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticMove, let screenFrame = screen?.visibleFrame else { return }
        let anchor = PopupPositionGeometry.normalizedAnchor(
            forPanelFrame: frame,
            in: screenFrame
        )
        UserDefaults.standard.set(anchor.x, forKey: Self.anchorXKey)
        UserDefaults.standard.set(anchor.y, forKey: Self.anchorYKey)
    }

    /// Arms preview dwell auto-open while the panel is key.
    func windowDidBecomeKey(_ notification: Notification) {
        previewState.panelBecameKey()
    }

    /// Disarms preview dwell auto-open when the panel loses key.
    func windowDidResignKey(_ notification: Notification) {
        previewState.panelResignedKey()
    }

    // MARK: - Anchor persistence

    private static let anchorXKey = "clipy.panelAnchorX"
    private static let anchorYKey = "clipy.panelAnchorY"

    /// The persisted normalized anchor, or nil when the user has never
    /// dragged the panel (`.lastPosition` then falls back to `.cursor`).
    static func savedAnchor() -> NSPoint? {
        let defaults = UserDefaults.standard
        guard let x = defaults.object(forKey: anchorXKey) as? Double,
              let y = defaults.object(forKey: anchorYKey) as? Double
        else { return nil }
        return NSPoint(x: x, y: y)
    }

    // MARK: - Private

    private func setFrameProgrammatically(_ frame: NSRect, display: Bool) {
        isProgrammaticMove = true
        setFrame(frame, display: display)
        isProgrammaticMove = false
    }
}

/// Maccy's `NSApplication+Windows.swift` replicated: the alert panel
/// currently on top, if any (matched by its AppKit-private class name —
/// there is no public "is an alert showing" property).
private extension NSApplication {
    var alertWindow: NSWindow? {
        windows.first { $0.className == "_NSAlertPanel" }
    }
}
