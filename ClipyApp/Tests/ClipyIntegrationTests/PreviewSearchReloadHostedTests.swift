import AppKit
import HistoryCore
import SwiftUI
import Testing
@testable import ClipyApp

/// Exercises the real observation and SwiftUI onChange boundary. A query's
/// temporary empty rows are not an authoritative removal of the selected item.
@Suite("Hosted preview through search reload", .serialized)
@MainActor
struct PreviewSearchReloadHostedTests {
    @Test func matchingQueryReloadKeepsPreviewButAuthoritativeMissClosesIt() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        _ = try await history.perform(.capture(ComposedSupport.textCapture(
            "The exact spelling when selected remains unchanged.",
            observedAt: Date(timeIntervalSinceReferenceDate: 700_319_000),
            source: "com.example.clipy.preview-query"
        )))
        let viewState = HistoryViewState(history: history)
        viewState.activate()
        defer { viewState.deactivate() }
        viewState.searchMode = .exact
        viewState.searchText = "spelling"
        let loaded = await ComposedSupport.waitFor {
            viewState.hasAuthoritativeFirstPage && viewState.rows.count == 1
        }
        try #require(loaded)
        let item = try #require(viewState.rows.first?.item)
        let preview = PreviewPaneState(autoOpenDelay: .zero)
        let surface = HistoryPanelSurfaceState(history: history, previewState: preview)
        surface.beginSession(rows: viewState.rows)
        defer { surface.endSession() }
        let host = NSHostingView(rootView: HistoryPanelView(
            viewState: viewState, previewState: preview, surfaceState: surface,
            appearance: PanelAppearanceSettings(isPreviewAutoOpenEnabled: true)
        ))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // This test observes state changes, not keyboard focus. Showing the
        // host without making it key avoids competing with other hosted tests.
        window.orderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        // Only the production selection observer can start this zero-delay
        // dwell, so opening proves the initial onChange has been consumed.
        surface.selection = item.id
        let opened = await ComposedSupport.waitFor {
            host.layoutSubtreeIfNeeded()
            return preview.isOpen && preview.previewedItem == item
        }
        try #require(opened)
        var hiddenCount = 0
        preview.onFloatingPreviewTransition = { transition in
            if case .hide = transition { hiddenCount += 1 }
        }

        viewState.searchText = "spelling when"
        #expect(!viewState.hasAuthoritativeFirstPage)
        #expect(viewState.rows.isEmpty)
        host.layoutSubtreeIfNeeded()
        let reloaded = await ComposedSupport.waitFor {
            host.layoutSubtreeIfNeeded()
            return viewState.hasAuthoritativeFirstPage && viewState.rows.first?.item == item
        }
        try #require(reloaded)
        #expect(surface.selection == item.id)
        #expect(preview.previewedItem == item)
        #expect(preview.isOpen)
        #expect(hiddenCount == 0, "The loading placeholder must not close the visible preview")

        viewState.searchText = "this exact query has no matching row"
        let missed = await ComposedSupport.waitFor {
            host.layoutSubtreeIfNeeded()
            return viewState.hasAuthoritativeFirstPage && viewState.rows.isEmpty
                && surface.selection == nil && !preview.isOpen
        }
        #expect(missed)
        #expect(hiddenCount == 1, "An authoritative miss still retires the selected preview")
    }
}
