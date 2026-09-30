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
        defaultMaximumUnpinnedItems: 2,
        maximumSourceApplicationObservationUTF8Bytes: 5,
        maximumStoredTitleUTF8Bytes: 16,
        maximumStoredSearchBodyUTF8Bytes: 32,
        pageRowLimitLowerBound: 1,
        pageRowLimitUpperBound: 5,
        maximumSearchTermUTF8Bytes: 16,
        maximumRegexpPatternCharacters: 8,
        maximumFuzzyQueryCharacters: 8,
        maximumFuzzyTitleBodyPrefixCharacters: 16,
        maximumRegexpTitleBodyPrefixCharacters: 16,
        maximumBodySearchSnippetCharacters: 8,
        thumbnailDimensionLowerBound: 1,
        thumbnailDimensionUpperBound: 8,
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
    @Test func cancelledCaptureDoesNotHashItsPayload() async {
        let preparation = IngestPreparationActor(fingerprint: { _ in
            Issue.record("Cancelled capture reached payload fingerprinting")
            return 0
        })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await preparation.prepare(ingestCapture([ingestRepresentation("a", byteCount: 1)]))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func facadeUsesItsLimitsForCaptureAndRevisionPreparation() async throws {
        let history = try await SQLiteHistory.open(
            configuration: HistoryConfiguration(persistence: .temporary),
            limits: tinyIngestLimits(), makeCandidateID: { HistoryItemID(rawValue: UUID()) }
        )
        let emptyUsage = try await history.usage()
        await #expect(throws: HistoryFailure.invalidInput(.byteLimit)) {
            try await history.perform(.capture(ingestCapture([ingestRepresentation("a", byteCount: 5)])))
        }
        #expect(try await history.usage() == emptyUsage)

        let receipt = try await history.perform(.capture(ingestCapture([ingestRepresentation("a", byteCount: 1)])))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            Issue.record("Expected a capture within the injected limits to succeed")
            return
        }
        let beforeRevision = try await history.usage()
        await #expect(throws: HistoryFailure.invalidInput(.byteLimit)) {
            try await history.perform(.revise(RevisionRequest(
                itemID: item.id, expected: item.contentVersion,
                intent: .replace(RevisionDraft(decisions: [
                    RevisionDecision(typeIdentifier: "a", action: .replace(bytes: Data(repeating: 0x42, count: 5))),
                ]))
            )))
        }
        #expect(try await history.usage() == beforeRevision)
        #expect(try await history.pastePayload(for: item.id).representations.map(\.bytes) == [Data([0x41])])
    }

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
        #expect(bundle.domain.canonical.representations.map(\.fingerprint.rawValue) == [1, 2])
    }
}
