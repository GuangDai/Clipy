/// ScreenParameterLifecycleHostedTests.swift — bounded Card 14C evidence for
/// AppKit's screen-configuration callback and the existing AppDelegate-owned
/// panel session. Synthetic offscreen geometry proves only the hosted owner
/// transition; it does not claim display hot-plug, Spaces, Stage Manager, or
/// a physical multi-display matrix.
import AppKit
import PasteboardAdapter
import Testing
@testable import ClipyApp

@Suite("Hosted screen-parameter lifecycle", .serialized)
@MainActor
struct ScreenParameterLifecycleHostedTests {
    @Test("reachable change keeps session; unreachable change closes until summon")
    func screenParameterChangePreservesOrRetiresTheOwnedSession() async throws {
        try #require(!NSScreen.screens.isEmpty)
        let history = LifecycleObservationHistory()
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "com.clipy.screen-parameter.\(UUID().uuidString)"
            )
        )
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard),
            observerPollInterval: 60,
            initialCaptureAccessBehavior: .allowed,
            captureAccessBehaviorProvider: { .allowed }
        )
        let appDelegate = AppDelegate()
        appDelegate.installCompositionForTesting(composition)
        defer {
            appDelegate.closePanel()
            composition.stop()
        }

        appDelegate.openPanelForTesting(at: .center)
        let panel = try #require(appDelegate.panelForTesting)
        let surface = try #require(appDelegate.panelSurfaceState)
        await history.waitForObservationCount(1)

        let notification = Notification(
            name: NSApplication.didChangeScreenParametersNotification,
            object: NSApp
        )
        appDelegate.applicationDidChangeScreenParameters(notification)

        // A Dock/menu-bar/configuration change that leaves the panel on a
        // current visible frame must not churn observation or selection state.
        #expect(panel.isPresented)
        #expect(surface.isSessionActive)
        #expect(surface.sessionGeneration == 1)

        // Keep the reachable and unreachable notifications in one MainActor
        // turn. A hosted NSPanel can independently resign key when the test
        // process yields; that production focus-loss path is proved by
        // PanelLifecycleHostedTests and must not race this screen callback.
        let currentFrames = NSScreen.screens.map(\.visibleFrame)
        let maximumX = currentFrames.map(\.maxX).max() ?? 0
        let maximumY = currentFrames.map(\.maxY).max() ?? 0
        panel.setFrameForScreenChangeTesting(
            NSRect(
                x: maximumX + 10_000,
                y: maximumY + 10_000,
                width: panel.frame.width,
                height: panel.frame.height
            )
        )
        appDelegate.applicationDidChangeScreenParameters(notification)
        await history.waitForTerminationCount(1)

        #expect(!panel.isPresented)
        #expect(!surface.isSessionActive)
        #expect(surface.sessionGeneration == 1)
        #expect(await history.observationCount == 1)
        #expect(await history.terminationCount == 1)

        // Screen changes never auto-open or steal focus. A later explicit
        // summon re-reads current NSScreen facts and owns one new generation.
        appDelegate.openPanelForTesting(at: .center)
        #expect(panel.isPresented)
        #expect(surface.isSessionActive)
        #expect(surface.sessionGeneration == 2)
        await history.waitForObservationCount(2)
        #expect(await history.observationCount == 2)
    }
}
