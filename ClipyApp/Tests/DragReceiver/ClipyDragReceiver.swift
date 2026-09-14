import AppKit
import Darwin
import Foundation

/// Test-only independent drag destination. Unlike XCTRunner, this process
/// owns an initialized AppKit application and a running main event loop.
@main
@MainActor
struct ClipyDragReceiver {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 5,
              let x = Double(arguments[0]), x.isFinite,
              let y = Double(arguments[1]), y.isFinite,
              let width = Double(arguments[2]), width.isFinite, width > 0,
              let height = Double(arguments[3]), height.isFinite, height > 0 else {
            exit(2)
        }
        // XCTest owns launch and process lifetime; retain the same test-local
        // stderr evidence without an alternate launcher or logging service.
        let outputDirectory = URL(fileURLWithPath: arguments[4], isDirectory: true)
        let logDescriptor = Darwin.open(
            outputDirectory.appendingPathComponent("receiver.log").path,
            O_WRONLY | O_CREAT | O_APPEND, mode_t(0o600)
        )
        guard logDescriptor >= 0 else { exit(4) }
        guard Darwin.dup2(logDescriptor, STDERR_FILENO) >= 0 else {
            _ = Darwin.close(logDescriptor)
            exit(4)
        }
        if logDescriptor != STDERR_FILENO { _ = Darwin.close(logDescriptor) }
        let application = NSApplication.shared
        let previousPolicy = application.activationPolicy()
        let switchResult: Bool? = previousPolicy == .regular
            ? nil : application.setActivationPolicy(.regular)
        let actualPolicy = application.activationPolicy()
        guard actualPolicy == .regular else {
            let resultDescription = switchResult.map { String($0) } ?? "not requested"
            FileHandle.standardError.write(Data(
                "receiver: regular activation policy unavailable; before=\(previousPolicy.rawValue) after=\(actualPolicy.rawValue) switchResult=\(resultDescription)\n".utf8
            ))
            exit(3)
        }
        let delegate = DragReceiverDelegate(
            frame: NSRect(x: x, y: y, width: width, height: height),
            outputDirectory: outputDirectory
        )
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
private final class DragReceiverDelegate: NSObject, NSApplicationDelegate {
    private let frame: NSRect
    private let outputDirectory: URL
    private var window: NSWindow?
    private var readinessTimer: Timer?
    private var didPublishWindowReadiness = false
    private var lastTargetHit: Int?

    init(frame: NSRect, outputDirectory: URL) {
        self.frame = frame
        self.outputDirectory = outputDirectory
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let receiver = NativeClipboardDropView(
            frame: NSRect(origin: .zero, size: frame.size),
            resultURL: outputDirectory.appendingPathComponent("received.json"),
            pointerReadinessURL: outputDirectory.appendingPathComponent("hovered.json")
        )
        let panel = NSWindow(contentRect: frame, styleMask: [.titled, .closable],
                            backing: .buffered, defer: false)
        panel.title = "Clipy native drag receiver"
        // `frame` is the free outer rectangle chosen by the source journey.
        // Keep the title bar inside it and publish the content's actual drop
        // rectangle below; a titled window has different frame/content sizes.
        panel.setFrame(frame, display: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.contentView = receiver
        receiver.autoresizingMask = [.width, .height]
        panel.acceptsMouseMovedEvents = true
        receiver.registerForDraggedTypes([.string, .init("com.clipy.tests.drag-opaque")])
        window = panel
        panel.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
        FileHandle.standardError.write(Data("receiver: requested regular application activation\n".utf8))
        // Readiness is a WindowServer fact after the event loop processes its
        // display work, not merely an isVisible flag from orderFront.
        let timer = Timer(timeInterval: 0.02, target: self, selector: #selector(publishReadiness),
                          userInfo: nil, repeats: true)
        readinessTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        FileHandle.standardError.write(Data("receiver: application became active\n".utf8))
    }

    @objc private func publishReadiness() {
        guard let window, NSApplication.shared.isRunning,
              NSApplication.shared.activationPolicy() == .regular,
              window.isVisible,
              let receiver = window.contentView as? NativeClipboardDropView,
              receiver.isTrackingPointer else { return }
        let contentFrame = window.convertToScreen(receiver.convert(receiver.bounds, to: nil))
        let center = NSPoint(x: contentFrame.midX, y: contentFrame.midY)
        let hitWindowNumber = NSWindow.windowNumber(at: center, belowWindowWithWindowNumber: 0)
        if lastTargetHit != hitWindowNumber {
            lastTargetHit = hitWindowNumber
            FileHandle.standardError.write(Data(
                "receiver: target hit=\(hitWindowNumber) expected=\(window.windowNumber) center=\(center)\n".utf8
            ))
        }
        guard hitWindowNumber == window.windowNumber, !didPublishWindowReadiness else { return }
        // Exercise an ordinary destination application's real activation and
        // key-window lifecycle once. `activate()` is a request, so the ready
        // receipt joins the resulting public state rather than assuming it.
        guard NSApplication.shared.isActive, window.isKeyWindow else { return }
        let ready = ReceiverReadiness(
            windowNumber: window.windowNumber,
            hitWindowNumber: hitWindowNumber,
            frame: ReceiverFrame(x: Double(contentFrame.minX), y: Double(contentFrame.minY),
                                 width: Double(contentFrame.width), height: Double(contentFrame.height)),
            activationPolicy: NSApplication.shared.activationPolicy().rawValue,
            isRunning: NSApplication.shared.isRunning,
            isActive: NSApplication.shared.isActive,
            isKeyWindow: window.isKeyWindow
        )
        do {
            try JSONEncoder().encode(ready).write(
                to: outputDirectory.appendingPathComponent("ready.json"), options: .atomic
            )
            didPublishWindowReadiness = true
        } catch {
            FileHandle.standardError.write(Data("receiver: readiness write failed\n".utf8))
            NSApplication.shared.terminate(nil)
        }
    }
}

@MainActor
private final class NativeClipboardDropView: NSView {
    private let resultURL: URL
    private let pointerReadinessURL: URL
    private var didPublishPointerReadiness = false
    private var pointerTrackingArea: NSTrackingArea?
    var isTrackingPointer: Bool { pointerTrackingArea != nil }

    init(frame: NSRect, resultURL: URL, pointerReadinessURL: URL) {
        self.resultURL = resultURL
        self.pointerReadinessURL = pointerReadinessURL
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self, userInfo: nil
        )
        pointerTrackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        FileHandle.standardError.write(Data(
            "receiver: pointer entered buttons=\(NSEvent.pressedMouseButtons)\n".utf8
        ))
        publishPointerReadiness(event)
    }

    override func mouseMoved(with event: NSEvent) {
        publishPointerReadiness(event)
    }

    /// Readiness requires a real event delivered to the registered NSView,
    /// before any drag. A visible WindowServer window alone does not establish
    /// that its content participates in AppKit's event dispatch yet.
    private func publishPointerReadiness(_ event: NSEvent) {
        guard !didPublishPointerReadiness, NSEvent.pressedMouseButtons == 0,
              let window, event.windowNumber == window.windowNumber,
              registeredDraggedTypes.contains(.string) else { return }
        let point = convert(event.locationInWindow, from: nil)
        let pointInSuperview = superview?.convert(event.locationInWindow, from: nil)
            ?? event.locationInWindow
        guard bounds.contains(point), hitTest(pointInSuperview) === self else { return }
        let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        let hitWindow = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        guard hitWindow == window.windowNumber else { return }
        do {
            let value = ReceiverPointerReadiness(
                windowNumber: window.windowNumber, hitWindowNumber: hitWindow,
                pointX: Double(screenPoint.x), pointY: Double(screenPoint.y)
            )
            try JSONEncoder().encode(value).write(to: pointerReadinessURL, options: .atomic)
            didPublishPointerReadiness = true
            FileHandle.standardError.write(Data("receiver: view event handshake complete\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("receiver: pointer readiness write failed\n".utf8))
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        FileHandle.standardError.write(Data("receiver: dragging entered\n".utf8))
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let items = sender.draggingPasteboard.pasteboardItems, !items.isEmpty else { return false }
        var received: [ReceivedItem] = []
        for item in items {
            var representations: [ReceivedRepresentation] = []
            for type in item.types {
                // Missing promised data fails the actual drop; never report a
                // partial gesture as a successful round trip.
                guard let bytes = item.data(forType: type) else { return false }
                representations.append(ReceivedRepresentation(typeIdentifier: type.rawValue, bytes: bytes))
            }
            received.append(ReceivedItem(representations: representations))
        }
        do {
            // This is the only writer of received.json. No fixture input,
            // readiness callback, or scripted request can populate its bytes.
            try JSONEncoder().encode(ReceivedDrag(items: received)).write(to: resultURL, options: .atomic)
            FileHandle.standardError.write(Data("receiver: drag delivered\n".utf8))
            return true
        } catch {
            FileHandle.standardError.write(Data("receiver: result write failed\n".utf8))
            return false
        }
    }
}

private struct ReceiverFrame: Codable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

private struct ReceiverReadiness: Codable, Sendable {
    let windowNumber: Int
    let hitWindowNumber: Int
    let frame: ReceiverFrame
    let activationPolicy: Int
    let isRunning: Bool
    let isActive: Bool
    let isKeyWindow: Bool
}

private struct ReceiverPointerReadiness: Codable, Sendable {
    let windowNumber: Int
    let hitWindowNumber: Int
    let pointX: Double
    let pointY: Double
}

private struct ReceivedRepresentation: Codable, Sendable {
    let typeIdentifier: String
    let bytes: Data
}

private struct ReceivedItem: Codable, Sendable {
    let representations: [ReceivedRepresentation]
}

private struct ReceivedDrag: Codable, Sendable {
    let items: [ReceivedItem]
}
