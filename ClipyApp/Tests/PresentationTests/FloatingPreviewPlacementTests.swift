/// FloatingPreviewPlacementTests — the floating preview pane's pure
/// side-picking and clamping geometry (`PopupPositionGeometry.floatingPreviewFrame`):
/// fixed 340pt width, the main panel's height, top edges aligned, trailing
/// side when the visible frame has room (width + 8pt gap), otherwise
/// leading, always clamped into the visible frame.
import AppKit
@testable import ClipyApp
import Testing

@Suite("Floating preview placement geometry")
struct FloatingPreviewPlacementTests {

    private let mainFrame = NSRect(x: 0, y: 0, width: 1_440, height: 875)
    private let negativeOriginFrame = NSRect(x: -1_600, y: -200, width: 1_600, height: 1_000)

    @Test func trailingSideWhenTheRightSideHasRoom() {
        let panel = NSRect(x: 100, y: 200, width: 360, height: 560)
        let placement = PopupPositionGeometry.floatingPreviewFrame(
            beside: panel, in: mainFrame
        )
        #expect(placement.placement == .trailing)
        #expect(placement.frame == NSRect(
            x: 100 + 360 + PanelGeometry.floatingPreviewGap,
            y: 200,
            width: PanelGeometry.floatingPreviewWidth,
            height: 560
        ))
    }

    @Test func leadingSideAtTheScreensRightEdge() {
        // 1_000 + 360 + 8 + 340 > 1_440, so the pane flips to the leading
        // side — the main panel never moves.
        let panel = NSRect(x: 1_000, y: 200, width: 360, height: 560)
        let placement = PopupPositionGeometry.floatingPreviewFrame(
            beside: panel, in: mainFrame
        )
        #expect(placement.placement == .leading)
        #expect(placement.frame == NSRect(
            x: 1_000 - PanelGeometry.floatingPreviewGap - PanelGeometry.floatingPreviewWidth,
            y: 200,
            width: PanelGeometry.floatingPreviewWidth,
            height: 560
        ))
    }

    @Test func leadingSideAtANegativeOriginScreensRightEdge() {
        let panel = NSRect(x: -360, y: 240, width: 360, height: 560)
        let placement = PopupPositionGeometry.floatingPreviewFrame(
            beside: panel, in: negativeOriginFrame
        )
        #expect(placement.placement == .leading)
        #expect(negativeOriginFrame.contains(placement.frame))
        #expect(placement.frame.maxX + PanelGeometry.floatingPreviewGap
            == panel.minX)
    }

    @Test func aPanelAtTheLeftEdgeKeepsTrailing() {
        // Leading would cross the screen's left edge; trailing has room.
        let panel = NSRect(x: 0, y: 100, width: 360, height: 560)
        let placement = PopupPositionGeometry.floatingPreviewFrame(
            beside: panel, in: mainFrame
        )
        #expect(placement.placement == .trailing)
        #expect(mainFrame.contains(placement.frame))
    }

    @Test func neitherSideFittingStillClampsIntoTheVisibleFrame() {
        // A 700pt-wide screen cannot hold panel + gap + pane on either
        // side; trailing does not fit, so the choice is leading, and the
        // clamp pulls the leading-side pane fully inside.
        let screen = NSRect(x: -700, y: 0, width: 700, height: 800)
        let panel = NSRect(x: -650, y: 100, width: 600, height: 560)
        let placement = PopupPositionGeometry.floatingPreviewFrame(
            beside: panel, in: screen
        )
        #expect(placement.placement == .leading)
        #expect(screen.contains(placement.frame))
    }

    @Test func withoutAScreenThePaneGoesTrailingUnclamped() {
        let panel = NSRect(x: 1_000, y: 200, width: 360, height: 560)
        let placement = PopupPositionGeometry.floatingPreviewFrame(
            beside: panel, in: nil
        )
        #expect(placement.placement == .trailing)
        #expect(placement.frame.minX
            == panel.maxX + PanelGeometry.floatingPreviewGap)
        #expect(placement.frame.minY == panel.minY)
    }

    @Test func topEdgesAlignAndHeightFollowsTheMainPanel() {
        let panel = NSRect(x: 100, y: 50, width: 500, height: 700)
        let placement = PopupPositionGeometry.floatingPreviewFrame(
            beside: panel, in: mainFrame
        )
        #expect(placement.frame.maxY == panel.maxY)
        #expect(placement.frame.height == panel.height)
        #expect(placement.frame.width == PanelGeometry.floatingPreviewWidth)
    }
}
