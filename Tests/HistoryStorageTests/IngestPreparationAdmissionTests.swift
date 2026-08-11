/// Direct admission-branch and cross-layer invariant canaries for capture
/// preparation (docs/05-authority-kernel.md §6.1 steps 1–7).
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

private func tinyIngestLimits() -> HistoryLimits {
    HistoryLimits(
        maximumRepresentationsPerCaptureOrRevision: 2,
        maximumTypeIdentifierUTF8Bytes: 8,
        maximumRepresentationBytes: 4,
        maximumCaptureBytes: 6,
        maximumProposedRevisionBytes: 4,
        maximumRevisionsPerItem: 2,
        maximumTotalRevisionBytesPerItem: 8,
        hardMaximumRetainedItems: 5,
        userMaximumUnpinnedRange: 1...5,
        defaultMaximumUnpinnedItems: 2,
        maximumSourceApplicationObservationUTF8Bytes: 5,
        maximumStoredTitleUTF8Bytes: 16,
        maximumStoredSearchBodyUTF8Bytes: 32,
        pageRowLimitRange: 1...5,
        maximumSearchTermUTF8Bytes: 16,
        maximumRegexpPatternCharacters: 8,
        maximumFuzzyQueryCharacters: 8,
        maximumFuzzyTitleBodyPrefixCharacters: 16,
        maximumRegexpTitleBodyPrefixCharacters: 16,
        maximumBodySearchSnippetCharacters: 8,
        thumbnailDimensionRange: 1...8,
        maximumEncodedThumbnailBytes: 32
    )!
}

private func ingestCapture(
    _ representations: [CapturedRepresentation],
    sourceApplication: String? = nil
) -> ClipboardCapture {
    ClipboardCapture(
        representations: representations,
        origin: CopyOriginObservation(
            sourceApplication: sourceApplication,
            lineageHint: nil
        ),
        observedAt: Date(timeIntervalSinceReferenceDate: 700_400_000)
    )
}

private func ingestRepresentation(
    _ typeIdentifier: String,
    byteCount: Int
) -> CapturedRepresentation {
    CapturedRepresentation(
        typeIdentifier: typeIdentifier,
        bytes: Data(repeating: 0x41, count: byteCount)
    )
}

struct IngestPreparationAdmissionTests {
    @Test func rejectsEveryStepOneCountAndByteBranch() async {
        let preparation = IngestPreparationActor(limits: tinyIngestLimits())

        await #expect(throws: HistoryFailure.invalidInput(.emptyCapture)) {
            try await preparation.prepare(ingestCapture([]))
        }
        await #expect(throws: HistoryFailure.invalidInput(.representationLimit)) {
            try await preparation.prepare(ingestCapture([
                ingestRepresentation("a", byteCount: 1),
                ingestRepresentation("b", byteCount: 1),
                ingestRepresentation("c", byteCount: 1),
            ]))
        }
        await #expect(throws: HistoryFailure.invalidInput(.byteLimit)) {
            try await preparation.prepare(ingestCapture([
                ingestRepresentation("a", byteCount: 4),
                ingestRepresentation("b", byteCount: 4),
            ]))
        }
        await #expect(throws: HistoryFailure.invalidInput(.byteLimit)) {
            try await preparation.prepare(ingestCapture(
                [ingestRepresentation("a", byteCount: 1)],
                sourceApplication: "123456"
            ))
        }
    }

    @Test func rejectsEveryStepTwoAndFourNormalizationBranch() async {
        let preparation = IngestPreparationActor(limits: tinyIngestLimits())

        await #expect(throws: HistoryFailure.invalidInput(.byteLimit)) {
            try await preparation.prepare(ingestCapture([
                ingestRepresentation("a", byteCount: 5),
            ]))
        }
        await #expect(throws: HistoryFailure.invalidInput(.byteLimit)) {
            try await preparation.prepare(ingestCapture([
                ingestRepresentation("a", byteCount: 0),
            ]))
        }
        await #expect(throws: HistoryFailure.invalidInput(
            .unsupportedRepresentationType("")
        )) {
            try await preparation.prepare(ingestCapture([
                ingestRepresentation("", byteCount: 1),
            ]))
        }
        let oversizedType = "123456789"
        await #expect(throws: HistoryFailure.invalidInput(
            .unsupportedRepresentationType(oversizedType)
        )) {
            try await preparation.prepare(ingestCapture([
                ingestRepresentation(oversizedType, byteCount: 1),
            ]))
        }
        await #expect(throws: HistoryFailure.invalidInput(
            .duplicateRepresentationType("same")
        )) {
            try await preparation.prepare(ingestCapture([
                ingestRepresentation("same", byteCount: 1),
                ingestRepresentation("same", byteCount: 2),
            ]))
        }
    }

    @Test func preparationSortsAndUsesInjectedIdentitySource() async throws {
        let fixedID = HistoryItemID(rawValue: UUID(
            uuidString: "00000000-0000-0000-0000-000000000401"
        )!)
        let preparation = IngestPreparationActor(
            limits: tinyIngestLimits(),
            fingerprint: { UInt64($0.count) },
            makeCandidateID: { fixedID }
        )

        let bundle = try await preparation.prepare(ingestCapture([
            ingestRepresentation("b", byteCount: 2),
            ingestRepresentation("a", byteCount: 1),
        ]))

        #expect(bundle.domain.candidateID == fixedID)
        #expect(bundle.domain.canonical.representations.map {
            $0.content.typeIdentifier
        } == ["a", "b"])
        #expect(bundle.signatureEntries.map(\.fingerprint.rawValue) == [1, 2])
    }
}
