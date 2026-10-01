/// FloatingPreviewPanel.swift — the transient floating preview pane: a
/// borderless, non-activating child NSPanel ordered beside the main
/// `FloatingPanel`. The redesign moves the preview OUT of the main window:
/// no in-window column, no divider, no edge opener — the main panel's
/// geometry never changes for preview.
///
/// Geometry (PopupPositionGeometry.floatingPreviewFrame): preferred width, the
/// main panel's actual height, top edges aligned, trailing
/// side when the screen's visible frame has room, otherwise leading; clamped into the
/// visible frame. Placement applies with an instant, non-animated
/// `setFrame`; a newly shown pane reveals its SwiftUI content from the inner edge.
///
/// The pane is a CHILD window of the main panel, so it follows the parent's
/// ordering and can never outlive it. Showing it preserves the browsing
/// surface's focus; an intentional click enables native text-copy commands.
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The floating preview window. Prepared once the app graph opens and reused;
/// dismissal ends any owned sheet before ordering the window out.
@MainActor
final class FloatingPreviewPanel: NSPanel, NSWindowDelegate {

    /// Whether the pane is currently on screen.
    private(set) var isPresented = false
    private let previewState: PreviewPaneState
    private let defaults: UserDefaults
    private let presentationDuration: @MainActor (NSScreen?) -> TimeInterval
    private let onExitCommand: @MainActor () -> Void
    private let motionPresentation = AppMotionPresentation()
    private var placement: PreviewPlacement = .trailing
    private var lastParentFrame: NSRect?
    private var resizedAnchor: (innerEdge: CGFloat, width: CGFloat, gap: CGFloat, placement: PreviewPlacement)?
    private var mouseDownScreenX: CGFloat?
    private var widthResize: (pointerX: CGFloat, frame: NSRect, placement: PreviewPlacement)?
    private var nativeSheetCount = 0

    init(
        rootView: FloatingPreviewRootView,
        defaults: UserDefaults = .standard,
        presentationDuration: @escaping @MainActor (NSScreen?) -> TimeInterval = { _ in 0 }
    ) {
        self.previewState = rootView.appDelegate.previewState
        self.defaults = defaults
        self.presentationDuration = presentationDuration
        self.onExitCommand = { [weak appDelegate = rootView.appDelegate] in
            guard let appDelegate else { return }
            FloatingPreviewRootView.handleExitCommand(appDelegate: appDelegate)
        }
        super.init(
            contentRect: NSRect(
                x: 0, y: 0,
                width: PanelGeometry.floatingPreviewWidth,
                height: PanelGeometry.height
            ),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // The main panel's floating traits, with a SwiftUI width handle: no application
        // activation theft, no hide-on-deactivate, transparent chrome
        // under a rounded content layer (macOS 26's 12-point radius).
        animationBehavior = .none
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        // The pane is reused across dismissals — never let AppKit release
        // it out from under the AppDelegate.
        isReleasedWhenClosed = false
        // Keep window identity on the native window. A second SwiftUI
        // identifier on the transparent root Group replaces the content's
        // `clipy.preview.root` in the accessibility tree (CI preview journeys).
        setAccessibilityIdentifier("clipy.panel.floatingPreview")

        var presentationRoot = rootView
        presentationRoot.motionPresentation = motionPresentation
        let hostingView = NSHostingView(rootView: presentationRoot.appLanguage())
        hostingView.sizingOptions = []
        hostingView.wantsLayer = true
        contentView = hostingView

        // Retry's pointer can already be over this non-key window while
        // SwiftUI still reports only the main window's exit. Check actual
        // screen containment before the shared exit grace hides the pane.
        rootView.appDelegate.previewState.pointerSurfacesContainingPointer = { [weak self] in
            guard let self, self.isPresented else { return [] }
            let pointer = NSEvent.mouseLocation
            var surfaces: Set<PreviewPaneState.PreviewPointerSurface> = []
            // The SwiftUI alert binding can become false before AppKit has
            // detached its closing sheet. That native modal family still
            // owns this preview, even when its buttons lie outside our frame.
            if self.nativeSheetCount > 0 || self.attachedSheet != nil || self.frame.contains(pointer) {
                surfaces.insert(.preview)
            }
            if let parent = self.parent {
                if parent.attachedSheet != nil || (parent.isVisible && parent.frame.contains(pointer)) {
                    surfaces.insert(.mainPanel)
                }
            }
            return surfaces
        }
        rootView.appDelegate.previewState.pointerIsBetweenSurfaces = { [weak self] in
            guard let self, self.isPresented, let parent = self.parent, parent.isVisible else { return false }
            return PopupPositionGeometry.pointerIsBetweenPanels(
                NSEvent.mouseLocation, main: parent.frame, preview: self.frame
            )
        }
        delegate = self
    }

    /// Automatic presentation never makes this window key. Clicking the
    /// preview explicitly transfers keyboard focus so SwiftUI's selection
    /// receives standard Copy commands instead of the main panel's responder.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape) {
            let responder = firstResponder
            let hasMarkedText = (responder as? NSTextInputClient)?.hasMarkedText() ?? false
            let unmodified = event.modifierFlags.intersection([
                .command, .control, .option, .shift,
            ]).isEmpty
            if unmodified, !hasMarkedText, !previewState.isFileConfirmationPresented,
               attachedSheet == nil, parent?.attachedSheet == nil {
                onExitCommand()
                return
            }
        }
        if event.type == .leftMouseDown {
            mouseDownScreenX = convertPoint(toScreen: event.locationInWindow).x
            if !isKeyWindow { makeKey() }
        }
        super.sendEvent(event)
        if event.type == .leftMouseUp {
            finishWidthResize()
            mouseDownScreenX = nil
        }
    }

    override func becomeKey() {
        super.becomeKey()
        (parent as? FloatingPanel)?.previewDidBecomeKey()
    }

    override func resignKey() {
        super.resignKey()
        (parent as? FloatingPanel)?.previewDidResignKey()
    }

    /// A new exact target appears immediately, even during a slow reveal.
    /// Frame following alone keeps the original presentation uninterrupted.
    func cancelArrival() {
        motionPresentation.cancel()
    }

    /// Shows the pane beside `mainPanel` (or re-positions an already
    /// visible pane), without animating geometry. Recomputing the frame on every
    /// call keeps the pane aligned with the main panel's actual height.
    func present(beside mainPanel: NSWindow) {
        guard widthResize == nil else { return }
        // The main panel can move or resize while this pane owns a sheet.
        // Apply its current frame only after AppKit retires the sheet.
        guard attachedSheet == nil else {
            return
        }
        // Adding an ordered child can make it visible synchronously. Retain
        // the need to restore before reattachment changes AppKit's visibility.
        let shouldRestoreOrdering = isPresented && !isVisible
        let width = PanelGeometry.persistedFloatingPreviewWidth(from: defaults)
        let gap = PanelGeometry.persistedFloatingPreviewGap(from: defaults)
        if lastParentFrame != mainPanel.frame || resizedAnchor?.width != width || resizedAnchor?.gap != gap {
            resizedAnchor = nil
        }
        lastParentFrame = mainPanel.frame
        let placement = PopupPositionGeometry.floatingPreviewFrame(
            beside: mainPanel.frame,
            in: mainPanel.screen?.visibleFrame,
            previewWidth: width,
            gap: gap,
            preferredPlacement: resizedAnchor?.placement,
            preferredInnerEdge: resizedAnchor?.innerEdge
        )
        self.placement = placement.placement
        if frame != placement.frame {
            setFrame(placement.frame, display: isPresented)
        }
        publishDisplayedGeometry()
        if !isPresented {
            // Adding an ordered child can reveal it synchronously. Set the
            // SwiftUI start pose before that first native visibility change.
            motionPresentation.play(duration: presentationDuration(screen ?? mainPanel.screen))
        }
        if mainPanel.childWindows?.contains(self) != true {
            mainPanel.addChildWindow(self, ordered: .above)
        }
        if !isPresented {
            orderFrontRegardless()
            isPresented = true
        } else if shouldRestoreOrdering {
            // Native sheet ordering may hide an intended-visible owner.
            // Restore ordering without replaying its arrival animation.
            motionPresentation.cancel()
            orderFrontRegardless()
        }
    }

    override func beginSheet(
        _ sheetWindow: NSWindow,
        completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil
    ) {
        // The native completion owns the actual end of the modal session.
        // A notification plus Task.yield cannot establish that attachment and
        // ordering have finished. Let the caller's close/purge intent run first.
        nativeSheetCount += 1
        super.beginSheet(sheetWindow) { [weak self] response in
            guard let self else { handler?(response); return }
            self.finishSheet(response, handler: handler)
        }
    }

    override func beginCriticalSheet(
        _ sheetWindow: NSWindow,
        completionHandler handler: ((NSApplication.ModalResponse) -> Void)?
    ) {
        nativeSheetCount += 1
        super.beginCriticalSheet(sheetWindow) { [weak self] response in
            guard let self else { handler?(response); return }
            self.finishSheet(response, handler: handler)
        }
    }

    private func finishSheet(
        _ response: NSApplication.ModalResponse,
        handler: ((NSApplication.ModalResponse) -> Void)?
    ) {
        handler?(response)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.nativeSheetCount -= 1
                if self.isPresented { self.previewState.pointerExited(.preview) }
            }
            // Return from the actual completion before applying geometry;
            // AppKit can finish its owner-frame restoration on that stack.
            guard self.isPresented, self.previewState.isOpen,
                  let parent = self.parent, parent.isVisible else { return }
            self.present(beside: parent)
        }
    }

    /// SwiftUI owns the drag gesture; AppKit supplies screen-space pointer
    /// coordinates so moving a leading edge cannot feed back into translation.
    func resizeWidth(at screenX: CGFloat) {
        guard isPresented, attachedSheet == nil, screenX.isFinite, previewState.isOpen else { return }
        if widthResize == nil {
            widthResize = (mouseDownScreenX ?? screenX, frame, placement)
            previewState.beginPreviewResize()
        }
        guard let widthResize else { return }
        let resized = PopupPositionGeometry.resizedFloatingPreviewFrame(
            from: widthResize.frame,
            placement: widthResize.placement,
            pointerDeltaX: screenX - widthResize.pointerX,
            in: parent?.screen?.visibleFrame
        )
        if frame != resized { setFrame(resized, display: true) }
        publishDisplayedGeometry()
    }

    func finishWidthResize() {
        guard let widthResize else { return }
        self.widthResize = nil
        rememberResizeAnchor(frame, placement: widthResize.placement)
        if frame.width != widthResize.frame.width {
            PanelGeometry.persistFloatingPreviewWidth(frame.width, to: defaults)
        }
        if let parent, isPresented { present(beside: parent) }
        previewState.endPreviewResize()
    }

    /// VoiceOver adjustment uses the same bounds and persistence as dragging.
    func adjustWidth(by delta: CGFloat) {
        guard isPresented, attachedSheet == nil, delta.isFinite, previewState.isOpen else { return }
        let priorWidth = frame.width
        let adjusted = PopupPositionGeometry.resizedFloatingPreviewFrame(
            from: frame, placement: placement,
            pointerDeltaX: placement == .trailing ? delta : -delta,
            in: parent?.screen?.visibleFrame
        )
        guard adjusted.width != priorWidth else { return }
        rememberResizeAnchor(adjusted, placement: placement)
        PanelGeometry.persistFloatingPreviewWidth(adjusted.width, to: defaults)
        if let parent { present(beside: parent) }
    }

    private func publishDisplayedGeometry() {
        if previewState.availablePreviewHeight != frame.height {
            previewState.availablePreviewHeight = frame.height
        }
        if previewState.displayedPreviewWidth != frame.width {
            previewState.displayedPreviewWidth = frame.width
        }
        let isLeading = placement == .leading
        if previewState.isPreviewOnLeadingSide != isLeading {
            previewState.isPreviewOnLeadingSide = isLeading
        }
    }

    private func rememberResizeAnchor(_ frame: NSRect, placement: PreviewPlacement) {
        // Recomputing a large preferred gap after mouse-up would shift the
        // handle away from the pointer. Preserve its actual inner edge until
        // the main window or an explicit width/gap preference changes.
        resizedAnchor = (
            placement == .trailing ? frame.minX : frame.maxX,
            frame.width,
            PanelGeometry.persistedFloatingPreviewGap(from: defaults),
            placement
        )
    }

    /// Orders the pane out and detaches it from its parent; the instance is
    /// reused on the next `present(beside:)`.
    func dismiss() {
        motionPresentation.cancel()
        // Explicit retirement wins over modal ownership. Mark the intent
        // closed before ending the sheet so didEndSheet cannot resurrect it.
        isPresented = false
        if let sheet = attachedSheet {
            endSheet(sheet, returnCode: .cancel)
            sheet.orderOut(nil)
        }
        // A purge, Details navigation or panel close always wins over a
        // gesture; retiring this session must not save an unfinished drag.
        widthResize = nil
        mouseDownScreenX = nil
        resizedAnchor = nil
        lastParentFrame = nil
        // A pointer-exit hide retires only the preview. Return its keyboard
        // focus before detaching, unless the whole browsing session closed.
        if isKeyWindow, let panel = parent as? FloatingPanel, panel.isPresented {
            panel.makeKey()
        }
        parent?.removeChildWindow(self)
        orderOut(nil)
        previewState.endPreviewResize()
    }

}

/// The floating preview's content root. Reads the app delegate's
/// composition and preview state through `@Observable` tracking and renders
/// the existing `HistoryPreviewView` for the exact previewed item — the
/// same fenced loader, typed failure taxonomy, and `clipy.preview.*`
/// identifiers the quick-look overlay uses. Content and window geometry
/// update without retaining a fading copy of the previously selected item.
struct FloatingPreviewRootView: View {
    let appDelegate: AppDelegate
    var motionPresentation: AppMotionPresentation?
    @Environment(\.layoutDirection) private var layoutDirection

    private var resizePaddingEdge: Edge.Set {
        let isPhysicalLeft = appDelegate.previewState.isPreviewOnLeadingSide
        return isPhysicalLeft == (layoutDirection == .leftToRight) ? .leading : .trailing
    }

    /// The per-pane icon store, built once at this AppKit boundary through
    /// the same public provider seam the main panel uses (01 §8).
    @State private var sourceIcons: SourceIconStore?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        _sourceIcons = State(
            initialValue: SourceIconStore(
                provider: SourceIconProviderFactory.makeProvider()
            )
        )
    }

    @MainActor
    static func handleExitCommand(appDelegate: AppDelegate) {
        if appDelegate.previewState.isInformationPresented {
            appDelegate.previewState.isInformationPresented = false
        } else if appDelegate.panelSurfaceState?.quickLookReference != nil {
            appDelegate.panelSurfaceState?.quickLookReference = nil
        } else {
            appDelegate.closePanel()
        }
    }

    @ViewBuilder
    var body: some View {
        if let motionPresentation {
            previewContent.modifier(PreviewMotionSurface(
                presentation: motionPresentation,
                isOnLeadingSide: appDelegate.previewState.isPreviewOnLeadingSide
            ))
        } else {
            previewContent
        }
    }

    private var previewContent: some View {
        Group {
            if let composition = appDelegate.composition,
               appDelegate.previewState.isOpen,
               let item = appDelegate.previewState.previewedItem {
                HistoryPreviewView(
                    viewState: composition.viewState,
                    previewState: appDelegate.previewState,
                    sourceIcons: sourceIcons,
                    maximumHeight: appDelegate.previewState.availablePreviewHeight,
                    fillsAvailableHeight: true,
                    preparedLoader: appDelegate.floatingPreviewLoader
                )
                .padding(resizePaddingEdge, PreviewWidthResizeHandle.thickness)
                .id(item)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // Retargeting removes the old content immediately, including
                // sensitive text and pending file confirmations.
                .transition(.identity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Use physical sides for window geometry even in an RTL interface.
        .overlay(alignment: .topLeading) {
            GeometryReader { geometry in
                PreviewWidthResizeHandle(
                    width: appDelegate.previewState.displayedPreviewWidth,
                    onDragChanged: { appDelegate.resizeFloatingPreviewWidth() },
                    onDragEnded: { appDelegate.finishFloatingPreviewWidthResize() },
                    onAdjust: { appDelegate.adjustFloatingPreviewWidth(by: $0) }
                )
                .position(
                    x: appDelegate.previewState.isPreviewOnLeadingSide
                        ? PreviewWidthResizeHandle.thickness / 2
                        : geometry.size.width - PreviewWidthResizeHandle.thickness / 2,
                    y: geometry.size.height / 2
                )
            }
        }
        .onExitCommand {
            Self.handleExitCommand(appDelegate: appDelegate)
        }
        // The preview and browsing panel share an active interaction session,
        // including keyboard focus transferred by a click inside the preview.
        .environment(\.workflowExecutionQueue, appDelegate.composition?.workflowRunner.executionQueue)
        .environment(\.appearsActive, appDelegate.previewState.isAutoOpenEnabled)
        .environment(\.displayMemoryPressure, appDelegate.panelSurfaceState?.memoryPressure ?? .normal)
        .environment(\.displayMemoryPressureGeneration, appDelegate.panelSurfaceState?.memoryPressureGeneration ?? 0)
        .onChange(of: appDelegate.panelSurfaceState?.memoryPressureGeneration, initial: true) { _, _ in
            sourceIcons?.respondToMemoryPressure(appDelegate.panelSurfaceState?.memoryPressure ?? .normal)
        }
        // The window is transparent; the content carries the solid background so
        // only the rounded corners remain transparent.
        .background { NativePanelBackground() }
        // The pane's half of the two-window pointer presence: leaving BOTH
        // windows hides the preview after its grace; re-entry cancels.
        .background(PanelMouseMovementMonitor(onMouseMoved: {
            appDelegate.previewState.pointerMoved(over: .preview)
            if let item = appDelegate.previewState.previewedItem {
                appDelegate.panelSurfaceState?.selection = item.id
            }
        }, onHover: { isInside in
            if isInside {
                appDelegate.previewState.pointerEntered(.preview)
                if appDelegate.previewState.isPointerInteractionActive,
                   let item = appDelegate.previewState.previewedItem {
                    appDelegate.panelSurfaceState?.selection = item.id
                }
            } else {
                appDelegate.previewState.pointerExited(.preview)
            }
        }))
    }
}

/// NSTrackingArea-backed pointer-movement signal for the list area
/// (Maccy's `MouseMovedViewModifer`). SwiftUI `onHover` also fires when
/// list content scrolls beneath a STATIONARY pointer, so only a real
/// `mouseMoved` event may flip the panel's input mode back to pointer
/// control; `.inVisibleRect` keeps the tracked region on the visible
/// portion without any layout updates. The non-key preview also uses this
/// responder for native entry/exit, independently of SwiftUI content churn.
/// Lives in the AppKit-owning Panel
/// layer so the presentation views stay AppKit-free (01 §8).
struct PanelMouseMovementMonitor: NSViewRepresentable {
    let onMouseMoved: () -> Void
    /// The floating preview opens without becoming key. Its tracking area
    /// must keep delivering entry/exit events while non-key,
    /// including the real departure after an exit-grace containment rescue.
    var onHover: ((Bool) -> Void)? = nil

    /// AppKit responder that forwards native movement and entry/exit.
    final class Coordinator: NSResponder {
        var onMouseMoved: () -> Void = {}
        var onHover: ((Bool) -> Void)?

        override func mouseMoved(with event: NSEvent) {
            onMouseMoved()
        }

        override func mouseEntered(with event: NSEvent) {
            onHover?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onHover?(false)
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.onMouseMoved = onMouseMoved
        coordinator.onHover = onHover
        return coordinator
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: onHover == nil
                    ? [.activeInKeyWindow, .inVisibleRect, .mouseMoved]
                    : [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
                owner: context.coordinator,
                userInfo: nil
            )
        )
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onMouseMoved = onMouseMoved
        context.coordinator.onHover = onHover
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        nsView.trackingAreas.forEach { nsView.removeTrackingArea($0) }
    }
}

extension View {
    /// Fires on real pointer movement over the modified view's visible
    /// rect — never when content scrolls beneath a stationary pointer.
    func onPanelMouseMovement(_ perform: @escaping () -> Void) -> some View {
        background(PanelMouseMovementMonitor(onMouseMoved: perform))
    }
}
