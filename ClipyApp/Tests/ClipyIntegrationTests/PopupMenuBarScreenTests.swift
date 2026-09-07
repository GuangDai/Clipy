import AppKit
import PresentationUI
import Testing
@testable import ClipyApp

struct PopupMenuBarScreenTests {
    private let main = (
        frame: NSRect(x: 0, y: 0, width: 1_440, height: 900),
        visibleFrame: NSRect(x: 0, y: 0, width: 1_440, height: 875)
    )
    private let secondary = (
        frame: NSRect(x: 1_440, y: 0, width: 1_920, height: 1_080),
        visibleFrame: NSRect(x: 1_440, y: 48, width: 1_920, height: 1_007)
    )

    @Test func secondaryMenuBarClickPlacesThePanelOnThatScreen() {
        let button = NSRect(x: 2_800, y: 1_055, width: 30, height: 25)
        let pointer = NSPoint(x: button.midX, y: button.midY)
        #expect(!secondary.visibleFrame.contains(pointer))
        let origin = PopupPositionGeometry.origin(
            for: .statusItem, panelSize: NSSize(width: 400, height: 560),
            statusItemButtonScreenFrame: button, mouseLocation: pointer,
            screens: [main, secondary], lastPositionAnchor: nil
        )
        #expect(origin == NSPoint(x: 2_800, y: 495))
        #expect(secondary.visibleFrame.contains(NSRect(origin: origin, size: NSSize(width: 400, height: 560))))
    }

    @Test func statusButtonSelectsItsScreenForSizingEvenWhenPointerIsElsewhere() {
        let small = (
            frame: NSRect(x: -800, y: 0, width: 800, height: 600),
            visibleFrame: NSRect(x: -800, y: 30, width: 800, height: 545)
        )
        let button = NSRect(x: -50, y: 575, width: 30, height: 25)
        #expect(PopupPositionGeometry.targetVisibleFrame(
            for: .statusItem, statusItemButtonScreenFrame: button,
            mouseLocation: NSPoint(x: 500, y: 500), screens: [main, small]
        ) == small.visibleFrame)
    }

    @Test func menuAndDockPointerPositionsKeepTheirDisplayForNonStatusModes() {
        for point in [NSPoint(x: 2_000, y: 1_065), NSPoint(x: 2_000, y: 20)] {
            #expect(!secondary.visibleFrame.contains(point))
            for mode in [PopupPositionMode.cursor, .center, .lastPosition] {
                let origin = PopupPositionGeometry.origin(
                    for: mode, panelSize: NSSize(width: 400, height: 560),
                    statusItemButtonScreenFrame: nil, mouseLocation: point,
                    screens: [main, secondary], lastPositionAnchor: NSPoint(x: 0.5, y: 1)
                )
                #expect(secondary.visibleFrame.contains(NSRect(origin: origin, size: NSSize(width: 400, height: 560))))
            }
        }
    }

    @Test func menuBarNearATallerNeighbourStillBelongsToItsFullScreen() {
        // The neighbouring visible rectangle is closer than the main
        // display's safe rectangle. Nearest-rectangle heuristics would pick
        // the wrong monitor; full screen ownership is decisive.
        let button = NSRect(x: 1_425, y: 875, width: 10, height: 25)
        #expect(PopupPositionGeometry.targetVisibleFrame(
            for: .statusItem, statusItemButtonScreenFrame: button,
            mouseLocation: NSPoint(x: 2_000, y: 500), screens: [main, secondary]
        ) == main.visibleFrame)
    }
}
