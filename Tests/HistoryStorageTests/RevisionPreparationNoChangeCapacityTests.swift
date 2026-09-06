/// Append capacity cannot reject an already-current proposal. Input validation
/// and the changed-content R3/capacity path retain their existing precedence.
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct RevisionPreparationNoChangeCapacityTests {
    private let type = "com.example.opaque"
    private let currentBytes = Data([0x00, 0xFF, 0x01, 0x02])

    @Test(arguments: [CapacityKind.revisionCount, .revisionBytes])
    func unchangedProposalNeedsNoAppendCapacity(_ capacity: CapacityKind) async throws {
        let source = try await snapshot()
        let preparation = RevisionPreparationActor(limits: try limits(
            count: capacity == .revisionCount ? 1 : 10,
            bytes: capacity == .revisionBytes ? 4 : 64
        ))
        let unchanged = try await preparation.prepare(request(bytes: currentBytes), from: source)
        #expect(unchanged.domain.basedOn == source.contentVersion)
        #expect(unchanged.domain.proposedContent == source.revisions[0].content)
        #expect(unchanged.domain.proposedContent.representations[0].bytes == currentBytes)

        await #expect(throws: HistoryFailure.capacityExceeded(capacity)) {
            try await preparation.prepare(
                request(bytes: Data([0x00, 0xFF, 0x01, 0x03])), from: source
            )
        }
        await #expect(throws: HistoryFailure.invalidInput(.incoherentRevisionDraft)) {
            try await preparation.prepare(request(bytes: Data()), from: source)
        }
    }

    @Test func r3StillAllowsAChangedAppendByPruningItsOldRevision() async throws {
        let source = try await snapshot()
        let preparation = RevisionPreparationActor(limits: try limits(count: 1, bytes: 4))
        let policies = HistoryRetentionPolicies(
            age: nil, storage: nil,
            revisions: RevisionRetention(maxRevisionsPerItem: 1, maxRevisionBytesPerItem: 4)
        )
        let same = try await preparation.prepare(
            request(bytes: currentBytes), from: source, retentionPolicies: policies
        )
        #expect(same.domain.proposedContent == source.revisions[0].content)
        let changedBytes = Data([0x00, 0xFE, 0x01, 0x02])
        let changed = try await preparation.prepare(
            request(bytes: changedBytes), from: source, retentionPolicies: policies
        )
        #expect(changed.domain.proposedContent.representations[0].bytes == changedBytes)
        #expect(changed.domain.basedOn == source.contentVersion)
    }

    @Test(arguments: [CapacityKind.revisionCount, .revisionBytes], [false, true])
    func equivalentTypeSpellingsNeedNoAppendCapacity(
        _ capacity: CapacityKind, _ useDecomposedCanonical: Bool
    ) async throws {
        let canonicalType = useDecomposedCanonical ? "e\u{301}" : "\u{e9}"
        let activeType = useDecomposedCanonical ? "\u{e9}" : "e\u{301}"
        let captured = try await IngestPreparationActor().prepare(ClipboardCapture(
            representations: [
                CapturedRepresentation(typeIdentifier: canonicalType, bytes: Data([0x01, 0x02])),
                CapturedRepresentation(typeIdentifier: "f", bytes: Data([0x03, 0x04])),
            ],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_093_000)
        ))
        let active = ContentRevision(
            id: RevisionID(rawValue: UUID()),
            createdAt: Date(timeIntervalSinceReferenceDate: 700_093_001),
            content: EffectiveContent(representations: [
                ContentRepresentation(typeIdentifier: activeType, bytes: Data([0x01, 0x02])),
                ContentRepresentation(typeIdentifier: "f", bytes: Data([0x03, 0x04])),
            ].sorted {
                $0.typeIdentifier.unicodeScalars.lexicographicallyPrecedes($1.typeIdentifier.unicodeScalars)
            })
        )
        let source = RevisionPreparationSnapshot(
            canonical: captured.domain.canonical, revisions: [active],
            activeRevisionID: active.id, contentVersion: ContentVersion(rawValue: 2)
        )
        let preparation = RevisionPreparationActor(limits: try limits(
            count: capacity == .revisionCount ? 1 : 10,
            bytes: capacity == .revisionBytes ? 4 : 64
        ))
        let revert = RevisionRequest(
            itemID: HistoryItemID(rawValue: UUID()), expected: source.contentVersion,
            intent: .revert(to: .canonical)
        )
        let unchanged = try await preparation.prepare(revert, from: source)
        #expect(unchanged.domain.proposedContent.representations == captured.domain.canonical.representations.map(\.content))
        let changed = RevisionRequest(
            itemID: revert.itemID, expected: source.contentVersion,
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(typeIdentifier: canonicalType, action: .replace(bytes: Data([0x01, 0x05]))),
                RevisionDecision(typeIdentifier: "f", action: .inheritCanonical),
            ]))
        )
        await #expect(throws: HistoryFailure.capacityExceeded(capacity)) {
            try await preparation.prepare(changed, from: source)
        }
    }

    private func request(bytes: Data) -> RevisionRequest {
        RevisionRequest(
            itemID: HistoryItemID(rawValue: UUID()), expected: ContentVersion(rawValue: 2),
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(typeIdentifier: type, action: .replace(bytes: bytes)),
            ]))
        )
    }

    private func snapshot() async throws -> RevisionPreparationSnapshot {
        let captured = try await IngestPreparationActor().prepare(ClipboardCapture(
            representations: [CapturedRepresentation(typeIdentifier: type, bytes: Data([0x03]))],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_093_000)
        ))
        let revision = ContentRevision(
            id: RevisionID(rawValue: UUID()),
            createdAt: Date(timeIntervalSinceReferenceDate: 700_093_001),
            content: EffectiveContent(representations: [ContentRepresentation(
                typeIdentifier: type, bytes: currentBytes
            )])
        )
        return RevisionPreparationSnapshot(
            canonical: captured.domain.canonical, revisions: [revision],
            activeRevisionID: revision.id, contentVersion: ContentVersion(rawValue: 2)
        )
    }

    private func limits(count: Int, bytes: Int) throws -> HistoryLimits {
        let standard = HistoryLimits.standard
        // Each proposal is four bytes. Keep the single-representation and
        // proposed-revision bounds inside the small cumulative bound, so a
        // changed proposal reaches append capacity rather than input rejection.
        let representationBytes = currentBytes.count
        let limits = HistoryLimits(
            maximumRepresentationsPerCaptureOrRevision: standard.maximumRepresentationsPerCaptureOrRevision,
            maximumTypeIdentifierUTF8Bytes: standard.maximumTypeIdentifierUTF8Bytes,
            maximumRepresentationBytes: representationBytes,
            maximumCaptureBytes: representationBytes,
            maximumProposedRevisionBytes: representationBytes,
            maximumRevisionsPerItem: count,
            maximumTotalRevisionBytesPerItem: bytes,
            hardMaximumRetainedItems: standard.hardMaximumRetainedItems,
            userMaximumUnpinnedLowerBound: standard.userMaximumUnpinnedRange.lowerBound,
            userMaximumUnpinnedUpperBound: standard.userMaximumUnpinnedRange.upperBound,
            defaultMaximumUnpinnedItems: standard.defaultMaximumUnpinnedItems,
            maximumSourceApplicationObservationUTF8Bytes: standard.maximumSourceApplicationObservationUTF8Bytes,
            maximumStoredTitleUTF8Bytes: standard.maximumStoredTitleUTF8Bytes,
            maximumStoredSearchBodyUTF8Bytes: standard.maximumStoredSearchBodyUTF8Bytes,
            pageRowLimitLowerBound: standard.pageRowLimitRange.lowerBound,
            pageRowLimitUpperBound: standard.pageRowLimitRange.upperBound,
            maximumSearchTermUTF8Bytes: standard.maximumSearchTermUTF8Bytes,
            maximumRegexpPatternCharacters: standard.maximumRegexpPatternCharacters,
            maximumFuzzyQueryCharacters: standard.maximumFuzzyQueryCharacters,
            maximumFuzzyTitleBodyPrefixCharacters: standard.maximumFuzzyTitleBodyPrefixCharacters,
            maximumRegexpTitleBodyPrefixCharacters: standard.maximumRegexpTitleBodyPrefixCharacters,
            maximumBodySearchSnippetCharacters: standard.maximumBodySearchSnippetCharacters,
            thumbnailDimensionLowerBound: standard.thumbnailDimensionRange.lowerBound,
            thumbnailDimensionUpperBound: standard.thumbnailDimensionRange.upperBound,
            maximumEncodedThumbnailBytes: standard.maximumEncodedThumbnailBytes
        )
        return try #require(limits, "the four-byte capacity fixture must satisfy every HistoryLimits constraint")
    }
}
