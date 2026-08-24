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
import Carbon.HIToolbox
import PresentationUI
import SwiftUI

enum PanelSubmitDecision {
    static func shouldSubmit(
        eventType: NSEvent.EventType,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        hasMarkedText: Bool
    ) -> Bool {
        let disallowedModifiers: NSEvent.ModifierFlags = [
            .command, .control, .option,
        ]
        return eventType == .keyDown
            && (keyCode == UInt16(kVK_Return)
                || keyCode == UInt16(kVK_ANSI_KeypadEnter))
            && modifierFlags.intersection(disallowedModifiers).isEmpty
            && !hasMarkedText
    }
}

/// The panel window. One instance per app run, created lazily on first
/// open and reused — closing only hides it (Maccy's model: the SwiftUI
/// content persists across open/close. AppDelegate is the only per-open
/// session/observation owner; the SwiftUI root observes its session generation
/// only to reconcile selection and first responder (Card 14D).
@MainActor
final class FloatingPanel: NSPanel, NSWindowDelegate {

    /// Whether the panel is currently on screen.
    private(set) var isPresented = false

    /// Whether the preview column is currently shown (drives the width).
    private(set) var isPreviewVisible = false

    /// The real column order shared with the hosted SwiftUI view.
    private(set) var previewPlacement: PreviewPlacement = .trailing

    /// The preview pane state whose panel-lifecycle hooks the window
    /// delegate drives (Maccy's `windowDidBecomeKey` → `enableAutoOpen` /
    /// `windowDidResignKey` → `disableAutoOpen` pair).
    private let previewState: PreviewPaneState

    /// Invoked after every close (AppDelegate bookkeeping: deactivate the
    /// view state, reset the preview pane).
    private let onPanelClosed: () -> Void
    private let onSubmitSelection: () -> Void

    /// Publishes geometry's placement decision to AppDelegate so the hosted
    /// HistoryPanelView orders its columns from the same value.
    private let onPreviewPlacementChange: (PreviewPlacement) -> Void

    /// Set around programmatic `setFrame` calls so `windowDidMove` persists
    /// only USER drag positions as the `.lastPosition` anchor.
    private var isProgrammaticMove = false

    init(
        rootView: PanelRootView,
        previewState: PreviewPaneState,
        onPreviewPlacementChange: @escaping (PreviewPlacement) -> Void,
        onSubmitSelection: @escaping () -> Void = {},
        onClosed: @escaping () -> Void
    ) {
        self.previewState = previewState
        self.onPreviewPlacementChange = onPreviewPlacementChange
        self.onSubmitSelection = onSubmitSelection
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

    /// Window-owned Return routing keeps the behavior independent of which
    /// SwiftUI child currently owns first responder. Marked text always goes
    /// back to AppKit's field editor; only an unmodified settled Return enters
    /// the product paste intent (REVIEW Card 14A/15).
    override func sendEvent(_ event: NSEvent) {
        let hasMarkedText = (firstResponder as? NSTextInputClient)?
            .hasMarkedText() ?? false
        guard PanelSubmitDecision.shouldSubmit(
            eventType: event.type,
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags,
            hasMarkedText: hasMarkedText
        ) else {
            super.sendEvent(event)
            return
        }
        onSubmitSelection()
    }

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
        if isPreviewVisible {
            setPreviewVisible(false)
        }
        onPanelClosed()
    }

    /// Closes the panel when it loses key status — an outside click
    /// dismisses (Maccy's `resignKey`); a modal alert on top keeps it open
    /// (`NSApplication.isModalAlertPresented` below — public modal/sheet
    /// API replacing Maccy's private `_NSAlertPanel` class-name scan;
    /// audit S-5 / APL-C-11).
    override func resignKey() {
        super.resignKey()
        if !NSApp.isModalAlertPresented {
            close()
        }
    }

    // MARK: - Preview width (Maccy's no-animation setFrame)

    /// Widens/narrows the panel by the preview column width in a single
    /// `setFrame` — never animated (an animated resize forces a full
    /// NSHostingView layout per display-link frame; Maccy documents the
    /// resulting layout storm). Geometry chooses the side with room while
    /// preserving the main surface's exact screen frame (Card 9C/9F).
    func setPreviewVisible(_ visible: Bool) {
        guard visible != isPreviewVisible else { return }
        if visible {
            let expansion = PopupPositionGeometry.expandedPreviewFrame(
                preservingMainSurface: frame,
                in: screen?.visibleFrame
            )
            isPreviewVisible = true
            setPreviewPlacement(expansion.placement)
            setFrameProgrammatically(expansion.panelFrame, display: isPresented)
        } else {
            let mainSurfaceFrame = PopupPositionGeometry.mainSurfaceFrame(
                in: frame,
                previewPlacement: previewPlacement,
                previewVisible: true
            )
            isPreviewVisible = false
            setPreviewPlacement(.trailing)
            setFrameProgrammatically(mainSurfaceFrame, display: isPresented)
        }
    }

    // MARK: - Window delegate

    /// Persists the user-dragged position as the normalized `.lastPosition`
    /// anchor (Maccy's `saveWindowPosition`, gated to user drags only).
    func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticMove, let screenFrame = screen?.visibleFrame else { return }
        let anchor = PopupPositionGeometry.normalizedAnchor(
            forPanelFrame: frame,
            previewPlacement: previewPlacement,
            previewVisible: isPreviewVisible,
            mainSurfaceWidth: PanelGeometry.contentWidth,
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

    private func setPreviewPlacement(_ placement: PreviewPlacement) {
        guard placement != previewPlacement else { return }
        previewPlacement = placement
        onPreviewPlacementChange(placement)
    }
}

/// Whether the app is currently presenting an alert on top — public-API
/// replacement for Maccy's `NSApplication+Windows.swift` alert scan, which
/// matched the AppKit-private class name `_NSAlertPanel` (audit S-5 /
/// APL-C-11: Apple publishes no such class-name contract, and
/// docs/00-overview.md:65-69 requires documented platform behavior, not an
/// invented API surface). Both documented alert presentations are covered:
/// `NSApplication.modalWindow` is non-nil while an alert runs as an
/// app-modal session (`NSAlert.runModal`), and `NSWindow.attachedSheet` is
/// non-nil while an alert/sheet is attached to any app window
/// (`NSAlert.beginSheetModal`). This is also tighter than the old scan: it
/// cannot false-positive on an ordered-out alert window lingering in
/// `NSApplication.windows` (whose contents and order Apple leaves
/// unspecified).
private extension NSApplication {
    var isModalAlertPresented: Bool {
        modalWindow != nil || windows.contains { $0.attachedSheet != nil }
    }
}
