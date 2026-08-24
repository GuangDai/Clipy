/// Actual hosted accessibility-tree tracer for REVIEW Card 15A/15B. A real
/// NSPanel/NSHostingView exposes the production row element; its default and
/// named actions must reach the same AppComposition and History intents.
import AppKit
import Foundation
import HistoryCore
import HistoryStorage
import PasteboardAdapter
import PresentationUI
import SwiftUI
import Testing
@testable import ClipyApp

@Suite("Hosted accessibility tree and product actions")
@MainActor
struct AccessibilityTreeHostedTests {
    @Test
    func rowDefaultAndNamedActionsReachProductOwners() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let expectedText = "hosted accessibility action"
        let receipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                expectedText,
                observedAt: Date(
                    timeIntervalSinceReferenceDate: 700_337_000
                ),
                source: "com.example.AccessibilitySource"
            )
        ))
        let reference = try #require(
            ComposedSupport.insertedReference(
                from: receipt,
                "AX arrange"
            )
        )

        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard)
        )
        defer { composition.stop() }
        var pasteCompletionCount = 0
        var shownDetails: HistoryItemReference?
        composition.onPasteCompleted = { pasteCompletionCount += 1 }
        composition.viewState.activate()
        try #require(await ComposedSupport.waitFor {
            composition.viewState.rows.map(\.item) == [reference]
        })

        let hosted = HostedAccessibilityHistoryList(
            viewState: composition.viewState,
            thumbnails: ThumbnailStore(history: history),
            onShowDetails: { shownDetails = $0 }
        )
        let hostingView = NSHostingView(rootView: hosted)
        hostingView.frame = NSRect(x: 0, y: 0, width: 400, height: 560)
        let panel = NSPanel(
            contentRect: hostingView.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.contentView = hostingView
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        hostingView.needsLayout = true
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        defer { panel.close() }

        let identifier = "clipy.history.row.\(reference.id.description)"
        let row = await ComposedSupport.waitForValue(timeout: 5) {
            accessibilityElement(in: hostingView, identifier: identifier)
        }
        guard let row else {
            Issue.record(
                "Row was absent from public AX children:\n\(accessibilityTreeDescription(hostingView))"
            )
            return
        }
        #expect(row.accessibilityRole() == .button)
        let label = try #require(row.accessibilityLabel())
        #expect(label.contains(expectedText))
        #expect(label.contains("AccessibilitySource"))
        let actionNames = Set(
            (row.accessibilityCustomActions() ?? []).map(\.name)
        )
        #expect(actionNames == Set(["Pin", "Show Details", "Remove"]))

        #expect(row.accessibilityPerformPress())
        try #require(await ComposedSupport.waitFor {
            pasteboard.string(forType: .string) == expectedText
                && pasteCompletionCount == 1
        })

        let pin = try #require(row.accessibilityCustomActions()?.first(where: {
            $0.name == "Pin"
        }))
        #expect(pin.handler?() == true)
        try #require(await ComposedSupport.waitFor {
            composition.viewState.rows.first?.pinnedPosition == 0
        })

        let pinnedRow = try #require(await ComposedSupport.waitForValue {
            accessibilityElement(in: hostingView, identifier: identifier)
        })
        let details = try #require(
            pinnedRow.accessibilityCustomActions()?.first(where: {
                $0.name == "Show Details"
            })
        )
        #expect(details.handler?() == true)
        #expect(shownDetails == reference)

        let remove = try #require(
            pinnedRow.accessibilityCustomActions()?.first(where: {
                $0.name == "Remove"
            })
        )
        #expect(remove.handler?() == true)
        try #require(await ComposedSupport.waitFor {
            composition.viewState.rows.isEmpty
        })
    }
}

@MainActor
private struct HostedAccessibilityHistoryList: View {
    let viewState: HistoryViewState
    let thumbnails: ThumbnailStore
    let onShowDetails: (HistoryItemReference) -> Void

    @State private var selection: HistoryItemID?

    var body: some View {
        HistoryListView(
            viewState: viewState,
            thumbnails: thumbnails,
            isSearchFieldFocused: false,
            selection: $selection,
            onShowDetails: onShowDetails
        )
    }
}

@MainActor
private func accessibilityElement(
    in root: Any,
    identifier: String,
    remainingDepth: Int = 24
) -> (any NSAccessibilityProtocol)? {
    guard remainingDepth > 0,
          let element = root as? any NSAccessibilityProtocol else {
        return nil
    }
    if element.accessibilityIdentifier() == identifier {
        return element
    }
    for child in element.accessibilityChildren() ?? [] {
        if let match = accessibilityElement(
            in: child,
            identifier: identifier,
            remainingDepth: remainingDepth - 1
        ) {
            return match
        }
    }
    return nil
}

@MainActor
private func accessibilityTreeDescription(
    _ root: Any,
    remainingDepth: Int = 8,
    indentation: String = ""
) -> String {
    guard remainingDepth > 0,
          let element = root as? any NSAccessibilityProtocol else {
        return "\(indentation)<non-AX>\n"
    }
    var result = "\(indentation)role=\(String(describing: element.accessibilityRole()))"
    result += " id=\(element.accessibilityIdentifier() ?? "nil")"
    result += " label=\(element.accessibilityLabel() ?? "nil")\n"
    for child in element.accessibilityChildren() ?? [] {
        result += accessibilityTreeDescription(
            child,
            remainingDepth: remainingDepth - 1,
            indentation: indentation + "  "
        )
    }
    return result
}
