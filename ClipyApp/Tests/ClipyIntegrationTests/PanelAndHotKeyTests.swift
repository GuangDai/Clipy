/// PanelAndHotKeyTests — the hosted-integration proofs for the Maccy-style
/// panel machinery the composition root owns:
///
/// - `PopupPositionGeometryTests`: the pure origin math (cursor, status-item
///   anchor with right-edge clamp, center, last-position round trip,
///   multi-screen, fallbacks) over synthetic screen frames — no live
///   `NSScreen` needed (ClipyApp/Sources/Panel/PopupPositionGeometry.swift).
/// - `GlobalHotKeyTests`: Carbon registration is accepted headlessly,
///   idempotent, and reversible, and the handler's fire path runs the
///   action (ClipyApp/Sources/HotKey/GlobalHotKey.swift).
///
/// `@testable import ClipyApp` reaches the internal panel/hotkey machinery
/// (the same seam AppCompositionTests uses).
import AppKit
import Carbon.HIToolbox
import Foundation
import PresentationUI
import Testing
@testable import ClipyApp

struct PanelSubmitDecisionTests {
    @Test("Return submits only after marked text settles")
    func returnSubmissionDefersToIMEAndModifiedCommands() {
        #expect(PanelSubmitDecision.shouldSubmit(
            eventType: .keyDown,
            keyCode: UInt16(kVK_Return),
            modifierFlags: [],
            hasMarkedText: false,
            isSelectionSubmissionEnabled: true
        ))
        #expect(!PanelSubmitDecision.shouldSubmit(
            eventType: .keyDown,
            keyCode: UInt16(kVK_Return),
            modifierFlags: [],
            hasMarkedText: true,
            isSelectionSubmissionEnabled: true
        ))
        #expect(!PanelSubmitDecision.shouldSubmit(
            eventType: .keyDown,
            keyCode: UInt16(kVK_Return),
            modifierFlags: .command,
            hasMarkedText: false,
            isSelectionSubmissionEnabled: true
        ))
        #expect(!PanelSubmitDecision.shouldSubmit(
            eventType: .keyUp,
            keyCode: UInt16(kVK_ANSI_KeypadEnter),
            modifierFlags: [],
            hasMarkedText: false,
            isSelectionSubmissionEnabled: true
        ))
        #expect(!PanelSubmitDecision.shouldSubmit(
            eventType: .keyDown,
            keyCode: UInt16(kVK_Return),
            modifierFlags: [],
            hasMarkedText: false,
            isSelectionSubmissionEnabled: false
        ))
    }
}

struct PopupPositionGeometryTests {

    /// Two synthetic screens: a 1440×875 main visible frame and a
    /// 1920×1080 display to its right. Individual tests add a synthetic
    /// negative-origin display; these values prove only the pure screen-space
    /// arithmetic, not WindowServer display or Space lifecycle behavior.
    private let mainFrame = NSRect(x: 0, y: 0, width: 1_440, height: 875)
    private let rightFrame = NSRect(x: 1_440, y: 0, width: 1_920, height: 1_080)
    private let negativeOriginFrame = NSRect(x: -1_600, y: -200, width: 1_600, height: 1_000)
    private let panelSize = NSSize(width: 400, height: 560)

    private func panelOrigin(
        _ mode: PopupPositionMode,
        mouse: NSPoint,
        buttonFrame: NSRect? = nil,
        anchor: NSPoint? = nil
    ) -> NSPoint {
        PopupPositionGeometry.origin(
            for: mode,
            panelSize: panelSize,
            statusItemButtonScreenFrame: buttonFrame,
            mouseLocation: mouse,
            screenVisibleFrames: [mainFrame, rightFrame],
            lastPositionAnchor: anchor
        )
    }

    @Test func cursorModeHangsThePanelBelowThePointer() {
        let origin = panelOrigin(.cursor, mouse: NSPoint(x: 500, y: 800))
        #expect(origin == NSPoint(x: 500, y: 240))  // 800 - 560
    }

    @Test func cursorModeClampsIntoTheVisibleFrame() {
        // Pointer near the right/bottom edges: the panel must not spill.
        // (Explicitly typed expectations: a bare integer ARITHMETIC
        // expression on the RHS of #expect infers Int and never equals a
        // CGFloat; plain literals infer CGFloat fine.)
        let origin = panelOrigin(.cursor, mouse: NSPoint(x: 1_430, y: 100))
        let expectedX: CGFloat = (1_440 - 400)
        #expect(origin.x == expectedX)
        #expect(origin.y == 0)
    }

    @Test func cursorModeUsesTheScreenContainingThePointer() {
        let origin = panelOrigin(.cursor, mouse: NSPoint(x: 1_500, y: 900))
        #expect(origin.x == 1_500)
        #expect(origin.y == 340)  // 900 - 560
    }

    @Test func cursorModeClampsToTheChosenNegativeOriginVisibleFrame() {
        // The pointer is inside the synthetic left-hand display and near its
        // bottom-right corner. Both axes clamp against that display's literal
        // visible-frame edges rather than the primary display's zero origin;
        // the width is the real expanded panel width, not the 400-point main
        // surface alone.
        let expandedPanelSize = NSSize(width: 721, height: 560)
        let origin = PopupPositionGeometry.origin(
            for: .cursor,
            panelSize: expandedPanelSize,
            statusItemButtonScreenFrame: nil,
            mouseLocation: NSPoint(x: -5, y: -195),
            screenVisibleFrames: [mainFrame, negativeOriginFrame],
            lastPositionAnchor: nil
        )

        #expect(origin == NSPoint(x: -721, y: -200))
        #expect(origin.x >= negativeOriginFrame.minX)
        #expect(origin.x + expandedPanelSize.width <= negativeOriginFrame.maxX)
        #expect(origin.y >= negativeOriginFrame.minY)
        #expect(origin.y + expandedPanelSize.height <= negativeOriginFrame.maxY)
    }

    @Test func centerModeCentersInThePointerScreen() {
        let origin = panelOrigin(.center, mouse: NSPoint(x: 100, y: 100))
        let expectedX: CGFloat = (1_440 - 400) / 2
        let expectedY: CGFloat = (875 - 560) / 2
        #expect(origin.x == expectedX)
        #expect(origin.y == expectedY)

        let rightOrigin = panelOrigin(.center, mouse: NSPoint(x: 2_000, y: 500))
        let expectedRightX: CGFloat = 1_440 + (1_920 - 400) / 2
        let expectedRightY: CGFloat = (1_080 - 560) / 2
        #expect(rightOrigin.x == expectedRightX)
        #expect(rightOrigin.y == expectedRightY)
    }

    @Test func statusItemModeHangsBelowTheButton() {
        // Button x 900: the 400-wide panel fits (900 + 400 ≤ 1440), so no
        // edge clamp engages.
        let buttonFrame = NSRect(x: 900, y: 855, width: 24, height: 22)
        let origin = panelOrigin(.statusItem, mouse: NSPoint(x: 0, y: 0), buttonFrame: buttonFrame)
        #expect(origin == NSPoint(x: 900, y: 295))  // 855 - 560, inside the frame
    }

    @Test func statusItemModeClampsTheRightEdge() {
        // A button near the right edge of the menu bar: the panel must not
        // spill onto the neighboring screen (Maccy's right-edge clamp).
        let buttonFrame = NSRect(x: 1_300, y: 855, width: 24, height: 22)
        let origin = panelOrigin(.statusItem, mouse: NSPoint(x: 0, y: 0), buttonFrame: buttonFrame)
        let expectedX: CGFloat = 1_440 - 400
        #expect(origin.x == expectedX)
        #expect(origin.y == 295)
    }

    @Test func statusItemModeFallsBackToCursorWithoutAButtonFrame() {
        let mouse = NSPoint(x: 500, y: 800)
        let origin = panelOrigin(.statusItem, mouse: mouse, buttonFrame: nil)
        #expect(origin == NSPoint(x: 500, y: 240))
    }

    @Test func lastPositionRoundTripsThroughTheNormalizedAnchor() {
        let original = NSRect(x: 520, y: 315, width: 400, height: 560)
        let anchor = PopupPositionGeometry.normalizedAnchor(
            forPanelFrame: original,
            previewPlacement: .trailing,
            previewVisible: false,
            mainSurfaceWidth: 400,
            in: mainFrame
        )
        #expect(abs(anchor.x - 0.5) < 0.000_001)
        #expect(abs(anchor.y - 1.0) < 0.000_001)

        let origin = panelOrigin(.lastPosition, mouse: NSPoint(x: 0, y: 0), anchor: anchor)
        #expect(abs(origin.x - original.minX) < 0.000_001)
        #expect(abs(origin.y - original.minY) < 0.000_001)
    }

    @Test func lastPositionUsesTheMainSurfaceWhenPreviewOpenedRight() {
        // Main surface: x 520...920. Preview occupies x 921...1,241.
        let previewPanel = NSRect(x: 520, y: 315, width: 721, height: 560)
        let anchor = PopupPositionGeometry.normalizedAnchor(
            forPanelFrame: previewPanel,
            previewPlacement: .trailing,
            previewVisible: true,
            mainSurfaceWidth: 400,
            in: mainFrame
        )

        #expect(anchor == NSPoint(x: 0.5, y: 1))
        let reopened = panelOrigin(
            .lastPosition,
            mouse: .zero,
            anchor: anchor
        )
        #expect(reopened == NSPoint(x: 520, y: 315))
    }

    @Test func previewAtRightEdgeOpensLeadingWithoutMovingTheMainSurface() {
        let mainSurface = NSRect(x: 1_000, y: 200, width: 400, height: 560)

        let expansion = PopupPositionGeometry.expandedPreviewFrame(
            preservingMainSurface: mainSurface,
            in: mainFrame
        )

        #expect(expansion.placement == .leading)
        #expect(expansion.panelFrame == NSRect(x: 679, y: 200, width: 721, height: 560))
        let collapsedFrame = PopupPositionGeometry.mainSurfaceFrame(
            in: expansion.panelFrame,
            previewPlacement: expansion.placement,
            previewVisible: true
        )
        #expect(collapsedFrame == mainSurface)
    }

    @Test func previewUsesTrailingWhenTheRightSideHasSpace() {
        let mainSurface = NSRect(x: 100, y: 200, width: 400, height: 560)

        let expansion = PopupPositionGeometry.expandedPreviewFrame(
            preservingMainSurface: mainSurface,
            in: mainFrame
        )

        #expect(expansion.placement == .trailing)
        #expect(expansion.panelFrame == NSRect(x: 100, y: 200, width: 721, height: 560))
        #expect(
            PopupPositionGeometry.mainSurfaceFrame(
                in: expansion.panelFrame,
                previewPlacement: expansion.placement,
                previewVisible: true
            ) == mainSurface
        )
    }

    @Test func negativeOriginLeftEdgePreviewCycleUsesTrailingAndKeepsTheMainSurface() {
        let mainSurface = NSRect(x: -1_600, y: -200, width: 400, height: 560)

        let expansion = PopupPositionGeometry.expandedPreviewFrame(
            preservingMainSurface: mainSurface,
            in: negativeOriginFrame
        )

        #expect(expansion.placement == .trailing)
        #expect(expansion.panelFrame == NSRect(x: -1_600, y: -200, width: 721, height: 560))
        #expect(expansion.panelFrame.minX == negativeOriginFrame.minX)
        #expect(expansion.panelFrame.maxX <= negativeOriginFrame.maxX)
        #expect(expansion.panelFrame.minY == negativeOriginFrame.minY)
        #expect(expansion.panelFrame.maxY <= negativeOriginFrame.maxY)

        let collapsedFrame = PopupPositionGeometry.mainSurfaceFrame(
            in: expansion.panelFrame,
            previewPlacement: expansion.placement,
            previewVisible: true
        )
        #expect(collapsedFrame == mainSurface)
    }

    @Test func negativeOriginRightEdgePreviewCycleUsesLeadingAndKeepsTheMainSurface() {
        let mainSurface = NSRect(x: -400, y: 240, width: 400, height: 560)

        let expansion = PopupPositionGeometry.expandedPreviewFrame(
            preservingMainSurface: mainSurface,
            in: negativeOriginFrame
        )

        #expect(expansion.placement == .leading)
        #expect(expansion.panelFrame == NSRect(x: -721, y: 240, width: 721, height: 560))
        #expect(expansion.panelFrame.minX >= negativeOriginFrame.minX)
        #expect(expansion.panelFrame.maxX == negativeOriginFrame.maxX)
        #expect(expansion.panelFrame.minY >= negativeOriginFrame.minY)
        #expect(expansion.panelFrame.maxY == negativeOriginFrame.maxY)

        let collapsedFrame = PopupPositionGeometry.mainSurfaceFrame(
            in: expansion.panelFrame,
            previewPlacement: expansion.placement,
            previewVisible: true
        )
        #expect(collapsedFrame == mainSurface)
    }

    @Test func previewConservativelyUsesTrailingWithoutAScreen() {
        let mainSurface = NSRect(x: 1_000, y: 200, width: 400, height: 560)

        let expansion = PopupPositionGeometry.expandedPreviewFrame(
            preservingMainSurface: mainSurface,
            in: nil
        )

        #expect(expansion.placement == .trailing)
        #expect(expansion.panelFrame.origin == mainSurface.origin)
    }

    @Test func lastPositionUsesActualMainSurfaceWhenExpandedWindowShiftedLeft() {
        // Leading preview: preview x 199...519, main x 520...920. The
        // persisted anchor follows the actual main surface, not panel.minX.
        let previewPanel = NSRect(x: 199, y: 315, width: 721, height: 560)
        let anchor = PopupPositionGeometry.normalizedAnchor(
            forPanelFrame: previewPanel,
            previewPlacement: .leading,
            previewVisible: true,
            mainSurfaceWidth: 400,
            in: mainFrame
        )

        let reopened = panelOrigin(
            .lastPosition,
            mouse: .zero,
            anchor: anchor
        )
        #expect(reopened == NSPoint(x: 520, y: 315))
    }

    @Test func lastPositionFallsBackToCursorWithoutAnAnchor() {
        let mouse = NSPoint(x: 500, y: 800)
        let origin = panelOrigin(.lastPosition, mouse: mouse, anchor: nil)
        #expect(origin == NSPoint(x: 500, y: 240))
    }

    @Test func aPanelLargerThanTheScreenPinsToTheBottomLeft() {
        let origin = PopupPositionGeometry.origin(
            for: .center,
            panelSize: NSSize(width: 5_000, height: 5_000),
            statusItemButtonScreenFrame: nil,
            mouseLocation: NSPoint(x: 100, y: 100),
            screenVisibleFrames: [mainFrame],
            lastPositionAnchor: nil
        )
        #expect(origin == mainFrame.origin)
    }
}

struct GlobalHotKeyTests {

    /// Carbon registration works on the headless runner (no accessibility
    /// grant needed — that is why the Carbon API was chosen), re-registration
    /// is an idempotent no-op, and `fire()` runs the action (the tail of the
    /// Carbon event handler, driven directly here).
    @Test @MainActor
    func hotKeyRegistersIdempotentlyFiresAndUnregisters() {
        var fired = 0
        let hotKey = GlobalHotKey.summonPanelHotKey { fired += 1 }
        #expect(hotKey.register(), "Carbon accepts the ⇧⌘C registration")
        #expect(hotKey.register(), "re-registration is an idempotent no-op")
        hotKey.fire()
        #expect(fired == 1)
        hotKey.unregister()
        hotKey.unregister()  // idempotent teardown
    }

    /// S-6 (docs/reviews/2026-08-20-clipy-maccy-audit/01-standards.md): the
    /// Carbon handler no longer assumes main-thread delivery — it checks
    /// `Thread.isMainThread` and block-hops through `DispatchQueue.main.sync`
    /// otherwise. The C callback is file-private and only Carbon can invoke
    /// it with a real `EventRef`, so neither branch of that check is
    /// deterministically exercisable from a hosted test; what is provable
    /// here is the mechanism the off-main fallback relies on — a block
    /// enqueued on the main queue runs on the main thread, where
    /// `MainActor.assumeIsolated` holds and `fire()` runs the action.
    @Test @MainActor
    func fireRunsTheActionFromAMainQueueHop() async {
        var fired = 0
        let hotKey = GlobalHotKey.summonPanelHotKey { fired += 1 }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    hotKey.fire()
                    continuation.resume()
                }
            }
        }
        #expect(fired == 1)
        hotKey.unregister()  // never registered; proves teardown is a safe no-op
    }
}
