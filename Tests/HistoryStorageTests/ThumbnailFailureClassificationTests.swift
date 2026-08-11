/// Thumbnail encoding failures use stable public vocabulary: valid encoded
/// output over the configured envelope is capacity, while failure of the PNG
/// encoder itself is an encode-side invariant. docs/05 §16; docs/06 §2.
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
