/// HistoryRowAccessibilityHostedTests — runtime evidence for the combined
/// row's explicit operability contract (docs/v2/V2-07-ux.md §9). The tests
/// traverse the AppKit accessibility tree produced by `NSHostingView`, then
/// perform its default and named actions; no source-string proxy is used.
import AppKit
import HistoryCore
import HistoryStorage
import PresentationUI
import SwiftUI
import Testing

@Suite("Hosted history-row accessibility actions")
@MainActor
struct HistoryRowAccessibilityHostedTests {

    @Test
    func unpinnedRowPerformsCopyPinDetailsAndRemove() async throws {
        let rowFixture = try await rowFixture(pinned: false)
        let row = rowFixture.row
        let recorder = RowActionRecorder()
        let hosted = hostedRow(
            row,
            history: rowFixture.history,
            recorder: recorder
        )
        let fixture = host(hosted)
        defer { fixture.window.close() }

        let element = try #require(
            await rowElement(for: row, in: fixture.hostingView),
            "The combined row must materialize as one identified AX element"
        )

        #expect(element.accessibilityPerformPress(), "Copy is the default AX action")
        try perform("Pin", on: element)
        try perform("Show Details", on: element)
        try perform("Remove", on: element)

        #expect(customActionNames(of: element) == ["Pin", "Remove", "Show Details"])
        #expect(recorder.events == [
            .copy(row.item),
            .pin(row.item.id, .first),
            .showDetails(row.item),
            .remove(row.item.id),
        ])
    }

    @Test
    func pinnedRowPerformsCopyUnpinDetailsAndRemove() async throws {
        let rowFixture = try await rowFixture(pinned: true)
        let row = rowFixture.row
        let recorder = RowActionRecorder()
        let hosted = hostedRow(
            row,
            history: rowFixture.history,
            recorder: recorder
        )
        let fixture = host(hosted)
        defer { fixture.window.close() }

        let element = try #require(
            await rowElement(for: row, in: fixture.hostingView),
            "The combined pinned row must materialize as one identified AX element"
        )

        #expect(element.accessibilityPerformPress(), "Copy remains the default AX action")
        try perform("Unpin", on: element)
        try perform("Show Details", on: element)
        try perform("Remove", on: element)

        #expect(customActionNames(of: element) == ["Remove", "Show Details", "Unpin"])
        #expect(recorder.events == [
            .copy(row.item),
            .unpin(row.item.id),
            .showDetails(row.item),
            .remove(row.item.id),
        ])
    }

    private func rowFixture(pinned: Bool) async throws -> RowFixture {
        let history = try await ComposedSupport.openMemoryHistory()
        let receipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                pinned ? "pinned accessibility row" : "unpinned accessibility row",
                observedAt: Date(timeIntervalSinceReferenceDate: 702_000_000),
                source: "com.example.clipy.accessibility"
            )
        ))
        let reference = try #require(
            ComposedSupport.insertedReference(
                from: receipt,
                "HistoryRow accessibility fixture"
            )
        )
        if pinned {
            _ = try await history.perform(.placePinned(reference.id, at: .first))
        }
        let page = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 20)
        )
        let row = try #require(
            page.rows.first { $0.item.id == reference.id },
            "The real in-memory History returns the inserted row"
        )
        #expect((row.pinnedPosition != nil) == pinned)
        return RowFixture(row: row, history: history)
    }

    private func hostedRow(
        _ row: HistoryRow,
        history: any ClipboardHistory,
        recorder: RowActionRecorder
    ) -> some View {
        HistoryRowView(
            row: row,
            pinnedOrdinal: row.pinnedPosition.map { $0 + 1 },
            thumbnails: ThumbnailStore(history: history),
            onCopy: { recorder.events.append(.copy($0)) },
            onPin: { recorder.events.append(.pin($0, $1)) },
            onUnpin: { recorder.events.append(.unpin($0)) },
            onRemove: { recorder.events.append(.remove($0)) },
            onShowDetails: { recorder.events.append(.showDetails($0)) }
        )
        .padding()
        .frame(width: 420)
    }

    private func host<Content: View>(
        _ content: Content
    ) -> HostedFixture<Content> {
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: 440, height: 90)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        // Row custom actions do not require keyboard focus. Avoid stealing
        // the shared AppKit field editor from concurrently running hosted
        // search tests, whose product behavior genuinely depends on a key
        // window.
        window.orderFront(nil)
        return HostedFixture(window: window, hostingView: hostingView)
    }

    private func rowElement<Content: View>(
        for row: HistoryRow,
        in hostingView: NSHostingView<Content>
    ) async -> (any NSAccessibilityProtocol)? {
        let identifier = "clipy.history.row.\(row.item.id.description)"
        let deadline = Date().addingTimeInterval(2)
        repeat {
            hostingView.layoutSubtreeIfNeeded()
            if let element = accessibilityElement(
                identifier: identifier,
                in: hostingView
            ), customActionNames(of: element).count == 3 {
                return element
            }
            try? await Task.sleep(for: .milliseconds(10))
        } while Date() < deadline
        return accessibilityElement(identifier: identifier, in: hostingView)
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

    private func customActionNames(
        of element: any NSAccessibilityProtocol
    ) -> [String] {
        (element.accessibilityCustomActions() ?? []).map(\.name).sorted()
    }

    private func perform(
        _ name: String,
        on element: any NSAccessibilityProtocol
    ) throws {
        let action = try #require(
            element.accessibilityCustomActions()?.first { $0.name == name },
            "The hosted AX element exposes the named \(name) action"
        )
        let handler = try #require(
            action.handler,
            "SwiftUI's AppKit bridge provides an executable handler for \(name)"
        )
        #expect(handler(), "The named \(name) action reports successful execution")
    }
}

private struct RowFixture {
    let row: HistoryRow
    let history: SwiftDataHistory
}

@MainActor
private final class RowActionRecorder {
    var events: [RowActionEvent] = []
}

private enum RowActionEvent: Equatable {
    case copy(HistoryItemReference)
    case pin(HistoryItemID, PinnedPlacement)
    case unpin(HistoryItemID)
    case showDetails(HistoryItemReference)
    case remove(HistoryItemID)
}

@MainActor
private struct HostedFixture<Content: View> {
    let window: NSWindow
    let hostingView: NSHostingView<Content>
}
