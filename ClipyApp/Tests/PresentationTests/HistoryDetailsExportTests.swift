import Foundation
@testable import HistoryCore
@testable import HistoryStorage
import Testing
@testable import ClipyApp

struct HistoryDetailsExportTests {
    @Test func exportSelectsCompleteBytesFromTheDisplayedBasis() async throws {
        let textType = "public.utf8-plain-text"
        let opaqueType = "com.example.opaque"
        let original = Data([0xEF, 0xBB, 0xBF]) + Data(String(repeating: "original", count: 200).utf8)
        let revised = Data([0xFE, 0xFF, 0x00, 0x41])
        let opaque = Data([0x00, 0xFF, 0x10, 0x00])
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        let captured = try await history.perform(.capture(ClipboardCapture(
            representations: [
                CapturedRepresentation(typeIdentifier: textType, bytes: original),
                CapturedRepresentation(typeIdentifier: opaqueType, bytes: opaque),
            ],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSince1970: 1)
        )))
        guard case .committed(let captureCommit) = captured, case .inserted(let item) = captureCommit.outcome else {
            Issue.record("Expected captured fixture")
            return
        }
        _ = try await history.perform(.revise(RevisionRequest(itemID: item.id, expected: item.contentVersion,
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(typeIdentifier: textType, action: .replace(bytes: revised)),
                RevisionDecision(typeIdentifier: opaqueType, action: .hide),
            ])))))
        let snapshot = try await history.details(for: item.id)
        // Only selection constructs an exact-reference byte request; preparing
        // the overview does not pull Canonical or Effective payloads into it.
        let presentation = try DetailsContentPresentation(details: snapshot)
        #expect(presentation.effective[0].presentation == .metadataOnly)
        for (basis, type, expected) in [
            (ContentBasis.effective, textType, revised),
            (.canonical, textType, original),
            (.canonical, opaqueType, opaque),
        ] {
            let request = try #require(basis.representation(typeIdentifier: type, in: snapshot))
            #expect(request.item == snapshot.item)
            #expect(request.typeIdentifier == type)
            let representation = try await history.representation(request)
            #expect(representation.bytes == expected)
        }
        #expect(ContentBasis.effective.representation(typeIdentifier: opaqueType, in: snapshot) == nil)
        // History rejects empty capture representations. Empty-file export is
        // exercised directly by RepresentationExportHostedTests, while this
        // real-store test verifies stored bytes and hidden-type selection.
    }
}
