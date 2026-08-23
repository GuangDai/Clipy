/// HostedPanelAccessibilityTests — the first actual-view discriminator for
/// REVIEW Card 15A. It mounts the production PanelRootView in the production
/// FloatingPanel, then observes only AppKit's public accessibility interface.
/// No SwiftUI backing view, private class name, Mirror, or pixel output is an
/// oracle here.
import AppKit
import Foundation
import HistoryCore
import HistoryStorage
import PasteboardAdapter
import Testing
@testable import ClipyApp

@MainActor
struct HostedPanelAccessibilityTests {

    /// A real SwiftUI row hosted by the real panel exposes the stable identity,
    /// button semantics, user-facing content/source label, and default action
    /// declared by HistoryRowView. The search field proves the composed panel
    /// root — not a row-only test replica — supplied both observed elements.
    @Test
    func productionPanelExposesHistoryRowAndSearchFieldToAccessibility() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let receipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                "row-ax-probe",
                observedAt: Date(timeIntervalSinceReferenceDate: 700_315_000),
                source: "com.example.RowOracle"
            )
        ))
        let reference = try #require(
            ComposedSupport.insertedReference(from: receipt, "hosted AX row seed")
        )

        let pasteboard = ComposedSupport.makePasteboard()
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard),
            initialCaptureAccessBehavior: .allowed
        )
        let appDelegate = AppDelegate()
        appDelegate.installCompositionForTesting(composition)

        let panel = FloatingPanel(
            rootView: PanelRootView(appDelegate: appDelegate),
            previewState: appDelegate.previewState,
            onPreviewPlacementChange: { _ in },
            onClosed: {}
        )
        defer {
            panel.close()
            composition.stop()
        }

        panel.open(at: .center, statusItemButtonScreenFrame: nil)
        let contentView = try #require(panel.contentView)
        let rowIdentifier = "clipy.history.row.\(reference.id.description)"

        let searchField = waitForAccessibilityElement(
            identifier: "clipy.search.field",
            in: panel,
            layoutRoot: contentView
        )
        let row = waitForAccessibilityElement(
            identifier: rowIdentifier,
            in: panel,
            layoutRoot: contentView
        )

        let actualSearchField = try #require(
            searchField,
            "the production search field must enter the hosted AX tree"
        )
        let actualRow = try #require(
            row,
            "the observed history row must enter the hosted AX tree"
        )

        #expect(actualSearchField.accessibilityIdentifier() == "clipy.search.field")
        #expect(actualRow.accessibilityIdentifier() == rowIdentifier)
        #expect(actualRow.isAccessibilityElement())
        #expect(actualRow.isAccessibilityEnabled())
        #expect(actualRow.accessibilityRole() == .button)

        let label = try #require(actualRow.accessibilityLabel())
        #expect(label.contains("row-ax-probe"))
        #expect(label.contains("RowOracle"))

        // Apple's public action method returns true only when it successfully
        // triggers the element's button action. This is an action oracle, not
        // a claim that the asynchronous paste side effect has completed.
        #expect(actualRow.accessibilityPerformPress())
    }

    /// Bounded same-process layout/AX convergence. Running the main run loop
    /// lets SwiftUI's hosted `.task` observation and AppKit accessibility
    /// bridge publish naturally; there is no fixed sleep deciding the result.
    private func waitForAccessibilityElement(
        identifier: String,
        in root: any NSAccessibilityProtocol,
        layoutRoot: NSView,
        timeout: Duration = .seconds(5)
    ) -> (any NSAccessibilityProtocol)? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            layoutRoot.layoutSubtreeIfNeeded()
            if let element = accessibilityElement(identifier: identifier, in: root) {
                return element
            }
            _ = RunLoop.main.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: 0.01)
            )
        }

        layoutRoot.layoutSubtreeIfNeeded()
        return accessibilityElement(identifier: identifier, in: root)
    }

    /// Breadth-first traversal of the public accessibility hierarchy only.
    /// The values' concrete AppKit/SwiftUI implementation classes are never
    /// inspected and therefore are not part of the test's interface.
    private func accessibilityElement(
        identifier: String,
        in root: any NSAccessibilityProtocol
    ) -> (any NSAccessibilityProtocol)? {
        var pending: [any NSAccessibilityProtocol] = [root]
        var index = 0

        while index < pending.count {
            let element = pending[index]
            index += 1
            if element.accessibilityIdentifier() == identifier {
                return element
            }
            let children = element.accessibilityChildren() ?? []
            pending.append(contentsOf: children.compactMap {
                $0 as? any NSAccessibilityProtocol
            })
        }
        return nil
    }
}
