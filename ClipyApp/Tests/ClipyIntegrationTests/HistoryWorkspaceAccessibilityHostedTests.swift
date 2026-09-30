import AppKit
import HistoryCore
import HistoryStorage
import SwiftUI
import Testing
@testable import ClipyApp

@Suite("History workspace accessibility", .serialized)
@MainActor
struct HistoryWorkspaceAccessibilityHostedTests {
    @Test func workspaceGroupKeepsDistinctSearchSortAndListControls() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        _ = try await history.perform(.capture(ComposedSupport.textCapture(
            "Workspace accessibility row", observedAt: Date(timeIntervalSinceReferenceDate: 700_331_000)
        )))
        let state = HistoryViewState(history: history)
        let host = NSHostingView(rootView: HistoryWorkspaceView(
            viewState: state, copyState: HistoryWorkspaceCopyState()
        ))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.close()
            state.deactivate()
        }
        let required: Set<String> = [
            "clipy.history.workspace", "clipy.search.field", "clipy.history.workspace.refresh",
            "clipy.history.workspace.sort", "clipy.history.workspace.count",
            "clipy.history.workspace.select-page", "clipy.history.workspace.list",
        ]
        let ready = await ComposedSupport.waitFor {
            host.layoutSubtreeIfNeeded()
            let identifiers = Set(accessibilityElements(beneath: host).compactMap { $0.accessibilityIdentifier() })
            return state.hasAuthoritativeFirstPage && required.isSubset(of: identifiers)
        }
        try #require(ready, "The workspace group must retain every child control's own accessibility identifier")
        let elements = accessibilityElements(beneath: host)
        #expect(elements.first { $0.accessibilityIdentifier() == "clipy.history.workspace.refresh" }?.accessibilityRole() == .button)
        #expect(elements.first { $0.accessibilityIdentifier() == "clipy.search.field" }?.accessibilityRole() == .textField)
    }

    private func accessibilityElements(beneath root: any NSAccessibilityProtocol) -> [any NSAccessibilityProtocol] {
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
