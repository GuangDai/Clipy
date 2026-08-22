/// PanelPreviewPlacementHostedTests — app-hosted evidence for REVIEW Cards
/// 9C/9F at the real SwiftUI/AppKit boundary. The tests host the production
/// `HistoryPanelView` in the production `FloatingPanel`, then inspect the
/// AppKit accessibility tree's screen-space frames. This proves one-process
/// column ordering and preservation of the main surface across the actual
/// `NSPanel` resize; WindowServer behavior across Spaces, display hot-plug,
/// and multiple physical displays remains a signed runtime gate.
import AppKit
import Foundation
import HistoryCore
import Observation
import PresentationUI
import SwiftUI
import Testing
@testable import ClipyApp

@MainActor
struct PanelPreviewPlacementHostedTests {

    @Test
    func trailingPreviewKeepsTheHostedMainSurfaceFixed() async throws {
        try await proveHostedPlacement(.trailing)
    }

    @Test
    func leadingPreviewKeepsTheHostedMainSurfaceFixed() async throws {
        try await proveHostedPlacement(.leading)
    }

    private func proveHostedPlacement(
        _ expectedPlacement: PreviewPlacement
    ) async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let receipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                "Hosted preview placement",
                observedAt: Date(timeIntervalSinceReferenceDate: 700_500_000)
            )
        ))
        let reference = try #require(
            ComposedSupport.insertedReference(
                from: receipt,
                "hosted preview placement fixture"
            )
        )

        let viewState = HistoryViewState(history: history)
        let previewState = PreviewPaneState(autoOpenDelay: .zero)
        let placement = HostedPreviewPlacement()
        let rootView = HostedHistoryPanel(
            viewState: viewState,
            previewState: previewState,
            placement: placement
        )
        let panel = FloatingPanel(
            rootView: rootView,
            previewState: previewState,
            onPreviewPlacementChange: { placement.value = $0 },
            onClosed: {}
        )
        defer {
            viewState.deactivate()
            panel.orderOut(nil)
        }

        let screen = try #require(NSScreen.screens.first)
        let hostedMargin: CGFloat = 8
        try #require(
            screen.visibleFrame.width
                >= PanelGeometry.totalWidth(previewOpen: true) + 2 * hostedMargin
        )
        try #require(
            screen.visibleFrame.height >= PanelGeometry.height + 2 * hostedMargin
        )
        let mainFrame = mainSurfaceFrame(
            for: expectedPlacement,
            in: screen.visibleFrame
        )
        panel.setFrame(mainFrame, display: false)
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        let panelBefore = panel.frame

        let mainBefore = try #require(await accessibleFrame(
            identifier: "clipy.history.main-column",
            in: panel
        ))

        previewState.togglePreview(for: reference)
        panel.setPreviewVisible(true)
        let observedPlacement = placement.value
        #expect(observedPlacement == expectedPlacement)
        #expect(
            abs(
                panel.frame.width
                    - PanelGeometry.totalWidth(previewOpen: true)
            ) <= 0.5
        )
        switch expectedPlacement {
        case .leading:
            #expect(panel.frame.minX < panelBefore.minX)
        case .trailing:
            #expect(abs(panel.frame.minX - panelBefore.minX) <= 0.5)
        }

        let previewOpen = try #require(await accessibleFrame(
            identifier: "clipy.history.preview-column",
            in: panel
        ))
        // Finding the newly inserted preview first fences the following
        // main-frame read to the expanded SwiftUI hierarchy.
        let mainOpen = try #require(await accessibleFrame(
            identifier: "clipy.history.main-column",
            in: panel
        ))

        #expect(rectApproximatelyEqual(mainOpen, mainBefore))
        switch expectedPlacement {
        case .leading:
            #expect(previewOpen.maxX <= mainOpen.minX)
        case .trailing:
            #expect(mainOpen.maxX <= previewOpen.minX)
        }

        previewState.togglePreview(for: reference)
        panel.setPreviewVisible(false)
        #expect(await waitForAccessibilityElement(
            identifier: "clipy.history.preview-column",
            present: false,
            in: panel
        ))
        let mainAfter = try #require(await accessibleFrame(
            identifier: "clipy.history.main-column",
            in: panel
        ))
        #expect(rectApproximatelyEqual(mainAfter, mainBefore))
        #expect(rectApproximatelyEqual(panel.frame, panelBefore))
    }

    /// Picks a real-screen frame which forces the requested branch without
    /// pretending that a synthetic rectangle is an `NSScreen`. The pure
    /// tests own literal multi-screen geometry; this hosted control owns the
    /// actual AppKit/SwiftUI frame handoff only (Card 9C support limit).
    private func mainSurfaceFrame(
        for placement: PreviewPlacement,
        in screen: NSRect
    ) -> NSRect {
        let margin: CGFloat = 8
        let x: CGFloat
        switch placement {
        case .leading:
            x = screen.maxX - PanelGeometry.contentWidth - margin
        case .trailing:
            x = screen.minX + margin
        }
        return NSRect(
            x: x,
            y: screen.minY + margin,
            width: PanelGeometry.contentWidth,
            height: min(PanelGeometry.height, screen.height - 2 * margin)
        )
    }

    private func accessibleFrame(
        identifier: String,
        in panel: FloatingPanel
    ) async -> NSRect? {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            panel.contentView?.layoutSubtreeIfNeeded()
            if let root = panel.contentView,
               let element = accessibilityElement(
                   identifier: identifier,
                   in: root
               ) {
                return element.accessibilityFrame()
            }
            try? await Task.sleep(for: .milliseconds(10))
        } while Date() < deadline
        return nil
    }

    private func waitForAccessibilityElement(
        identifier: String,
        present: Bool,
        in panel: FloatingPanel
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            panel.contentView?.layoutSubtreeIfNeeded()
            let found = panel.contentView.flatMap {
                accessibilityElement(identifier: identifier, in: $0)
            } != nil
            if found == present { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while Date() < deadline
        return (panel.contentView.flatMap {
            accessibilityElement(identifier: identifier, in: $0)
        } != nil) == present
    }

    private func accessibilityElement(
        identifier: String,
        in candidate: Any
    ) -> (any NSAccessibilityProtocol)? {
        guard let element = candidate as? any NSAccessibilityProtocol else {
            return nil
        }
        if element.accessibilityIdentifier() == identifier {
            return element
        }
        for child in element.accessibilityChildren() ?? [] {
            if let match = accessibilityElement(identifier: identifier, in: child) {
                return match
            }
        }
        return nil
    }

    private func rectApproximatelyEqual(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        let tolerance: CGFloat = 0.5
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}

@MainActor @Observable
private final class HostedPreviewPlacement {
    var value: PreviewPlacement = .trailing
}

private struct HostedHistoryPanel: View {
    let viewState: HistoryViewState
    let previewState: PreviewPaneState
    let placement: HostedPreviewPlacement

    var body: some View {
        HistoryPanelView(
            viewState: viewState,
            previewState: previewState,
            previewPlacement: placement.value
        )
    }
}
