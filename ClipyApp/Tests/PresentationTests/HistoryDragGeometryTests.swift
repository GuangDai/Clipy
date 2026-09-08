import AppKit
import HistoryCore
import Testing
@testable import ClipyApp

/// Exercise the same native admission used by mouseDown, with a row and list
/// in separate branches and mixed flipped coordinates. The XCUI journey
/// separately verifies SwiftUI row wiring and the complete native drop.
@MainActor
struct HistoryDragGeometryTests {
    @Test func rowHitUsesItsNativeCoordinatesWithPreviewBesideTheList() {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.source.hover(fixture.item, region: fixture.row, isInside: true)

        // This is the CI failure's list-local mouse point. Its row occupies
        // (22, 40, 356, 48) here, but (343, 84, 356, 48) in the root view.
        let inside = fixture.source.convert(NSPoint(x: 200, y: 64), to: nil)
        #expect(fixture.source.item(at: inside) == fixture.item)
        let besideRow = fixture.source.convert(NSPoint(x: 12, y: 64), to: nil)
        #expect(fixture.source.item(at: besideRow) == nil)
        let belowRow = fixture.source.convert(NSPoint(x: 200, y: 100), to: nil)
        #expect(fixture.source.item(at: belowRow) == nil)
    }

    @Test func movingTheListReadsLiveGeometryWithoutAnotherHover() {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.source.hover(fixture.item, region: fixture.row, isInside: true)
        let oldPoint = fixture.source.convert(NSPoint(x: 200, y: 64), to: nil)
        #expect(fixture.source.item(at: oldPoint) == fixture.item)

        fixture.source.setFrameOrigin(NSPoint(x: 0, y: 44))
        fixture.rowHost.setFrameOrigin(NSPoint(x: 0, y: 44))
        #expect(fixture.source.item(at: oldPoint) == nil)
        let newPoint = fixture.source.convert(NSPoint(x: 200, y: 64), to: nil)
        #expect(fixture.source.item(at: newPoint) == fixture.item)
    }

    @Test func clippedHiddenAndDetachedRowsCannotAdmitADrag() {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.source.hover(fixture.item, region: fixture.row, isInside: true)
        let inside = fixture.source.convert(NSPoint(x: 200, y: 64), to: nil)
        fixture.row.isHidden = true
        #expect(fixture.source.item(at: inside) == nil)
        fixture.row.isHidden = false
        fixture.rowHost.setBoundsOrigin(NSPoint(x: 0, y: 500))
        let clippedCenter = fixture.row.convert(NSPoint(x: 178, y: 24), to: nil)
        #expect(fixture.source.item(at: clippedCenter) == nil)
        fixture.row.removeFromSuperview()
        #expect(fixture.source.item(at: inside) == nil)
    }

    @MainActor
    private struct Fixture {
        let window: NSWindow
        let source = HistoryListDraggingView()
        let rowHost = NSView(frame: NSRect(x: 321, y: 44, width: 400, height: 516))
        let row = HistoryRowDragRegionView()
        let item = HistoryItemReference(id: .init(rawValue: UUID()), contentVersion: .init(rawValue: 1))

        init() {
            window = NSWindow(contentRect: NSRect(x: 71, y: 63, width: 721, height: 560),
                              styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let root = FlippedRoot(frame: NSRect(x: 0, y: 0, width: 721, height: 560))
            window.contentView = root
            source.frame = NSRect(x: 321, y: 44, width: 400, height: 516)
            root.addSubview(source)
            root.addSubview(rowHost)
            rowHost.clipsToBounds = true
            // rowHost is unflipped; row and list are flipped.
            row.frame = NSRect(x: 22, y: 428, width: 356, height: 48)
            rowHost.addSubview(row)
        }

        func close() {
            source.stopMonitoring()
            window.close()
        }
    }

    private final class FlippedRoot: NSView {
        override var isFlipped: Bool { true }
    }
}
