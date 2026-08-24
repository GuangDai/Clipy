/// Six public X.7 tracer bullets: each AppIntent crosses the production facade
/// exactly once and is observed through its user result plus public audit state.
import AppIntents
import AppKit
import Foundation
import HistoryCore
import PasteboardAdapter
import Testing
@testable import ClipyApp

@Suite("App Intents behavior (X.7)")
struct AppIntentBehaviorTests {
    @Test("Search returns bounded transient rows through the browse grant")
    func search() async throws {
        let support = try await AppIntentTestSupport.make(grants: [.browse])
        let intent = SearchHistoryIntent(
            query: "intent-seed",
            mode: .exact,
            limit: 20,
            history: support.ingress,
            dependencyManager: support.manager
        )

        let result = try await intent.perform()

        let rows = try #require(result.value)
        #expect(rows.count == 1)
        #expect(rows[0].id == support.itemID.description)
        #expect(rows[0].title == "intent-seed")
        #expect(try await support.lastAuditOperation() == .readSearch)
    }

    @Test("Details projects metadata without content bytes")
    func details() async throws {
        let support = try await AppIntentTestSupport.make(grants: [.readContent])
        let intent = GetItemDetailsIntent(
            itemID: support.itemID.description,
            history: support.ingress,
            dependencyManager: support.manager
        )

        let result = try await intent.perform()

        let details = try #require(result.value)
        #expect(details.id == support.itemID.description)
        #expect(details.typeIdentifiers == ["public.utf8-plain-text"])
        #expect(details.copyCount == "1")
        #expect(try await support.lastAuditOperation() == .readDetails)
    }

    @Test("Paste writes every byte and lineage hint to a private pasteboard")
    func paste() async throws {
        let support = try await AppIntentTestSupport.make(grants: [.readContent])
        let pasteboardName = "com.clipy.tests.app-intent-paste"
        _ = await MainActor.run {
            NSPasteboard(name: NSPasteboard.Name(pasteboardName))
                .clearContents()
        }
        let intent = PasteItemIntent(
            itemID: support.itemID.description,
            pasteboardName: pasteboardName,
            history: support.ingress,
            dependencyManager: support.manager
        )

        let result = try await intent.perform()

        #expect(result.value == true)
        let capture = try #require(await MainActor.run {
            PasteboardAdapter(pasteboard: NSPasteboard(
                name: NSPasteboard.Name(pasteboardName)
            )).capture()
        })
        #expect(capture.representations == [CapturedRepresentation(
            typeIdentifier: "public.utf8-plain-text",
            bytes: Data("intent-seed".utf8)
        )])
        #expect(capture.origin.lineageHint == support.itemID)
        #expect(try await support.lastAuditOperation() == .readPastePayload)
    }

    @Test("Pin returns whether state changed")
    func pin() async throws {
        let support = try await AppIntentTestSupport.make(grants: [.manage])
        let intent = PinItemIntent(
            itemID: support.itemID.description,
            history: support.ingress,
            dependencyManager: support.manager
        )

        let result = try await intent.perform()

        #expect(result.value == true)
        #expect(try await support.lastAuditOperation() == .managePin)
    }

    @Test("Unpin returns whether state changed")
    func unpin() async throws {
        let support = try await AppIntentTestSupport.make(grants: [.manage])
        _ = try await support.ingress.perform(.pin(support.itemID))
        let intent = UnpinItemIntent(
            itemID: support.itemID.description,
            history: support.ingress,
            dependencyManager: support.manager
        )

        let result = try await intent.perform()

        #expect(result.value == true)
        #expect(try await support.lastAuditOperation() == .manageUnpin)
    }

    @Test("Remove returns whether an item was removed")
    func remove() async throws {
        let support = try await AppIntentTestSupport.make(grants: [.manage])
        let intent = RemoveItemIntent(
            itemID: support.itemID.description,
            history: support.ingress,
            dependencyManager: support.manager
        )

        let result = try await intent.perform()

        #expect(result.value == true)
        #expect(try await support.lastAuditOperation() == .manageRemove)
    }
}
