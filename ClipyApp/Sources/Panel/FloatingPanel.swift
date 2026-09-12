/// The app-owned floating panel. Content determines its compact size;
/// the active display supplies resize limits, and display fitting never
/// rewrites saved dimensions. The transient preview lives in the separate
/// `FloatingPreviewPanel` child window; this panel's geometry never changes
/// for preview.
import AppKit
import Carbon.HIToolbox
import SwiftUI

enum PanelKeyEventDisposition: Equatable {
    case deliverToMarkedTextResponder
    case submitSelection
    case forwardToWindow
}

enum PanelKeyEventDecision {
    static func disposition(
        eventType: NSEvent.EventType,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        hasMarkedText: Bool,
        isSelectionSubmissionEnabled: Bool
    ) -> PanelKeyEventDisposition {
        guard eventType == .keyDown else { return .forwardToWindow }

        let isReturn = keyCode == UInt16(kVK_Return)
            || keyCode == UInt16(kVK_ANSI_KeypadEnter)
        let isEscape = keyCode == UInt16(kVK_Escape)
        if hasMarkedText, isReturn || isEscape {
            return .deliverToMarkedTextResponder
        }

        let disallowedModifiers: NSEvent.ModifierFlags = [
            .command, .control, .option,
        ]
        guard isReturn,
              modifierFlags.intersection(disallowedModifiers).isEmpty,
              isSelectionSubmissionEnabled
        else { return .forwardToWindow }
        return .submitSelection
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

    /// The preview pane state whose panel-lifecycle hooks the window
    /// delegate drives (Maccy's `windowDidBecomeKey` → `enableAutoOpen` /
    /// `windowDidResignKey` → `disableAutoOpen` pair).
    private let previewState: PreviewPaneState

    /// Invoked after every close (AppDelegate bookkeeping: deactivate the
    /// view state, reset the preview pane).
    private let onPanelClosed: () -> Void
    private let onSubmitSelection: () -> Void
    private let isSelectionSubmissionEnabled: () -> Bool

    /// Invoked when the panel changes screens, so the AppDelegate can hide
    /// the floating preview pane rather than leave it on the old display.
    private let onDidChangeScreen: () -> Void

    /// Invoked on every frame change (`windowDidResize`), so the AppDelegate
    /// can re-place the visible floating preview pane: child windows follow
    /// parent drags on their own, but a height change (content fit or a
    /// live user resize) leaves the child's size/side stale.
    private let onFrameChanged: () -> Void

    /// Re-read on every deferred focus-loss decision: the app shell's
    /// keep-open pin suppresses ONLY the resignKey close; explicit closes
    /// (Esc, paste completion, Quit, workspace lifecycle) still retire the
    /// panel through `close()`. Defaults to "never pinned", which is
    /// today's exact behavior.
    private let isKeepOpenActive: () -> Bool

    /// Set around programmatic `setFrame` calls so `windowDidMove` persists
    /// only USER drag positions as the `.lastPosition` anchor.
    private var isProgrammaticMove = false

    /// The latest content-fit demand (the oracle's ideal height), retained
    /// so the live-resize settle boundary and a later open can re-apply it.
    private var pendingContentFitHeight: CGFloat?

    /// Content fit is suspended while the user drags a resize edge; the
    /// settle boundary persists the dragged height as the new ceiling and
    /// re-applies the retained demand (Maccy's popup semantics: content
    /// smaller than the new ceiling shrinks the panel).
    private var isLiveResizeActive = false
    private var liveResizeStartingSize: NSSize?

    /// AppKit can notify the parent that it resigned key before
    /// `beginSheetModal` has made `attachedSheet` observable. Defer the close
    /// decision one MainActor turn, then re-read only public window/modal
    /// state. The single replaceable task also coalesces duplicate resign
    /// callbacks without introducing a second lifecycle owner (Card 14D).
    private var deferredFocusLossCloseTask: Task<Void, Never>?

    init(
        rootView: PanelRootView,
        previewState: PreviewPaneState,
        isSelectionSubmissionEnabled: @escaping () -> Bool = { true },
        onSubmitSelection: @escaping () -> Void = {},
        isKeepOpenActive: @escaping () -> Bool = { false },
        onDidChangeScreen: @escaping () -> Void = {},
        onFrameChanged: @escaping () -> Void = {},
        onClosed: @escaping () -> Void
    ) {
        self.previewState = previewState
        self.isSelectionSubmissionEnabled = isSelectionSubmissionEnabled
        self.onSubmitSelection = onSubmitSelection
        self.isKeepOpenActive = isKeepOpenActive
        self.onDidChangeScreen = onDidChangeScreen
        self.onFrameChanged = onFrameChanged
        self.onPanelClosed = onClosed
        super.init(
            contentRect: NSRect(
                x: 0, y: 0,
                width: PanelGeometry.contentWidth,
                height: PanelGeometry.height
            ),
            // `.resizable` admits user drags within the
            // PanelGeometry-bounded `contentMinSize`/`contentMaxSize`
            // applied below; every other flag is unchanged.
            styleMask: [.nonactivatingPanel, .closable, .resizable, .fullSizeContentView],
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
        // SwiftUI's header background owns window dragging; AppKit's
        // automatic background drag would fight that gesture.
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        // The panel is reused across closes — never let AppKit release it
        // out from under the AppDelegate.
        isReleasedWhenClosed = false
        // The initial frame is the default size; the persisted size is
        // applied at open. The bounds only constrain interactive resizes.
        applyResizeLimits()

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 12
        hostingView.layer?.masksToBounds = true
        contentView = hostingView

        delegate = self
    }

    /// Text inputs inside the panel receive keyboard focus (Maccy's
    /// `canBecomeKey` override — the whole point of the non-activating
    /// panel technique).
    override var canBecomeKey: Bool { true }

    /// Window-owned Return routing keeps the behavior independent of which
    /// SwiftUI child currently owns first responder. Marked Return/Escape is
    /// delivered directly to that text responder so a window-level SwiftUI
    /// key equivalent cannot overtake the IME. Settled Escape continues
    /// through normal window dispatch: the list root owns Clear Search then
    /// Close, while Details/editor destinations own their dismissal intent.
    /// Only an unmodified settled Return enters the product paste intent
    /// (REVIEW Card 14A/15; UI-7).
    override func sendEvent(_ event: NSEvent) {
        // `keyCode` is valid only for key events. Reading it from a mouse
        // event raises an AppKit exception before `super` can deliver the
        // click, which made every SwiftUI control in this panel inert under
        // real mouse input (observed by the Card 14A running-app tracer).
        guard event.type == .keyDown else {
            super.sendEvent(event)
            return
        }
        let responder = firstResponder
        let hasMarkedText = (responder as? NSTextInputClient)?
            .hasMarkedText() ?? false
        switch PanelKeyEventDecision.disposition(
            eventType: event.type,
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags,
            hasMarkedText: hasMarkedText,
            isSelectionSubmissionEnabled: isSelectionSubmissionEnabled()
        ) {
        case .deliverToMarkedTextResponder:
            // `firstResponder` is necessarily an NSTextInputClient when the
            // fact above is true. Keep the fallback defensive for AppKit
            // responder replacement between the two reads.
            if let responder {
                responder.keyDown(with: event)
            } else {
                super.sendEvent(event)
            }
        case .submitSelection:
            onSubmitSelection()
        case .forwardToWindow:
            super.sendEvent(event)
        }
    }

    // MARK: - Open / close

    /// Positions the panel per `mode` and orders it front as key window
    /// WITHOUT activating the app (`orderFrontRegardless` + `makeKey` —
    /// Maccy's `open(height:at:)`; the user's previously focused app keeps
    /// focus ownership for the paste that follows).
    ///
    /// The open size is the persisted user size (PanelGeometry's clamped
    /// read of the `clipy.panel*` keys, defaulting to 360×420), shrunk to
    /// fit the target screen's visible frame when a size persisted on a
    /// larger display would overflow — the geometry layer clamps ORIGINS
    /// only, so the shrink must happen here. The persisted height is the
    /// content-fit CEILING: a retained content-fit demand determines the
    /// actual size before placement. Without one, the next demand from
    /// SwiftUI fits the displayed content after opening.
    func open(
        at mode: PopupPositionMode,
        statusItemButtonScreenFrame: NSRect?
    ) {
        deferredFocusLossCloseTask?.cancel()
        deferredFocusLossCloseTask = nil
        let persisted = PanelGeometry.persistedSize(from: .standard)
        var size = NSSize(
            width: persisted.contentWidth,
            height: persisted.height
        )
        // Position the actual compact surface, not its taller saved ceiling.
        // Otherwise center placement ends above center, and cursor/last-position
        // placement near the bottom unnecessarily jumps up to fit empty space.
        if let idealHeight = pendingContentFitHeight {
            size.height = PanelContentFit.clampedHeight(idealHeight, ceiling: size.height)
        }
        let mouseLocation = NSEvent.mouseLocation
        let screens = NSScreen.screens.map { (frame: $0.frame, visibleFrame: $0.visibleFrame) }
        // Size and origin use the same target display, including a status
        // item summoned while the pointer remains on a different screen.
        let targetVisibleFrame = PopupPositionGeometry.targetVisibleFrame(
            for: mode, statusItemButtonScreenFrame: statusItemButtonScreenFrame,
            mouseLocation: mouseLocation, screens: screens
        )
        applyResizeLimits(in: targetVisibleFrame)
        if let targetVisibleFrame {
            size = NSSize(
                width: min(size.width, targetVisibleFrame.width),
                height: min(size.height, targetVisibleFrame.height)
            )
        }
        let origin = PopupPositionGeometry.origin(
            for: mode,
            panelSize: size,
            statusItemButtonScreenFrame: statusItemButtonScreenFrame,
            mouseLocation: mouseLocation,
            screens: screens,
            lastPositionAnchor: Self.savedAnchor()
        )
        setFrameProgrammatically(NSRect(origin: origin, size: size), display: false)
        orderFrontRegardless()
        makeKey()
        isPresented = true
        applyContentFit()
    }

    /// Closes the panel (hides it; the instance is reused). Child windows
    /// (the floating preview pane) order out with it.
    override func close() {
        guard isPresented else { return }
        deferredFocusLossCloseTask?.cancel()
        deferredFocusLossCloseTask = nil
        super.close()
        isPresented = false
        onPanelClosed()
    }

    /// Whether any current screen's safe drawing area still contains a
    /// visible part of this panel. Screen configuration facts are supplied by
    /// the AppDelegate at notification time and are never retained here.
    func isReachable(in screenVisibleFrames: [NSRect]) -> Bool {
        screenVisibleFrames.contains { $0.intersects(frame) }
    }

    /// Closes the panel when it loses key status — an outside click
    /// dismisses (Maccy's `resignKey`); a modal alert on top keeps it open
    /// (`NSApplication.isModalAlertPresented` below — public modal/sheet
    /// API replacing Maccy's private `_NSAlertPanel` class-name scan;
    /// audit S-5 / APL-C-11). The keep-open pin is a third suppression:
    /// while the user has pinned the panel, focus loss alone never closes
    /// it. The pin is consulted inside the SAME deferred decision so the
    /// modal-alert ordering semantics above are untouched.
    override func resignKey() {
        super.resignKey()
        deferredFocusLossCloseTask?.cancel()
        deferredFocusLossCloseTask = Task { @MainActor [weak self] in
            // `beginSheetModal` completes its public sheet attachment only
            // after the parent-window resign callback returns. Yielding keeps
            // outside-click behavior prompt while closing that ordering gap.
            await Task.yield()
            guard !Task.isCancelled,
                  let self,
                  self.isPresented,
                  !self.isKeyWindow,
                  !NSApp.isModalAlertPresented,
                  !self.isKeepOpenActive()
            else { return }
            self.close()
        }
    }

    // MARK: - Window delegate

    /// Persists the user-dragged position as the normalized `.lastPosition`
    /// anchor (Maccy's `saveWindowPosition`, gated to user drags only). The
    /// panel frame IS the whole surface — the floating preview lives in its
    /// own child window and never enters this frame.
    func windowDidMove(_ notification: Notification) {
        persistAnchor()
    }

    private func persistAnchor() {
        guard !isProgrammaticMove, let screenFrame = screen?.visibleFrame else { return }
        let anchor = PopupPositionGeometry.normalizedAnchor(
            forPanelFrame: frame,
            in: screenFrame
        )
        UserDefaults.standard.set(anchor.x, forKey: Self.anchorXKey)
        UserDefaults.standard.set(anchor.y, forKey: Self.anchorYKey)
    }

    /// Content fit must not fight the user's drag: while a live resize is
    /// active the retained demand is kept but not applied.
    func windowWillStartLiveResize(_ notification: Notification) {
        isLiveResizeActive = true
        liveResizeStartingSize = frame.size
    }

    /// Persists the user-settled panel size through PanelGeometry's single
    /// clamping write path (the size twin of `windowDidMove`'s anchor write
    /// for drags). Programmatic frames never fire live-resize callbacks, so
    /// no `isProgrammaticMove` gate is needed here. A settle outside the
    /// bounds — not reachable through the resize limits, but possible when
    /// the limits changed under an existing frame — snaps back without
    /// animation. The dragged height is the new content-fit CEILING: the
    /// retained fit demand re-applies immediately, shrinking the panel back
    /// to its displayed content (Maccy's popup semantics).
    func windowDidEndLiveResize(_ notification: Notification) {
        isLiveResizeActive = false
        let contentWidth = PanelGeometry.clampedContentWidth(frame.width)
        let height = PanelGeometry.clampedHeight(frame.height)
        // Preserve each untouched dimension (V2-11). A width-only drag must
        // not save a short fitted height; a height-only drag on a smaller
        // screen must not erase the preferred width for a larger display.
        let saved = PanelGeometry.persistedSize(from: .standard)
        let preferredWidth = liveResizeStartingSize?.width == frame.width
            ? saved.contentWidth : contentWidth
        let heightCeiling = liveResizeStartingSize?.height == frame.height
            ? saved.height : height
        liveResizeStartingSize = nil
        PanelGeometry.persistSize(
            contentWidth: preferredWidth,
            height: heightCeiling,
            to: .standard
        )
        let clampedSize = NSSize(
            width: contentWidth,
            height: height
        )
        if clampedSize != frame.size {
            setFrameProgrammatically(
                NSRect(origin: frame.origin, size: clampedSize),
                display: isPresented
            )
        }
        persistAnchor()
        applyContentFit()
        onFrameChanged()
    }

    /// The panel's frame changed (content fit, user resize, snap-back).
    /// The AppDelegate re-places the visible floating preview pane so it
    /// keeps the main panel's height, side, and top alignment.
    func windowDidResize(_ notification: Notification) {
        onFrameChanged()
    }

    // MARK: - Content fit

    /// Publishes the latest analytic ideal content height
    /// (`PanelContentFit`) and applies it unless a live user resize is
    /// active; the demand is retained either way so the settle boundary
    /// and the next open re-apply it.
    func fitToContent(idealHeight: CGFloat) {
        pendingContentFitHeight = idealHeight
        applyContentFit()
    }

    /// Applies the retained fit demand with an INSTANT, non-animated
    /// `setFrame` (the layout-storm rationale above: window frames never
    /// animate). The new height is the ideal clamped to
    /// [PanelContentFit floor, persisted ceiling] and the screen's visible
    /// frame; the panel's TOP edge stays pinned unless that would push the
    /// bottom offscreen, in which case the frame shifts up just enough to
    /// stay inside (the same clamp family PopupPositionGeometry uses).
    private func applyContentFit() {
        guard isPresented,
              !isLiveResizeActive,
              let idealHeight = pendingContentFitHeight
        else { return }
        let ceiling = PanelGeometry.persistedSize(from: .standard).height
        let visibleFrame = screen?.visibleFrame
        var fitted = PanelContentFit.clampedHeight(idealHeight, ceiling: ceiling)
        if let visibleFrame {
            fitted = min(fitted, visibleFrame.height)
        }
        guard fitted != frame.height else { return }
        var newFrame = NSRect(
            x: frame.minX,
            y: frame.maxY - fitted,
            width: frame.width,
            height: fitted
        )
        if let visibleFrame {
            if newFrame.maxY > visibleFrame.maxY {
                newFrame.origin.y -= newFrame.maxY - visibleFrame.maxY
            }
            if newFrame.minY < visibleFrame.minY {
                newFrame.origin.y = visibleFrame.minY
            }
        }
        setFrameProgrammatically(newFrame, display: true)
    }

    /// Arms preview dwell auto-open while the panel is key.
    func windowDidBecomeKey(_ notification: Notification) {
        deferredFocusLossCloseTask?.cancel()
        deferredFocusLossCloseTask = nil
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
              let y = defaults.object(forKey: anchorYKey) as? Double,
              x.isFinite, y.isFinite
        else { return nil }
        return NSPoint(x: x, y: y)
    }

    // MARK: - Private

    /// Content-size bounds and the current screen's available drawing area.
    private func applyResizeLimits(in visibleFrame: NSRect? = nil) {
        let available = visibleFrame ?? screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let maximum = available?.size ?? NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        contentMinSize = NSSize(
            width: min(PanelGeometry.minimumContentWidth, maximum.width),
            height: min(PanelGeometry.minimumHeight, maximum.height)
        )
        contentMaxSize = maximum
    }

    func windowDidChangeScreen(_ notification: Notification) {
        // Moving between screens changes available resize space, not the
        // saved preferred size. A later open fits that preference to its
        // screen. The floating preview pane hides rather than trailing
        // behind on the old display.
        applyResizeLimits()
        onDidChangeScreen()
    }

    private func setFrameProgrammatically(_ frame: NSRect, display: Bool) {
        isProgrammaticMove = true
        setFrame(frame, display: display)
        isProgrammaticMove = false
    }

#if DEBUG
    /// Deterministic hosted-test join for the public-state focus-loss decision.
    /// Production has no caller-facing lifecycle seam.
    func waitForDeferredFocusLossCloseForTesting() async {
        await deferredFocusLossCloseTask?.value
    }

    /// Places the actual hosted panel without recording a user-drag anchor.
    /// This lets the screen-parameter test represent a removed display while
    /// leaving production placement and UserDefaults untouched.
    func setFrameForScreenChangeTesting(_ frame: NSRect) {
        setFrameProgrammatically(frame, display: false)
    }
#endif
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
