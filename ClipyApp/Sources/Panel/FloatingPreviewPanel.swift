/// FloatingPreviewPanel.swift — the transient floating preview pane: a
/// borderless, non-activating child NSPanel ordered beside the main
/// `FloatingPanel`. The redesign moves the preview OUT of the main window:
/// no in-window column, no divider, no edge opener — the main panel's
/// geometry never changes for preview.
///
/// Geometry (PopupPositionGeometry.floatingPreviewFrame): preferred width, the
/// rendered content's height, top edges aligned, trailing
/// side when the screen's visible frame has room, otherwise leading; clamped into the
/// visible frame. Placement applies with an instant, non-animated
/// `setFrame`; the SwiftUI content's own opacity fade is the only motion.
///
/// The pane is a CHILD window of the main panel, so it follows the parent's
/// ordering and can never outlive it. Showing it preserves the browsing
/// surface's focus; an intentional click enables native text-copy commands.
import AppKit
import SwiftUI

/// The floating preview window. One instance per app run, created lazily by
/// the AppDelegate on the first show and reused — dismissing only orders it
/// out.
@MainActor
final class FloatingPreviewPanel: NSPanel {

    /// Whether the pane is currently on screen.
    private(set) var isPresented = false
    private var contentHeight: CGFloat?
    private let previewState: PreviewPaneState
    private let defaults: UserDefaults
    private var placement: PreviewPlacement = .trailing
    private var lastParentFrame: NSRect?
    private var resizedAnchor: (innerEdge: CGFloat, width: CGFloat, gap: CGFloat, placement: PreviewPlacement)?
    private var mouseDownScreenX: CGFloat?
    private var widthResize: (pointerX: CGFloat, frame: NSRect, placement: PreviewPlacement)?

    func fitToContent(height: CGFloat) {
        guard height.isFinite, height > 0, contentHeight != height else { return }
        contentHeight = height
        guard widthResize == nil else { return }
        if let parent, isPresented { present(beside: parent) }
    }

    init(rootView: FloatingPreviewRootView, defaults: UserDefaults = .standard) {
        self.previewState = rootView.appDelegate.previewState
        self.defaults = defaults
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

        let hostingView = NSHostingView(rootView: rootView.appLanguage())
        hostingView.sizingOptions = []
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 12
        hostingView.layer?.masksToBounds = true
        contentView = hostingView

        // Retry's pointer can already be over this non-key window while
        // SwiftUI still reports only the main window's exit. Check actual
        // screen containment before the shared exit grace hides the pane.
        rootView.appDelegate.previewState.pointerSurfacesContainingPointer = { [weak self] in
            guard let self, self.isPresented else { return [] }
            let pointer = NSEvent.mouseLocation
            var surfaces: Set<PreviewPaneState.PreviewPointerSurface> = []
            if self.frame.contains(pointer) { surfaces.insert(.preview) }
            if let parent = self.parent, parent.isVisible, parent.frame.contains(pointer) {
                surfaces.insert(.mainPanel)
            }
            return surfaces
        }
        rootView.appDelegate.previewState.pointerIsBetweenSurfaces = { [weak self] in
            guard let self, self.isPresented, let parent = self.parent, parent.isVisible else { return false }
            return PopupPositionGeometry.pointerIsBetweenPanels(
                NSEvent.mouseLocation, main: parent.frame, preview: self.frame
            )
        }
    }

    /// Automatic presentation never makes this window key. Clicking the
    /// preview explicitly transfers keyboard focus so SwiftUI's selection
    /// receives standard Copy commands instead of the main panel's responder.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
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

    /// Shows the pane beside `mainPanel` (or re-positions an already
    /// visible pane), without animation. Recomputing the frame on every
    /// call keeps the pane aligned to the main panel while retaining its
    /// independently measured content height.
    func present(beside mainPanel: NSWindow) {
        guard widthResize == nil else { return }
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
            previewHeight: contentHeight,
            gap: gap,
            preferredPlacement: resizedAnchor?.placement,
            preferredInnerEdge: resizedAnchor?.innerEdge
        )
        self.placement = placement.placement
        setFrame(placement.frame, display: isPresented)
        publishDisplayedGeometry()
        if mainPanel.childWindows?.contains(self) != true {
            mainPanel.addChildWindow(self, ordered: .above)
        }
        orderFrontRegardless()
        isPresented = true
    }

    /// SwiftUI owns the drag gesture; AppKit supplies screen-space pointer
    /// coordinates so moving a leading edge cannot feed back into translation.
    func resizeWidth(at screenX: CGFloat) {
        guard isPresented, screenX.isFinite, previewState.isOpen else { return }
        if widthResize == nil {
            widthResize = (mouseDownScreenX ?? screenX, frame, placement)
            previewState.beginPreviewResize()
        }
        guard let widthResize else { return }
        setFrame(PopupPositionGeometry.resizedFloatingPreviewFrame(
            from: widthResize.frame,
            placement: widthResize.placement,
            pointerDeltaX: screenX - widthResize.pointerX,
            in: parent?.screen?.visibleFrame
        ), display: true)
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
        guard isPresented, delta.isFinite, previewState.isOpen else { return }
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
        previewState.displayedPreviewWidth = frame.width
        previewState.isPreviewOnLeadingSide = placement == .leading
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
        isPresented = false
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

    var body: some View {
        Group {
            if let composition = appDelegate.composition,
               appDelegate.previewState.isOpen,
               let item = appDelegate.previewState.previewedItem {
                HistoryPreviewView(
                    viewState: composition.viewState,
                    previewState: appDelegate.previewState,
                    sourceIcons: sourceIcons,
                    maximumHeight: appDelegate.previewState.availablePreviewHeight,
                    preparedLoader: appDelegate.floatingPreviewLoader
                )
                .padding(resizePaddingEdge, PreviewWidthResizeHandle.thickness)
                .id(item)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height.rounded(.up)
                } action: { height in
                    appDelegate.floatingPreviewContentHeightDidChange(height, for: item)
                }
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
            if appDelegate.previewState.isInformationPresented {
                appDelegate.previewState.isInformationPresented = false
            } else if appDelegate.panelSurfaceState?.quickLookReference != nil {
                appDelegate.panelSurfaceState?.quickLookReference = nil
            } else {
                appDelegate.closePanel()
            }
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
