import AppKit
import Foundation
import HistoryCore
import SwiftUI

/// One list-owned AppKit source is needed because onDrag vends one provider,
/// while ClipboardHistory retains an ordered collection with dynamic types.
/// AppKit writes one NSPasteboardItem per NSDraggingItem (V2-09 §11).
struct HistoryListDragSource: NSViewRepresentable {
    let view: HistoryListDraggingView
    let load: @MainActor (HistoryItemReference) async throws -> PastePayload?

    func makeNSView(context: Context) -> HistoryListDraggingView {
        view.load = load
        return view
    }

    func updateNSView(_ view: HistoryListDraggingView, context: Context) {
        view.load = load
    }

    static func dismantleNSView(_ view: HistoryListDraggingView, coordinator: ()) {
        view.stopMonitoring()
        view.load = nil
    }
}

@MainActor
final class HistoryListDraggingView: NSView, NSDraggingSource {
    var load: (@MainActor (HistoryItemReference) async throws -> PastePayload?)?
    private var hovered: (item: HistoryItemReference, frame: NSRect)?
    private var pressed: (item: HistoryItemReference, event: NSEvent)?
    private var preparation: Task<Void, Never>?
    private var eventMonitor: Any?
    private var session: NSDraggingSession?
    // Keep the delegate alive if closing the panel dismantles this view during
    // the native session. AppKit's ended callback releases this scoped owner.
    private var activeSource: HistoryListDraggingView?
#if DEBUG
    private var dragTraceLines: [String] = []
    private let dragTraceURL: URL? = {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CLIPY_RUNNING_UI_TEST"] == "1",
              let path = environment["CLIPY_UI_TEST_DRAG_TRACE_PATH"] else { return nil }
        return URL(fileURLWithPath: path)
    }()
#endif

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func hover(_ item: HistoryItemReference, frame: NSRect, isInside: Bool) {
        if isInside {
            hovered = (item, frame)
            trace("hover-enter frame=\(frame) bounds=\(bounds) visible=\(visibleRect)")
        }
        else if hovered?.item == item { hovered = nil }
    }

    /// Geometry and revision changes also refresh a stationary pointer's one
    /// candidate. No collection of row rectangles is retained.
    func refresh(_ item: HistoryItemReference, frame: NSRect) {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if visibleRect.contains(point), frame.contains(point) { hovered = (item, frame) }
        else if hovered?.item.id == item.id { hovered = nil }
    }

    func retire(_ item: HistoryItemReference) {
        if hovered?.item == item { hovered = nil }
        if pressed?.item == item, session == nil { cancelPreparation() }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { stopMonitoring() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, eventMonitor == nil else { return }
        trace("monitor-attached bounds=\(bounds) visible=\(visibleRect)")
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel, .keyDown]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.receive(event) }
            // Clicks, double-clicks, row selection, context menus and scrolling
            // remain SwiftUI's events. The native session owns drag tracking.
            return event
        }
    }

    func stopMonitoring() {
        trace("monitor-stopped")
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        hovered = nil
        cancelPreparation()
    }

    private func receive(_ event: NSEvent) {
        guard session == nil else { return }
        if event.type == .leftMouseUp || event.type == .scrollWheel
            || (event.type == .keyDown && event.keyCode == 53) {
            cancelPreparation()
            return
        }
        if event.type == .leftMouseDown {
            trace("mouse-down same-window=\(event.windowNumber == window?.windowNumber) candidate=\(hovered != nil)")
        }
        guard let window, event.windowNumber == window.windowNumber else { return }
        switch event.type {
        case .leftMouseDown:
            cancelPreparation()
            let point = convert(event.locationInWindow, from: nil)
            trace("mouse-hit point=\(point) bounds=\(bounds) visible=\(visibleRect) candidate-frame=\(String(describing: hovered?.frame)) clicks=\(event.clickCount)")
            guard event.clickCount == 1, !event.modifierFlags.contains(.control),
                  visibleRect.contains(point), let hovered, hovered.frame.contains(point) else { return }
            pressed = (hovered.item, event)
            trace("pressed-admitted")
        case .leftMouseDragged:
            trace("mouse-dragged")
            guard preparation == nil, let pressed, let load else { return }
            let start = pressed.event.locationInWindow
            let current = event.locationInWindow
            let dx = current.x - start.x
            let dy = current.y - start.y
            guard dx * dx + dy * dy >= 16 else { return }
            trace("threshold-admitted")
            preparation = Task { [weak self, weak window] in
                defer {
                    // Success, nil and failure all finish this attempt. Clearing
                    // pressed too prevents retries during the same mouse hold.
                    if let self, self.pressed?.event === pressed.event {
                        self.preparation = nil
                        self.pressed = nil
                    }
                }
                do {
                    self?.trace("payload-read-started")
                    guard let payload = try await load(pressed.item) else {
                        self?.trace("payload-read-empty")
                        return
                    }
                    self?.trace("payload-read-returned left-held=\(NSEvent.pressedMouseButtons & 1 != 0) cancelled=\(Task.isCancelled)")
                    try Task.checkCancellation()
                    guard let self, let window, self.window === window,
                          self.pressed?.event === pressed.event,
                          NSEvent.pressedMouseButtons & 1 != 0 else { return }
                    let writers = try Self.pasteboardItems(for: payload)
                    let point = self.convert(pressed.event.locationInWindow, from: nil)
                    let image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
                        ?? NSImage(size: NSSize(width: 32, height: 32))
                    let items = writers.enumerated().map { index, writer in
                        let item = NSDraggingItem(pasteboardWriter: writer)
                        item.setDraggingFrame(NSRect(
                            x: point.x + CGFloat(index * 2), y: point.y + CGFloat(index * 2),
                            width: 32, height: 32
                        ), contents: image)
                        return item
                    }
                    self.activeSource = self
                    let session = self.beginDraggingSession(with: items, event: pressed.event, source: self)
                    session.draggingFormation = .stack
                    self.session = session
                    self.trace("session-created item-count=\(writers.count)")
                    self.preparation = nil
                } catch {
                    self?.trace("payload-read-failed cancelled=\(Task.isCancelled)")
                    // Failure starts no session and exports no partial item.
                    // A cancelled gesture has no late UI or pasteboard effect.
                }
            }
        default: break
        }
    }

    private func cancelPreparation() {
        if preparation != nil || pressed != nil { trace("preparation-cancelled") }
        preparation?.cancel()
        preparation = nil
        pressed = nil
    }

    /// Stage every format before AppKit publishes the session. Receivers get
    /// the exact dynamic identifiers and Data; file URLs remain inert values,
    /// and a later revision/removal cannot mix bytes into this gesture.
    static func pasteboardItems(for payload: PastePayload) throws -> [NSPasteboardItem] {
        let grouped = Dictionary(grouping: payload.representations, by: \.pasteboardItemIndex)
        return try grouped.keys.sorted().map { index in
            let writer = NSPasteboardItem()
            for representation in grouped[index] ?? [] {
                guard writer.setData(representation.bytes, forType: .init(representation.typeIdentifier)) else {
                    throw NSError(domain: NSItemProvider.errorDomain,
                                  code: NSItemProvider.ErrorCode.itemUnavailableError.rawValue)
                }
            }
            return writer
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        trace("session-will-begin")
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        trace("session-ended operation=\(operation.rawValue)")
        self.session = nil
        activeSource = nil
        cancelPreparation()
    }
    private func trace(_ stage: @autoclosure () -> String) {
#if DEBUG
        guard let dragTraceURL, dragTraceLines.count < 32 else { return }
        let value = stage()
        guard !dragTraceLines.contains(value) else { return }
        dragTraceLines.append(value)
        let lines = dragTraceLines.map { "[DEBUG-native-drag] " + $0 }.joined(separator: "\n")
        try? Data(lines.utf8).write(to: dragTraceURL, options: .atomic)
#endif
    }

}
