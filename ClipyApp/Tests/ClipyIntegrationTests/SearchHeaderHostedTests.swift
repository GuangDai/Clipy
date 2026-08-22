/// SearchHeaderHostedTests — Card 8G evidence at the real AppKit/SwiftUI
/// boundary (docs/v2/V2-07-ux.md §9): stable accessibility identifiers,
/// byte-preserving search entry, and the visible Clear button's immediate
/// `.recent` intent are exercised through controls materialized by
/// `NSHostingView`, not through source inspection or a pixel snapshot.
import AppKit
import HistoryCore
import HistoryStorage
import PresentationUI
import SwiftUI
import Testing

@Suite("Hosted search controls")
@MainActor
struct SearchHeaderHostedTests {

    /// Proves only behavior observable from controls in the headless hosted
    /// test process. Full Keyboard Access tab-order is a user preference and
    /// cannot be established reliably here; this test deliberately makes no
    /// claim about that system-level traversal policy.
    @Test
    func textFieldPreservesLiteralSyntaxAndClearStartsOneRecentIntent() async throws {
        let storage = try await ComposedSupport.openMemoryHistory()
        let history = RecordingHistory(base: storage)
        let viewState = HistoryViewState(history: history)
        defer { viewState.deactivate() }
        viewState.activate()

        #expect(await waitForRequests(from: history) { $0.count == 1 })

        let hosted = HostedSearchHeader(viewState: viewState)
        let hostingView = NSHostingView(rootView: hosted)
        hostingView.frame = NSRect(x: 0, y: 0, width: 520, height: 80)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        let searchField = try #require(
            await hostedControl(
                NSTextField.self,
                identifier: "clipy.search.field",
                in: hostingView
            ),
            "Card 8G: the actual search field has a stable AX identifier"
        )

        viewState.searchMode = .exact
        let exactLiteral = "  teh clipboard  "
        try replaceText(exactLiteral, in: searchField, window: window)
        #expect(await ComposedSupport.waitFor {
            viewState.searchText == exactLiteral
        })
        #expect(searchField.stringValue == exactLiteral)
        #expect(await waitForRequests(from: history) {
            $0.last?.kind == .search(text: exactLiteral, mode: .exact)
        })
        #expect(window.makeFirstResponder(nil))
        #expect(viewState.searchText == exactLiteral)
        #expect(searchField.stringValue == exactLiteral)

        viewState.searchMode = .regexp
        let regexpLiteral = "  ^(teh|clipy)\\s+$  "
        try replaceText(regexpLiteral, in: searchField, window: window)
        #expect(await ComposedSupport.waitFor {
            viewState.searchText == regexpLiteral
        })
        #expect(searchField.stringValue == regexpLiteral)
        #expect(await waitForRequests(from: history) {
            $0.last?.kind == .search(text: regexpLiteral, mode: .regexp)
        })
        #expect(window.makeFirstResponder(nil))
        #expect(viewState.searchText == regexpLiteral)
        #expect(searchField.stringValue == regexpLiteral)

        let clearButton = try #require(
            await hostedControl(
                NSButton.self,
                identifier: "clipy.search.clear",
                in: hostingView
            ),
            "Card 8G: the visible Clear control has a stable AX identifier"
        )
        let requestCountBeforeClear = await history.requests().count
        clearButton.performClick(nil)

        #expect(await waitForRequests(from: history) {
            $0.count == requestCountBeforeClear + 1
                && $0.last?.kind == .recent
        })
        #expect(viewState.searchText.isEmpty)
        #expect(searchField.stringValue.isEmpty)

        let focusReturned = await ComposedSupport.waitFor {
            let fieldEditor = window.fieldEditor(false, for: searchField)
            return window.firstResponder === searchField
                || window.firstResponder === fieldEditor
        }
        #expect(
            focusReturned,
            "Clear returns focus to the search field inside the hosted window"
        )
    }

    private func replaceText(
        _ text: String,
        in field: NSTextField,
        window: NSWindow
    ) throws {
        #expect(window.makeFirstResponder(field))
        field.selectText(nil)
        let editor = try #require(
            field.currentEditor() as? NSTextView,
            "The hosted NSTextField provides its ordinary field editor"
        )
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    private func hostedControl<Control: NSView>(
        _ type: Control.Type,
        identifier: String,
        in hostingView: NSHostingView<HostedSearchHeader>
    ) async -> Control? {
        var match: Control?
        _ = await ComposedSupport.waitFor {
            hostingView.layoutSubtreeIfNeeded()
            match = descendant(
                of: type,
                identifier: identifier,
                below: hostingView
            )
            return match != nil
        }
        return match
    }

    private func waitForRequests(
        from history: RecordingHistory,
        timeout: TimeInterval = 2,
        matching condition: ([HistoryObservationRequest]) -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(await history.requests()) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition(await history.requests())
    }

    private func descendant<Control: NSView>(
        of type: Control.Type,
        identifier: String,
        below view: NSView
    ) -> Control? {
        if let control = view as? Control,
           control.accessibilityIdentifier() == identifier {
            return control
        }
        for child in view.subviews {
            if let match = descendant(
                of: type,
                identifier: identifier,
                below: child
            ) {
                return match
            }
        }
        return nil
    }
}

@MainActor
private struct HostedSearchHeader: View {
    let viewState: HistoryViewState
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        SearchHeaderView(
            viewState: viewState,
            searchFieldFocused: $searchFieldFocused
        )
        .padding()
    }
}

/// Transparent recording decorator: every operation still runs against the
/// real `SwiftDataHistory`; this only exposes the public observation intents
/// emitted by the hosted UI so the Clear cardinality can be asserted.
private actor RecordingHistory: ClipboardHistory {
    private let base: any ClipboardHistory
    private(set) var observationRequests: [HistoryObservationRequest] = []

    init(base: any ClipboardHistory) {
        self.base = base
    }

    func requests() -> [HistoryObservationRequest] {
        observationRequests
    }

    func perform(_ action: HistoryAction) async throws -> HistoryReceipt {
        try await base.perform(action)
    }

    func browse(_ request: HistoryBrowseRequest) async throws -> HistoryPage {
        try await base.browse(request)
    }

    func observe(
        _ request: HistoryObservationRequest
    ) async -> AsyncThrowingStream<HistoryPage, Error> {
        observationRequests.append(request)
        return await base.observe(request)
    }

    func details(for id: HistoryItemID) async throws -> HistoryDetails {
        try await base.details(for: id)
    }

    func pastePayload(for id: HistoryItemID) async throws -> PastePayload {
        try await base.pastePayload(for: id)
    }

    func thumbnail(
        for item: HistoryItemReference,
        pixels: PixelSize
    ) async throws -> ThumbnailPayload? {
        try await base.thumbnail(for: item, pixels: pixels)
    }

    func retentionConfiguration() async throws -> HistoryRetentionConfiguration {
        try await base.retentionConfiguration()
    }
}
