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
import Foundation
import PresentationUI
import Testing
@testable import ClipyApp

struct PopupPositionGeometryTests {

    /// Two synthetic screens: a 1440×875 main visible frame and a
    /// 1920×1080 display to its right.
    private let mainFrame = NSRect(x: 0, y: 0, width: 1_440, height: 875)
    private let rightFrame = NSRect(x: 1_440, y: 0, width: 1_920, height: 1_080)
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
        let origin = panelOrigin(.cursor, mouse: NSPoint(x: 1_430, y: 100))
        #expect(origin.x == 1_440 - 400)
        #expect(origin.y == 0)
    }

    @Test func cursorModeUsesTheScreenContainingThePointer() {
        let origin = panelOrigin(.cursor, mouse: NSPoint(x: 1_500, y: 900))
        #expect(origin.x == 1_500)
        #expect(origin.y == 340)  // 900 - 560
    }

    @Test func centerModeCentersInThePointerScreen() {
        let origin = panelOrigin(.center, mouse: NSPoint(x: 100, y: 100))
        #expect(origin.x == (1_440 - 400) / 2)
        #expect(origin.y == (875 - 560) / 2)

        let rightOrigin = panelOrigin(.center, mouse: NSPoint(x: 2_000, y: 500))
        #expect(rightOrigin.x == 1_440 + (1_920 - 400) / 2)
        #expect(rightOrigin.y == (1_080 - 560) / 2)
    }

    @Test func statusItemModeHangsBelowTheButton() {
        let buttonFrame = NSRect(x: 1_100, y: 855, width: 24, height: 22)
        let origin = panelOrigin(.statusItem, mouse: NSPoint(x: 0, y: 0), buttonFrame: buttonFrame)
        #expect(origin == NSPoint(x: 1_100, y: 295))  // 855 - 560, inside the frame
    }

    @Test func statusItemModeClampsTheRightEdge() {
        // A button near the right edge of the menu bar: the panel must not
        // spill onto the neighboring screen (Maccy's right-edge clamp).
        let buttonFrame = NSRect(x: 1_300, y: 855, width: 24, height: 22)
        let origin = panelOrigin(.statusItem, mouse: NSPoint(x: 0, y: 0), buttonFrame: buttonFrame)
        #expect(origin.x == 1_440 - 400)
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
            in: mainFrame
        )
        #expect(abs(anchor.x - 0.5) < 0.000_001)
        #expect(abs(anchor.y - 1.0) < 0.000_001)

        let origin = panelOrigin(.lastPosition, mouse: NSPoint(x: 0, y: 0), anchor: anchor)
        #expect(abs(origin.x - original.minX) < 0.000_001)
        #expect(abs(origin.y - original.minY) < 0.000_001)
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
}
