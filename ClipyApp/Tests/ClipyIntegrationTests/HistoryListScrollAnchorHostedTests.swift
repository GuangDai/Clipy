/// Exercises the production SwiftUI viewport while the bounded three-page
/// window retires and inserts real History pages (04 §6, V2-09 §12).
/// Frames and scroll input use AppKit's public accessibility interface; no
/// SwiftUI implementation views or replacement history writer are involved.
import AppKit
import HistoryCore
import HistoryStorage
import SwiftUI
import Testing
@testable import ClipyApp

@Suite("Hosted history scroll anchors", .serialized)
@MainActor
struct HistoryListScrollAnchorHostedTests {
    private static let pageLimit = 24

    @Test(arguments: [false, true])
    func loadingOlderPreservesTheVisibleRowWhenTheNewestPageIsRetired(
        retireSelection: Bool
    ) async throws {
        let fixture = try await makeFixture(preloadedPages: 3)
        defer { fixture.close() }

        // Retain keyboard mode: a reconciled selection must not be mistaken
        // for an arrow-key command that scrolls back to the window's start.
        if retireSelection {
            fixture.surface.selection = fixture.orderedIDs[0]
        }
        try await fixture.scroll(to: 0.80, expectedFirstVisibleIndex: 48..<64)
        let anchor = try #require(fixture.visibleRows().first)
        if !retireSelection {
            fixture.surface.selection = anchor.id
        }
        let before = try await fixture.settledOffset(of: anchor.id)

        // The last four rows remain outside the viewport, so this explicit
        // request isolates publication from automatic edge prefetch.
        #expect(fixture.state.rows.count == Self.pageLimit * 3)
        #expect(fixture.visibleRows().allSatisfy { $0.index < 68 })
        fixture.state.loadNextPage()
        let advanced = await ComposedSupport.waitFor {
            fixture.state.rows.first?.item.id == fixture.orderedIDs[24]
                && fixture.state.rows.last?.item.id == fixture.orderedIDs[95]
                && !fixture.state.isLoadingPage
        }
        try #require(advanced)

        try await fixture.expectAnchor(anchor.id, offset: before)
        #expect(fixture.state.loadedPageCount == 3)
        #expect(fixture.state.failure == nil)
        if retireSelection {
            #expect(fixture.surface.selection != fixture.orderedIDs[0])
        } else {
            #expect(fixture.surface.selection == anchor.id)
        }
    }

    @Test
    func loadingNewerPreservesTheVisibleRowWhenTheOldestPageIsRetired() async throws {
        let fixture = try await makeFixture(preloadedPages: 3)
        defer { fixture.close() }
        // Establish the older window from its interior. Mounting an older
        // window at the top would correctly start automatic newer prefetch.
        try await fixture.scroll(to: 0.80, expectedFirstVisibleIndex: 48..<64)
        fixture.state.loadNextPage()
        let olderLoaded = await ComposedSupport.waitFor {
            fixture.state.rows.first?.item.id == fixture.orderedIDs[24]
                && fixture.state.rows.last?.item.id == fixture.orderedIDs[95]
                && !fixture.state.isLoadingPage
        }
        try #require(olderLoaded)
        try #require(fixture.state.hasPreviousPage)

        // Start within the first retained page, clear of its automatic newer
        // threshold, and keep the page that will be retired fully offscreen.
        try await fixture.scroll(to: 0.16, expectedFirstVisibleIndex: 30..<44)
        let anchor = try #require(fixture.visibleRows().first)
        fixture.surface.selection = anchor.id
        let before = try await fixture.settledOffset(of: anchor.id)
        #expect(fixture.visibleRows().allSatisfy { $0.index > 27 && $0.index < 72 })

        fixture.state.loadPreviousPage()
        let returned = await ComposedSupport.waitFor {
            fixture.state.rows.first?.item.id == fixture.orderedIDs[0]
                && fixture.state.rows.last?.item.id == fixture.orderedIDs[71]
                && !fixture.state.isLoadingPage
        }
        try #require(returned)

        try await fixture.expectAnchor(anchor.id, offset: before)
        #expect(fixture.surface.selection == anchor.id)
        #expect(fixture.state.loadedPageCount == 3)
        #expect(!fixture.state.hasPreviousPage)
        #expect(fixture.state.failure == nil)
    }

    private func makeFixture(preloadedPages: Int) async throws -> Fixture {
        let history = try await ComposedSupport.openMemoryHistory()
        let base = Date(timeIntervalSinceReferenceDate: 700_321_000)
        var insertedIDs: [HistoryItemID] = []
        for index in 0..<120 {
            let receipt = try await history.perform(.capture(ComposedSupport.textCapture(
                "Scroll anchor item \(index)",
                observedAt: base.addingTimeInterval(Double(index)),
                source: "com.example.clipy.scroll-anchor"
            )))
            let item = try #require(ComposedSupport.insertedReference(
                from: receipt, "Hosted scroll-anchor arrange"
            ))
            insertedIDs.append(item.id)
        }
        let orderedIDs = Array(insertedIDs.reversed())
        let state = HistoryViewState(history: history, pageLimit: Self.pageLimit)
        state.activate()
        let firstLoaded = await ComposedSupport.waitFor {
            state.hasAuthoritativeFirstPage && state.rows.count == Self.pageLimit
        }
        try #require(firstLoaded)
        for page in 1..<preloadedPages {
            state.loadNextPage()
            let lastExpectedID = orderedIDs[(page + 1) * Self.pageLimit - 1]
            let loaded = await ComposedSupport.waitFor {
                state.rows.last?.item.id == lastExpectedID && !state.isLoadingPage
            }
            try #require(loaded)
        }

        let preview = PreviewPaneState()
        let surface = HistoryPanelSurfaceState(history: history, previewState: preview)
        surface.beginSession(rows: state.rows)
        return Fixture(state: state, surface: surface, preview: preview, orderedIDs: orderedIDs)
    }

    /// Observes the SwiftUI publication boundary as well as the model update.
    /// This prevents an unchanged pre-publication AX frame from passing the
    /// assertion before the list has consumed its replacement page window.
    @MainActor
    private final class RenderObservation {
        var rowIDs: [HistoryItemID] = []
    }

    private struct HostedPanel: View {
        let state: HistoryViewState
        let surface: HistoryPanelSurfaceState
        let preview: PreviewPaneState
        let observation: RenderObservation

        var body: some View {
            HistoryPanelView(
                viewState: state, previewState: preview, surfaceState: surface,
                appearance: PanelAppearanceSettings(isPreviewAutoOpenEnabled: false)
            )
            .onChange(of: state.rows.map(\.item.id), initial: true) { _, ids in
                observation.rowIDs = ids
            }
        }
    }

    @MainActor
    private final class Fixture {
        struct VisibleRow {
            let id: HistoryItemID
            let index: Int
            let offset: CGFloat
        }

        let state: HistoryViewState
        let surface: HistoryPanelSurfaceState
        let orderedIDs: [HistoryItemID]
        private let observation: RenderObservation
        private let host: NSHostingView<HostedPanel>
        private let window: NSWindow

        init(
            state: HistoryViewState, surface: HistoryPanelSurfaceState,
            preview: PreviewPaneState, orderedIDs: [HistoryItemID]
        ) {
            self.state = state
            self.surface = surface
            self.orderedIDs = orderedIDs
            let observation = RenderObservation()
            let host = NSHostingView(rootView: HostedPanel(
                state: state, surface: surface, preview: preview, observation: observation
            ))
            host.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            self.observation = observation
            self.host = host
            self.window = window
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
        }

        func close() {
            window.close()
            surface.endSession()
            state.deactivate()
        }

        func scroll(to fraction: Double, expectedFirstVisibleIndex: Range<Int>) async throws {
            let ready = await ComposedSupport.waitFor {
                self.host.layoutSubtreeIfNeeded()
                return self.scrollElement()?.accessibilityVerticalScrollBar() != nil
            }
            try #require(ready, "The mounted production list exposes its vertical scrollbar")
            let scroller = try #require(
                scrollElement()?.accessibilityVerticalScrollBar() as? any NSAccessibilityProtocol
            )
            let minimum = try #require(scroller.accessibilityMinValue() as? NSNumber).doubleValue
            let maximum = try #require(scroller.accessibilityMaxValue() as? NSNumber).doubleValue
            scroller.setAccessibilityValue(NSNumber(value: minimum + (maximum - minimum) * fraction))
            let positioned = await ComposedSupport.waitFor {
                self.host.layoutSubtreeIfNeeded()
                guard let first = self.visibleRows().first else { return false }
                return expectedFirstVisibleIndex.contains(first.index) && !self.state.isLoadingPage
            }
            try #require(positioned, "The scrollbar moves the viewport to the retained page's interior")
        }

        func settledOffset(of id: HistoryItemID) async throws -> CGFloat {
            var previous: CGFloat?
            var stableSamples = 0
            let settled = await ComposedSupport.waitFor {
                self.host.layoutSubtreeIfNeeded()
                guard self.observation.rowIDs == self.state.rows.map(\.item.id),
                      let offset = self.visibleRows().first(where: { $0.id == id })?.offset
                else { return false }
                stableSamples = previous.map { abs($0 - offset) <= 1 } == true ? stableSamples + 1 : 0
                previous = offset
                return stableSamples >= 3
            }
            try #require(settled, "The target row must remain visible after SwiftUI publishes the page window")
            return try #require(previous)
        }

        func expectAnchor(_ id: HistoryItemID, offset: CGFloat) async throws {
            let after = try await settledOffset(of: id)
            #expect(abs(after - offset) <= 1,
                    "Inserting or retiring a page must preserve the visible row's pixel offset")
        }

        func visibleRows() -> [VisibleRow] {
            guard let scroll = scrollElement() else { return [] }
            let viewport = scroll.accessibilityFrame()
            guard !viewport.isEmpty else { return [] }
            let indices = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map {
                ("clipy.history.row.\($0.element.description)", $0.offset)
            })
            return accessibilityElements(beneath: scroll).compactMap { element -> VisibleRow? in
                guard let identifier = element.accessibilityIdentifier(),
                      let index = indices[identifier] else { return nil }
                let frame = element.accessibilityFrame()
                // Use a fully visible row, excluding clipped edge text and
                // offscreen lazy rows retained in the accessibility tree.
                guard !frame.isEmpty, viewport.contains(frame) else { return nil }
                return VisibleRow(id: orderedIDs[index], index: index,
                                  offset: viewport.maxY - frame.maxY)
            }.sorted { $0.offset < $1.offset }
        }

        private func scrollElement() -> (any NSAccessibilityProtocol)? {
            accessibilityElements(beneath: host).first {
                $0.accessibilityIdentifier() == "clipy.history.scroll"
            }
        }

        /// Only the documented NSAccessibility hierarchy is inspected. The
        /// test never assumes any private NSHostingView descendant class.
        private func accessibilityElements(
            beneath root: any NSAccessibilityProtocol
        ) -> [any NSAccessibilityProtocol] {
            var pending: [any NSAccessibilityProtocol] = [root]
            var index = 0
            while index < pending.count && index < 4_096 {
                let element = pending[index]
                index += 1
                pending.append(contentsOf: (element.accessibilityChildren() ?? []).compactMap {
                    $0 as? any NSAccessibilityProtocol
                })
            }
            return pending
        }
    }
}
