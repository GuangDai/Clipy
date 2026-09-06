/// Thumbnail encoding failures use stable public vocabulary: valid encoded
/// output over the configured envelope is capacity, while failure of the PNG
/// encoder itself is an encode-side invariant. docs/05 §16; docs/06 §2.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

@Test func encodedThumbnailByteEnvelopeUsesThumbnailCapacityKind() throws {
    let limits = HistoryLimits.standard
    try ThumbnailWorker.validateEncodedThumbnailByteCount(
        limits.maximumEncodedThumbnailBytes,
        limits: limits
    )
    #expect(throws: HistoryFailure.capacityExceeded(.thumbnailBytes)) {
        try ThumbnailWorker.validateEncodedThumbnailByteCount(
            limits.maximumEncodedThumbnailBytes + 1,
            limits: limits
        )
    }
}

@Test func thumbnailEncoderFailureIsNotStoredValueCorruption() {
    #expect(
        ThumbnailWorker.encodingFailure
            == .persistence(.invariantViolation)
    )
}

/// Opaque capture does not promise image validity. A false PNG declaration
/// and a truncated PNG remain byte-exact History values even when ImageIO
/// cannot create a thumbnail (03b §9/§10; 05 §16).
@Test(arguments: [
    Data("not a PNG image".utf8),
    Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89,
    ]),
])
func undecodableImageIsStillReadableAndPasteable(_ bytes: Data) async throws {
    let history = try await SwiftDataHistory.open(
        configuration: HistoryConfiguration(persistence: .memory)
    )
    let receipt = try await history.perform(.capture(ClipboardCapture(
        representations: [CapturedRepresentation(typeIdentifier: "public.png", bytes: bytes)],
        origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
        observedAt: Date(timeIntervalSinceReferenceDate: 700_040_500)
    )))
    guard case let .committed(commit) = receipt,
          case let .inserted(reference) = commit.outcome else {
        Issue.record("Expected opaque PNG bytes to be captured")
        return
    }

    await #expect(throws: HistoryFailure.thumbnailUnavailable) {
        try await history.thumbnail(for: reference, pixels: PixelSize(width: 32, height: 32))
    }

    let expected = [HistoryRepresentation(typeIdentifier: "public.png", bytes: bytes)]
    let details = try await history.details(for: reference.id)
    #expect(details.item == reference)
    #expect(details.canonical == expected)
    #expect(details.effective == expected)
    let paste = try await history.pastePayload(for: reference.id)
    #expect(paste.item == reference)
    #expect(paste.representations == expected)
    let page = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 1))
    #expect(page.position == commit.position)
}

@Test func undecodableSelectedImageDoesNotFallBackToALaterValidImage() async throws {
    let history = try await SwiftDataHistory.open(
        configuration: HistoryConfiguration(persistence: .memory)
    )
    let png = try #require(Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
    ))
    // Effective Content orders public.jpeg before public.png. Keeping the
    // later PNG valid distinguishes failure from candidate fallback (05 §16).
    let receipt = try await history.perform(.capture(ClipboardCapture(
        representations: [
            CapturedRepresentation(typeIdentifier: "public.png", bytes: png),
            CapturedRepresentation(typeIdentifier: "public.jpeg", bytes: Data("not JPEG".utf8)),
        ],
        origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
        observedAt: Date(timeIntervalSinceReferenceDate: 700_040_501)
    )))
    guard case let .committed(commit) = receipt,
          case let .inserted(reference) = commit.outcome else {
        Issue.record("Expected both opaque image representations to be captured")
        return
    }
    await #expect(throws: HistoryFailure.thumbnailUnavailable) {
        try await history.thumbnail(for: reference, pixels: PixelSize(width: 32, height: 32))
    }
}
