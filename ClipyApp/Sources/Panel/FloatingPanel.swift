/// FloatingPanel.swift — the floating clipboard panel: Maccy's
/// `FloatingPanel` (Maccy/FloatingPanel.swift) replicated onto Clipy's
/// surface — a non-activating `NSPanel` that becomes key without
/// foregrounding the app, positions itself per `PopupPositionMode`,
/// widens for the preview column without animation (Maccy's layout-storm
/// lesson), persists its dragged-to anchor for `.lastPosition`, and closes
/// on focus loss.
///
/// The browsing column and the height are user-RESIZABLE within
/// PanelGeometry's minimum/maximum bounds (enforced through
/// `contentMinSize`/`contentMaxSize`); a settled user size persists under
/// PanelGeometry's `clipy.panel*` keys and is re-applied on every open,
/// shrunk to fit the target screen when a size persisted on a larger
/// display would overflow. The preview column's width change is the
/// `dividerWidth + persisted preview column width` extension — the
/// panel's free-drag divider width, read fresh from defaults per width
/// computation — driven by `setPreviewVisible(_:)`. The keep-open pin
/// (AppDelegate's `isPanelKeepOpenActive`, read through `isKeepOpenActive`)
/// suppresses ONLY the focus-loss close; every explicit close path is
/// untouched.
import AppKit
import Carbon.HIToolbox
import PresentationUI
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
        isMovableByWindowBackground = true
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
    /// fixed preview extension when the pane is open, shrunk to fit the
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
                + (isPreviewVisible ? Self.previewExtension : 0),
            height: persisted.height
        )
        let mouseLocation = NSEvent.mouseLocation
        let screenVisibleFrames = NSScreen.screens.map(\.visibleFrame)
        // The target screen is the one PopupPositionGeometry places the
        // panel on: the visible frame containing the pointer, else the
        // first. Shrink only — placement-mode origins are untouched.
        if let targetVisibleFrame = screenVisibleFrames
            .first(where: { $0.contains(mouseLocation) })
            ?? screenVisibleFrames.first {
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
            screenVisibleFrames: screenVisibleFrames,
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

    /// Widens/narrows the panel by the preview column width in a single
    /// `setFrame` — never animated (an animated resize forces a full
    /// NSHostingView layout per display-link frame; Maccy documents the
    /// resulting layout storm). Geometry chooses the side with room —
    /// pinned to the session's `previewSide` preference when one is set —
    /// while preserving the main surface's exact screen frame, including a
    /// user-resized width (Card 9C/9F). The resize bounds follow the
    /// visibility so a preview-open panel can never be dragged narrower
    /// than the main column's minimum plus the extension.
    func setPreviewVisible(_ visible: Bool) {
        guard visible != isPreviewVisible else { return }
        if visible {
            let expansion = PopupPositionGeometry.expandedPreviewFrame(
                preservingMainSurface: frame,
                in: screen?.visibleFrame,
                previewSide: previewSide,
                previewColumnWidth: Self.persistedPreviewColumnWidth
            )
            isPreviewVisible = true
            setPreviewPlacement(expansion.placement)
            setFrameProgrammatically(expansion.panelFrame, display: isPresented)
        } else {
            let mainSurfaceFrame = PopupPositionGeometry.mainSurfaceFrame(
                in: frame,
                previewPlacement: previewPlacement,
                previewVisible: true,
                mainSurfaceWidth: frame.width - Self.previewExtension
            )
            isPreviewVisible = false
            setPreviewPlacement(.trailing)
            setFrameProgrammatically(mainSurfaceFrame, display: isPresented)
        }
        applyResizeLimits()
    }

    // MARK: - Window delegate

    /// Persists the user-dragged position as the normalized `.lastPosition`
    /// anchor (Maccy's `saveWindowPosition`, gated to user drags only). The
    /// main-surface width is the LIVE browsing-column width, so a resized
    /// panel's anchor still tracks the stable main surface.
    func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticMove, let screenFrame = screen?.visibleFrame else { return }
        let anchor = PopupPositionGeometry.normalizedAnchor(
            forPanelFrame: frame,
            previewPlacement: previewPlacement,
            previewVisible: isPreviewVisible,
            mainSurfaceWidth: frame.width
                - (isPreviewVisible ? Self.previewExtension : 0),
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
        let previewExtension = isPreviewVisible ? Self.previewExtension : 0
        let contentWidth = PanelGeometry.clampedContentWidth(
            frame.width - previewExtension
        )
        let height = PanelGeometry.clampedHeight(frame.height)
        PanelGeometry.persistSize(
            contentWidth: contentWidth,
            height: height,
            to: .standard
        )
        let clampedSize = NSSize(
            width: contentWidth + previewExtension,
            height: height
        )
        if clampedSize != frame.size {
            setFrameProgrammatically(
                NSRect(origin: frame.origin, size: clampedSize),
                display: isPresented
            )
        }
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

    /// The width the preview column adds when open: the divider plus the
    /// persisted free-drag preview column width. The width is read fresh
    /// from defaults at EVERY width computation (open, preview toggle,
    /// resize settle, limits), so a settled divider drag applies to the
    /// next computation and no cached width can go stale. The 320 default
    /// equals the historical constant (`dividerWidth + 320`), so existing
    /// frame fixtures are unchanged.
    private static var previewExtension: CGFloat {
        PanelGeometry.dividerWidth + persistedPreviewColumnWidth
    }

    /// The divider's persisted preview column width, read fresh from
    /// defaults at call time — the single load behind `previewExtension`
    /// and the expansion geometry's `previewColumnWidth` input.
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
              let y = defaults.object(forKey: anchorYKey) as? Double
        else { return nil }
        return NSPoint(x: x, y: y)
    }

    // MARK: - Private

    /// The interactive-resize bounds for the current preview visibility:
    /// the browsing column stays within PanelGeometry's width bounds and
    /// the fixed preview extension rides on top while the pane is open.
    /// These constrain only user drags; programmatic frames (open's
    /// shrink-to-fit on a smaller display) are never clamped by them.
    private func applyResizeLimits() {
        let previewExtension = isPreviewVisible ? Self.previewExtension : 0
        contentMinSize = NSSize(
            width: PanelGeometry.minimumContentWidth + previewExtension,
            height: PanelGeometry.minimumHeight
        )
        contentMaxSize = NSSize(
            width: PanelGeometry.maximumContentWidth + previewExtension,
            height: PanelGeometry.maximumHeight
        )
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
