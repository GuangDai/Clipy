/// FloatingPanelFrameHostedTests.swift — hosted Card 9C evidence for the
/// actual AppKit window boundary. The production `FloatingPanel` hosts the
/// production `PanelRootView`; assertions observe only the real `NSPanel`
/// frames, never SwiftUI/AX/private trees.
///
/// The test opens through `.statusItem` with synthetic screen-space button
/// rectangles, so persisted `.lastPosition` state is neither read nor needed.
/// This proves same-process frame behavior only. It does not prove
/// WindowServer animation/rendering, cross-Space behavior, accessibility, or
/// the remaining Card 9C/9F acceptance cells.
///
/// The preview is the transient `FloatingPreviewPanel` child window: the
/// preview tests here assert the pane presents beside the panel at the pure
/// geometry's frame and that the MAIN panel's frame never changes for
/// preview. The side-picking math itself lives in the pure
/// FloatingPreviewPlacementTests.
///
/// The resize tests drive `windowDidEndLiveResize` after a programmatic
/// frame change — the same settle boundary AppKit reports when an
/// interactive resize drag ends — and save/restore PanelGeometry's
/// persisted geometry keys because the hosted process shares
/// `UserDefaults.standard` with the other suites. They add same-process
/// persisted-size round-trip evidence; the interactive edge-drag gesture
/// itself remains unproved here. The fit tests drive `fitToContent`
/// directly (the AppDelegate's coalesced caller is thin wiring) and pin
/// the top-edge-pinned, floor/ceiling-clamped, live-resize-suspended
/// semantics; the persisted height is the content-fit CEILING, so a reopen
/// starts at the ceiling and re-fits from the retained demand.
import AppKit
import Testing
@testable import ClipyApp

@Suite("Hosted floating-panel frame", .serialized)
@MainActor
struct FloatingPanelFrameHostedTests {

    /// The floating preview pane presents beside the panel on the trailing
    /// side at the pure geometry's frame, and the main panel's frame never
    /// changes for preview (the redesign moved preview out of the window).
    @Test
    func floatingPreviewPresentsTrailingWithoutResizingTheMainPanel() throws {
        let restoreGeometry = isolatePersistedPanelGeometryKeys()
        defer { restoreGeometry() }
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let visibleFrame = screen.visibleFrame
        try #require(visibleFrame.width >= 721)
        try #require(visibleFrame.height >= 560)

        let appDelegate = AppDelegate()
        let panel = FloatingPanel(
            rootView: PanelRootView(appDelegate: appDelegate),
            previewState: appDelegate.previewState,
            onClosed: {}
        )
        defer { panel.close() }

        panel.open(
            at: .statusItem,
            statusItemButtonScreenFrame: NSRect(
                x: visibleFrame.minX,
                y: visibleFrame.maxY - 1,
                width: 1,
                height: 1
            )
        )
        let mainFrame = panel.frame
        #expect(mainFrame.width == 360)

        let preview = FloatingPreviewPanel(
            rootView: FloatingPreviewRootView(appDelegate: appDelegate)
        )
        defer { preview.dismiss() }
        preview.present(beside: panel)
        #expect(preview.isPresented)
        #expect(panel.childWindows?.contains(preview) == true)
        let expected = PopupPositionGeometry.floatingPreviewFrame(
            beside: mainFrame,
            in: visibleFrame
        )
        #expect(expected.placement == .trailing)
        #expect(preview.frame == expected.frame)
        #expect(panel.frame == mainFrame)

        preview.dismiss()
        #expect(!preview.isPresented)
        #expect(panel.childWindows?.contains(preview) != true)
        #expect(panel.frame == mainFrame)
    }

    /// A panel pinned to the screen's right edge leaves no trailing room:
    /// the pane flips to the leading side while the main frame stays put.
    @Test
    func floatingPreviewFlipsLeadingAtTheScreensRightEdge() throws {
        let restoreGeometry = isolatePersistedPanelGeometryKeys()
        defer { restoreGeometry() }
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let visibleFrame = screen.visibleFrame
        try #require(visibleFrame.width >= 721)
        try #require(visibleFrame.height >= 560)

        let appDelegate = AppDelegate()
        let panel = FloatingPanel(
            rootView: PanelRootView(appDelegate: appDelegate),
            previewState: appDelegate.previewState,
            onClosed: {}
        )
        defer { panel.close() }

        panel.open(
            at: .statusItem,
            statusItemButtonScreenFrame: NSRect(
                x: visibleFrame.maxX - 1,
                y: visibleFrame.maxY - 1,
                width: 1,
                height: 1
            )
        )
        let mainFrame = panel.frame
        #expect(mainFrame.width == 360)
        #expect(mainFrame.maxX == visibleFrame.maxX)

        let preview = FloatingPreviewPanel(
            rootView: FloatingPreviewRootView(appDelegate: appDelegate)
        )
        defer { preview.dismiss() }
        preview.present(beside: panel)
        let expected = PopupPositionGeometry.floatingPreviewFrame(
            beside: mainFrame,
            in: visibleFrame
        )
        #expect(expected.placement == .leading)
        #expect(preview.frame == expected.frame)
        #expect(preview.frame.maxX < mainFrame.minX)
        #expect(panel.frame == mainFrame)
    }

    @Test
    func userResizeSettlePersistsAndReopensAtTheSettledSize() throws {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let visibleFrame = screen.visibleFrame
        try #require(visibleFrame.width >= 721)
        try #require(visibleFrame.height >= 640)

        let restorePersistedSize = isolatePersistedPanelGeometryKeys()
        defer { restorePersistedSize() }

        let appDelegate = AppDelegate()
        let panel = FloatingPanel(
            rootView: PanelRootView(appDelegate: appDelegate),
            previewState: appDelegate.previewState,
            onClosed: {}
        )
        defer { panel.close() }

        let statusItemY = visibleFrame.maxY - 1
        panel.open(
            at: .statusItem,
            statusItemButtonScreenFrame: NSRect(
                x: visibleFrame.minX,
                y: statusItemY,
                width: 1,
                height: 1
            )
        )
        // No persisted keys: the open size is the PanelGeometry default.
        #expect(panel.frame.width == 360)
        #expect(panel.frame.height == 420)

        // The settle boundary an interactive drag ends at: the frame has
        // already moved (AppKit resizes live), then the delegate is told
        // the live resize ended.
        var settledFrame = panel.frame
        settledFrame.size = NSSize(width: 480, height: 640)
        panel.setFrame(settledFrame, display: false)
        panel.windowDidEndLiveResize(
            Notification(name: NSWindow.didEndLiveResizeNotification, object: panel)
        )
        // 480×640 is inside the resizable bounds: no snap-back correction.
        #expect(panel.frame.width == 480)
        #expect(panel.frame.height == 640)

        panel.close()
        panel.open(
            at: .statusItem,
            statusItemButtonScreenFrame: NSRect(
                x: visibleFrame.minX,
                y: statusItemY,
                width: 1,
                height: 1
            )
        )
        #expect(panel.frame.width == 480)
        #expect(panel.frame.height == 640)
    }

    @Test
    func userResizeBelowTheMinimumClampsAndPersistsTheClampedSize() throws {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let visibleFrame = screen.visibleFrame
        try #require(visibleFrame.width >= 721)
        try #require(visibleFrame.height >= 560)

        let restorePersistedSize = isolatePersistedPanelGeometryKeys()
        defer { restorePersistedSize() }

        let appDelegate = AppDelegate()
        let panel = FloatingPanel(
            rootView: PanelRootView(appDelegate: appDelegate),
            previewState: appDelegate.previewState,
            onClosed: {}
        )
        defer { panel.close() }

        panel.open(
            at: .statusItem,
            statusItemButtonScreenFrame: NSRect(
                x: visibleFrame.minX,
                y: visibleFrame.maxY - 1,
                width: 1,
                height: 1
            )
        )

        // 200×40 is below both minimums (the height floor is the content-fit
        // floor, header + one text row + slack — no longer 420). AppKit may
        // already have clamped the programmatic frame to `contentMinSize`;
        // either way the settle boundary persists and settles at the
        // PanelGeometry minimums.
        var settledFrame = panel.frame
        settledFrame.size = NSSize(width: 200, height: 40)
        panel.setFrame(settledFrame, display: false)
        panel.windowDidEndLiveResize(
            Notification(name: NSWindow.didEndLiveResizeNotification, object: panel)
        )

        #expect(panel.frame.width == PanelGeometry.minimumContentWidth)
        #expect(panel.frame.height == PanelGeometry.minimumHeight)
        let persisted = PanelGeometry.persistedSize(from: .standard)
        #expect(persisted.contentWidth == PanelGeometry.minimumContentWidth)
        #expect(persisted.height == PanelGeometry.minimumHeight)

        panel.close()
        panel.open(
            at: .statusItem,
            statusItemButtonScreenFrame: NSRect(
                x: visibleFrame.minX,
                y: visibleFrame.maxY - 1,
                width: 1,
                height: 1
            )
        )
        #expect(panel.frame.width == PanelGeometry.minimumContentWidth)
        #expect(panel.frame.height == PanelGeometry.minimumHeight)
    }

    /// The content fit applies instantly, pins the panel's TOP edge, and
    /// clamps into [floor, persisted ceiling] (PanelContentFit). The pure
    /// height math itself lives in PresentationTests/PanelContentFitTests.
    @Test
    func contentFitPinsTheTopEdgeAndClampsIntoFloorAndCeiling() throws {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let visibleFrame = screen.visibleFrame
        try #require(visibleFrame.width >= 721)
        try #require(visibleFrame.height >= 560)

        let restorePersistedSize = isolatePersistedPanelGeometryKeys()
        defer { restorePersistedSize() }

        let appDelegate = AppDelegate()
        let panel = FloatingPanel(
            rootView: PanelRootView(appDelegate: appDelegate),
            previewState: appDelegate.previewState,
            onClosed: {}
        )
        defer { panel.close() }

        panel.open(
            at: .statusItem,
            statusItemButtonScreenFrame: NSRect(
                x: visibleFrame.minX,
                y: visibleFrame.maxY - 1,
                width: 1,
                height: 1
            )
        )
        let top = panel.frame.maxY

        panel.fitToContent(idealHeight: 200)
        #expect(panel.frame.height == 200)
        #expect(panel.frame.maxY == top)

        // Below the floor the panel still fits at the floor, top-pinned.
        panel.fitToContent(idealHeight: 10)
        #expect(panel.frame.height == PanelGeometry.minimumHeight)
        #expect(panel.frame.maxY == top)

        // Above the persisted ceiling (the default 420 with no persisted
        // keys) the panel stops at the ceiling — the persisted height is a
        // MAXIMUM, not a fixed height.
        panel.fitToContent(idealHeight: 5_000)
        #expect(panel.frame.height == PanelGeometry.height)
        #expect(panel.frame.maxY == top)
    }

    /// The full-height destination demand (Details/quick-look publishes
    /// `PanelContentFit.fullHeightDemand`) clamps to the persisted ceiling
    /// through the real window: a row-fitted panel grows to the ceiling,
    /// top-pinned, and a later row-derived demand refits it back down.
    @Test
    func fullHeightDestinationDemandClampsToThePersistedCeiling() throws {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let visibleFrame = screen.visibleFrame
        try #require(visibleFrame.width >= 721)
        try #require(visibleFrame.height >= 560)

        let restorePersistedSize = isolatePersistedPanelGeometryKeys()
        defer { restorePersistedSize() }

        let appDelegate = AppDelegate()
        let panel = FloatingPanel(
            rootView: PanelRootView(appDelegate: appDelegate),
            previewState: appDelegate.previewState,
            onClosed: {}
        )
        defer { panel.close() }

        panel.open(
            at: .statusItem,
            statusItemButtonScreenFrame: NSRect(
                x: visibleFrame.minX,
                y: visibleFrame.maxY - 1,
                width: 1,
                height: 1
            )
        )
        panel.fitToContent(idealHeight: 200)
        #expect(panel.frame.height == 200)
        let top = panel.frame.maxY

        // Entering a full-height destination: the unbounded demand stops at
        // the persisted ceiling (the default 420 with no persisted keys).
        panel.fitToContent(idealHeight: PanelContentFit.fullHeightDemand)
        #expect(panel.frame.height == PanelGeometry.height)
        #expect(panel.frame.maxY == top)

        // Leaving the destination refits to the row-derived demand.
        panel.fitToContent(idealHeight: 200)
        #expect(panel.frame.height == 200)
        #expect(panel.frame.maxY == top)
    }

    /// During the user's live resize the fit is suspended; at the settle
    /// boundary the dragged height persists as the new ceiling and the
    /// retained demand re-applies (content smaller than the new ceiling
    /// shrinks the panel — Maccy's popup semantics).
    @Test
    func contentFitIsSuspendedDuringLiveResizeAndReappliedAtTheSettle() throws {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let visibleFrame = screen.visibleFrame
        try #require(visibleFrame.width >= 721)
        try #require(visibleFrame.height >= 640)

        let restorePersistedSize = isolatePersistedPanelGeometryKeys()
        defer { restorePersistedSize() }

        let appDelegate = AppDelegate()
        let panel = FloatingPanel(
            rootView: PanelRootView(appDelegate: appDelegate),
            previewState: appDelegate.previewState,
            onClosed: {}
        )
        defer { panel.close() }

        let button = NSRect(
            x: visibleFrame.minX, y: visibleFrame.maxY - 1, width: 1, height: 1
        )
        panel.open(at: .statusItem, statusItemButtonScreenFrame: button)
        panel.fitToContent(idealHeight: 200)
        #expect(panel.frame.height == 200)

        panel.windowWillStartLiveResize(
            Notification(name: NSWindow.willStartLiveResizeNotification, object: panel)
        )
        // The drag's live frame (AppKit resizes live), then a mid-drag fit
        // demand — suspended, so the dragged frame stands.
        var draggedFrame = panel.frame
        draggedFrame.size.height = 640
        draggedFrame.origin.y = panel.frame.maxY - draggedFrame.height
        panel.setFrame(draggedFrame, display: false)
        panel.fitToContent(idealHeight: 300)
        #expect(panel.frame.height == 640)

        let draggedTop = panel.frame.maxY
        panel.windowDidEndLiveResize(
            Notification(name: NSWindow.didEndLiveResizeNotification, object: panel)
        )
        // The dragged 640 is the persisted ceiling; the retained 300 demand
        // re-applies immediately, top-pinned.
        #expect(PanelGeometry.persistedSize(from: .standard).height == 640)
        #expect(panel.frame.height == 300)
        #expect(panel.frame.maxY == draggedTop)

        // Reopening starts at the persisted ceiling, then the retained
        // demand fits the height again.
        panel.close()
        panel.open(at: .statusItem, statusItemButtonScreenFrame: button)
        #expect(PanelGeometry.persistedSize(from: .standard).height == 640)
        #expect(panel.frame.height == 300)
    }

    /// The floating preview pane follows a content-fit height change: the
    /// panel's frame-change hook re-places it at the pure geometry's frame
    /// (same side logic and top alignment, with a usable preview minimum).
    @Test
    func floatingPreviewFollowsAFittedMainPanelHeight() throws {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let visibleFrame = screen.visibleFrame
        try #require(visibleFrame.width >= 721)
        try #require(visibleFrame.height >= 560)

        let restorePersistedSize = isolatePersistedPanelGeometryKeys()
        defer { restorePersistedSize() }

        let appDelegate = AppDelegate()
        let box = PreviewFollowBox()
        let panel = FloatingPanel(
            rootView: PanelRootView(appDelegate: appDelegate),
            previewState: appDelegate.previewState,
            onFrameChanged: { [box] in
                guard let panel = box.panel,
                      let preview = box.preview,
                      preview.isPresented
                else { return }
                preview.present(beside: panel)
            },
            onClosed: {}
        )
        box.panel = panel
        defer { panel.close() }

        panel.open(
            at: .statusItem,
            statusItemButtonScreenFrame: NSRect(
                x: visibleFrame.minX,
                y: visibleFrame.maxY - 1,
                width: 1,
                height: 1
            )
        )
        let preview = FloatingPreviewPanel(
            rootView: FloatingPreviewRootView(appDelegate: appDelegate)
        )
        box.preview = preview
        defer { preview.dismiss() }
        preview.present(beside: panel)
        #expect(preview.frame.height == panel.frame.height)

        panel.fitToContent(idealHeight: 200)
        #expect(panel.frame.height == 200)
        #expect(preview.frame.height == PanelGeometry.floatingPreviewMinimumHeight)
        #expect(preview.frame.maxY == panel.frame.maxY)
        let expected = PopupPositionGeometry.floatingPreviewFrame(
            beside: panel.frame,
            in: visibleFrame
        )
        #expect(preview.frame == expected.frame)
    }

    @Test func wideWindowUsesScreenLimitsAndKeepsItsSizeThroughPreview() throws {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let visible = screen.visibleFrame
        try #require(visible.width >= 900 && visible.height >= 640)
        let restore = isolatePersistedPanelGeometryKeys()
        defer { restore() }
        PanelGeometry.persistSize(contentWidth: 900, height: 640, to: .standard)
        let appDelegate = AppDelegate()
        let panel = FloatingPanel(rootView: PanelRootView(appDelegate: appDelegate),
            previewState: appDelegate.previewState, onClosed: {})
        defer { panel.close() }
        panel.open(at: .statusItem, statusItemButtonScreenFrame:
            NSRect(x: visible.minX, y: visible.maxY - 1, width: 1, height: 1))
        let original = panel.frame
        #expect(original.size == NSSize(width: 900, height: 640))
        #expect(panel.contentMaxSize == visible.size)
        // The floating preview lives in its own child window: presenting or
        // dismissing it never changes the main panel's frame or limits.
        let preview = FloatingPreviewPanel(
            rootView: FloatingPreviewRootView(appDelegate: appDelegate)
        )
        defer { preview.dismiss() }
        preview.present(beside: panel)
        #expect(panel.frame == original)
        #expect(panel.contentMaxSize == visible.size)
        panel.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: panel))
        #expect(PanelGeometry.persistedSize(from: .standard).contentWidth == 900)
        preview.dismiss()
        #expect(panel.frame == original)
    }

    @Test func fittingALargerPreferredSizeDoesNotRewriteItOnScreenChange() throws {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let visible = screen.visibleFrame
        let restore = isolatePersistedPanelGeometryKeys()
        defer { restore() }
        let preferred = NSSize(width: visible.width + 500, height: visible.height + 500)
        PanelGeometry.persistSize(contentWidth: preferred.width, height: preferred.height, to: .standard)
        let appDelegate = AppDelegate()
        let panel = FloatingPanel(rootView: PanelRootView(appDelegate: appDelegate),
            previewState: appDelegate.previewState, onClosed: {})
        defer { panel.close() }
        panel.open(at: .statusItem, statusItemButtonScreenFrame:
            NSRect(x: visible.minX, y: visible.maxY - 1, width: 1, height: 1))
        #expect(panel.frame.size == visible.size)
        panel.windowDidChangeScreen(Notification(name: NSWindow.didChangeScreenNotification, object: panel))
        let saved = PanelGeometry.persistedSize(from: .standard)
        #expect(saved.contentWidth == preferred.width)
        #expect(saved.height == preferred.height)
        let preview = FloatingPreviewPanel(
            rootView: FloatingPreviewRootView(appDelegate: appDelegate)
        )
        defer { preview.dismiss() }
        preview.present(beside: panel)
        #expect(panel.frame.size == visible.size)
        preview.dismiss()
        #expect(panel.frame.size == visible.size)
    }

    @Test func userChosenWindowSizeSurvivesFloatingPreviewCycles() throws {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let visible = screen.visibleFrame
        try #require(visible.width >= 900 && visible.height >= 640)
        let restore = isolatePersistedPanelGeometryKeys()
        defer { restore() }
        PanelGeometry.persistSize(contentWidth: 900, height: 640, to: .standard)
        let appDelegate = AppDelegate()
        let panel = FloatingPanel(rootView: PanelRootView(appDelegate: appDelegate),
            previewState: appDelegate.previewState, onClosed: {})
        defer { panel.close() }
        let button = NSRect(x: visible.minX, y: visible.maxY - 1, width: 1, height: 1)
        panel.open(at: .statusItem, statusItemButtonScreenFrame: button)
        let chosen = panel.frame
        #expect(chosen.width == 900)
        // Present/dismiss cycles of the floating preview pane must leave the
        // user-chosen main-panel frame and its persisted size untouched.
        let preview = FloatingPreviewPanel(
            rootView: FloatingPreviewRootView(appDelegate: appDelegate)
        )
        defer { preview.dismiss() }
        preview.present(beside: panel)
        #expect(panel.frame == chosen)
        preview.dismiss()
        #expect(panel.frame == chosen)
        preview.present(beside: panel)
        #expect(panel.frame == chosen)
        panel.close()
        panel.open(at: .statusItem, statusItemButtonScreenFrame: button)
        #expect(panel.frame == chosen)
        preview.present(beside: panel)
        #expect(panel.frame == chosen)
    }

    /// Saves and clears PanelGeometry's persisted panel-geometry keys and
    /// returns the restore action — the hosted process shares
    /// `UserDefaults.standard` with the other suites, so the production
    /// keys must leave no residue behind a passing or throwing test.
    private func isolatePersistedPanelGeometryKeys() -> () -> Void {
        let defaults = UserDefaults.standard
        let keys = [
            PanelGeometry.panelContentWidthDefaultsKey,
            PanelGeometry.panelHeightDefaultsKey,
            "clipy.panelAnchorX",
            "clipy.panelAnchorY",
        ]
        let priorValues = keys.map { key in (key, defaults.object(forKey: key)) }
        for key in keys {
            defaults.removeObject(forKey: key)
        }
        return {
            for (key, value) in priorValues {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
    }
}

/// Mutable holder letting a FloatingPanel's frame-change closure reach the
/// preview pane created after the panel (the closure is captured at panel
/// construction time). Stands in for the AppDelegate's
/// panel→preview re-place wiring.
@MainActor
private final class PreviewFollowBox {
    var panel: FloatingPanel?
    var preview: FloatingPreviewPanel?
}
