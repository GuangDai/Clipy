/// Hosted Card 5B characterization through the complete production capture
/// boundary: a real named private NSPasteboard, its public lazy-data-provider
/// API, PasteboardObserver, AppComposition, and the real in-memory
/// SQLiteHistory. No failure hook substitutes for the unavailable payload.
import AppKit
import Foundation
import HistoryCore
import HistoryStorage
import PasteboardAdapter
import Synchronization
import Testing
@testable import ClipyApp

@Suite("Hosted exact pasteboard outcomes (Card 5B)")
struct AppCaptureExactOutcomeTests {
    /// The running-app banner journey uses the same over-limit declaration
    /// shape. This hosted leaf proves observer→composition→shell publication
    /// from real pasteboard facts, without a failure hook or a timer wait.
    @Test @MainActor
    func overLimitDeclarationsPublishOneDismissibleUnsupportedEpisode() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let pasteboard = ComposedSupport.makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        let count = HistoryLimits.standard.maximumRepresentationsPerCaptureOrRevision + 1
        let types = (0..<count).map {
            NSPasteboard.PasteboardType("com.clipy.fixture.health.hosted.\($0)")
        }
        for type in types {
            #expect(item.setData(Data([1]), forType: type))
        }
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([item]))
        let declaredTypes = try #require(pasteboard.pasteboardItems?.first?.types)
        #expect(types.allSatisfy { declaredTypes.contains($0) })

        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard)
        )
        defer { composition.stop() }
        let appDelegate = AppDelegate()
        appDelegate.installCompositionForTesting(composition)

        #expect(appDelegate.captureNotice == .failed(.unsupportedClipboardShape))
        #expect(appDelegate.captureHealth.failedCaptureCount == 1)
        #expect(appDelegate.captureHealth.activeCommitCount == 0)
        #expect(appDelegate.captureHealth.pendingCaptureCount == 0)
        appDelegate.dismissCaptureNotice()
        appDelegate.receiveCaptureHealthForTesting(composition.captureHealth)
        #expect(appDelegate.captureNotice == nil)

        let page = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
        #expect(page.rows.isEmpty)
        #expect(page.position.rawValue == 0)
    }

    /// A real NSPasteboardItemDataProvider that declares ownership of a type
    /// but deliberately declines to publish bytes when AppKit requests them.
    /// The provider makes no timeout or permission diagnosis: the only
    /// observable fact is that the declared payload remains unavailable.
    private final class RefusingDataProvider: NSObject, NSPasteboardItemDataProvider {
        private let requestedTypes = Mutex<[NSPasteboard.PasteboardType]>([])

        func pasteboard(
            _ pasteboard: NSPasteboard?,
            item: NSPasteboardItem,
            provideDataForType type: NSPasteboard.PasteboardType
        ) {
            requestedTypes.withLock { $0.append(type) }
        }

        func receivedRequest(for type: NSPasteboard.PasteboardType) -> Bool {
            requestedTypes.withLock { $0.contains(type) }
        }
    }

    /// REVIEW Card 5B: an item that publicly declares content but whose real
    /// provider refuses the bytes reaches the app as one terminal,
    /// content-free failure. It never occupies either bounded lane slot and
    /// never becomes partial Canonical Content in History.
    @Test @MainActor
    func declaredButUnavailableProviderNeverEntersHistory() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let pasteboard = ComposedSupport.makePasteboard()
        let unavailableType = NSPasteboard.PasteboardType(
            "com.clipy.fixture.declared-unavailable"
        )
        let provider = RefusingDataProvider()
        let item = NSPasteboardItem()

        #expect(
            item.setString("available sibling must not commit", forType: .string)
        )
        #expect(item.setDataProvider(provider, forTypes: [unavailableType]))
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([item]))
        let declaredTypes = try #require(pasteboard.pasteboardItems?.first?.types)
        #expect(declaredTypes.contains(.string))
        #expect(declaredTypes.contains(unavailableType))

        let adapter = PasteboardAdapter(pasteboard: pasteboard)
        #expect(
            adapter.captureAccessBehavior == .allowed,
            "a named private pasteboard must permit the production observer"
        )
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: adapter
        )
        let appDelegate = AppDelegate()
        appDelegate.installCompositionForTesting(composition)
        defer { composition.stop() }

        #expect(provider.receivedRequest(for: unavailableType))
        #expect(
            appDelegate.captureNotice
                == .failed(.declaredContentUnavailable)
        )
        #expect(
            appDelegate.captureHealth.lastFailure
                == .declaredContentUnavailable
        )
        #expect(appDelegate.captureHealth.failedCaptureCount == 1)
        #expect(appDelegate.captureHealth.activeCommitCount == 0)
        #expect(appDelegate.captureHealth.activeCaptureBytes == 0)
        #expect(appDelegate.captureHealth.pendingCaptureCount == 0)
        #expect(appDelegate.captureHealth.pendingCaptureBytes == 0)

        let page = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 10)
        )
        #expect(page.rows.isEmpty)
        #expect(page.position.rawValue == 0)
    }
}
