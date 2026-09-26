/// FloatingPreviewPlacementTests — the floating preview pane's pure
/// side-picking and clamping geometry (`PopupPositionGeometry.floatingPreviewFrame`):
/// preferred width (340pt by default), content-driven height within the screen, trailing
/// side when the visible frame has room (width + gap), otherwise
/// leading, always clamped into the visible frame.
import AppKit
@testable import ClipyApp
import Testing

@Suite("Floating preview placement geometry")
struct FloatingPreviewPlacementTests {
    @Test func customWidthFitsTheScreenIncludingNegativeOrigins() {
        let screen = NSRect(x: -800, y: -200, width: 800, height: 700)
        let panel = NSRect(x: -400, y: 0, width: 360, height: 420)
        let preview = PopupPositionGeometry.floatingPreviewFrame(
            beside: panel, in: screen, previewWidth: 10_000
        )
        #expect(preview.frame.width == screen.width)
        #expect(screen.contains(preview.frame))
    }

    @Test func trailingResizeKeepsTheInnerEdgeAndClampsAtTheDisplay() {
        let initial = NSRect(x: 700, y: 200, width: 340, height: 400)
        let wider = PopupPositionGeometry.resizedFloatingPreviewFrame(
            from: initial, placement: .trailing, pointerDeltaX: 100, in: mainFrame
        )
        #expect(wider.width == 440)
        #expect(wider.minX == initial.minX)
        #expect(wider.maxY == initial.maxY)
        let limited = PopupPositionGeometry.resizedFloatingPreviewFrame(
            from: initial, placement: .trailing, pointerDeltaX: 10_000, in: mainFrame
        )
        #expect(limited.minX == initial.minX)
        #expect(limited.maxX == mainFrame.maxX)
        let narrow = PopupPositionGeometry.resizedFloatingPreviewFrame(
            from: initial, placement: .trailing, pointerDeltaX: -10_000, in: mainFrame
        )
        #expect(narrow.width == PanelGeometry.minimumPersistedFloatingPreviewWidth)
    }

    @Test func leadingResizeUsesScreenDeltaWithoutMovingTheInnerEdge() {
        let initial = NSRect(x: -1_000, y: 0, width: 340, height: 400)
        let wider = PopupPositionGeometry.resizedFloatingPreviewFrame(
            from: initial, placement: .leading, pointerDeltaX: -100, in: negativeOriginFrame
        )
        #expect(wider.width == 440)
        #expect(wider.maxX == initial.maxX)
        #expect(wider.maxY == initial.maxY)
        let limited = PopupPositionGeometry.resizedFloatingPreviewFrame(
            from: initial, placement: .leading, pointerDeltaX: -10_000, in: negativeOriginFrame
        )
        #expect(limited.minX == negativeOriginFrame.minX)
        #expect(limited.maxX == initial.maxX)
    }

    @Test func finishingALeadingResizeCanKeepItsChosenSide() {
        let panel = NSRect(x: 400, y: 100, width: 360, height: 420)
        let fitted = PopupPositionGeometry.floatingPreviewFrame(
            beside: panel, in: mainFrame, previewWidth: 200, preferredPlacement: .leading
        )
        #expect(fitted.placement == .leading)
        #expect(fitted.frame.maxX < panel.minX)
    }

    @Test func pointerGapCoversTheRouteButNotOutsideOrOverlappingWindows() {
        let main = NSRect(x: 100, y: 100, width: 360, height: 420)
        let trailing = NSRect(x: 500, y: 400, width: 340, height: 120)
        #expect(PopupPositionGeometry.pointerIsBetweenPanels(
            NSPoint(x: 480, y: 200), main: main, preview: trailing))
        #expect(!PopupPositionGeometry.pointerIsBetweenPanels(
            NSPoint(x: 480, y: 80), main: main, preview: trailing))
        #expect(!PopupPositionGeometry.pointerIsBetweenPanels(
            NSPoint(x: 900, y: 200), main: main, preview: trailing))
        let leading = NSRect(x: -260, y: 200, width: 340, height: 320)
        #expect(PopupPositionGeometry.pointerIsBetweenPanels(
            NSPoint(x: 90, y: 300), main: main, preview: leading))
        #expect(!PopupPositionGeometry.pointerIsBetweenPanels(
            NSPoint(x: 300, y: 300), main: main, preview: main))
    }

    @Test func preferredGapFitsAvailableSpaceWithoutMovingTheMainPanel() {
        let screen = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let panel = NSRect(x: 20, y: 200, width: 360, height: 420)
        let touching = PopupPositionGeometry.floatingPreviewFrame(beside: panel, in: screen, gap: 0)
        #expect(touching.frame.minX == panel.maxX)
        let spacious = PopupPositionGeometry.floatingPreviewFrame(beside: panel, in: screen, gap: 10_000)
        #expect(spacious.frame.maxX == screen.maxX)
        #expect(spacious.frame.minX >= panel.maxX)
        #expect(screen.contains(spacious.frame))
    }

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
        // 1_000 + 360 + 2 + 340 > 1_440, so the pane flips to the leading
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

    @Test func shortContentDoesNotGrowToAnArbitraryMinimum() {
        let panel = NSRect(x: 100, y: 600, width: 360, height: 111)
        let preview = PopupPositionGeometry.floatingPreviewFrame(
            beside: panel, in: mainFrame, previewHeight: 62
        ).frame
        #expect(preview.height == 62)
        #expect(preview.maxY == panel.maxY)
        #expect(mainFrame.contains(preview))
    }

    @Test func shortScreenLimitsPreviewHeightAndKeepsItVisible() {
        let screen = NSRect(x: -800, y: -400, width: 800, height: 300)
        let panel = NSRect(x: -790, y: -220, width: 360, height: 111)
        let preview = PopupPositionGeometry.floatingPreviewFrame(
            beside: panel, in: screen, previewHeight: 600
        ).frame
        #expect(preview.height == 300)
        #expect(screen.contains(preview))
    }
}
