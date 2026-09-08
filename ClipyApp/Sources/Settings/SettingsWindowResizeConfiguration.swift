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
        configureWindow()
    }

    func configureWindow() {
        guard let window else { return }
        window.styleMask.insert(.resizable)
        window.contentMinSize = NSSize(width: 560, height: 420)
        window.contentMaxSize = NSSize(width: .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    }
}
