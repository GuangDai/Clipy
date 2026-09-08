import AppKit
import Testing
@testable import ClipyApp

@MainActor
@Suite("Settings window resizing", .serialized)
struct SettingsWindowResizeHostedTests {
    @Test func attachingSettingsContentEnablesNativeResizeAndReleasesFixedBounds() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 780, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentMinSize = NSSize(width: 780, height: 620)
        window.contentMaxSize = NSSize(width: 780, height: 620)
        #expect(!window.styleMask.contains(.resizable))
        let originalFrame = window.frame
        let resizeView = SettingsWindowResizeView()
        let content = try #require(window.contentView)
        content.addSubview(resizeView)

        #expect(window.styleMask.contains(.resizable))
        #expect(window.contentMinSize == NSSize(width: 560, height: 420))
        #expect(window.contentMaxSize.width > 780)
        #expect(window.contentMaxSize.height > 620)
        #expect(window.frame == originalFrame)

        // The configuration changes capabilities and constraints, never the
        // user's current size. Reapplying it after pane updates is harmless.
        window.setContentSize(NSSize(width: 600, height: 520))
        let narrowFrame = window.frame
        resizeView.configureWindow()
        #expect(window.frame == narrowFrame)
        #expect(window.contentRect(forFrameRect: window.frame).width == 600)
        window.setContentSize(NSSize(width: 700, height: 520))
        #expect(window.contentRect(forFrameRect: window.frame).width == 700)
    }
}
