/// The app-owned floating panel. User dimensions have usability floors;
/// the active display supplies resize limits. Preview borrows existing width
/// before adding space, and display fitting never rewrites saved dimensions.
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

    /// Whether the preview column is currently shown (drives the width).
    private(set) var isPreviewVisible = false

    /// The real column order shared with the hosted SwiftUI view.
    private(set) var previewPlacement: PreviewPlacement = .trailing

    /// The preview-side preference captured at each open (`.automatic`
    /// keeps the screen-geometry choice); `setPreviewVisible(_:)` reads it.
    private var previewSide: PreviewSidePreference = .automatic

    /// The preview pane state whose panel-lifecycle hooks the window
    /// delegate drives (Maccy's `windowDidBecomeKey` → `enableAutoOpen` /
    /// `windowDidResignKey` → `disableAutoOpen` pair).
    private let previewState: PreviewPaneState

    /// Invoked after every close (AppDelegate bookkeeping: deactivate the
    /// view state, reset the preview pane).
    private let onPanelClosed: () -> Void
    private let onSubmitSelection: () -> Void
    private let isSelectionSubmissionEnabled: () -> Bool

    /// Publishes geometry's placement decision to AppDelegate so the hosted
    /// HistoryPanelView orders its columns from the same value.
    private let onPreviewPlacementChange: (PreviewPlacement) -> Void

    /// Re-read on every deferred focus-loss decision: the app shell's
    /// keep-open pin suppresses ONLY the resignKey close; explicit closes
    /// (Esc, paste completion, Quit, workspace lifecycle) still retire the
    /// panel through `close()`. Defaults to "never pinned", which is
    /// today's exact behavior.
    private let isKeepOpenActive: () -> Bool

    /// Set around programmatic `setFrame` calls so `windowDidMove` persists
    /// only USER drag positions as the `.lastPosition` anchor.
    private var isProgrammaticMove = false

    /// Only space actually added for this preview session is removed when
    /// it closes. Preview inside an already-wide window leaves its size alone.
    private var previewAddedWidth: CGFloat = 0

    /// AppKit can notify the parent that it resigned key before
    /// `beginSheetModal` has made `attachedSheet` observable. Defer the close
    /// decision one MainActor turn, then re-read only public window/modal
    /// state. The single replaceable task also coalesces duplicate resign
    /// callbacks without introducing a second lifecycle owner (Card 14D).
    private var deferredFocusLossCloseTask: Task<Void, Never>?

    init(
        rootView: PanelRootView,
        previewState: PreviewPaneState,
        onPreviewPlacementChange: @escaping (PreviewPlacement) -> Void,
        isSelectionSubmissionEnabled: @escaping () -> Bool = { true },
        onSubmitSelection: @escaping () -> Void = {},
        isKeepOpenActive: @escaping () -> Bool = { false },
        onClosed: @escaping () -> Void
    ) {
        self.previewState = previewState
        self.onPreviewPlacementChange = onPreviewPlacementChange
        self.isSelectionSubmissionEnabled = isSelectionSubmissionEnabled
        self.onSubmitSelection = onSubmitSelection
        self.isKeepOpenActive = isKeepOpenActive
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
        // SwiftUI's header background owns window dragging. AppKit's
        // automatic background drag also moved the whole panel when the
        // user dragged the preview divider instead of resizing its column.
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
    /// read of the `clipy.panel*` keys, defaulting to 400×560), plus the
    /// space added by the current preview session, shrunk to fit the
    /// target screen's visible frame when a size persisted on a larger
    /// display would overflow — the geometry layer clamps ORIGINS only, so
    /// the shrink must happen here. `previewSide` is captured for every
    /// `setPreviewVisible(_:)` during this session; `.automatic` keeps the
    /// screen-geometry choice.
    func open(
        at mode: PopupPositionMode,
        statusItemButtonScreenFrame: NSRect?,
        previewSide: PreviewSidePreference = .automatic
    ) {
        deferredFocusLossCloseTask?.cancel()
        deferredFocusLossCloseTask = nil
        self.previewSide = previewSide
        let persisted = PanelGeometry.persistedSize(from: .standard)
        var size = NSSize(
            width: persisted.contentWidth
                + (isPreviewVisible ? previewAddedWidth : 0),
            height: persisted.height
        )
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
    }

    /// Closes the panel (hides it; the instance is reused).
    override func close() {
        guard isPresented else { return }
        deferredFocusLossCloseTask?.cancel()
        deferredFocusLossCloseTask = nil
        super.close()
        isPresented = false
        if isPreviewVisible {
            setPreviewVisible(false)
        }
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

    // MARK: - Preview width (Maccy's no-animation setFrame)

    /// Borrow existing width for preview and add only missing space, without
    /// animation. Closing reverses that addition, rather than subtracting a
    /// complete pane from an already-wide user window.
    func setPreviewVisible(_ visible: Bool) {
        guard visible != isPreviewVisible else { return }
        if visible {
            let previousWidth = frame.width
            let expansion = PopupPositionGeometry.openingPreviewFrame(
                from: frame,
                in: screen?.visibleFrame,
                previewSide: previewSide,
                previewColumnWidth: Self.persistedPreviewColumnWidth
            )
            isPreviewVisible = true
            previewAddedWidth = max(0, expansion.panelFrame.width - previousWidth)
            setPreviewPlacement(expansion.placement)
            setFrameProgrammatically(expansion.panelFrame, display: isPresented)
        } else {
            let mainSurfaceFrame = PopupPositionGeometry.mainSurfaceFrame(
                in: frame,
                previewPlacement: previewPlacement,
                previewVisible: true,
                mainSurfaceWidth: max(PanelGeometry.minimumContentWidth, frame.width - previewAddedWidth)
            )
            isPreviewVisible = false
            previewAddedWidth = 0
            // Keep the actual side for the closed-edge opener. The next
            // expansion resolves placement from its current screen and preference.
            setFrameProgrammatically(mainSurfaceFrame, display: isPresented)
        }
        applyResizeLimits()
    }

    // MARK: - Window delegate

    /// Persists the user-dragged position as the normalized `.lastPosition`
    /// anchor (Maccy's `saveWindowPosition`, gated to user drags only). The
    /// anchor describes the frame that will remain when preview closes.
    /// Borrowing space inside a wide window must not shift its next reopen.
    func windowDidMove(_ notification: Notification) {
        persistAnchor()
    }

    private func persistAnchor() {
        guard !isProgrammaticMove, let screenFrame = screen?.visibleFrame else { return }
        let anchor = PopupPositionGeometry.normalizedAnchor(
            forPanelFrame: frame,
            previewPlacement: previewPlacement,
            previewVisible: isPreviewVisible,
            mainSurfaceWidth: frame.width
                - (isPreviewVisible ? previewAddedWidth : 0),
            in: screenFrame
        )
        UserDefaults.standard.set(anchor.x, forKey: Self.anchorXKey)
        UserDefaults.standard.set(anchor.y, forKey: Self.anchorYKey)
    }

    /// Persists the user-settled panel size through PanelGeometry's single
    /// clamping write path (the size twin of `windowDidMove`'s anchor write
    /// for drags). Programmatic frames never fire live-resize callbacks, so
    /// no `isProgrammaticMove` gate is needed here. A settle outside the
    /// bounds — not reachable through the resize limits, but possible when
    /// the limits changed under an existing frame — snaps back without
    /// animation.
    func windowDidEndLiveResize(_ notification: Notification) {
        // An explicit resize chooses the whole window's dimensions. It
        // supersedes automatic preview expansion, so closing/reopening the
        // pane must not subtract old borrowed space from that user choice.
        previewAddedWidth = 0
        let contentWidth = PanelGeometry.clampedContentWidth(frame.width)
        let height = PanelGeometry.clampedHeight(frame.height)
        PanelGeometry.persistSize(
            contentWidth: contentWidth,
            height: height,
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

    /// The preferred divider width; display fitting leaves it unchanged.
    private static var persistedPreviewColumnWidth: CGFloat {
        PanelGeometry.persistedPreviewColumnWidth(from: .standard)
    }

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

    /// Usability minima and the current screen's available drawing area.
    private func applyResizeLimits(in visibleFrame: NSRect? = nil) {
        let available = visibleFrame ?? screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let maximum = available?.size ?? NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let previewExtension = isPreviewVisible
            ? PanelGeometry.dividerWidth + PanelGeometry.minimumPreviewColumnWidth : 0
        contentMinSize = NSSize(
            width: min(PanelGeometry.minimumContentWidth + previewExtension, maximum.width),
            height: min(PanelGeometry.minimumHeight, maximum.height)
        )
        contentMaxSize = maximum
    }

    func windowDidChangeScreen(_ notification: Notification) {
        // Moving between screens changes available resize space, not the
        // saved preferred size. A later open fits that preference to its screen.
        applyResizeLimits()
    }

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
