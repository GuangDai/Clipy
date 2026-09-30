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
    @Test
    func repeatedPresentationKeepsTheFrameAndDoesNotRestartTheArrivalAnimation() throws {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let visible = screen.visibleFrame
        let owner = AppDelegate()
        let main = NSWindow(
            contentRect: NSRect(x: visible.minX, y: visible.maxY - 420, width: 360, height: 420),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        main.isReleasedWhenClosed = false
        main.orderFrontRegardless()
        defer { main.close() }
        var arrivals = 0
        let preview = FloatingPreviewPanel(
            rootView: FloatingPreviewRootView(appDelegate: owner),
            presentationDuration: { _ in arrivals += 1; return 0.435 }
        )
        defer { preview.dismiss() }
        preview.present(beside: main)
        let firstFrame = preview.frame
        #expect(preview.isVisible)
        preview.contentView?.layoutSubtreeIfNeeded()
        #expect(preview.frame == firstFrame)
        preview.present(beside: main)
        #expect(preview.frame == firstFrame)
        #expect(arrivals == 1)
        #expect(main.childWindows?.filter { $0 === preview }.count == 1)

        // Native modal ordering can hide a window without changing the
        // product's intended visibility. Reconcile it without a new arrival.
        preview.orderOut(nil)
        #expect(preview.isPresented && !preview.isVisible)
        preview.present(beside: main)
        #expect(preview.isPresented && preview.isVisible)
        #expect(arrivals == 1)

        let resizedMainHeight = PanelGeometry.minimumHeight + 40
        main.setFrame(NSRect(x: main.frame.minX, y: main.frame.maxY - resizedMainHeight,
                             width: main.frame.width, height: resizedMainHeight), display: false)
        preview.present(beside: main)
        #expect(preview.frame.height == main.frame.height)
        #expect(owner.previewState.availablePreviewHeight == main.frame.height)
        #expect(arrivals == 1)
        preview.dismiss()
        #expect(!preview.isVisible)
        preview.present(beside: main)
        #expect(arrivals == 2)
        #expect(preview.frame.height == main.frame.height)
        preview.dismiss()
        #expect(!preview.isPresented && !preview.isVisible)
    }

    @Test
    func anAttachedSheetRetainsItsOwnerFrameUntilEndAndDismissalEndsTheModal() async throws {
        let item = try await capturedReference()
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let visible = screen.visibleFrame
        try #require(visible.height >= 500)
        let owner = AppDelegate()
        let pointer = NSEvent.mouseLocation
        let initialHeight = PanelGeometry.minimumHeight + 20
        let main = NSWindow(
            contentRect: NSRect(x: visible.minX,
                                y: pointer.y < visible.midY ? visible.maxY - initialHeight : visible.minY,
                                width: 360, height: initialHeight),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        main.isReleasedWhenClosed = false
        main.orderFrontRegardless()
        owner.previewState.togglePreview(for: item)
        let preview = FloatingPreviewPanel(rootView: FloatingPreviewRootView(appDelegate: owner))
        let alert = NSAlert()
        alert.messageText = "Hosted preview confirmation"
        alert.addButton(withTitle: "OK")
        defer {
            preview.dismiss()
            owner.previewState.panelClosed()
            main.close()
        }
        preview.present(beside: main)
        alert.beginSheetModal(for: preview) { _ in }
        try #require(await ComposedSupport.waitFor { preview.attachedSheet === alert.window })
        try #require(!preview.frame.contains(NSEvent.mouseLocation))
        try #require(!main.frame.contains(NSEvent.mouseLocation))
        #expect(!owner.previewState.isFileConfirmationPresented)
        #expect(owner.previewState.pointerSurfacesContainingPointer?().contains(.preview) == true)
        let modalOwnerFrame = preview.frame
        var resizedMainFrame = main.frame
        // Keep the parent's origin fixed so native child-window movement
        // cannot itself reposition the modal owner during this resize.
        resizedMainFrame.size.height = PanelGeometry.minimumHeight + 10
        main.setFrame(resizedMainFrame, display: false)
        preview.present(beside: main)
        resizedMainFrame.size.height = PanelGeometry.minimumHeight
        main.setFrame(resizedMainFrame, display: false)
        preview.present(beside: main)
        #expect(preview.frame == modalOwnerFrame)
        preview.endSheet(alert.window)
        try #require(await ComposedSupport.waitFor {
            preview.attachedSheet == nil && preview.frame.height == main.frame.height
        })
        #expect(preview.isPresented && preview.isVisible)

        // A purge/close must end an attached modal immediately. Its native
        // end callback cannot restore a pane whose presentation was retired.
        alert.beginSheetModal(for: preview) { _ in }
        try #require(await ComposedSupport.waitFor { preview.attachedSheet === alert.window })
        preview.dismiss()
        #expect(!preview.isPresented && !preview.isVisible)
        try #require(await ComposedSupport.waitFor { preview.attachedSheet == nil })
        #expect(!preview.isPresented && !preview.isVisible)
        #expect(main.childWindows?.contains(preview) != true)

        // A close from the real sheet-completion callback also wins over
        // geometry queued by didEndSheet in the same native exit pass.
        preview.present(beside: main)
        var sheetCompletionObserved = false
        alert.beginSheetModal(for: preview) { _ in
            preview.dismiss()
            sheetCompletionObserved = true
        }
        try #require(await ComposedSupport.waitFor { preview.attachedSheet === alert.window })
        resizedMainFrame.size.height = PanelGeometry.minimumHeight + 10
        main.setFrame(resizedMainFrame, display: false)
        preview.present(beside: main)
        preview.endSheet(alert.window)
        try #require(await ComposedSupport.waitFor {
            sheetCompletionObserved && preview.attachedSheet == nil
        })
        #expect(owner.previewState.isOpen)
        #expect(!preview.isPresented && !preview.isVisible)
        #expect(main.childWindows?.contains(preview) != true)
    }

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
        #expect(main.frame == originalMain)

        // A parent resize during drag cannot move the handle vertically;
        // releasing it resumes following the parent's actual height.
        let resizedMainHeight = PanelGeometry.minimumHeight + 40
        main.setFrame(NSRect(x: main.frame.minX, y: main.frame.maxY - resizedMainHeight,
                             width: main.frame.width, height: resizedMainHeight), display: false)
        let resizedMain = main.frame
        preview.present(beside: main)
        #expect(preview.frame.height == original.height)
        preview.finishWidthResize()
        #expect(!appDelegate.previewState.isResizingPreview)
        #expect(preview.frame.width == original.width + 80)
        #expect(preview.frame.height == main.frame.height)
        #expect(PanelGeometry.persistedFloatingPreviewWidth(from: defaults) == original.width + 80)
        #expect(defaults.bool(forKey: PanelGeometry.usesCustomFloatingPreviewWidthDefaultsKey))
        #expect(main.frame == resizedMain)

        preview.dismiss()
        preview.present(beside: main)
        #expect(preview.frame.width == original.width + 80)
        #expect(main.frame == resizedMain)
        preview.adjustWidth(by: 20)
        #expect(preview.frame.width == original.width + 100)
        #expect(PanelGeometry.persistedFloatingPreviewWidth(from: defaults) == original.width + 100)
        #expect(main.frame == resizedMain)
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
        preview.contentView?.layoutSubtreeIfNeeded()
        preview.present(beside: main)
        #expect(preview.frame == beforeRelease)
        #expect(preview.frame.minX == beforeRelease.minX)
        #expect(preview.frame.width == beforeRelease.width)

        // A new explicit spacing choice replaces the temporary drag anchor.
        defaults.set(0, forKey: PanelGeometry.floatingPreviewGapDefaultsKey)
        preview.present(beside: main)
        #expect(preview.frame == PopupPositionGeometry.floatingPreviewFrame(
            beside: main.frame, in: visible,
            previewWidth: beforeRelease.width, gap: 0
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
