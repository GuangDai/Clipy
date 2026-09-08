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
        let application = NSApplication.shared
        guard application.setActivationPolicy(.accessory) else {
            FileHandle.standardError.write(Data("receiver: accessory activation policy refused\n".utf8))
            exit(3)
        }
        let delegate = DragReceiverDelegate(
            frame: NSRect(x: x, y: y, width: width, height: height),
            outputDirectory: URL(fileURLWithPath: arguments[4], isDirectory: true)
        )
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
private final class DragReceiverDelegate: NSObject, NSApplicationDelegate {
    private let frame: NSRect
    private let outputDirectory: URL
    private var window: NSPanel?
    private var readinessTimer: Timer?

    init(frame: NSRect, outputDirectory: URL) {
        self.frame = frame
        self.outputDirectory = outputDirectory
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let receiver = NativeClipboardDropView(
            frame: NSRect(origin: .zero, size: frame.size),
            resultURL: outputDirectory.appendingPathComponent("received.json")
        )
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.contentView = receiver
        receiver.registerForDraggedTypes([.string, .init("com.clipy.tests.drag-opaque")])
        window = panel
        panel.orderFrontRegardless()
        // Readiness is a WindowServer fact after the event loop processes its
        // display work, not merely an isVisible flag from orderFront.
        let timer = Timer(timeInterval: 0.02, target: self, selector: #selector(publishReadiness),
                          userInfo: nil, repeats: true)
        readinessTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func publishReadiness() {
        guard let window, NSApplication.shared.isRunning,
              NSApplication.shared.activationPolicy() == .accessory,
              window.isVisible else { return }
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        guard NSWindow.windowNumber(at: center, belowWindowWithWindowNumber: 0) == window.windowNumber else { return }
        let ready = ReceiverReadiness(
            windowNumber: window.windowNumber,
            frame: ReceiverFrame(x: Double(window.frame.minX), y: Double(window.frame.minY),
                                 width: Double(window.frame.width), height: Double(window.frame.height)),
            activationPolicy: NSApplication.shared.activationPolicy().rawValue,
            isRunning: NSApplication.shared.isRunning
        )
        do {
            try JSONEncoder().encode(ready).write(
                to: outputDirectory.appendingPathComponent("ready.json"), options: .atomic
            )
            readinessTimer?.invalidate()
            readinessTimer = nil
        } catch {
            FileHandle.standardError.write(Data("receiver: readiness write failed\n".utf8))
            NSApplication.shared.terminate(nil)
        }
    }
}

@MainActor
private final class NativeClipboardDropView: NSView {
    private let resultURL: URL

    init(frame: NSRect, resultURL: URL) {
        self.resultURL = resultURL
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
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
    let frame: ReceiverFrame
    let activationPolicy: Int
    let isRunning: Bool
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
