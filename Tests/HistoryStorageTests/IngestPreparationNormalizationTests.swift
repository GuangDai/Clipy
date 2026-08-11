/// Capture-normalization tests at the preparation seam
/// (docs/05-authority-kernel.md §6.1 step 4; docs/02-domain.md §2.1).
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

@Test func canonicallyEquivalentNonAdjacentTypeIdentifiersAreTypedDuplicates() async {
    let decomposed = "e\u{301}"
    let precomposed = "\u{e9}"
    let scalarOrderedBetweenThem = "f"
    let capture = ClipboardCapture(
        representations: [
            CapturedRepresentation(
                typeIdentifier: decomposed,
                bytes: Data([0x01])
            ),
            CapturedRepresentation(
                typeIdentifier: scalarOrderedBetweenThem,
                bytes: Data([0x02])
            ),
            CapturedRepresentation(
                typeIdentifier: precomposed,
                bytes: Data([0x03])
            ),
        ],
        origin: CopyOriginObservation(
            sourceApplication: nil,
            lineageHint: nil
        ),
        observedAt: Date(timeIntervalSinceReferenceDate: 700_200_000)
    )
    let preparation = IngestPreparationActor(fingerprint: { _ in 0 })

    await #expect(
        throws: HistoryFailure.invalidInput(
            .duplicateRepresentationType(precomposed)
        )
    ) {
        try await preparation.prepare(capture)
    }
}

@Test(arguments: [Double.nan, Double.infinity, -Double.infinity])
func nonFiniteCaptureTimestampIsRejectedBeforeFingerprinting(
    interval: Double
) async {
    let capture = ClipboardCapture(
        representations: [CapturedRepresentation(
            typeIdentifier: "public.utf8-plain-text",
            bytes: Data("finite content".utf8)
        )],
        origin: CopyOriginObservation(
            sourceApplication: nil,
            lineageHint: nil
        ),
        observedAt: Date(timeIntervalSinceReferenceDate: interval)
    )
    let preparation = IngestPreparationActor(fingerprint: { _ in
        Issue.record("A non-finite capture timestamp reached fingerprinting")
        return 0
    })

    await #expect(throws: HistoryFailure.invalidInput(.invalidTimestamp)) {
        try await preparation.prepare(capture)
    }
}
