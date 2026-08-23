/// HistoryListPaginationHostedTests — hosted evidence for REVIEW Card 8B.
/// A real all-pinned first page is allowed to paginate when its overall last
/// displayed row appears; the test observes only the public panel state and
/// never traverses SwiftUI's private view or accessibility trees.
import AppKit
import Foundation
import HistoryCore
import HistoryStorage
import PresentationUI
import SwiftUI
import Testing

@Suite("Hosted history-list pagination")
@MainActor
struct HistoryListPaginationHostedTests {

    @Test
    func lastVisiblePinnedRowLoadsTheContinuationPage() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let base = Date(timeIntervalSinceReferenceDate: 700_317_000)
        var expectedIDs: [HistoryItemID] = []

        for index in 0..<2 {
            let receipt = try await history.perform(.capture(
                ComposedSupport.textCapture(
                    "hosted pinned pagination \(index)",
                    observedAt: base.addingTimeInterval(Double(index)),
                    source: "com.example.clipy.pagination"
                )
            ))
            let item = try #require(
                ComposedSupport.insertedReference(
                    from: receipt,
                    "Card 8B hosted arrange"
                )
            )
            expectedIDs.append(item.id)
            _ = try await history.perform(.placePinned(item.id, at: .last))
        }

        let viewState = HistoryViewState(history: history, pageLimit: 1)
        defer { viewState.deactivate() }
        viewState.activate()

        let firstPageSettled = await ComposedSupport.waitFor {
            viewState.rows.count == 1
                && viewState.pinnedRows.count == 1
                && viewState.hasNextPage
        }
        #expect(
            firstPageSettled,
            "Card 8B: the all-pinned first page settles with a continuation"
        )
        #expect(viewState.rows.map(\.item.id) == [expectedIDs[0]])

        let hostedList = HostedHistoryList(
            viewState: viewState,
            thumbnails: ThumbnailStore(history: history)
        )
        let hostingView = NSHostingView(rootView: hostedList)
        hostingView.frame = NSRect(x: 0, y: 0, width: 400, height: 560)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.orderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        defer { window.close() }

        let continuationLoaded = await ComposedSupport.waitFor {
            viewState.rows.count == 2
                && viewState.pinnedRows.count == 2
                && !viewState.hasNextPage
        }
        #expect(
            continuationLoaded,
            "Card 8B: mounting the production list makes its last pinned row appear and appends the continuation page"
        )
        #expect(viewState.rows.map(\.item.id) == expectedIDs)
        #expect(viewState.failure == nil)
    }
}

@MainActor
private struct HostedHistoryList: View {
    let viewState: HistoryViewState
    let thumbnails: ThumbnailStore

    @State private var selection: HistoryItemID?

    var body: some View {
        HistoryListView(
            viewState: viewState,
            thumbnails: thumbnails,
            isSearchFieldFocused: false,
            selection: $selection,
            onShowDetails: { _ in }
        )
    }
}
