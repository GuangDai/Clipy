import AppKit
import SwiftUI

/// The Settings scene still owns presentation, its menu item and Command–,.
/// Its AppKit window must also opt into interactive resizing; a SwiftUI
/// content minimum alone did not enable edge resizing on macOS 26.
struct SettingsWindowResizeConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsWindowResizeView {
        SettingsWindowResizeView()
    }

    func updateNSView(_ view: SettingsWindowResizeView, context: Context) {
        view.configureWindow()
    }
}

@MainActor
final class SettingsWindowResizeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
#if DEBUG
        installResizeDiagnostics()
#endif
        configureWindow()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
#if DEBUG
        if newWindow !== window { stopResizeDiagnostics() }
#endif
        super.viewWillMove(toWindow: newWindow)
    }

    override func layout() {
        super.layout()
#if DEBUG
        recordResizeState("after-layout")
#endif
    }

    func configureWindow() {
        guard let window else { return }
#if DEBUG
        recordResizeState("before-configuration")
#endif
        window.styleMask.insert(.resizable)
        window.contentMinSize = NSSize(width: 560, height: 420)
        window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
#if DEBUG
        recordResizeState("after-configuration")
#endif
    }

#if DEBUG
    // Temporary, opt-in diagnostics for the actual SwiftUI Settings window.
    // They contain geometry and framework types only, never History values.
    private var traceURL: URL?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var lastLayoutState: String?

    private func installResizeDiagnostics() {
        guard let window, traceURL == nil,
              ProcessInfo.processInfo.environment["CLIPY_RUNNING_UI_TEST"] == "1",
              let path = ProcessInfo.processInfo.environment["CLIPY_UI_TEST_SETTINGS_RESIZE_TRACE_PATH"] else { return }
        traceURL = URL(fileURLWithPath: path)
        let center = NotificationCenter.default
        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.willStartLiveResizeNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didResizeNotification,
        ] {
            center.addObserver(self, selector: #selector(recordResizeNotification(_:)), name: name, object: window)
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.recordMouse(event, source: "local") }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.recordMouse(event, source: "global") }
        }
        recordResizeState("attached")
    }

    private func stopResizeDiagnostics() {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
        NotificationCenter.default.removeObserver(self)
        traceURL = nil
        lastLayoutState = nil
    }

    @objc private func recordResizeNotification(_ notification: Notification) {
        recordResizeState(notification.name.rawValue)
    }

    private func recordMouse(_ event: NSEvent, source: String) {
        guard let window else { return }
        let point = NSEvent.mouseLocation
        appendResizeTrace(
            "mouse source=\(source) type=\(event.type.rawValue) screen=\(point) "
                + "insideFrame=\(window.frame.contains(point)) eventWindow=\(event.windowNumber) "
                + "settingsWindow=\(window.windowNumber) inLiveResize=\(window.inLiveResize)"
        )
        recordResizeState("mouse-\(source)-\(event.type.rawValue)")
    }

    private func recordResizeState(_ event: String) {
        guard traceURL != nil, let window else { return }
        let proposed = NSSize(width: 600, height: window.frame.height)
        let accepted = window.delegate?.windowWillResize?(window, to: proposed)
        var state = "windowType=\(String(reflecting: type(of: window))) "
            + "frame=\(window.frame) mask=\(window.styleMask.rawValue) "
            + "resizable=\(window.styleMask.contains(.resizable)) inLiveResize=\(window.inLiveResize) "
            + "min=\(window.minSize) max=\(window.maxSize) "
            + "contentMin=\(window.contentMinSize) contentMax=\(window.contentMaxSize) "
            + "increments=\(window.resizeIncrements) contentIncrements=\(window.contentResizeIncrements) "
            + "aspect=\(window.aspectRatio) contentAspect=\(window.contentAspectRatio) "
            + "delegate=\(window.delegate.map { String(reflecting: type(of: $0)) } ?? "nil") "
            + "proposal600=\(accepted.map { String(describing: $0) } ?? "no delegate response")"
        var ancestor: NSView? = self
        while let current = ancestor {
            state += "\nview=\(String(reflecting: type(of: current))) frame=\(current.frame) "
                + "intrinsic=\(current.intrinsicContentSize)"
            if let hosting = current as? any SettingsHostingResizeDiagnostics {
                state += " sizingOptions=\(hosting.settingsSizingDescription) fitting=\(current.fittingSize)"
            }
            ancestor = current.superview
        }
        if event == "after-layout", state == lastLayoutState { return }
        if event == "after-layout" { lastLayoutState = state }
        appendResizeTrace("[DEBUG-settings-resize] \(event) \(state)")
    }

    private func appendResizeTrace(_ line: String) {
        guard let traceURL else { return }
        if !FileManager.default.fileExists(atPath: traceURL.path) {
            _ = FileManager.default.createFile(atPath: traceURL.path, contents: nil)
        }
        guard let file = try? FileHandle(forWritingTo: traceURL) else { return }
        defer { try? file.close() }
        do {
            _ = try file.seekToEnd()
            try file.write(contentsOf: Data((line + "\n").utf8))
        } catch { }
    }
#endif
}

#if DEBUG
/// Type erasure reads the public sizingOptions of an NSHostingView with any
/// Content type, including the scene's framework-owned generic root.
@MainActor
private protocol SettingsHostingResizeDiagnostics {
    var settingsSizingDescription: String { get }
}

extension NSHostingView: SettingsHostingResizeDiagnostics {
    fileprivate var settingsSizingDescription: String { String(describing: sizingOptions) }
}
#endif
