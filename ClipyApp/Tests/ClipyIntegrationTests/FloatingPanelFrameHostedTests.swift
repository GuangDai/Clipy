/// FloatingPanelFrameHostedTests.swift — hosted Card 9C evidence for the
/// actual AppKit window boundary. The production `FloatingPanel` hosts the
/// production `PanelRootView`; assertions observe only the real `NSPanel`
/// frame and its published preview placement, never SwiftUI/AX/private trees.
///
/// The test opens through `.statusItem` with synthetic screen-space button
/// rectangles, so persisted `.lastPosition` state is neither read nor needed.
/// This proves same-process frame expansion/collapse only. It does not prove
/// WindowServer animation/rendering, cross-Space behavior, accessibility, or
/// the remaining Card 9C/9F acceptance cells.
///
/// The resize tests drive `windowDidEndLiveResize` after a programmatic
/// frame change — the same settle boundary AppKit reports when an
/// interactive resize drag ends — and save/restore PanelGeometry's
/// persisted geometry keys (the size pair plus the divider's preview
/// column width) because the hosted process shares
/// `UserDefaults.standard` with the other suites. They add same-process
/// persisted-size round-trip evidence; the interactive edge-drag gesture
/// itself remains unproved here.
import AppKit
import Testing
@testable import ClipyApp

@Suite("Hosted floating-panel frame", .serialized)
@MainActor
struct FloatingPanelFrameHostedTests {

    @Test
    func previewExpandsOnEitherSideAndPreservesTheActualMainSurface() throws {
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
            onPreviewPlacementChange: { _ in },
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
        let trailingMainSurface = panel.frame
        #expect(trailingMainSurface.width == 400)

        panel.setPreviewVisible(true)
        let trailingExpandedFrame = panel.frame
        #expect(panel.previewPlacement == .trailing)
        #expect(trailingExpandedFrame.width == 721)
        #expect(
            NSRect(
                x: trailingExpandedFrame.minX,
                y: trailingExpandedFrame.minY,
                width: 400,
                height: trailingExpandedFrame.height
            ) == trailingMainSurface
        )

        panel.setPreviewVisible(false)
        #expect(panel.frame == trailingMainSurface)
        #expect(panel.frame.width == 400)

        panel.open(
            at: .statusItem,
            statusItemButtonScreenFrame: NSRect(
                x: visibleFrame.maxX - 1,
                y: statusItemY,
                width: 1,
                height: 1
            )
        )
        let leadingMainSurface = panel.frame
        #expect(leadingMainSurface.width == 400)
        #expect(leadingMainSurface.maxX == visibleFrame.maxX)

        panel.setPreviewVisible(true)
        let leadingExpandedFrame = panel.frame
        #expect(panel.previewPlacement == .leading)
        #expect(leadingExpandedFrame.width == 721)
        #expect(
            NSRect(
                x: leadingExpandedFrame.maxX - 400,
                y: leadingExpandedFrame.minY,
                width: 400,
                height: leadingExpandedFrame.height
            ) == leadingMainSurface
        )

        panel.setPreviewVisible(false)
        #expect(panel.frame == leadingMainSurface)
        #expect(panel.frame.width == 400)
    }

    /// The closed-edge opener consumes the same published physical placement
    /// as the visible divider. Closing must preserve that side as well as the
    /// main frame; this hosted test does not simulate the edge-pull gesture.
    @Test(arguments: [PreviewSidePreference.leading, .trailing])
    func closingPreviewPreservesItsPhysicalEdgeAndMainFrame(
        side: PreviewSidePreference
    ) throws {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let visibleFrame = screen.visibleFrame
        try #require(visibleFrame.width >= 721 && visibleFrame.height >= 560)
        let restoreGeometry = isolatePersistedPanelGeometryKeys()
        defer { restoreGeometry() }

        let expectedPlacement: PreviewPlacement = side == .leading ? .leading : .trailing
        var publishedPlacement: PreviewPlacement = .trailing
        let appDelegate = AppDelegate()
        let panel = FloatingPanel(
            rootView: PanelRootView(appDelegate: appDelegate),
            previewState: appDelegate.previewState,
            onPreviewPlacementChange: { publishedPlacement = $0 },
            onClosed: {}
        )
        defer { panel.close() }
        panel.open(
            at: .statusItem,
            statusItemButtonScreenFrame: NSRect(
                x: side == .leading ? visibleFrame.maxX - 1 : visibleFrame.minX,
                y: visibleFrame.maxY - 1, width: 1, height: 1
            ),
            previewSide: side
        )
        let mainFrame = panel.frame
        #expect(mainFrame.width == 400)
        panel.setPreviewVisible(true)
        #expect(panel.previewPlacement == expectedPlacement)
        #expect(publishedPlacement == expectedPlacement)
        #expect(panel.frame == NSRect(
            x: mainFrame.minX - (side == .leading ? 321 : 0),
            y: mainFrame.minY, width: 721, height: mainFrame.height
        ))

        panel.setPreviewVisible(false)
        #expect(panel.frame == mainFrame)
        #expect(panel.previewPlacement == expectedPlacement)
        #expect(publishedPlacement == expectedPlacement,
                "the closed-edge consumer must keep the side that just closed")
    }

    /// The preview extension is the divider's persisted free-drag width,
    /// read fresh per width computation: a persisted 400-point column
    /// widens the 400-point default main surface to 400+1+400 = 801 and
    /// collapses back exactly. (The default-320 721 geometry stays pinned
    /// by `previewExpandsOnEitherSideAndPreservesTheActualMainSurface`.)
    @Test
    func previewExpansionUsesThePersistedPreviewColumnWidth() throws {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let visibleFrame = screen.visibleFrame
        try #require(visibleFrame.width >= 801)
        try #require(visibleFrame.height >= 560)

        let restorePersistedGeometry = isolatePersistedPanelGeometryKeys()
        defer { restorePersistedGeometry() }
        PanelGeometry.persistPreviewColumnWidth(400, to: .standard)

        let appDelegate = AppDelegate()
        let panel = FloatingPanel(
            rootView: PanelRootView(appDelegate: appDelegate),
            previewState: appDelegate.previewState,
            onPreviewPlacementChange: { _ in },
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
        #expect(panel.frame.width == 400)

        panel.setPreviewVisible(true)
        #expect(panel.previewPlacement == .trailing)
        #expect(panel.frame.width == 801)

        panel.setPreviewVisible(false)
        #expect(panel.frame.width == 400)
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
            onPreviewPlacementChange: { _ in },
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
        #expect(panel.frame.width == 400)
        #expect(panel.frame.height == 560)

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
            onPreviewPlacementChange: { _ in },
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

        // 200×300 is below both minimums. AppKit may already have clamped
        // the programmatic frame to `contentMinSize`; either way the settle
        // boundary persists and settles at the PanelGeometry minimums.
        var settledFrame = panel.frame
        settledFrame.size = NSSize(width: 200, height: 300)
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

    @Test func wideWindowUsesScreenLimitsAndKeepsItsSizeThroughPreview() throws {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let visible = screen.visibleFrame
        try #require(visible.width >= 900 && visible.height >= 640)
        let restore = isolatePersistedPanelGeometryKeys()
        defer { restore() }
        PanelGeometry.persistSize(contentWidth: 900, height: 640, to: .standard)
        let appDelegate = AppDelegate()
        let panel = FloatingPanel(rootView: PanelRootView(appDelegate: appDelegate),
            previewState: appDelegate.previewState, onPreviewPlacementChange: { _ in }, onClosed: {})
        defer { panel.close() }
        panel.open(at: .statusItem, statusItemButtonScreenFrame:
            NSRect(x: visible.minX, y: visible.maxY - 1, width: 1, height: 1))
        let original = panel.frame
        #expect(original.size == NSSize(width: 900, height: 640))
        #expect(panel.contentMaxSize == visible.size)
        panel.setPreviewVisible(true)
        #expect(panel.frame == original)
        #expect(panel.contentMaxSize == visible.size)
        panel.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: panel))
        #expect(PanelGeometry.persistedSize(from: .standard).contentWidth == 900)
        panel.setPreviewVisible(false)
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
            previewState: appDelegate.previewState, onPreviewPlacementChange: { _ in }, onClosed: {})
        defer { panel.close() }
        panel.open(at: .statusItem, statusItemButtonScreenFrame:
            NSRect(x: visible.minX, y: visible.maxY - 1, width: 1, height: 1))
        #expect(panel.frame.size == visible.size)
        panel.windowDidChangeScreen(Notification(name: NSWindow.didChangeScreenNotification, object: panel))
        let saved = PanelGeometry.persistedSize(from: .standard)
        #expect(saved.contentWidth == preferred.width)
        #expect(saved.height == preferred.height)
        panel.setPreviewVisible(true)
        #expect(panel.frame.size == visible.size)
        panel.setPreviewVisible(false)
        #expect(panel.frame.size == visible.size)
    }

    @Test(arguments: [false, true])
    func userChosenWindowOrDividerSizeSurvivesPreviewCycles(resizeWindow: Bool) throws {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let visible = screen.visibleFrame
        try #require(visible.width >= 900 && visible.height >= 640)
        let restore = isolatePersistedPanelGeometryKeys()
        defer { restore() }
        PanelGeometry.persistSize(contentWidth: resizeWindow ? 400 : 900, height: 640, to: .standard)
        let appDelegate = AppDelegate()
        let panel = FloatingPanel(rootView: PanelRootView(appDelegate: appDelegate),
            previewState: appDelegate.previewState, onPreviewPlacementChange: { _ in }, onClosed: {})
        defer { panel.close() }
        let button = NSRect(x: visible.minX, y: visible.maxY - 1, width: 1, height: 1)
        panel.open(at: .statusItem, statusItemButtonScreenFrame: button)
        panel.setPreviewVisible(true)
        if resizeWindow {
            // An actual outer-window resize supersedes the automatic 321pt
            // addition. Closing preview must retain the chosen 900pt width.
            var resized = panel.frame
            resized.size.width = 900
            panel.setFrame(resized, display: false)
            panel.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: panel))
        } else {
            // Equivalent to settling the divider at the list's 360pt floor.
            // It already fits, so reopening must not add 40pt for a wider list.
            PanelGeometry.persistPreviewColumnWidth(539, to: .standard)
        }
        let chosen = panel.frame
        #expect(chosen.width == 900)
        panel.setPreviewVisible(false)
        #expect(panel.frame == chosen)
        panel.setPreviewVisible(true)
        #expect(panel.frame == chosen)
        panel.close()
        panel.open(at: .statusItem, statusItemButtonScreenFrame: button)
        #expect(panel.frame == chosen)
        panel.setPreviewVisible(true)
        #expect(panel.frame == chosen)
    }

    /// Saves and clears PanelGeometry's persisted panel-geometry keys (the
    /// two size keys plus the divider's preview column width) and returns
    /// the restore action — the hosted process shares
    /// `UserDefaults.standard` with the other suites, so the production
    /// keys must leave no residue behind a passing or throwing test.
    private func isolatePersistedPanelGeometryKeys() -> () -> Void {
        let defaults = UserDefaults.standard
        let keys = [
            PanelGeometry.panelContentWidthDefaultsKey,
            PanelGeometry.panelHeightDefaultsKey,
            PanelGeometry.previewColumnWidthDefaultsKey,
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
