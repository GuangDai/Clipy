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
import AppKit
import PresentationUI
import Testing
@testable import ClipyApp

@Suite("Hosted floating-panel frame", .serialized)
@MainActor
struct FloatingPanelFrameHostedTests {

    @Test
    func previewExpandsOnEitherSideAndPreservesTheActualMainSurface() throws {
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
}
