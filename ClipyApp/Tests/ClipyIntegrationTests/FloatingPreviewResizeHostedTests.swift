import AppKit
import CoreGraphics
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

    @Test(arguments: [false, true])
    func anAttachedSheetRetainsItsOwnerFrameUntilEndAndDismissalEndsTheModal(critical: Bool) async throws {
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
        alert.alertStyle = critical ? .critical : .warning
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
        let followedParent = await ComposedSupport.waitFor {
            preview.attachedSheet == nil && preview.frame.height == main.frame.height
        }
        try #require(followedParent,
                     "sheet=\(String(describing: preview.attachedSheet)) presented=\(preview.isPresented) open=\(owner.previewState.isOpen) visible=\(preview.isVisible) parentVisible=\(main.isVisible) preview=\(preview.frame) parent=\(main.frame)")
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
    func endingTheNativeSheetRestoresPointerExitAfterTheConfirmationBindingClears(critical: Bool) async throws {
        let item = try await capturedReference()
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let visible = screen.visibleFrame
        try #require(visible.height >= 500)
        let owner = AppDelegate()
        var interaction = AdvancedInteractionSettings()
        interaction.pointerGraceMilliseconds = 0
        owner.previewState.applyInteractionSettings(interaction)
        let height = PanelGeometry.minimumHeight + 20
        try #require(height < visible.height / 2)
        let pointer = NSEvent.mouseLocation
        let main = NSWindow(
            contentRect: NSRect(x: visible.minX,
                                y: pointer.y < visible.midY ? visible.maxY - height : visible.minY,
                                width: 360, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        main.isReleasedWhenClosed = false
        main.orderFrontRegardless()
        owner.previewState.togglePreview(for: item)
        let preview = FloatingPreviewPanel(rootView: FloatingPreviewRootView(appDelegate: owner))
        owner.previewState.onFloatingPreviewTransition = { [weak preview] transition in
            if case .hide = transition { preview?.dismiss() }
        }
        defer {
            owner.previewState.onFloatingPreviewTransition = nil
            owner.previewState.panelClosed()
            preview.dismiss()
            main.close()
        }
        preview.present(beside: main)
        let alert = NSAlert()
        alert.alertStyle = critical ? .critical : .warning
        alert.messageText = "Hosted preview confirmation exit"
        alert.addButton(withTitle: "OK")
        var sheetCompleted = false
        owner.previewState.isPointerInteractionActive = true
        owner.previewState.pointerEntered(.preview)
        owner.previewState.isFileConfirmationPresented = true
        alert.beginSheetModal(for: preview) { _ in sheetCompleted = true }
        try #require(await ComposedSupport.waitFor { preview.attachedSheet === alert.window })
        try #require(!preview.frame.contains(NSEvent.mouseLocation))
        try #require(!main.frame.contains(NSEvent.mouseLocation))
        try #require(owner.previewState.pointerIsBetweenSurfaces?() == false)
        owner.previewState.pointerExited(.preview)

        // SwiftUI can clear its binding while the native sheet still owns
        // the preview. That binding change must keep the sheet's owner alive.
        owner.previewState.isFileConfirmationPresented = false
        await Task.yield()
        await Task.yield()
        #expect(owner.previewState.isOpen)
        #expect(preview.isPresented)
        #expect(preview.attachedSheet === alert.window)

        preview.endSheet(alert.window)
        try #require(await ComposedSupport.waitFor {
            sheetCompleted && preview.attachedSheet == nil && !owner.previewState.isOpen
                && !preview.isPresented
        })
        #expect(owner.previewState.previewedItem == nil)
        #expect(!preview.isVisible)
        #expect(main.childWindows?.contains(preview) != true)
    }

    @Test(arguments: [false, true], [false, true])
    func endingASheetWithThePointerOnItsActionKeepsOnlyItsOriginalPresentation(
        critical: Bool, reopensInCompletion: Bool
    ) async throws {
        let item = try await capturedReference()
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let visible = screen.visibleFrame
        try #require(visible.height >= 500)
        let owner = AppDelegate()
        var interaction = AdvancedInteractionSettings()
        interaction.pointerGraceMilliseconds = 0
        owner.previewState.applyInteractionSettings(interaction)
        let height = PanelGeometry.minimumHeight + 20
        try #require(height < visible.height / 2)
        let main = NSWindow(
            contentRect: NSRect(x: visible.minX,
                                y: visible.maxY - height,
                                width: 360, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        main.isReleasedWhenClosed = false
        main.orderFrontRegardless()
        owner.previewState.togglePreview(for: item)
        let preview = FloatingPreviewPanel(rootView: FloatingPreviewRootView(appDelegate: owner))
        owner.previewState.onFloatingPreviewTransition = { [weak preview] transition in
            if case .hide = transition { preview?.dismiss() }
        }
        defer {
            owner.previewState.onFloatingPreviewTransition = nil
            preview.dismiss()
            owner.previewState.panelClosed()
            main.close()
        }
        preview.present(beside: main)
        let alert = NSAlert()
        alert.alertStyle = critical ? .critical : .warning
        alert.messageText = "Hosted stationary sheet action"
        alert.informativeText = String(repeating: "Loading this local file keeps clipboard history unchanged.\n", count: 7)
        alert.addButton(withTitle: "OK")
        var sheetCompleted = false
        owner.previewState.isPointerInteractionActive = true
        owner.previewState.pointerEntered(.preview)
        owner.previewState.isFileConfirmationPresented = true
        alert.beginSheetModal(for: preview) { _ in
            if reopensInCompletion {
                preview.dismiss()
                preview.present(beside: main)
            }
            sheetCompleted = true
        }
        try #require(await ComposedSupport.waitFor { preview.attachedSheet === alert.window })
        let originalPointer = try #require(CGEvent(source: nil)).location
        defer { _ = CGWarpMouseCursorPosition(originalPointer) }
        try movePointer(to: try #require(alert.buttons.first), in: alert.window)
        try #require(alert.window.frame.contains(NSEvent.mouseLocation))
        try #require(!main.frame.contains(NSEvent.mouseLocation))
        try #require(!preview.frame.contains(NSEvent.mouseLocation))
        owner.previewState.pointerExited(.preview)
        owner.previewState.isFileConfirmationPresented = false
        preview.endSheet(alert.window)
        if reopensInCompletion {
            try #require(await ComposedSupport.waitFor {
                sheetCompleted && preview.attachedSheet == nil && preview.frame.height == main.frame.height
                    && owner.previewState.pointerSurfacesContainingPointer?().isEmpty == true
            })
            #expect(owner.previewState.isOpen && preview.isPresented && preview.isVisible)
            #expect(owner.previewState.previewedItem == item)
            owner.previewState.recheckPointerAfterModal()
            try #require(await ComposedSupport.waitFor { !owner.previewState.isOpen && !preview.isPresented })
            return
        }
        try #require(await ComposedSupport.waitFor {
            sheetCompleted && preview.attachedSheet == nil && preview.frame.height == main.frame.height
                && owner.previewState.pointerSurfacesContainingPointer?().contains(.preview) == true
        })
        try #require(!preview.frame.contains(NSEvent.mouseLocation))
        owner.previewState.recheckPointerAfterModal()
        await Task.yield()
        await Task.yield()
        #expect(owner.previewState.isOpen && preview.isPresented && preview.isVisible)
        #expect(owner.previewState.previewedItem == item)

        preview.cancelArrival()
        #expect(owner.previewState.pointerSurfacesContainingPointer?().isEmpty == true)
        // Retirement removes the completed-modal containment as well as the
        // movement observation; it cannot leak into a reopened preview.
        preview.dismiss()
        #expect(owner.previewState.pointerSurfacesContainingPointer?().isEmpty == true)
        preview.present(beside: main)
        #expect(owner.previewState.pointerSurfacesContainingPointer?().isEmpty == true)
        owner.previewState.recheckPointerAfterModal()
        try #require(await ComposedSupport.waitFor { !owner.previewState.isOpen && !preview.isPresented })
    }

    @Test(arguments: [false, true])
    func endingTheParentsNativeSheetRestoresThePreviewsPointerExit(critical: Bool) async throws {
        let item = try await capturedReference()
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let visible = screen.visibleFrame
        try #require(visible.height >= 500)
        let owner = AppDelegate()
        var interaction = AdvancedInteractionSettings()
        interaction.pointerGraceMilliseconds = 0
        owner.previewState.applyInteractionSettings(interaction)
        let main = FloatingPanel(
            rootView: PanelRootView(appDelegate: owner),
            previewState: owner.previewState,
            onClosed: { owner.previewState.panelClosed() }
        )
        main.open(at: .center, statusItemButtonScreenFrame: nil)
        let pointer = NSEvent.mouseLocation
        let height = PanelGeometry.minimumHeight + 20
        try #require(height < visible.height / 2)
        main.setFrameForScreenChangeTesting(NSRect(
            x: visible.minX,
            y: pointer.y < visible.midY ? visible.maxY - height : visible.minY,
            width: 360, height: height
        ))
        owner.previewState.togglePreview(for: item)
        let preview = FloatingPreviewPanel(rootView: FloatingPreviewRootView(appDelegate: owner))
        owner.previewState.onFloatingPreviewTransition = { [weak preview] transition in
            if case .hide = transition { preview?.dismiss() }
        }
        defer {
            owner.previewState.onFloatingPreviewTransition = nil
            if let sheet = main.attachedSheet {
                main.endSheet(sheet)
                sheet.orderOut(nil)
            }
            preview.dismiss()
            main.close()
        }
        preview.present(beside: main)
        let alert = NSAlert()
        alert.alertStyle = critical ? .critical : .warning
        alert.messageText = "Hosted parent confirmation exit"
        alert.addButton(withTitle: "OK")
        var sheetCompleted = false
        alert.beginSheetModal(for: main) { _ in sheetCompleted = true }
        try #require(await ComposedSupport.waitFor { main.attachedSheet === alert.window })
        try #require(!main.frame.contains(NSEvent.mouseLocation))
        try #require(!preview.frame.contains(NSEvent.mouseLocation))
        try #require(owner.previewState.pointerIsBetweenSurfaces?() == false)
        owner.previewState.isPointerInteractionActive = true
        owner.previewState.pointerEntered(.preview)
        owner.previewState.pointerExited(.preview)
        owner.previewState.recheckPointerAfterModal()
        #expect(owner.previewState.pointerSurfacesContainingPointer?().contains(.mainPanel) == true)
        #expect(owner.previewState.isOpen && preview.isPresented)

        main.endSheet(alert.window)
        try #require(await ComposedSupport.waitFor {
            sheetCompleted && main.attachedSheet == nil && !owner.previewState.isOpen
                && !preview.isPresented
        })
        #expect(main.isPresented)
        #expect(!preview.isVisible)
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

    private func movePointer(to button: NSButton, in window: NSWindow) throws {
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let point = CGPoint(x: buttonFrame.midX,
                            y: CGDisplayBounds(CGMainDisplayID()).height - buttonFrame.midY)
        try #require(CGWarpMouseCursorPosition(point) == .success)
    }
}
