import AppKit
import Foundation
import HistoryCore
import HistoryStorage
import Testing
@testable import ClipyApp

/// Drives the real native window with explicit screen coordinates. SwiftUI
/// gesture delivery is covered separately by the running-app preview journey.
@Suite("Hosted floating-preview width", .serialized)
@MainActor
struct FloatingPreviewResizeHostedTests {
    @Test(arguments: [false, true])
    func resizingKeepsItsSideAndSavesOnlyAtMouseUp(leading: Bool) async throws {
        let item = try await capturedReference()
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let visible = screen.visibleFrame
        try #require(visible.width >= 900)
        let suite = "clipy-preview-resize-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appDelegate = AppDelegate()
        let main = NSWindow(
            contentRect: NSRect(
                x: leading ? visible.maxX - 360 : visible.minX,
                y: visible.maxY - 420, width: 360, height: 420),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        main.isReleasedWhenClosed = false
        main.orderFrontRegardless()
        defer { main.close() }
        appDelegate.previewState.togglePreview(for: item)
        let preview = FloatingPreviewPanel(
            rootView: FloatingPreviewRootView(appDelegate: appDelegate), defaults: defaults
        )
        defer {
            appDelegate.previewState.panelClosed()
            preview.dismiss()
        }
        preview.present(beside: main)
        let original = preview.frame
        let originalMain = main.frame
        #expect(appDelegate.previewState.isPreviewOnLeadingSide == leading)

        preview.resizeWidth(at: 1_000)
        preview.resizeWidth(at: leading ? 920 : 1_080)
        #expect(preview.frame.width == original.width + 80)
        #expect(leading ? preview.frame.maxX == original.maxX : preview.frame.minX == original.minX)
        #expect(appDelegate.previewState.displayedPreviewWidth == preview.frame.width)
        #expect(appDelegate.previewState.isResizingPreview)
        #expect(defaults.object(forKey: PanelGeometry.floatingPreviewWidthDefaultsKey) == nil)

        // Content changes during drag cannot move the handle vertically.
        preview.fitToContent(height: 100)
        #expect(preview.frame.height == original.height)
        preview.finishWidthResize()
        #expect(!appDelegate.previewState.isResizingPreview)
        #expect(preview.frame.width == original.width + 80)
        #expect(preview.frame.height == 100)
        #expect(PanelGeometry.persistedFloatingPreviewWidth(from: defaults) == original.width + 80)
        #expect(defaults.bool(forKey: PanelGeometry.usesCustomFloatingPreviewWidthDefaultsKey))
        #expect(main.frame == originalMain)

        preview.dismiss()
        preview.present(beside: main)
        #expect(preview.frame.width == original.width + 80)
        #expect(main.frame == originalMain)
        preview.adjustWidth(by: 20)
        #expect(preview.frame.width == original.width + 100)
        #expect(PanelGeometry.persistedFloatingPreviewWidth(from: defaults) == original.width + 100)
        #expect(main.frame == originalMain)
    }

    @Test func dismissalDuringDragDoesNotSaveAnUnfinishedWidth() async throws {
        let item = try await capturedReference()
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let visible = screen.visibleFrame
        try #require(visible.width >= 900)
        let suite = "clipy-preview-cancel-resize-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appDelegate = AppDelegate()
        let main = NSWindow(
            contentRect: NSRect(x: visible.minX, y: visible.maxY - 420, width: 360, height: 420),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        main.isReleasedWhenClosed = false
        main.orderFrontRegardless()
        defer { main.close() }
        appDelegate.previewState.togglePreview(for: item)
        let preview = FloatingPreviewPanel(
            rootView: FloatingPreviewRootView(appDelegate: appDelegate), defaults: defaults
        )
        defer { appDelegate.previewState.panelClosed() }
        preview.present(beside: main)
        preview.resizeWidth(at: 1_000)
        preview.resizeWidth(at: 1_080)
        #expect(preview.frame.width == 420)
        preview.dismiss()
        preview.finishWidthResize()
        #expect(!preview.isPresented)
        #expect(!appDelegate.previewState.isResizingPreview)
        #expect(defaults.object(forKey: PanelGeometry.floatingPreviewWidthDefaultsKey) == nil)
    }

    @Test func largeSavedWidthFitsTheCurrentScreenWithoutRewritingThePreference() throws {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let visible = screen.visibleFrame
        let suite = "clipy-preview-fit-width-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        PanelGeometry.persistFloatingPreviewWidth(visible.width + 500, to: defaults)
        let appDelegate = AppDelegate()
        let main = NSWindow(
            contentRect: NSRect(x: visible.minX, y: visible.maxY - 420, width: 360, height: 420),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        main.isReleasedWhenClosed = false
        main.orderFrontRegardless()
        defer { main.close() }
        let preview = FloatingPreviewPanel(
            rootView: FloatingPreviewRootView(appDelegate: appDelegate), defaults: defaults
        )
        defer { preview.dismiss() }
        preview.present(beside: main)
        #expect(preview.frame.width == visible.width)
        #expect(PanelGeometry.persistedFloatingPreviewWidth(from: defaults) == visible.width + 500)
    }

    @Test(arguments: [false, true])
    func finishingResizeKeepsTheHandlePositionWithAFittedGapOrOverlap(overlapping: Bool) async throws {
        let item = try await capturedReference()
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let visible = screen.visibleFrame
        try #require(visible.width >= 900)
        let suite = "clipy-preview-resize-anchor-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Double(visible.width), forKey: PanelGeometry.floatingPreviewGapDefaultsKey)
        if overlapping {
            PanelGeometry.persistFloatingPreviewWidth(visible.width - 100, to: defaults)
        }
        let appDelegate = AppDelegate()
        let main = NSWindow(
            contentRect: NSRect(
                x: overlapping ? visible.midX - 180 : visible.minX,
                y: visible.maxY - 420, width: 360, height: 420),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        main.isReleasedWhenClosed = false
        main.orderFrontRegardless()
        defer { main.close() }
        appDelegate.previewState.togglePreview(for: item)
        let preview = FloatingPreviewPanel(
            rootView: FloatingPreviewRootView(appDelegate: appDelegate), defaults: defaults
        )
        defer {
            appDelegate.previewState.panelClosed()
            preview.dismiss()
        }
        preview.present(beside: main)
        let initialWidth = preview.frame.width
        preview.resizeWidth(at: 1_000)
        preview.resizeWidth(at: appDelegate.previewState.isPreviewOnLeadingSide ? 1_064 : 936)
        let beforeRelease = preview.frame
        #expect(beforeRelease.width == initialWidth - 64)
        preview.finishWidthResize()
        #expect(preview.frame == beforeRelease)
        preview.fitToContent(height: 100)
        #expect(preview.frame.minX == beforeRelease.minX)
        #expect(preview.frame.width == beforeRelease.width)

        // A new explicit spacing choice replaces the temporary drag anchor.
        defaults.set(0, forKey: PanelGeometry.floatingPreviewGapDefaultsKey)
        preview.present(beside: main)
        #expect(preview.frame == PopupPositionGeometry.floatingPreviewFrame(
            beside: main.frame, in: visible,
            previewWidth: beforeRelease.width, previewHeight: 100, gap: 0
        ).frame)
    }

    private func capturedReference() async throws -> HistoryItemReference {
        let history = try await ComposedSupport.openMemoryHistory()
        _ = try await history.perform(.capture(ComposedSupport.textCapture(
            "preview-width", observedAt: Date(), source: nil
        )))
        let page = try await history.browse(.init(kind: .recent, limit: 1))
        return try #require(page.rows.first).item
    }
}
