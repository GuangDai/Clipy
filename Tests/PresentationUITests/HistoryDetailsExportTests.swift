import Foundation
import HistoryCore
import Testing
@testable import PresentationUI

struct HistoryDetailsExportTests {
    @Test(arguments: [false, true]) @MainActor
    func lateNoncooperativeFailureCannotPublishAfterDetailsRetires(cancelTask: Bool) async throws {
        let reference = HistoryItemReference(id: HistoryItemID(rawValue: UUID()), contentVersion: .initial)
        var fence = HistoryDetailsLoadFence()
        let loadRequest = fence.begin()
        let generation = try #require(loadRequest)
        var release: CheckedContinuation<Result<Void, RepresentationExportFailure>, Never>?
        var displayedFailure: RepresentationExportFailure?
        let request = Task {
            // This suspension deliberately ignores cancellation, like an
            // exporter whose underlying filesystem callback finishes late.
            let result = await withCheckedContinuation { release = $0 }
            guard fence.accepts(
                generation, returned: reference, expected: reference,
                isCancelled: Task.isCancelled
            ) else { return }
            if case .failure(let failure) = result { displayedFailure = failure }
        }
        #expect(await pollUntil { release != nil })
        let continuation = try #require(release)
        if cancelTask {
            request.cancel()
        } else {
            let purged = fence.purge(.item(reference.id), item: reference)
            #expect(purged)
        }
        continuation.resume(returning: .failure(.writeFailed))
        await request.value
        #expect(displayedFailure == nil)
    }

    @Test func exportSelectsCompleteBytesFromTheDisplayedBasis() throws {
        let textType = "public.utf8-plain-text"
        let opaqueType = "com.example.opaque"
        let emptyType = "com.example.empty"
        let original = Data([0xEF, 0xBB, 0xBF]) + Data(String(repeating: "original", count: 200).utf8)
        let revised = Data([0xFE, 0xFF, 0x00, 0x41])
        let opaque = Data([0x00, 0xFF, 0x10, 0x00])
        let snapshot = HistoryDetails(
            item: HistoryItemReference(id: HistoryItemID(rawValue: UUID()), contentVersion: .initial),
            canonical: [
                HistoryRepresentation(typeIdentifier: textType, bytes: original),
                HistoryRepresentation(typeIdentifier: opaqueType, bytes: opaque),
                HistoryRepresentation(typeIdentifier: emptyType, bytes: Data()),
            ],
            effective: [HistoryRepresentation(typeIdentifier: textType, bytes: revised)],
            revisions: [],
            occurrence: CopyOccurrenceSummary(
                firstCopiedAt: Date(timeIntervalSince1970: 0),
                lastCopiedAt: Date(timeIntervalSince1970: 0),
                count: 1, firstSource: nil, lastSource: nil
            ),
            pinnedPosition: nil
        )
        // The visible preview is bounded or unavailable. Export still selects
        // the full wire value, with no decoding, repair, or flavor substitution.
        let presentation = try DetailsContentPresentation(details: snapshot)
        #expect(presentation.effective[0].presentation == .metadataOnly)
        #expect(ContentBasis.effective.representation(typeIdentifier: textType, in: snapshot)?.bytes == revised)
        #expect(ContentBasis.canonical.representation(typeIdentifier: textType, in: snapshot)?.bytes == original)
        #expect(ContentBasis.canonical.representation(typeIdentifier: opaqueType, in: snapshot)?.bytes == opaque)
        #expect(ContentBasis.canonical.representation(typeIdentifier: emptyType, in: snapshot)?.bytes == Data())
        #expect(ContentBasis.effective.representation(typeIdentifier: opaqueType, in: snapshot) == nil)
        #expect(ContentBasis.effective.representation(typeIdentifier: emptyType, in: snapshot) == nil)
    }
}
