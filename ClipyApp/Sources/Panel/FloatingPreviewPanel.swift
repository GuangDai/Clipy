/// FloatingPreviewPanel.swift — the transient floating preview pane: a
/// borderless, non-activating child NSPanel ordered beside the main
/// `FloatingPanel`. The redesign moves the preview OUT of the main window:
/// no in-window column, no divider, no edge opener — the main panel's
/// geometry never changes for preview.
///
/// Geometry (PopupPositionGeometry.floatingPreviewFrame): fixed width, the
/// main panel's current height, top edges aligned, trailing side when the
/// screen's visible frame has room, otherwise leading; clamped into the
/// visible frame. Placement applies with an instant, non-animated
/// `setFrame`; the SwiftUI content's own opacity fade is the only motion.
///
/// The pane is a CHILD window of the main panel, so it follows the parent's
/// ordering and can never outlive it; it is not keyable, so it never steals
/// key status from the browsing surface.
import AppKit
import SwiftUI

/// The floating preview window. One instance per app run, created lazily by
/// the AppDelegate on the first show and reused — dismissing only orders it
/// out.
@MainActor
final class FloatingPreviewPanel: NSPanel {

    /// Whether the pane is currently on screen.
    private(set) var isPresented = false

    init(rootView: FloatingPreviewRootView) {
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

        // The main panel's floating traits, minus key-ability and resize:
        // no activation theft, no hide-on-deactivate, transparent chrome
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

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 12
        hostingView.layer?.masksToBounds = true
        contentView = hostingView
    }

    /// The pane is pure presentation: the browsing panel keeps key status.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows the pane beside `mainPanel` (or re-positions an already
    /// visible pane), without animation. Recomputing the frame on every
    /// call keeps the pane glued to the main panel's live height and side.
    func present(beside mainPanel: NSWindow) {
        let placement = PopupPositionGeometry.floatingPreviewFrame(
            beside: mainPanel.frame,
            in: mainPanel.screen?.visibleFrame
        )
        setFrame(placement.frame, display: isPresented)
        if mainPanel.childWindows?.contains(self) != true {
            mainPanel.addChildWindow(self, ordered: .above)
        }
        orderFrontRegardless()
        isPresented = true
    }

    /// Orders the pane out and detaches it from its parent; the instance is
    /// reused on the next `present(beside:)`.
    func dismiss() {
        parent?.removeChildWindow(self)
        orderOut(nil)
        isPresented = false
    }
}

/// The floating preview's content root. Reads the app delegate's
/// composition and preview state through `@Observable` tracking and renders
/// the existing `HistoryPreviewView` for the exact previewed item — the
/// same fenced loader, typed failure taxonomy, and `clipy.preview.*`
/// identifiers the quick-look overlay uses. The pane fades in with an
/// opacity-only 0.12 s easeOut on show and on item change (Maccy's lesson:
/// animate opacity, never window geometry).
struct FloatingPreviewRootView: View {
    let appDelegate: AppDelegate

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
                    sourceIcons: sourceIcons
                )
                .id(item)
                .transition(.opacity)
            }
        }
        .animation(
            .easeOut(duration: 0.12),
            value: appDelegate.previewState.previewedItem
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The window is transparent; the content carries the material so
        // the rounded corners show material, not the desktop behind it.
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipy.panel.floatingPreview")
        // The pane's half of the two-window pointer presence: leaving BOTH
        // windows hides the preview after its grace; re-entry cancels.
        .onHover { isInside in
            if isInside {
                appDelegate.previewState.pointerEntered(.preview)
            } else {
                appDelegate.previewState.pointerExited(.preview)
            }
        }
    }
}

/// NSTrackingArea-backed pointer-movement signal for the list area
/// (Maccy's `MouseMovedViewModifer`). SwiftUI `onHover` also fires when
/// list content scrolls beneath a STATIONARY pointer, so only a real
/// `mouseMoved` event may flip the panel's input mode back to pointer
/// control; `.inVisibleRect` keeps the tracked region on the visible
/// portion without any layout updates. Lives in the AppKit-owning Panel
/// layer so the presentation views stay AppKit-free (01 §8).
struct PanelMouseMovementMonitor: NSViewRepresentable {
    let onMouseMoved: () -> Void

    /// AppKit responder that forwards `mouseMoved` events to the closure.
    final class Coordinator: NSResponder {
        var onMouseMoved: () -> Void = {}

        override func mouseMoved(with event: NSEvent) {
            onMouseMoved()
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.onMouseMoved = onMouseMoved
        return coordinator
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved],
                owner: context.coordinator,
                userInfo: nil
            )
        )
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onMouseMoved = onMouseMoved
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
