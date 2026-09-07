/// Representation metadata must not borrow an item-level thumbnail's pixels
/// or unavailable state, especially across Canonical/Effective revision bases.
import Foundation
import ContentPreview
import HistoryCore
import HistoryStorage
import Testing
@testable import PresentationUI

@MainActor
struct DetailsImageMetadataTests {
    @Test func imageRevisionKeepsCanonicalMetadataIndependentOfTheNewItemThumbnail() async throws {
        let history = try await SQLiteHistory.open(
            configuration: HistoryConfiguration(persistence: .temporary)
        )
        let originalBytes = Data("original opaque PNG bytes".utf8)
        let original = try await capture([
            CapturedRepresentation(typeIdentifier: "public.png", bytes: originalBytes)
        ], into: history)
        let thumbnails = ThumbnailStore(history: history)
        thumbnails.prefetch(original)
        try #require(await pollUntil { thumbnails.inFlightCount == 0 })
        #expect(thumbnails.isUnavailable(for: original))
        let originalDetails = try await history.details(for: original.id)
        let originalContent = try DetailsContentPresentation(details: originalDetails)
        let originalRepresentation = try #require(originalContent.effective.first)
        expectImageMetadata(originalRepresentation, type: "public.png", byteCount: originalBytes.count)

        let revisedBytes = fixturePNGData
        let receipt = try await history.perform(.revise(RevisionRequest(
            itemID: original.id,
            expected: original.contentVersion,
            intent: .replace(RevisionDraft(decisions: [RevisionDecision(
                typeIdentifier: "public.png", action: .replace(bytes: revisedBytes)
            )]))
        )))
        guard case let .committed(commit) = receipt,
              case let .revised(revised) = commit.outcome else {
            Issue.record("Expected image replacement to append a revision")
            return
        }
        #expect(revised.id == original.id)
        #expect(revised.contentVersion.rawValue == 2)
        thumbnails.prefetch(revised)
        try #require(await pollUntil { thumbnails.inFlightCount == 0 })
        // An independently requested item thumbnail must not become a preview
        // of the different Canonical PNG in the metadata-only Details overview.
        #expect(thumbnails.imagePixelSize(for: revised) == PixelSize(width: 1, height: 1))
        #expect(!thumbnails.isUnavailable(for: revised))
        let details = try await history.details(for: revised.id)
        let content = try DetailsContentPresentation(details: details)
        #expect(!content.effectiveMatchesCanonical)
        let canonical = try await history.representation(HistoryRepresentationRequest(
            item: details.item, basis: .canonical, typeIdentifier: "public.png"
        ))
        let effective = try await history.representation(HistoryRepresentationRequest(
            item: details.item, basis: .effective, typeIdentifier: "public.png"
        ))
        #expect(canonical.bytes == originalBytes)
        #expect(effective.bytes == revisedBytes)
        expectImageMetadata(try #require(content.canonical.first),
                            type: "public.png", byteCount: originalBytes.count)
        expectImageMetadata(try #require(content.effective.first),
                            type: "public.png", byteCount: revisedBytes.count)
        #expect(thumbnails.isUnavailable(for: original))
        let paste = try await history.pastePayload(for: revised.id)
        #expect(paste.representations.map(\.bytes) == [revisedBytes])
    }

    @Test func multipleImageRowsDoNotClaimTheSuccessfulItemThumbnailAsTheirOwnPreview() async throws {
        let history = try await SQLiteHistory.open(
            configuration: HistoryConfiguration(persistence: .temporary)
        )
        let png = fixturePNGData
        let tiff = Data("not the selected PNG representation".utf8)
        let item = try await capture([
            CapturedRepresentation(typeIdentifier: "public.png", bytes: png),
            CapturedRepresentation(typeIdentifier: "public.tiff", bytes: tiff),
        ], into: history)
        let thumbnails = ThumbnailStore(history: history)
        thumbnails.prefetch(item)
        try #require(await pollUntil { thumbnails.inFlightCount == 0 })
        #expect(thumbnails.imagePixelSize(for: item) == PixelSize(width: 1, height: 1))
        let details = try await history.details(for: item.id)
        let content = try DetailsContentPresentation(details: details)
        #expect(content.effectiveMatchesCanonical)
        #expect(content.effective.count == 2)
        expectImageMetadata(try #require(content.effective.first),
                            type: "public.png", byteCount: png.count)
        expectImageMetadata(try #require(content.effective.last),
                            type: "public.tiff", byteCount: tiff.count)
        let selectedPNG = try await history.representation(HistoryRepresentationRequest(
            item: details.item, basis: .effective, typeIdentifier: "public.png"
        ))
        let selectedTIFF = try await history.representation(HistoryRepresentationRequest(
            item: details.item, basis: .effective, typeIdentifier: "public.tiff"
        ))
        #expect(selectedPNG.bytes == png)
        #expect(selectedTIFF.bytes == tiff)
        let renderer = ContentPreview()
        let tiffPreview = await renderer.renderHistoryPane([
            PreviewRepresentation(typeIdentifier: selectedTIFF.typeIdentifier, bytes: selectedTIFF.bytes)
        ])
        #expect(tiffPreview == .failed(.malformedRepresentation),
                "An explicit TIFF preview must not borrow the item's successful PNG thumbnail")
    }

    private func expectImageMetadata(
        _ representation: DetailsContentPresentation.Representation,
        type: String,
        byteCount: Int
    ) {
        #expect(representation.typeIdentifier == type)
        #expect(representation.byteCount == byteCount)
        #expect(representation.isImage)
        #expect(representation.presentation == .metadataOnly)
    }

    private func capture(
        _ representations: [CapturedRepresentation], into history: SQLiteHistory
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: representations,
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_092_000)
        )))
        guard case let .committed(commit) = receipt,
              case let .inserted(item) = commit.outcome else {
            throw CaptureFailure.expectedInsert
        }
        return item
    }

    private enum CaptureFailure: Error { case expectedInsert }
}
