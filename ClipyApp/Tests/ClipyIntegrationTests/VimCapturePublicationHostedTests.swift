import AppKit
import Foundation
import HistoryCore
import PasteboardAdapter
import Testing
@testable import ClipyApp

/// The native Vim writer declares both formats before publishing their
/// bytes. Observation between those calls must recover through the running
/// composition and save the complete gesture in the real History store.
@Suite("Hosted Vim capture publication")
@MainActor
struct VimCapturePublicationHostedTests {
    @Test
    func delayedVimPayloadReachesHistoryAndClearsTheCaptureFailure() async throws {
        try ComposedSupport.requireUsablePasteboard()
        let history = try await ComposedSupport.openMemoryHistory()
        let pasteboard = ComposedSupport.makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let adapter = PasteboardAdapter(pasteboard: pasteboard)
        try #require(adapter.captureAccessBehavior == .allowed)
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: adapter,
            observerPollInterval: 0.01
        )
        defer { composition.stop() }
        composition.viewState.activate()

        let vimType = NSPasteboard.PasteboardType("VimPboardType")
        let generation = pasteboard.declareTypes([vimType, .string], owner: nil)
        try #require(await ComposedSupport.waitFor {
            composition.captureHealth.lastFailure == .declaredContentUnavailable
        })
        let beforePublication = try await history.browse(.init(kind: .recent, limit: 10))
        try #require(beforePublication.rows.isEmpty)
        #expect(beforePublication.position.rawValue == 0)

        let text = "Vim hosted capture 中文"
        let selection: [Any] = [NSNumber(value: 1), text]
        try #require(pasteboard.setPropertyList(selection, forType: vimType))
        try #require(pasteboard.setString(text, forType: .string))
        try #require(pasteboard.changeCount == generation)
        let published = try #require(pasteboard.pasteboardItems?.first)
        try #require(published.types.count == 2)
        let expected = try published.types.map { type in
            CapturedRepresentation(
                typeIdentifier: type.rawValue,
                bytes: try #require(published.data(forType: type))
            )
        }
        try #require(pasteboard.data(forType: .string) == Data(text.utf8))
        try #require(pasteboard.data(forType: vimType)?.isEmpty == false)

        try #require(await ComposedSupport.waitFor {
            composition.viewState.rows.map(\.title) == [text]
                && composition.captureHealth.activeCommitCount == 0
                && composition.captureHealth.pendingCaptureCount == 0
                && composition.captureHealth.lastFailure == nil
        })
        let page = try await history.browse(.init(kind: .recent, limit: 10))
        try #require(page.rows.count == 1)
        #expect(page.rows.map(\.title) == [text])
        #expect(page.position.rawValue == 1)
        let row = try #require(page.rows.first)
        let details = try await history.details(for: row.item.id)
        #expect(details.occurrence.count == 1)
        #expect(Set(details.canonical.map(\.typeIdentifier)) == Set(expected.map(\.typeIdentifier)))
        for representation in expected {
            let stored = try await history.representation(.init(
                item: details.item,
                basis: .canonical,
                typeIdentifier: representation.typeIdentifier
            ))
            #expect(stored.bytes == representation.bytes)
        }
        let payload = try await history.pastePayload(for: row.item.id)
        #expect(Set(payload.representations.map {
            CapturedRepresentation(typeIdentifier: $0.typeIdentifier, bytes: $0.bytes)
        }) == Set(expected))
        #expect(composition.captureHealth.failedCaptureCount == 1)
        #expect(composition.captureHealth.droppedCaptureCount == 0)
        #expect(pasteboard.changeCount == generation)
    }
}
